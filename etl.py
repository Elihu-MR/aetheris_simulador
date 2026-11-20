"""Proceso ETL (RF-23, RF-24, Guía de desarrollo 7.1).

Ejecuta el procedimiento sp_etl_cargar() de la base de datos, que extrae solo lo
nuevo desde la última carga (dw.etl_corrida.cargado_hasta), descarta duplicados y
valores fuera de rango físico, anonimiza a los residentes y carga los hechos por
hora. Después evalúa las anomalías de las horas nuevas (RF-25).
Se programa cada hora (ver programador.py).

Uso:
  python etl.py                 # una corrida
  python etl.py --sin-anomalias
"""
import argparse

import anomalias
from comun.db import consulta, ejecutar


def main(con_anomalias=True):
    antes = consulta("SELECT coalesce(max(id_corrida), 0) AS id FROM dw.etl_corrida").id[0]
    ejecutar("CALL sp_etl_cargar()")
    c = consulta("SELECT * FROM dw.etl_corrida WHERE id_corrida > :id ORDER BY id_corrida DESC LIMIT 1", id=int(antes))
    if c.empty:
        print("ETL: no hay horas completas nuevas que cargar.")
    else:
        c = c.iloc[0]
        print(f"ETL {c.estado}: {c.registros_cargados} registros cargados, {c.registros_descartados} descartados "
              f"(hasta {c.cargado_hasta:%d/%m/%Y %H:%M}).")
        if c.estado == "error":
            print(f"  Detalle: {c.detalle}")
            return
    if con_anomalias:
        anomalias.evaluar_pendientes()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Carga incremental al Data Warehouse.")
    ap.add_argument("--sin-anomalias", action="store_true")
    main(not ap.parse_args().sin_anomalias)
