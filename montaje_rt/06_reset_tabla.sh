#!/usr/bin/env bash
# =============================================================================
#  RECUPERACION - usar si los datos rebotan a la tabla de errores o filas=0.
#  Para Dataflow, recrea EventosBruto como tabla TODO-STRING (acepta cualquier dato)
#  y relanza el streaming. No toca el webhook ni la URL registrada.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./00_variables.sh

echo "==> Cancelando jobs de Dataflow activos..."
gcloud dataflow jobs list --region="$REGION" --status=active \
  --format='value(JOB_ID)' --project="$PROJECT_ID" 2>/dev/null \
 | while read -r J; do
     [ -n "$J" ] && gcloud dataflow jobs cancel "$J" --region="$REGION" --project="$PROJECT_ID" || true
   done
echo "    (esperando 20s a que liberen la tabla)"; sleep 20

echo "==> Recreando ${TABLA} como tabla TODO-STRING (landing crudo)..."
bq rm -f -t "${PROJECT_ID}:${DATASET}.${TABLA}"
bq mk --table "${PROJECT_ID}:${DATASET}.${TABLA}" ./esquema_EventosBruto.json

# Tambien borra la tabla de errores si existia
bq rm -f -t "${PROJECT_ID}:${DATASET}.${TABLA}_error_records" 2>/dev/null || true

echo "==> Relanzando Dataflow..."
bash ./03_crear_dataflow.sh

echo ""
echo "[OK] Tabla recreada (todo-STRING) y Dataflow relanzado."
echo "     Espera ~5 min, luego: bash 05_diagnostico.sh  y  bash 04_transformacion.sh"
