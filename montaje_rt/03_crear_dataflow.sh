#!/usr/bin/env bash
# =============================================================================
#  PASO 3 - DATAFLOW (plantilla Pub/Sub Subscription to BigQuery) en la REGION valida.
#  Idempotente: si ya hay un job activo con el mismo nombre, no crea otro.
#
#  REINTENTO AUTOMATICO DE ZONA: los labs comparten cuota y a veces la zona
#  elegida devuelve ZONE_RESOURCE_POOL_EXHAUSTED (no hay maquinas libres). Este
#  script prueba varias zonas de la REGION en orden: lanza el job fijando una
#  zona, vigila el arranque y, si esa zona no levanta el worker, cancela y pasa
#  a la siguiente. Puedes forzar una zona concreta:  export WORKER_ZONE=us-east1-c
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

# --- Zonas candidatas dentro de la REGION (override con WORKER_ZONE=...) ------
if [ -n "${WORKER_ZONE:-}" ]; then
  ZONAS="$WORKER_ZONE"
else
  ZONAS="${REGION}-b ${REGION}-c ${REGION}-d ${REGION}-a"
fi

# Lanza el job fijado a una zona y vigila que llegue a RUNNING.
#   return 0 -> arranco bien (RUNNING)        return 1 -> esa zona no sirvio
lanzar_en_zona() {
  local zona="$1" jid estado i
  echo "==> Lanzando '$JOB_DF' en zona $zona (sin IP publica)..."
  jid="$(gcloud dataflow jobs run "$JOB_DF" \
    --gcs-location="gs://dataflow-templates-${REGION}/latest/PubSub_Subscription_to_BigQuery" \
    --region="$REGION" \
    --worker-zone="$zona" \
    --staging-location="gs://${BUCKET}/temp" \
    --disable-public-ips \
    --subnetwork="regions/${REGION}/subnetworks/default" \
    --project="$PROJECT_ID" \
    --parameters="inputSubscription=projects/${PROJECT_ID}/subscriptions/${SUSCRIPCION},outputTableSpec=${PROJECT_ID}:${DATASET}.${TABLA}" \
    --format='value(id)' 2>/dev/null)" || jid=""
  if [ -z "$jid" ]; then
    echo "    no se pudo enviar el job a $zona; pruebo otra zona."
    return 1
  fi
  echo "    job_id=$jid ; vigilando arranque (hasta ~5 min)..."
  for i in $(seq 1 30); do
    sleep 10
    estado="$(gcloud dataflow jobs describe "$jid" --region="$REGION" \
                --project="$PROJECT_ID" --format='value(currentState)' 2>/dev/null || true)"
    case "$estado" in
      JOB_STATE_RUNNING)
        echo ""
        echo "    [OK] job RUNNING en zona $zona  (job_id=$jid)"
        return 0;;
      JOB_STATE_FAILED|JOB_STATE_CANCELLED)
        echo ""
        echo "    [X] zona $zona sin recursos (estado=$estado); pruebo la siguiente."
        return 1;;
      *)
        printf '.';;
    esac
  done
  # No llego a RUNNING en el tiempo de espera: lo cancelo y pruebo otra zona.
  echo ""
  echo "    [X] zona $zona no llego a RUNNING (estado=$estado); cancelo y pruebo otra."
  gcloud dataflow jobs cancel "$jid" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 || true
  sleep 15
  return 1
}

ARRANCO=""
for Z in $ZONAS; do
  if lanzar_en_zona "$Z"; then
    ARRANCO="$Z"
    break
  fi
done

echo ""
if [ -n "$ARRANCO" ]; then
  echo "[OK] Dataflow arrancando en $REGION (zona $ARRANCO)."
  echo "    Espera 3-5 min y revisa Consola -> Dataflow -> Jobs (debe quedar Running)."
  echo "    RECUERDA: detener el job (Stop) cuando termines, para no gastar creditos."
else
  echo "[X] Ninguna zona de $REGION tenia recursos en este momento."
  echo "    Opciones:"
  echo "      1) Reintenta en unos minutos:  bash 03_crear_dataflow.sh"
  echo "      2) Cambia de region:"
  echo "           export REGION=us-east4   # o us-west1 / us-central1"
  echo "           rm -f .region"
  echo "           bash 01_crear_infra.sh && bash 03_crear_dataflow.sh"
  exit 1
fi
