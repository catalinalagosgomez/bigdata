-- =============================================================================
--  MODELO DE DATOS REAL TIME  (BigQuery)
--  Proyecto Big Data Real Time - DUOC | Catalina Lagos
-- -----------------------------------------------------------------------------
--  Flujo:  API DUOC -> Cloud Run (webhook) -> Pub/Sub "flujoeventos"
--          -> Dataflow (plantilla Pub/Sub Subscription to BigQuery)
--          -> StreamAnalytics.EventosBruto  (capa RAW, append continuo)
--          -> ESTE SCRIPT construye la capa LIMPIA y los MARTS (ELT)
--
--  ENFOQUE: ELT. Dataflow carga el JSON crudo tal cual (RAW) y BigQuery
--  ejecuta la transformacion. Es el mismo criterio del Informe 2 (batch).
--
--  NOTA: reemplazar el dataset si corresponde. Aqui se asume que el dataset
--  "StreamAnalytics" vive en el proyecto activo de la sesion de BigQuery.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0) TABLA DE AUDITORIA  (REGISTRO DE ACTIVIDAD de los procesos ELT)
--    Append-only: cada corrida del refresco inserta una fila con su resultado.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `StreamAnalytics.registro_procesos` (
  job_id        STRING    DEFAULT GENERATE_UUID(),
  proceso       STRING,                 -- p.ej. 'etl_limpia', 'merge_dedup'
  estado        STRING,                 -- OK | ERROR | SIN_DATOS
  filas_origen  INT64,
  filas_destino INT64,
  filas_dup     INT64,                  -- duplicados eliminados
  mensaje       STRING,
  fecha_ejec    TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- -----------------------------------------------------------------------------
-- 1) DIMENSION DE PRODUCTOS (enriquecimiento por sector del "activo")
--    Los productos de la subasta son companias tecnologicas cuyo precio fluctua.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `StreamAnalytics.dim_instrumento` AS
SELECT * FROM UNNEST([
  STRUCT('Nvidia'     AS producto, 'Semiconductores' AS sector),
  STRUCT('Apple',         'Hardware'),
  STRUCT('Cisco',         'Redes / Hardware'),
  STRUCT('Microsoft',     'Software / Cloud'),
  STRUCT('Alphabet',      'Software / Cloud'),
  STRUCT('Meta',          'Software / Cloud'),
  STRUCT('Salesforce',    'Software / Cloud'),
  STRUCT('Amazon',        'Servicios / Retail'),
  STRUCT('Disney',        'Servicios / Media')
]);

-- -----------------------------------------------------------------------------
-- 2) PROCEDIMIENTO DE REFRESCO DE LA CAPA LIMPIA + MARTS  (sp_refrescar_curada)
--    Encapsula toda la transformacion ELT en un solo objeto reutilizable:
--    se ejecuta una vez aqui (al final) y luego lo invoca la scheduled query
--    del archivo 03 (refresco periodico idempotente).
--
--    Cubre los 6 aspectos de la rubrica IL 3.2:
--      NORMALIZACION   -> SAFE_CAST de tipos, TRIM/INITCAP, forma_pago estandar
--      DEDUPLICACION   -> ROW_NUMBER por (id_cliente, id_producto, fecreg)
--      LIMPIEZA        -> descarta NULLs en claves y montos no positivos
--      VALIDACION      -> coherencia monto ~= precio * cantidad, genero valido
--      ENRIQUECIMIENTO -> fecha/hora/dia, franja horaria, sector, monto_calc
--      AGREGACION      -> marts pre-calculados
--    La capa limpia queda particionada por dia e idempotente (CREATE OR REPLACE).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `StreamAnalytics.sp_refrescar_curada`()
BEGIN

