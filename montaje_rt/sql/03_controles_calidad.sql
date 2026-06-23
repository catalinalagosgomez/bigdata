-- =============================================================================
--  CONTROLES TRANSVERSALES EN BIGQUERY - REAL TIME
--  Proyecto Big Data Real Time - DUOC | Catalina Lagos
--  Cubre, en la capa de datos: control de errores, duplicidad, registro de
--  actividad y validacion. Pensado para correr como SCHEDULED QUERY periodica.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A) REFRESCO IDEMPOTENTE CON REGISTRO DE ACTIVIDAD Y CONTROL DE ERRORES
--    Script BigQuery (BEGIN ... EXCEPTION) que reconstruye la capa limpia,
--    cuenta duplicados eliminados y deja traza en registro_procesos.
--    -> CONTROL DE ERRORES   : bloque EXCEPTION captura cualquier fallo.
--    -> REGISTRO DE ACTIVIDAD: inserta fila OK / ERROR / SIN_DATOS.
--    -> CONTROL DE DUPLICIDAD: compara filas RAW vs filas tras deduplicar.
--    Programar en BigQuery -> Scheduled queries (p.ej. cada 5 o 15 minutos).
-- -----------------------------------------------------------------------------
BEGIN
  DECLARE v_raw   INT64;
  DECLARE v_clean INT64;

  SET v_raw = (SELECT COUNT(*) FROM `StreamAnalytics.EventosBruto`);

  IF v_raw = 0 THEN
    -- VALIDACION: escenario "no llegaron datos en el periodo".
    INSERT INTO `StreamAnalytics.registro_procesos`
      (proceso, estado, filas_origen, filas_destino, filas_dup, mensaje)
    VALUES ('etl_limpia', 'SIN_DATOS', 0, 0, 0,
            'No hay registros en EventosBruto; se omite el refresco.');
  ELSE
    -- Reconstruye la capa limpia (la logica completa vive en 01_modelo_realtime.sql).
    CALL `StreamAnalytics`.sp_refrescar_curada();   -- opcional si se encapsula en SP

    SET v_clean = (SELECT COUNT(*) FROM `StreamAnalytics.operaciones_curadas`);

    INSERT INTO `StreamAnalytics.registro_procesos`
      (proceso, estado, filas_origen, filas_destino, filas_dup, mensaje)
    VALUES ('etl_limpia', 'OK', v_raw, v_clean, v_raw - v_clean,
            'Refresco de capa limpia completado.');
  END IF;

EXCEPTION WHEN ERROR THEN
  INSERT INTO `StreamAnalytics.registro_procesos`
    (proceso, estado, filas_origen, filas_destino, filas_dup, mensaje)
  VALUES ('etl_limpia', 'ERROR', NULL, NULL, NULL,
          @@error.message);                  -- mensaje real del error
END;

-- -----------------------------------------------------------------------------
-- B) DETECCION DE INTERRUPCION DEL FLUJO REAL TIME (VALIDACION DE PROCESOS)
--    Responde a la pregunta de la rubrica: "¿como manejaria el escenario donde
--    en un periodo de tiempo no se hayan recibido datos?".
--    Si el ultimo registro tiene mas de 5 minutos -> alerta SIN_DATOS.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `StreamAnalytics.v_monitor_flujo` AS
SELECT
  MAX(fecreg)                                            AS ultimo_registro,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(fecreg), MINUTE) AS minutos_sin_datos,
  CASE
    WHEN TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(fecreg), MINUTE) > 5
      THEN 'ALERTA: flujo detenido'
    ELSE 'OK: flujo activo'
  END                                                    AS estado_flujo
FROM `StreamAnalytics.operaciones_curadas`;

-- -----------------------------------------------------------------------------
-- C) CONTROL DE DUPLICIDAD EXPLICITO (auditoria)
--    Lista combinaciones logicas repetidas en la capa RAW. Deberia dar 0 filas
--    despues de la deduplicacion de la capa limpia.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `StreamAnalytics.v_duplicidad` AS
SELECT
  id_cliente, id_producto, fecreg, monto, COUNT(*) AS repeticiones
FROM `StreamAnalytics.EventosBruto`
GROUP BY id_cliente, id_producto, fecreg, monto
HAVING COUNT(*) > 1;

-- -----------------------------------------------------------------------------
-- D) INTEGRACION BATCH + REAL TIME  (FUENTE INTEGRADA)
--    La rubrica advierte que parte de los datos pudo cargarse en la etapa 2
--    (batch). Esta vista unifica ambas fuentes y deduplica por huella logica,
--    marcando el 'origen'. Si no existe tabla historica batch, devuelve solo RT.
--    (Crear `StreamAnalytics.operaciones_batch` con el mismo esquema si aplica.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `StreamAnalytics.v_integracion_fuentes` AS
WITH unificado AS (
  SELECT id_cliente, cliente, genero, id_producto, producto,
         precio, cantidad, monto, forma_pago, fecreg, origen
  FROM `StreamAnalytics.operaciones_curadas`
  -- UNION ALL con la fuente batch historica cuando exista:
  -- SELECT ..., 'BATCH' AS origen FROM `StreamAnalytics.operaciones_batch`
),
dedup AS (
  SELECT *, ROW_NUMBER() OVER (
            PARTITION BY id_cliente, id_producto, fecreg, monto
            ORDER BY origen) AS rn   -- prioriza una sola version del registro
  FROM unificado
)
SELECT * EXCEPT(rn) FROM dedup WHERE rn = 1;
