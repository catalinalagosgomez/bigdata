#!/usr/bin/env bash
# =============================================================================
#  PASO 2 - WEBHOOK  (se despliega como SERVICIO Cloud Run -> evita el bucket
#  .appspot.com que el lab bloquea, y usa la REGION permitida detectada).
#  Idempotente: re-desplegar simplemente actualiza el servicio.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./00_variables.sh

echo "==> Asegurando repositorio Artifact Registry en $REGION..."
if ! gcloud artifacts repositories describe cloud-run-source-deploy \
        --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create cloud-run-source-deploy \
    --repository-format=docker --location="$REGION" --project="$PROJECT_ID"
fi

echo "==> Desplegando webhook '$SERVICIO' como Cloud Run (Python 3.10)..."
gcloud run deploy "$SERVICIO" \
  --source=./funcion \
  --function=main \
  --region="$REGION" \
  --allow-unauthenticated \
  --set-env-vars="GCP_PROJECT=${PROJECT_ID},PUBSUB_TOPIC=${TOPICO}" \
  --project="$PROJECT_ID" \
  --quiet

echo "==> Permiso 'Pub/Sub Publisher' a la cuenta de servicio..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_COMPUTE}" \
  --role="roles/pubsub.publisher" \
  --condition=None >/dev/null
echo "    permiso asignado"

URL="$(gcloud run services describe "$SERVICIO" --region="$REGION" \
        --project="$PROJECT_ID" --format='value(status.url)')"
echo "$URL" > URL_WEBHOOK.txt

echo ""
echo "============================================================"
echo "   COPIA ESTA URL (es tu WEBHOOK) Y REGISTRALA EN:"
echo "   https://bdrealtimeescuelait.duoc.cl  ->  Registro de URL"
echo ""
echo "   >>>  $URL  <<<"
echo "============================================================"
echo "(tambien quedo en montaje_rt/URL_WEBHOOK.txt)"
