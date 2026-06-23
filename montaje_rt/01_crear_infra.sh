#!/usr/bin/env bash
# =============================================================================
#  PASO 1 - INFRAESTRUCTURA DE DESTINO  (idempotente: se puede correr varias veces)
#  Crea: APIs, topico + suscripcion Pub/Sub, dataset + tabla BigQuery y bucket temporal.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source ./00_variables.sh

echo "==> Habilitando APIs necesarias..."
gcloud services enable \
  run.googleapis.com cloudfunctions.googleapis.com pubsub.googleapis.com \
  dataflow.googleapis.com bigquery.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com eventarc.googleapis.com \
  --project="$PROJECT_ID"

echo "==> Configurando permisos para Dataflow (labs nuevos suelen quitarlos)..."
# Agente de servicio de Dataflow (lo crea si no existe) + su rol
gcloud beta services identity create --service=dataflow.googleapis.com --project="$PROJECT_ID" >/dev/null 2>&1 || true
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@dataflow-service-producer-prod.iam.gserviceaccount.com" \
  --role="roles/dataflow.serviceAgent" --condition=None >/dev/null 2>&1 || true
# Roles a la cuenta worker (compute por defecto)
for R in roles/dataflow.worker roles/bigquery.dataEditor roles/bigquery.jobUser \
         roles/pubsub.subscriber roles/storage.objectAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_COMPUTE}" --role="$R" --condition=None >/dev/null 2>&1 || true
done
echo "    permisos de Dataflow configurados"

echo "==> Topico Pub/Sub '$TOPICO'..."
if gcloud pubsub topics describe "$TOPICO" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "    ya existe"
else
  gcloud pubsub topics create "$TOPICO" --project="$PROJECT_ID"
fi

echo "==> Suscripcion '$SUSCRIPCION'..."
if gcloud pubsub subscriptions describe "$SUSCRIPCION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "    ya existe"
else
  gcloud pubsub subscriptions create "$SUSCRIPCION" --topic="$TOPICO" --project="$PROJECT_ID"
fi

echo "==> Dataset BigQuery '$DATASET' (location $BQ_LOCATION)..."
if bq show "${PROJECT_ID}:${DATASET}" >/dev/null 2>&1; then
  echo "    ya existe"
else
  bq --location="$BQ_LOCATION" mk --dataset "${PROJECT_ID}:${DATASET}"
fi

echo "==> Tabla '$TABLA' (esquema de 10 columnas)..."
if bq show "${PROJECT_ID}:${DATASET}.${TABLA}" >/dev/null 2>&1; then
  echo "    ya existe"
else
  bq mk --table "${PROJECT_ID}:${DATASET}.${TABLA}" ./esquema_EventosBruto.json
fi

echo "==> Bucket temporal gs://$BUCKET (region $REGION)..."
if gsutil ls -b "gs://$BUCKET" >/dev/null 2>&1; then
  echo "    ya existe"
else
  gsutil mb -l "$REGION" -p "$PROJECT_ID" "gs://$BUCKET"
fi

echo ""
echo "[OK] Infraestructura de destino lista."
