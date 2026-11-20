"""Registro y carga de versiones de modelos (dw.modelo_version, RF-27)."""
from datetime import datetime
from pathlib import Path

import joblib

from . import config
from .db import consulta, valor


def nueva_version(tipo: str) -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def ruta_archivo(tipo: str, version: str) -> Path:
    nombre = "isolation_forest" if tipo == "anomalias" else "random_forest"
    return config.CARPETA_MODELOS / f"{nombre}_{version}.joblib"


def registrar(tipo, version, datos, ruta: Path, vigente, precision=None, recall=None, f1=None, auc=None, umbral=None) -> int:
    rel = str(ruta.relative_to(config.RAIZ)) if ruta.is_relative_to(config.RAIZ) else str(ruta)
    return valor("""SELECT fn_registrar_modelo(:v, :t, :d, :r, :p, :rc, :f1, :auc, :u, :vig)""",
                 v=version, t=tipo, d=datos, r=rel, p=precision, rc=recall, f1=f1, auc=auc, u=umbral, vig=vigente)


def vigente(tipo: str):
    """Devuelve (fila de dw.modelo_version, objeto cargado) del modelo vigente, o (None, None)."""
    df = consulta("SELECT * FROM dw.modelo_version WHERE tipo = :t AND vigente", t=tipo)
    if df.empty:
        return None, None
    fila = df.iloc[0]
    ruta = Path(fila.ruta_archivo)
    if not ruta.is_absolute():
        ruta = config.RAIZ / ruta
    if not ruta.exists():
        return fila, None
    return fila, joblib.load(ruta)
