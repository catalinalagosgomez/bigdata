# =============================================================================
#  CLOUD FUNCTION (Cloud Run) - INGESTA REAL TIME
#  Proyecto Big Data Real Time - DUOC | Catalina Lagos
#  Recibe el JSON que la API DUOC (bdrealtimeescuelait.duoc.cl) envia por POST
#  al webhook y lo publica en el topico de Pub/Sub "flujoeventos".
#
#  Entry point:   main
#  Runtime:       Python 3.10
#  requirements:  ver requirements.txt
#
#  Cubre los 4 controles transversales del PASO 1 (conexion con la fuente):
#   - Control de ERRORES        -> try/except + logs + codigos HTTP
#   - Control de DUPLICIDAD      -> huella determinista (hash) como atributo
#   - REGISTRO DE ACTIVIDAD      -> logging estructurado a Cloud Logging
#   - VALIDACION DE DATOS         -> chequeo de campos y tipos antes de publicar
# =============================================================================

import os
import json
import hashlib
import logging
from datetime import datetime, timezone

from google.cloud import pubsub_v1

# ---------------------------------------------------------------------------
# Configuracion (el project_id se toma de variable de entorno; si no existe,
# usar el ID del proyecto qwiklabs activo). Reemplazar el valor por defecto.
# ---------------------------------------------------------------------------
PROJECT_ID = os.environ.get("GCP_PROJECT", "qwiklabs-gcp-00-XXXXXXXXXXXX")
TOPIC_ID = os.environ.get("PUBSUB_TOPIC", "flujoeventos")

# Campos minimos que debe traer cada registro para ser valido.
CAMPOS_REQUERIDOS = (
    "id_cliente", "cliente", "genero", "id_producto", "producto",
    "precio", "cantidad", "monto", "forma_pago", "fecreg",
)

# Cliente Pub/Sub inicializado una sola vez (se reutiliza entre invocaciones).
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)

# Logging estructurado -> queda visible en Cloud Logging / Logs Explorer.
logging.basicConfig(level=logging.INFO)
log = logging.getLogger("receptor_rt")


def _validar_registro(item):
    """VALIDACION DE DATOS: devuelve (True, '') si el registro es valido,
    o (False, motivo) si falta algun campo clave o un tipo no es coherente."""
    if not isinstance(item, dict):
        return False, "el registro no es un objeto JSON"

    faltantes = [c for c in CAMPOS_REQUERIDOS if c not in item]
    if faltantes:
        return False, f"faltan campos: {', '.join(faltantes)}"

    # Coherencia numerica minima (la limpieza fina se hace luego en BigQuery).
    try:
        precio = float(item["precio"])
        cantidad = float(item["cantidad"])
        monto = float(item["monto"])
    except (TypeError, ValueError):
        return False, "precio/cantidad/monto no son numericos"

    if precio <= 0 or cantidad <= 0 or monto <= 0:
        return False, "precio/cantidad/monto deben ser mayores a 0"

    return True, ""


def _publicar(item):
    """CONTROL DE DUPLICIDAD: calcula una huella determinista del registro y la
    envia como atributo 'huella'. Permite deduplicar aguas abajo (BigQuery)
    aunque Pub/Sub entregue el mismo mensaje mas de una vez (at-least-once)."""
    payload = json.dumps(item, sort_keys=True, ensure_ascii=False)
    huella = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    ts_ingesta = datetime.now(timezone.utc).isoformat()

    future = publisher.publish(
        topic_path,
        payload.encode("utf-8"),
        huella=huella,              # huella del registro (dedup)
        ts_ingesta=ts_ingesta,      # marca de ingesta (trazabilidad)
        fuente="bdrealtimeescuelait.duoc.cl",
    )
    return future.result()          # espera confirmacion del broker


def main(request):
    """Punto de entrada del webhook. La API DUOC hace POST con un objeto JSON
    o un arreglo de objetos. Se valida, se publica a Pub/Sub y se responde."""
    try:
        data = request.get_json(silent=True)
        if not data:
            log.warning("Solicitud sin JSON valido")
            return ("Solicitud sin JSON valido", 400)

        # Normaliza a lista para procesar uniformemente uno o varios registros.
        registros = data if isinstance(data, list) else [data]

        publicados, descartados = 0, 0
        for item in registros:
            ok, motivo = _validar_registro(item)
            if not ok:
                # CONTROL DE ERRORES: el registro invalido no detiene el lote,
                # se registra y se continua (tolerancia a fallos).
                descartados += 1
                log.error("Registro descartado (%s): %s", motivo, item)
                continue
            _publicar(item)
            publicados += 1

        # REGISTRO DE ACTIVIDAD: resumen de la invocacion a Cloud Logging.
        log.info(
            json.dumps({
                "evento": "ingesta_webhook",
                "recibidos": len(registros),
                "publicados": publicados,
                "descartados": descartados,
                "topic": TOPIC_ID,
            })
        )
        return (f"OK publicados={publicados} descartados={descartados}", 200)

    except Exception as e:  # noqa: BLE001 - se captura todo para no caer el servicio
        log.exception("Error al procesar la solicitud")
        return (f"Error al procesar la solicitud: {e}", 500)
