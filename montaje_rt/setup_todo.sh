#!/usr/bin/env bash
# =============================================================================
#  ORQUESTADOR MAESTRO - PIPELINE REAL TIME
#  Corre todo en orden y solo se detiene para que TU registres la URL del
#  webhook en la pagina del profe. Equivale al orquestador de la Eval 2.
#
#  Uso en Cloud Shell:   bash setup_todo.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

echo "############################################################"
echo "#  SETUP RAPIDO - PIPELINE REAL TIME                       #"
echo "############################################################"
source ./00_variables.sh
echo ""

read -p "¿Continuar con esta configuracion? (ENTER para si / Ctrl+C para cancelar) "

# --- 1) Infraestructura de destino ---
bash ./01_crear_infra.sh

# --- 2) Webhook (Cloud Run) ---
bash ./02_desplegar_webhook.sh

echo ""
echo "============================================================"
echo "  ACCION MANUAL (sigue la GUIA Pub/Sub del profe):"
echo "  1. Copia la URL de arriba (o de URL_WEBHOOK.txt)."
echo "  2. Entra a https://bdrealtimeescuelait.duoc.cl"
echo "  3. Pegala en 'Registro de URL' y pulsa Registrar."
echo "  4. Activa el envio de datos."
echo "============================================================"
read -p "Cuando hayas REGISTRADO la URL, presiona ENTER para arrancar Dataflow... "

# --- 3) Dataflow (streaming a BigQuery) ---
bash ./03_crear_dataflow.sh

echo ""
echo "Deja que los datos fluyan unos 15-30 minutos (arma los dashboards mientras)."
read -p "Cuando ya haya datos acumulados, presiona ENTER para correr la TRANSFORMACION... "

# --- 4) Transformacion ELT ---
bash ./04_transformacion.sh

echo ""
echo "############################################################"
echo "#  LISTO. Solo falta: armar los 2 dashboards en Looker.    #"
echo "#  Ver LEEME.md -> seccion LOOKER.                          #"
echo "#  NO OLVIDES: detener el job de Dataflow al terminar.      #"
echo "############################################################"
