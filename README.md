# bigdata — Pipeline Real Time (GCP)

Pipeline de datos **en tiempo real** sobre Google Cloud para la evaluación de Big Data (DUOC).
Ingesta continua desde la API DUOC, streaming a BigQuery y dashboards en vivo en Looker Studio.

```
API DUOC  --POST-->  Cloud Run  --publica-->  Pub/Sub  --stream-->  Dataflow  --insert-->  EventosBruto
   (1)                  (2)                     (3)                    (4)                   (RAW, crece solo)
                                                                                              │
                                                          v_operaciones_vivo (LIMPIA al vuelo) ◄───┘
                                                                                              │
                                                                                  Looker (2 dashboards)
```

Todo el montaje está automatizado en la carpeta [`montaje_rt/`](montaje_rt/). Ver
[`montaje_rt/LEEME.md`](montaje_rt/LEEME.md) para la guía completa.

## Arranque rápido (Cloud Shell)
```bash
cd ~
rm -rf bigdata
git clone https://github.com/catalinalagosgomez/bigdata.git
cd bigdata/montaje_rt
bash setup_todo.sh
```

## Recursos que crea
| Recurso | Nombre |
|---|---|
| Tópico / Suscripción Pub/Sub | `flujoeventos` / `flujoeventos-sub` |
| Webhook (Cloud Run) | `receptorstream` |
| Job de Dataflow | `streamHaciaBQ` |
| Dataset BigQuery | `StreamAnalytics` |
| Tabla RAW | `EventosBruto` |
| Capa limpia | `operaciones_curadas` |
| Vista en vivo (Looker) | `v_operaciones_vivo` |

> La parte GCP se hace en una sola sesión del lab. **Acuérdate de detener el job de Dataflow** al terminar para no gastar créditos.
