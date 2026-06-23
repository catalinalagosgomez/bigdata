-- =============================================================================
--  VISTA EN VIVO PARA LOOKER  (limpieza al vuelo, en tiempo real)
--  Proyecto Big Data Real Time - DUOC | Catalina Lagos
-- -----------------------------------------------------------------------------
--  A diferencia de la TABLA operaciones_curadas (que es una foto del momento en que
--  se corre la transformacion), esta VISTA aplica la limpieza CADA VEZ que se
--  consulta. Por eso, si Looker se conecta a v_operaciones_vivo, al refrescar
--  muestra SIEMPRE todos los datos que hay en EventosBruto en ese instante,
--  incluidos los que acaban de llegar por streaming -> dashboard en tiempo real.
--
--  Mismos 6 aspectos que la capa limpia: normalizacion, dedup, limpieza,
--  validacion, enriquecimiento (la agregacion la hace Looker sobre la vista).
-- =============================================================================
CREATE OR REPLACE VIEW `StreamAnalytics.v_operaciones_vivo` AS
WITH base AS (
  SELECT
    SAFE_CAST(id_cliente  AS INT64)               AS id_cliente,
    INITCAP(TRIM(cliente))                        AS cliente,
    UPPER(TRIM(genero))                           AS genero,
    SAFE_CAST(id_producto AS INT64)               AS id_producto,
    INITCAP(TRIM(producto))                       AS producto,
    SAFE_CAST(precio   AS NUMERIC)                AS precio,
    SAFE_CAST(cantidad AS INT64)                  AS cantidad,
    SAFE_CAST(monto    AS NUMERIC)                AS monto,
    CASE UPPER(TRIM(forma_pago))
      WHEN 'CREDITO'  THEN 'Credito'
      WHEN 'CRÉDITO'  THEN 'Credito'
      WHEN 'DEBITO'   THEN 'Debito'
      WHEN 'DÉBITO'   THEN 'Debito'
      WHEN 'EFECTIVO' THEN 'Efectivo'
      ELSE INITCAP(TRIM(forma_pago))
    END                                           AS forma_pago,
    SAFE_CAST(fecreg AS TIMESTAMP)                AS fecreg
  FROM `StreamAnalytics.EventosBruto`
),
dedup AS (
  SELECT *, ROW_NUMBER() OVER (
            PARTITION BY id_cliente, id_producto, fecreg, monto
            ORDER BY fecreg) AS rn
  FROM base
)
SELECT
  d.id_cliente, d.cliente, d.genero, d.id_producto, d.producto,
  d.precio, d.cantidad, d.monto, d.forma_pago, d.fecreg,
  DATE(d.fecreg)                                  AS fecha,
  EXTRACT(HOUR FROM d.fecreg)                     AS hora,
  FORMAT_TIMESTAMP('%A', d.fecreg)                AS dia_semana,
  CASE
    WHEN EXTRACT(HOUR FROM d.fecreg) BETWEEN 0  AND 5  THEN 'Madrugada'
    WHEN EXTRACT(HOUR FROM d.fecreg) BETWEEN 6  AND 11 THEN 'Manana'
    WHEN EXTRACT(HOUR FROM d.fecreg) BETWEEN 12 AND 17 THEN 'Tarde'
    ELSE 'Noche'
  END                                             AS franja_horaria,
  COALESCE(p.sector, 'Sin clasificar')            AS sector,
  ROUND(d.precio * d.cantidad, 2)                 AS monto_calculado,
  TIMESTAMP_TRUNC(d.fecreg, MINUTE)               AS minuto
FROM dedup d
LEFT JOIN `StreamAnalytics.dim_instrumento` p
       ON UPPER(d.producto) = UPPER(p.producto)
WHERE d.rn = 1
  AND d.id_cliente  IS NOT NULL
  AND d.id_producto IS NOT NULL
  AND d.fecreg      IS NOT NULL
  AND d.precio   > 0
  AND d.cantidad > 0
  AND d.monto    > 0
  AND d.genero IN ('H', 'M');
