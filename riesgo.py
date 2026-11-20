"""Cálculo diario del riesgo de cada residente (RF-26, Guía de desarrollo 7.3).

Carga el modelo vigente, calcula las variables de los últimos 7 días de cada
residente activo (no simulado) y guarda en dw.riesgo_residente su probabilidad,
su nivel (Bajo < 0.30 <= Medio < 0.60 <= Alto) y los tres factores principales.
Se programa todos los días a las 02:00 (ver programador.py).

Uso:
  python riesgo.py
"""
import json
from datetime import timedelta

import pandas as pd

from comun import config
from comun.db import consulta, valor
from comun.modelos import vigente
from comun.variables import DESCRIPCION, construir, cargar_datos


def factores(fila: pd.Series, referencia: dict, n=3) -> list:
    """Las n variables que más se alejan de lo normal, en la dirección que aumenta el riesgo."""
    puntos = {}
    for var, (media, desv) in referencia.items():
        nombre, direccion = DESCRIPCION[var]
        z = (fila[var] - media) / (desv or 1.0)
        puntos[var] = abs(z) if direccion == 0 else z * direccion
    top = sorted(puntos.items(), key=lambda x: x[1], reverse=True)[:n]
    return [{"variable": v, "descripcion": DESCRIPCION[v][0], "valor": round(float(fila[v]), 2),
             "normal": round(referencia[v][0], 2)} for v, p in top if p > 0.5]


def main():
    fila_mod, obj = vigente("riesgo")
    if obj is None:
        raise SystemExit("No hay un modelo de riesgo vigente con archivo disponible. Ejecuta primero entrenar.py.")

    # Residentes activos reales y su id en el Data Warehouse
    res = consulta("""
        SELECT r.id_residente, r.nombre || ' ' || r.apellido AS residente, d.id_residente_dw
          FROM residente r JOIN dw.dim_residente d ON d.clave_anonima = dw.clave_residente(r.id_residente)
         WHERE r.activo""")
    sin_dw = valor("SELECT count(*) FROM residente WHERE activo") - len(res)
    if res.empty:
        raise SystemExit("Ningún residente activo está en el Data Warehouse. Ejecuta primero etl.py.")

    corte = pd.Timestamp.now(tz=config.ZONA_HORARIA).tz_localize(None).floor("h")
    datos = cargar_datos(desde=corte - timedelta(days=31))
    df = construir(datos, [corte], con_etiqueta=False, residentes=res.id_residente_dw.tolist())
    df = df.merge(res, on="id_residente_dw")

    m, u, ref = obj["modelo"], obj["umbral"], obj["referencia"]
    if df.empty:
        print(f"Ningún residente tiene al menos {config.MIN_HORAS_VENTANA} horas de lecturas en los últimos 7 días; no se calculó riesgo.")
        return
    df["probabilidad"] = m.predict_proba(df[obj["variables"]].astype(float))[:, 1]

    for _, f in df.iterrows():
        valor("SELECT fn_guardar_riesgo(:id, :p, CAST(:fac AS jsonb))",
              id=int(f.id_residente), p=round(float(f.probabilidad), 3), fac=json.dumps(factores(f, ref), ensure_ascii=False))
    nivel = pd.cut(df.probabilidad, [-1, config.NIVEL_MEDIO, config.NIVEL_ALTO, 2], right=False, labels=["Bajo", "Medio", "Alto"])
    print(f"Riesgo calculado con el modelo {fila_mod.version} para {len(df)} residentes: {nivel.value_counts().to_dict()}")
    for _, f in df.sort_values("probabilidad", ascending=False).iterrows():
        print(f"  {f.residente:<30} {f.probabilidad:.2f}")
    omitidos = len(res) - len(df) + sin_dw
    if omitidos:
        print(f"  ({omitidos} residentes sin datos suficientes en los últimos 7 días)")


if __name__ == "__main__":
    main()
