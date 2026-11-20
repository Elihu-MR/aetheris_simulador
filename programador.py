"""Tareas programadas del módulo ECBD.

  - Cada hora (minuto 5): ETL + evaluación de anomalías.
  - Todos los días a las 02:00 (hora de Tijuana): cálculo de riesgo.
  - Día 25 de cada mes: particiones de los meses siguientes.

Uso (dejarlo corriendo en el servidor, por ejemplo con systemd, pm2 o screen):
  python programador.py
"""
import logging

from apscheduler.schedulers.blocking import BlockingScheduler

import etl
import riesgo
from comun import config
from comun.db import ejecutar

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


def tarea(nombre, funcion):
    def _():
        try:
            funcion()
        except SystemExit as e:
            logging.warning("%s: %s", nombre, e)
        except Exception:
            logging.exception("Error en %s", nombre)
    return _


if __name__ == "__main__":
    s = BlockingScheduler(timezone=config.ZONA_HORARIA)
    s.add_job(tarea("ETL", etl.main), "cron", minute=5, id="etl")
    s.add_job(tarea("Riesgo", riesgo.main), "cron", hour=2, minute=0, id="riesgo")
    s.add_job(tarea("Particiones", lambda: ejecutar("CALL sp_crear_particiones()")), "cron", day=25, hour=3, id="particiones")
    logging.info("Programador del módulo ECBD iniciado (Ctrl+C para detener).")
    s.start()
