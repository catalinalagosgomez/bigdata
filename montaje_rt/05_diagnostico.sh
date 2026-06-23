#!/usr/bin/env bash
# =============================================================================
#  DIAGNOSTICO - revisa el estado de todo el pipeline de un vistazo.
#  Util cuando filas=0 para saber si es tema de tiempo o de tipos de datos.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ./00_variables.sh

echo ""
echo "=================== 1) JOBS DE DATAFLOW ==================="
gcloud dataflow jobs list --region="$REGION" --project="$PROJECT_ID" 2>/dev/null \
  || echo "(no pude listar jobs)"

echo ""
echo "=================== 2) TABLAS EN $DATASET ==================="
bq ls "$DATASET" 2>/dev/null || echo "(no pude listar)"

echo ""
echo "=================== 3) FILAS EN EventosBruto (crudo) ==================="
bq query --use_legacy_sql=false --project_id="$PROJECT_ID" \
  "SELECT COUNT(*) AS filas_raw FROM \`${PROJECT_ID}.${DATASET}.${TABLA}\`" 2>/dev/null \
  || echo "(sin datos aun)"

echo ""
echo "=================== 4) ¿TABLA DE ERRORES? ==================="
if bq show "${PROJECT_ID}:${DATASET}.${TABLA}_error_records" >/dev/null 2>&1; then
  echo ">> EXISTE ${TABLA}_error_records  (los datos estan rebotando por tipo de dato)"
  bq query --use_legacy_sql=false --project_id="$PROJECT_ID" \
    "SELECT COUNT(*) AS errores FROM \`${PROJECT_ID}.${DATASET}.${TABLA}_error_records\`" 2>/dev/null
  echo ">> SOLUCION: corre  ->  bash 06_reset_tabla.sh"
else
  echo "No hay tabla de errores (bien)."
fi

echo ""
echo "=================== 5) ULTIMOS REGISTROS ==================="
bq query --use_legacy_sql=false --project_id="$PROJECT_ID" \
  "SELECT id_cliente, producto, precio, monto, fecreg
   FROM \`${PROJECT_ID}.${DATASET}.${TABLA}\` ORDER BY fecreg DESC LIMIT 5" 2>/dev/null \
  || echo "(aun sin datos)"

echo ""
echo "Resumen: si el job esta RUNNING y filas_raw sube -> todo OK, corre 04_transformacion.sh"
echo "         si hay tabla de errores o filas_raw queda en 0 -> corre 06_reset_tabla.sh"