CREATE OR REPLACE TABLE `StreamAnalytics.operaciones_curadas`
PARTITION BY DATE(fecreg)
CLUSTER BY producto, forma_pago AS
WITH base AS (
  SELECT
    -- NORMALIZACION de tipos (SAFE_CAST: si falla devuelve NULL, no rompe)
    SAFE_CAST(id_cliente  AS INT64)               AS id_cliente,
    INITCAP(TRIM(cliente))                        AS cliente,
    UPPER(TRIM(genero))                           AS genero,
    SAFE_CAST(id_producto AS INT64)               AS id_producto,
    INITCAP(TRIM(producto))                       AS producto,
    SAFE_CAST(precio   AS NUMERIC)                AS precio,
    SAFE_CAST(cantidad AS INT64)                  AS cantidad,
    SAFE_CAST(monto    AS NUMERIC)                AS monto,
    -- NORMALIZACION de la forma de pago a un set controlado
    CASE UPPER(TRIM(forma_pago))
      WHEN 'CREDITO'  THEN 'Credito'
      WHEN 'CRÉDITO'  THEN 'Credito'
      WHEN 'DEBITO'   THEN 'Debito'
      WHEN 'DÉBITO'   THEN 'Debito'
      WHEN 'EFECTIVO' THEN 'Efectivo'
      ELSE INITCAP(TRIM(forma_pago))
    END                                           AS forma_pago,
    -- NORMALIZACION de la fecha: castea string ISO a TIMESTAMP (no rompe si ya lo es)
    SAFE_CAST(fecreg AS TIMESTAMP)                AS fecreg
  FROM `StreamAnalytics.EventosBruto`
),
dedup AS (
  -- DEDUPLICACION: en streaming Pub/Sub es at-least-once; ademas el proceso
  -- puede reejecutarse. Conservamos 1 fila por combinacion logica del registro.
  SELECT *, ROW_NUMBER() OVER (
            PARTITION BY id_cliente, id_producto, fecreg, monto
            ORDER BY fecreg
          ) AS rn
  FROM base
)
SELECT
  d.id_cliente, d.cliente, d.genero,
  d.id_producto, d.producto, d.precio, d.cantidad, d.monto, d.forma_pago,
  d.fecreg,
  -- ENRIQUECIMIENTO temporal
  DATE(d.fecreg)                                  AS fecha,
  EXTRACT(HOUR FROM d.fecreg)                     AS hora,
  FORMAT_TIMESTAMP('%A', d.fecreg)                AS dia_semana,
  CASE
    WHEN EXTRACT(HOUR FROM d.fecreg) BETWEEN 0  AND 5  THEN 'Madrugada'
    WHEN EXTRACT(HOUR FROM d.fecreg) BETWEEN 6  AND 11 THEN 'Manana'
    WHEN EXTRACT(HOUR FROM d.fecreg) BETWEEN 12 AND 17 THEN 'Tarde'
    ELSE 'Noche'
  END                                             AS franja_horaria,
  -- ENRIQUECIMIENTO por dimension de producto
  COALESCE(p.sector, 'Sin clasificar')            AS sector,
  -- VALIDACION de coherencia: monto declarado vs precio*cantidad
  ROUND(d.precio * d.cantidad, 2)                 AS monto_calculado,
  ABS(d.monto - ROUND(d.precio * d.cantidad, 2)) <= 0.5 AS monto_coherente,
  'REALTIME'                                      AS origen,
  CURRENT_TIMESTAMP()                             AS cargado_en
FROM dedup d
LEFT JOIN `StreamAnalytics.dim_instrumento` p
       ON UPPER(d.producto) = UPPER(p.producto)
WHERE d.rn = 1                          -- DEDUPLICACION
  AND d.id_cliente   IS NOT NULL        -- LIMPIEZA: clave obligatoria
  AND d.id_producto  IS NOT NULL
  AND d.fecreg       IS NOT NULL
  AND d.precio   > 0                     -- VALIDACION / LIMPIEZA
  AND d.cantidad > 0
  AND d.monto    > 0
  AND d.genero IN ('H', 'M');           -- VALIDACION de dominio

-- -----------------------------------------------------------------------------
-- 3) MARTS  (AGREGACION pre-calculada para los dashboards y las 3 preguntas)
-- -----------------------------------------------------------------------------

-- 3.1 Mart por producto: volumen, recaudacion y volatilidad de precio (subasta)
CREATE OR REPLACE TABLE `StreamAnalytics.mart_instrumento` AS
SELECT
  producto,
  ANY_VALUE(sector)                 AS sector,
  COUNT(*)                          AS n_flujoeventos,
  SUM(cantidad)                     AS unidades,
  SUM(monto)                        AS monto_total,
  ROUND(AVG(precio), 2)             AS precio_prom,
  MIN(precio)                       AS precio_min,
  MAX(precio)                       AS precio_max,
  ROUND(MAX(precio) - MIN(precio), 2)               AS rango_precio,   -- volatilidad
  ROUND(SAFE_DIVIDE(STDDEV(precio), AVG(precio)), 4) AS coef_variacion -- volatilidad relativa
FROM `StreamAnalytics.operaciones_curadas`
GROUP BY producto;

-- 3.2 Mart por forma de pago
CREATE OR REPLACE TABLE `StreamAnalytics.mart_forma_pago` AS
SELECT
  forma_pago,
  COUNT(*)              AS n_flujoeventos,
  SUM(monto)            AS monto_total,
  ROUND(AVG(monto), 2)  AS ticket_promedio
FROM `StreamAnalytics.operaciones_curadas`
GROUP BY forma_pago;

-- 3.3 Mart serie temporal por minuto (para ver el flujo real time en el dashboard)
CREATE OR REPLACE TABLE `StreamAnalytics.mart_flujo_minuto` AS
SELECT
  TIMESTAMP_TRUNC(fecreg, MINUTE) AS minuto,
  producto,
  COUNT(*)              AS n_flujoeventos,
  SUM(monto)            AS monto_total,
  ROUND(AVG(precio), 2) AS precio_prom
FROM `StreamAnalytics.operaciones_curadas`
GROUP BY minuto, producto;

END;   -- fin del procedimiento sp_refrescar_curada

-- Materializa la capa limpia y los marts por primera vez.
CALL `StreamAnalytics.sp_refrescar_curada`();

-- -----------------------------------------------------------------------------
-- 4) VISTA DE CALIDAD  (VALIDACION DE DATOS Y PROCESOS)
--    Compara RAW vs LIMPIA y reporta % de descarte y duplicados.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW `StreamAnalytics.v_control_calidad` AS
WITH raw AS  (SELECT COUNT(*) n FROM `StreamAnalytics.EventosBruto`),
     cln AS  (SELECT COUNT(*) n FROM `StreamAnalytics.operaciones_curadas`)
SELECT
  raw.n                                   AS filas_raw,
  cln.n                                   AS filas_clean,
  raw.n - cln.n                           AS filas_descartadas,
  ROUND(SAFE_DIVIDE(raw.n - cln.n, raw.n) * 100, 2) AS pct_descarte
FROM raw, cln;
