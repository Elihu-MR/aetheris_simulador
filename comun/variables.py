"""Construcción de las variables del modelo de riesgo (Guía de desarrollo, Tabla 9).

Cada fila es un residente en una ventana de 7 días que termina en un "corte".
- Variables: se calculan con los datos de los 7 días anteriores al corte
  (alertas: 30 días anteriores; chequeo: el último antes del corte).
- Etiqueta: 1 si en los 7 días siguientes al corte tuvo una alerta biométrica
  Crítica confirmada (no falsa alarma); 0 si no.
"""
from datetime import timedelta

import numpy as np
import pandas as pd

from . import config
from .db import consulta

VARIABLES = [
    "fc_media", "fc_desviacion", "fc_minima", "fc_maxima", "pct_fuera_rango", "horas_anomalas",
    "alertas_biometricas_30d", "alertas_criticas_30d", "falsas_alarmas_30d",
    "temperatura_ultima", "imc_ultimo", "cambio_peso", "edad_rango", "tiene_afecciones",
]

# Nombre legible y dirección de riesgo (+1: más alto es peor, -1: más bajo es peor, 0: alejarse en cualquier sentido)
DESCRIPCION = {
    "fc_media": ("Frecuencia cardiaca promedio (lpm)", 0),
    "fc_desviacion": ("Variabilidad de la frecuencia cardiaca", 1),
    "fc_minima": ("Frecuencia cardiaca mínima (lpm)", -1),
    "fc_maxima": ("Frecuencia cardiaca máxima (lpm)", 1),
    "pct_fuera_rango": ("% de lecturas fuera de rango", 1),
    "horas_anomalas": ("Horas con patrón anómalo en la semana", 1),
    "alertas_biometricas_30d": ("Alertas biométricas en 30 días", 1),
    "alertas_criticas_30d": ("Alertas críticas en 30 días", 1),
    "falsas_alarmas_30d": ("Falsas alarmas en 30 días", 0),
    "temperatura_ultima": ("Última temperatura corporal (°C)", 1),
    "imc_ultimo": ("Último IMC", 0),
    "cambio_peso": ("Cambio de peso desde el chequeo anterior (kg)", -1),
    "edad_rango": ("Rango de edad", 1),
    "tiene_afecciones": ("Tiene condiciones médicas registradas", 1),
}

EDAD = {"<75": 0, "75-79": 1, "80-84": 2, "85+": 3}


def cargar_datos(desde=None) -> dict:
    """Lee del Data Warehouse lo necesario para construir las variables."""
    filtro = "WHERE (t.fecha + make_interval(hours => t.hora)) >= :desde" if desde is not None else ""
    p = {"desde": desde} if desde is not None else {}
    horas = consulta(f"""
        SELECT h.id_residente_dw, (t.fecha + make_interval(hours => t.hora)) AS ts,
               h.fc_promedio::float, h.fc_minima::float, h.fc_maxima::float, h.desviacion::float,
               h.lecturas, h.lecturas_fuera_rango, coalesce(a.es_anomalia, false) AS es_anomalia
          FROM dw.hecho_frecuencia_cardiaca_hora h
          JOIN dw.dim_tiempo t ON t.id_tiempo = h.id_tiempo
          LEFT JOIN dw.anomalia_fc a ON a.id_tiempo = h.id_tiempo AND a.id_residente_dw = h.id_residente_dw
          {filtro}""", **p)
    alertas = consulta(f"""
        SELECT ha.id_residente_dw, (t.fecha + make_interval(hours => t.hora)) AS ts,
               n.nombre AS nivel, ha.origen, coalesce(ha.es_falsa_alarma, false) AS falsa
          FROM dw.hecho_alerta ha
          JOIN dw.dim_tiempo t ON t.id_tiempo = ha.id_tiempo
          JOIN dw.dim_nivel_alerta n ON n.id_nivel_dw = ha.id_nivel_dw
         {filtro.replace('WHERE', 'WHERE ha.id_residente_dw IS NOT NULL AND') if filtro else 'WHERE ha.id_residente_dw IS NOT NULL'}""", **p)
    chequeos = consulta("""
        SELECT c.id_residente_dw, (t.fecha + make_interval(hours => t.hora)) AS ts,
               c.temperatura_corporal::float AS temperatura, c.peso::float AS peso, c.imc::float AS imc
          FROM dw.hecho_chequeo c JOIN dw.dim_tiempo t ON t.id_tiempo = c.id_tiempo""")
    residentes = consulta("""
        SELECT id_residente_dw, rango_edad, tiene_afecciones, clave_anonima LIKE 'SIM%' AS simulado
          FROM dw.dim_residente""")
    for df in (horas, alertas, chequeos):
        if not df.empty:
            df["ts"] = pd.to_datetime(df["ts"])
    return {"horas": horas, "alertas": alertas, "chequeos": chequeos.sort_values("ts"), "residentes": residentes}


