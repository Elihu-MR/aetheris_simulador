"""Detección de anomalías en la frecuencia cardiaca (RF-25, Guía de desarrollo 7.2).

Un Isolation Forest evalúa cada hora de cada residente con la media, mínima, máxima
y desviación de su frecuencia cardiaca, normalizadas respecto a su propio historial
(una hora "normal" para un residente puede ser anómala para otro). El resultado se
guarda en dw.anomalia_fc.

Uso:
  python anomalias.py              # evalúa las horas que aún no tienen resultado
  python anomalias.py --entrenar   # entrena un modelo nuevo, lo publica y evalúa todo el historial
"""
import argparse

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest

from comun import config
from comun.db import consulta, copiar, ejecutar
from comun.modelos import nueva_version, registrar, ruta_archivo, vigente

COLUMNAS = ["fc_promedio", "fc_minima", "fc_maxima", "desviacion"]
VARIABLES = ["z_media", "z_minima", "z_maxima", "z_desviacion"]
MIN_HORAS_HISTORIAL = 24


def _horas() -> pd.DataFrame:
    return consulta("""
        SELECT h.id_tiempo, h.id_residente_dw, h.fc_promedio::float, h.fc_minima::float,
               h.fc_maxima::float, h.desviacion::float, (a.id_tiempo IS NOT NULL) AS evaluada
          FROM dw.hecho_frecuencia_cardiaca_hora h
          LEFT JOIN dw.anomalia_fc a ON a.id_tiempo = h.id_tiempo AND a.id_residente_dw = h.id_residente_dw""")


def normalizar(df: pd.DataFrame) -> pd.DataFrame:
    """Calcula el valor z de cada variable respecto al historial del propio residente."""
    g = df.groupby("id_residente_dw")
    df = df[g.id_tiempo.transform("count") >= MIN_HORAS_HISTORIAL].copy()
    g = df.groupby("id_residente_dw")
    for col, z in zip(COLUMNAS, VARIABLES):
        media = g[col].transform("mean")
        desv = g[col].transform("std").clip(lower=1.0)
        df[z] = (df[col] - media) / desv
    return df


def entrenar() -> object:
    df = normalizar(_horas())
    if df.empty:
        raise SystemExit("No hay horas suficientes en dw.hecho_frecuencia_cardiaca_hora para entrenar.")
    modelo = IsolationForest(n_estimators=200, contamination=config.CONTAMINACION, random_state=config.SEMILLA, n_jobs=-1)
    modelo.fit(df[VARIABLES])
    version = nueva_version("anomalias")
    ruta = ruta_archivo("anomalias", version)
    joblib.dump({"modelo": modelo, "variables": VARIABLES, "version": version}, ruta)
    sim = consulta("SELECT id_residente_dw, clave_anonima LIKE 'SIM%' AS s FROM dw.dim_residente")
    s = set(sim[sim.s].id_residente_dw); usados = set(df.id_residente_dw)
    datos = "mixto" if (usados & s and usados - s) else ("simulado" if usados <= s else "piloto")
    registrar("anomalias", version, datos, ruta, vigente=True)
    print(f"Isolation Forest {version} entrenado con {len(df):,} horas ({datos}) y publicado.")
    ejecutar("DELETE FROM dw.anomalia_fc")    # se vuelve a evaluar todo el historial con el modelo nuevo
    return modelo


def evaluar_pendientes(modelo=None) -> int:
    """Evalúa las horas sin resultado y las guarda en dw.anomalia_fc. Devuelve cuántas evaluó."""
    if modelo is None:
        _, obj = vigente("anomalias")
        if obj is None:
            print("Anomalías: no hay un modelo vigente con archivo disponible; ejecuta entrenar.py.")
            return 0
        else:
            modelo = obj["modelo"]
    df = normalizar(_horas())
    pend = df[~df.evaluada]
    if pend.empty:
        print("Anomalías: no hay horas pendientes.")
        return 0
    X = pend[VARIABLES]
    pend = pend.assign(puntaje=np.round(modelo.decision_function(X), 4), es_anomalia=modelo.predict(X) == -1)
    copiar(pend, "dw.anomalia_fc", ["id_tiempo", "id_residente_dw", "puntaje", "es_anomalia"])
    print(f"Anomalías: {len(pend):,} horas evaluadas, {int(pend.es_anomalia.sum()):,} anómalas.")
    return len(pend)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Detección de anomalías en la frecuencia cardiaca.")
    ap.add_argument("--entrenar", action="store_true", help="Entrena y publica un modelo nuevo antes de evaluar.")
    a = ap.parse_args()
    m = entrenar() if a.entrenar else None
    evaluar_pendientes(m)
