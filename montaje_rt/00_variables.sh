#!/usr/bin/env bash
# =============================================================================
#  CONFIGURACION CENTRAL + DETECCION AUTOMATICA DE REGION
#  Algunos labs bloquean us-central1 por org policy (constraints/gcp.resourceLocations).
#  Este archivo detecta una region PERMITIDA y la cachea en .region
#  (los demas scripts hacen 'source' de este archivo).
#
#  Si ya sabes la region permitida (la dice el panel del lab), puedes forzarla:
#     export REGION=us-east1   &&   bash setup_todo.sh
# =============================================================================

export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null)"

REGION_CACHE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.region"

_detectar_region() {
  local cands="" r probe
  # 1) Pistas desde la org policy (si hay permiso de lectura)
  if command -v jq >/dev/null 2>&1; then
    cands=$(gcloud org-policies describe gcp.resourceLocations \
              --project="$PROJECT_ID" --effective --format=json 2>/dev/null \
            | jq -r '.spec.rules[]?.values.allowedValues[]?' 2>/dev/null \
            | sed -E 's/^in://; s/-locations$//')
  fi
  # 2) Lista de respaldo (US primero, porque BigQuery US funciona en este lab)
  cands="$cands us-east1 us-east4 us-west1 us-west4 us-central1 \
         northamerica-northeast1 southamerica-east1 \
         europe-west1 europe-west4 asia-east1 asia-southeast1 australia-southeast1"
  # 3) Probar creando un bucket chico: la 1a region que lo permita es la valida
  probe="gs://${PROJECT_ID}-rgnprobe-$(date +%s)"
  for r in $cands; do
    case "$r" in us|eu|asia|global|"") continue;; esac     # saltar multi-regiones
    if gsutil mb -l "$r" -p "$PROJECT_ID" "$probe" >/dev/null 2>&1; then
      gsutil rb "$probe" >/dev/null 2>&1
      echo "$r"; return 0
    fi
  done
  return 1
}

if [ -n "${REGION:-}" ]; then
  :                                            # respeta REGION si viene del entorno
elif [ -f "$REGION_CACHE" ]; then
  REGION="$(cat "$REGION_CACHE")"              # usa la cacheada
else
  echo "Detectando una region permitida por el lab (puede tardar unos segundos)..." >&2
  REGION="$(_detectar_region || true)"
  if [ -z "$REGION" ]; then
    echo "[AVISO] No pude detectar una region permitida automaticamente." >&2
    echo "        Mira en el panel del lab cual region usar y corre:  export REGION=esa-region" >&2
    REGION="us-east1"
  else
    echo "$REGION" > "$REGION_CACHE"
    echo "Region permitida detectada: $REGION  (guardada en .region)" >&2
  fi
fi
export REGION

# --- Recursos (coinciden con la Guia Pub/Sub del profe) ---
export TOPICO="flujoeventos"
export SUSCRIPCION="flujoeventos-sub"
export SERVICIO="receptorstream"
export DATASET="StreamAnalytics"
export TABLA="EventosBruto"
export BQ_LOCATION="US"                         # multi-region permitida en el lab
export BUCKET="${PROJECT_ID}-flujo-stg"
export JOB_DF="streamHaciaBQ"
export SA_COMPUTE="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "  PROJECT_ID   = $PROJECT_ID"
echo "  REGION       = $REGION   (BigQuery: $BQ_LOCATION)"
echo "  TOPICO/SUB   = $TOPICO / $SUSCRIPCION"
echo "  SERVICIO     = $SERVICIO"
echo "  DATASET.TBL  = $DATASET.$TABLA"
echo "  BUCKET       = gs://$BUCKET"