def construir(datos: dict, cortes, con_etiqueta=True, residentes=None) -> pd.DataFrame:
    """Devuelve una fila por residente y corte con las variables (y la etiqueta si se pide)."""
    H, A, C, R = datos["horas"], datos["alertas"], datos["chequeos"], datos["residentes"].set_index("id_residente_dw")
    v = timedelta(days=config.VENTANA_DIAS)
    filas = []
    for corte in pd.to_datetime(list(cortes)):
        h = H[(H.ts > corte - v) & (H.ts <= corte)]
        if residentes is not None:
            h = h[h.id_residente_dw.isin(residentes)]
        if h.empty:
            continue
        g = h.groupby("id_residente_dw").agg(
            fc_media=("fc_promedio", "mean"), fc_desviacion=("desviacion", "mean"),
            fc_minima=("fc_minima", "min"), fc_maxima=("fc_maxima", "max"),
            lecturas=("lecturas", "sum"), fuera=("lecturas_fuera_rango", "sum"),
            horas_anomalas=("es_anomalia", "sum"), horas_datos=("ts", "count"))
        g["pct_fuera_rango"] = 100 * g.fuera / g.lecturas.replace(0, np.nan)

        a30 = A[(A.ts > corte - timedelta(days=30)) & (A.ts <= corte)]
        bio = a30[a30.origen == "biometrica"]
        g["alertas_biometricas_30d"] = bio[~bio.falsa].groupby("id_residente_dw").size()
        g["alertas_criticas_30d"] = bio[(~bio.falsa) & (bio.nivel == "Crítica")].groupby("id_residente_dw").size()
        g["falsas_alarmas_30d"] = a30[a30.falsa].groupby("id_residente_dw").size()

        c = C[C.ts <= corte]
        ult = c.groupby("id_residente_dw").tail(2)
        last = ult.groupby("id_residente_dw").last()
        prev = ult.groupby("id_residente_dw").first()
        n = ult.groupby("id_residente_dw").size()
        g["temperatura_ultima"] = last.temperatura
        g["imc_ultimo"] = last.imc
        g["cambio_peso"] = (last.peso - prev.peso).where(n > 1, 0)

        g["edad_rango"] = R.rango_edad.map(EDAD).reindex(g.index)
        g["tiene_afecciones"] = R.tiene_afecciones.astype(int).reindex(g.index)
        g["simulado"] = R.simulado.reindex(g.index)
        g["corte"] = corte

        if con_etiqueta:
            fut = A[(A.ts > corte) & (A.ts <= corte + v) & (A.origen == "biometrica") & (~A.falsa) & (A.nivel == "Crítica")]
            g["etiqueta"] = g.index.isin(fut.id_residente_dw.unique()).astype(int)
        filas.append(g.reset_index())

    if not filas:
        return pd.DataFrame(columns=["id_residente_dw", "corte", *VARIABLES])
    df = pd.concat(filas, ignore_index=True)
    df = df[df.horas_datos >= config.MIN_HORAS_VENTANA].copy()
    for col in ["alertas_biometricas_30d", "alertas_criticas_30d", "falsas_alarmas_30d", "cambio_peso", "pct_fuera_rango"]:
        df[col] = df[col].fillna(0)
    df["temperatura_ultima"] = df["temperatura_ultima"].fillna(36.6)
    df["imc_ultimo"] = df["imc_ultimo"].fillna(df["imc_ultimo"].median() if df["imc_ultimo"].notna().any() else 24.0)
    df["edad_rango"] = df["edad_rango"].fillna(1)
    df["tiene_afecciones"] = df["tiene_afecciones"].fillna(0)
    return df


def cortes_semanales(datos: dict):
    """Lunes a las 00:00 entre el inicio de los datos + 7 días y el final - 7 días
    (para que cada fila tenga su semana de variables y su semana de etiqueta completas)."""
    H = datos["horas"]
    if H.empty:
        return []
    ini = H.ts.min().normalize() + timedelta(days=config.VENTANA_DIAS)
    fin = H.ts.max().normalize() - timedelta(days=config.VENTANA_DIAS)
    lunes = pd.date_range(ini, fin, freq="W-MON")
    return list(lunes)
