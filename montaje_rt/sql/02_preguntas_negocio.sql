-- =============================================================================
--  3 PREGUNTAS DE NEGOCIO - REAL TIME  (IL 3.3 - USO/CONSUMO E INSIGHTS)
--  Proyecto Big Data Real Time - DUOC | Catalina Lagos
--  Cada query se ejecuta sobre la capa LIMPIA y alimenta un grafico Looker.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PREGUNTA 1: ¿Cuales son los productos (activos) con mayor monto transado y
--             cual es su precio promedio en tiempo real?
-- Grafico sugerido: barra horizontal (producto vs monto_total).
-- Insight: en que activos se concentra la demanda y el dinero de la subasta.
-- -----------------------------------------------------------------------------
SELECT
  producto,
  sector,
  n_flujoeventos,
  unidades,
  monto_total,
  precio_prom
FROM `StreamAnalytics.mart_instrumento`
ORDER BY monto_total DESC
LIMIT 10;

-- -----------------------------------------------------------------------------
-- PREGUNTA 2: ¿Que productos presentan mayor VOLATILIDAD de precio?
--             (rango precio_max - precio_min y coeficiente de variacion)
-- Grafico sugerido: columnas (producto vs rango_precio) o scatter precio_prom
--                   vs coef_variacion.
-- Insight: nucleo del caso "subasta": que activos fluctuan mas -> mas riesgo
--          y oportunidad de arbitraje en tiempo real.
-- -----------------------------------------------------------------------------
SELECT
  producto,
  sector,
  precio_min,
  precio_max,
  precio_prom,
  rango_precio,
  coef_variacion
FROM `StreamAnalytics.mart_instrumento`
WHERE n_flujoeventos >= 5          -- umbral defensivo: evita volatilidad espuria
ORDER BY rango_precio DESC
LIMIT 10;

-- -----------------------------------------------------------------------------
-- PREGUNTA 3: ¿Como se distribuye la recaudacion por forma de pago y como
--             evoluciona el flujo de flujoeventos en el tiempo (real time)?
-- Grafico sugerido: dona/torta (forma_pago vs monto_total) + serie temporal.
-- Insight: comportamiento de pago y pulso de la subasta minuto a minuto.
-- -----------------------------------------------------------------------------
-- 3a) Distribucion por forma de pago
SELECT
  forma_pago,
  n_flujoeventos,
  monto_total,
  ROUND(SAFE_DIVIDE(monto_total, SUM(monto_total) OVER ()) * 100, 2) AS pct_monto,
  ticket_promedio
FROM `StreamAnalytics.mart_forma_pago`
ORDER BY monto_total DESC;

-- 3b) Pulso real time: recaudacion por minuto (ultimos 60 minutos)
SELECT
  minuto,
  SUM(n_flujoeventos) AS flujoeventos,
  SUM(monto_total)     AS monto_total
FROM `StreamAnalytics.mart_flujo_minuto`
WHERE minuto >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 60 MINUTE)
GROUP BY minuto
ORDER BY minuto;
