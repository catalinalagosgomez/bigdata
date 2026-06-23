#!/usr/bin/env bash
# =============================================================================
#  PASO 3 - DATAFLOW (plantilla Pub/Sub Subscription to BigQuery) en la REGION valida.
#  Idempotente: si ya hay un job activo con el mismo nombre, no crea otro.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./00_variables.sh

echo "==> Revisando si ya hay un job '$JOB_DF' activo..."
ACTIVO="$(gcloud dataflow jobs list --region="$REGION" --status=active \
            --filter="name=${JOB_DF}" --format='value(JOB_ID)' \
            --project="$PROJECT_ID" 2>/dev/null | head -n1 || true)"
if [ -n "$ACTIVO" ]; then
  echo "    Ya hay un job activo ($ACTIVO). No se crea otro."
  exit 0
fi

echo "==> Asegurando permisos de Dataflow (idempotente, por si el lab los quita)..."
gcloud beta services identity create --service=dataflow.googleapis.com --project="$PROJECT_ID" >/dev/null 2>&1 || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@dataflow-service-producer-prod.iam.gserviceaccount.com" \
  --role="roles/dataflow.serviceAgent" --condition=None >/dev/null 2>&1 || true
for R in roles/dataflow.worker roles/bigquery.dataEditor roles/bigquery.jobUser \
         roles/pubsub.subscriber roles/storage.objectAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_COMPUTE}" --role="$R" --condition=None >/dev/null 2>&1 || true
done
echo "    permisos verificados; esperando 60s a que propaguen antes de lanzar..."
sleep 60

echo "==> Habilitando Private Google Access en la subred default (por si el lab bloquea IPs publicas)..."
gcloud compute networks subnets update default --region="$REGION" \
  --enable-private-ip-google-access --project="$PROJECT_ID" >/dev/null 2>&1 \
  && echo "    PGA habilitado" || echo "    (no se pudo o ya estaba; continua igual)"

echo "==> Lanzando job de Dataflow '$JOB_DF' en $REGION (sin IP publica)..."
gcloud dataflow jobs run "$JOB_DF" \
  --gcs-location="gs://dataflow-templates-${REGION}/latest/PubSub_Subscription_to_BigQuery" \
  --region="$REGION" \
  --staging-location="gs://${BUCKET}/temp" \
  --disable-public-ips \
  --subnetwork="regions/${REGION}/subnetworks/default" \
  --project="$PROJECT_ID" \
  --parameters="inputSubscription=projects/${PROJECT_ID}/subscriptions/${SUSCRIPCION},outputTableSpec=${PROJECT_ID}:${DATASET}.${TABLA}"

echo ""
echo "[OK] Job enviado. Espera 3-5 min a que aparezca 'Running' (Consola -> Dataflow -> Jobs)."
echo "    RECUERDA: detener el job (Stop) cuando termines, para no gastar creditos."
