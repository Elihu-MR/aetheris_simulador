"""Simulador de historial para entrenar los modelos (Guía de desarrollo, sección 7.3).

Genera el historial de N residentes simulados durante varios meses y lo carga
directamente en el Data Warehouse (esquema dw), por hora, como lo dejaría el ETL:
  - dw.dim_residente (clave_anonima con prefijo 'SIM' para distinguirlos)
  - dw.hecho_frecuencia_cardiaca_hora
  - dw.hecho_chequeo (un chequeo semanal)
  - dw.hecho_alerta (alertas Medias, Críticas y falsas alarmas)

Cada residente tiene un perfil de riesgo (bajo, medio o alto). Antes de cada
complicación (alerta Crítica) hay de 4 a 8 días de señales: frecuencia más alta y
variable, más lecturas fuera de rango, algo de fiebre y pérdida de peso. También hay
episodios "falsos" con señales parecidas que no terminan en complicación, para que
el modelo no sea perfecto.

Además, con --reales DIAS agrega historial de prueba a los residentes reales que ya
existen en el Data Warehouse (por omisión 14 días), para que riesgo.py pueda calcular su
riesgo durante las pruebas y la demostración (sus chequeos se toman de los reales).
Este historial no se elimina con --borrar. No usarlo con datos reales del piloto.

Uso:
  python simulador.py                    # 50 residentes, 6 meses, 14 días para los reales
  python simulador.py --reales 0         # sin historial para los residentes reales
  python simulador.py --residentes 80 --meses 6 --semilla 7
  python simulador.py --borrar           # elimina todos los datos simulados
"""
import argparse
import hashlib
from datetime import datetime, timedelta

import numpy as np
import pandas as pd
from scipy.stats import norm

from comun.db import copiar, ejecutar, valor, consulta

PERFILES = {          # prob. del perfil, complicaciones por día, episodios falsos por día, prob. de afecciones
    "bajo":  (0.60, 0.002, 0.004, 0.35),
    "medio": (0.25, 0.010, 0.008, 0.70),
    "alto":  (0.15, 0.028, 0.012, 0.90),
}
EDADES = ["<75", "75-79", "80-84", "85+"]


def borrar():
    sim = "SELECT id_residente_dw FROM dw.dim_residente WHERE clave_anonima LIKE 'SIM%'"
    for t in ["dw.riesgo_residente", "dw.anomalia_fc", "dw.hecho_alerta", "dw.hecho_chequeo", "dw.hecho_frecuencia_cardiaca_hora"]:
        ejecutar(f"DELETE FROM {t} WHERE id_residente_dw IN ({sim})")
    n = ejecutar("DELETE FROM dw.dim_residente WHERE clave_anonima LIKE 'SIM%'").rowcount
    print(f"Datos simulados eliminados ({n} residentes).")


def id_tiempo(ts: pd.Series) -> pd.Series:
    return (ts.dt.year * 1000000 + ts.dt.month * 10000 + ts.dt.day * 100 + ts.dt.hour).astype(int)


def nuevo_residente(rng, perfil, clave):
    _, tasa, tasa_falsa, p_afec = PERFILES[perfil]
    base = float(np.clip(rng.normal(72, 6), 60, 86))
    personal = rng.random() < 0.6
    return dict(clave=clave, perfil=perfil, tasa=tasa, tasa_falsa=tasa_falsa,
                edad=rng.choice(EDADES, p=[0.2, 0.3, 0.3, 0.2] if perfil == "bajo" else [0.1, 0.2, 0.35, 0.35]),
                genero=rng.choice(["Femenino", "Masculino"]), afec=bool(rng.random() < p_afec),
                base=base, var=float(rng.normal(4.0, 0.8)),
                rmin=round(base - 17) if personal else 50, rmax=round(base + 38) if personal else 120,
                peso=float(rng.normal(66, 11)), altura=float(rng.normal(1.62, 0.08)))


def generar(r, rid, horas, rng, niveles, eventos=True, episodio_actual=False, chequeos=True):
    """Genera las horas de frecuencia cardiaca, los chequeos y las alertas de un residente."""
    dias = max(1, len(horas) // 24)
    # Complicaciones reales y episodios falsos (señales sin complicación)
    n_ev = rng.poisson(r["tasa"] * dias) if eventos else 0
    evs = sorted(rng.uniform(min(7 * 24, len(horas) // 4), len(horas) - 1, n_ev).astype(int))
    n_fa = rng.poisson(r["tasa_falsa"] * dias)
    falsos = sorted(rng.uniform(min(7 * 24, len(horas) // 4), len(horas) - 1, n_fa).astype(int))

    offset = np.zeros(len(horas)); mult = np.ones(len(horas)); temp_extra = np.zeros(len(horas))
    if episodio_actual:                                   # señales en curso, aún sin complicación
        falsos.append(len(horas) - 1)
    for ev, fuerza in [(e, 1.0) for e in evs] + [(e, 1.5 if (episodio_actual and e == len(horas) - 1) else rng.uniform(0.4, 0.8)) for e in falsos]:
        dur = int(rng.uniform(4, 8) * 24)
        a = max(0, ev - dur)
        rampa = np.linspace(0, 1, ev - a) * fuerza
        offset[a:ev] += rampa * rng.uniform(8, 16)
        mult[a:ev] += rampa * rng.uniform(0.4, 0.9)
        temp_extra[a:ev] += rampa * rng.uniform(0.3, 0.8)

    media = r["base"] + 4 * np.sin(2 * np.pi * (horas.hour.values - 15) / 24) + offset + rng.normal(0, 2, len(horas))
    desv = np.clip(r["var"] * mult + rng.normal(0, 0.6, len(horas)), 1.0, None)
    lect = rng.integers(360, 721, len(horas))
    p_fuera = norm.cdf((r["rmin"] - media) / desv) + 1 - norm.cdf((r["rmax"] - media) / desv)
    fuera = rng.binomial(lect, np.clip(p_fuera, 0, 1))
    presente = rng.random(len(horas)) > 0.03          # 3 % de horas sin pulsera
    df = pd.DataFrame({"ts": horas, "id_residente_dw": rid, "fc_promedio": media.round(1),
                       "fc_minima": np.clip(media - 2.2 * desv - np.abs(rng.normal(0, 2, len(horas))), 30, 220).round().astype(int),
                       "fc_maxima": np.clip(media + 2.2 * desv + np.abs(rng.normal(0, 2, len(horas))), 30, 220).round().astype(int),
                       "desviacion": desv.round(2), "lecturas": lect, "lecturas_fuera_rango": fuera})[presente]

    chq, al = [], []
    # Chequeo semanal (lunes 9:00) con el peso que baja en los episodios
    peso = r["peso"]
    for d in (pd.date_range(horas[0].date(), horas[-1].date(), freq="W-MON") if chequeos else []):
        ts = pd.Timestamp(d) + pd.Timedelta(hours=9)
        k = int((ts - horas[0]) / pd.Timedelta(hours=1))
        if k < 0 or k >= len(horas):
            continue
        ventana = slice(max(0, k - 72), k + 1)
        peso += rng.normal(0, 0.3) - (0.9 if temp_extra[ventana].max() > 0.2 else 0)
        chq.append({"ts": ts, "id_residente_dw": rid, "frecuencia_cardiaca": int(round(media[k])),
                         "temperatura_corporal": round(36.6 + temp_extra[k] + rng.normal(0, 0.2), 1),
                         "peso": round(peso, 2), "imc": round(peso / r["altura"] ** 2, 1)})

    # Alertas
    for e in evs:                                       # complicación: alerta Crítica atendida
        al.append({"ts": horas[e], "id_residente_dw": rid, "id_nivel_dw": niveles["Crítica"], "estado_final": "atendida",
                        "segundos_respuesta": int(rng.uniform(40, 240)), "falsa": False})
    en_episodio = offset > 6
    for k in np.where(rng.random(len(horas)) < np.where(en_episodio, 0.02, 0.0008 if r["perfil"] == "bajo" else 0.0015))[0]:
        al.append({"ts": horas[k], "id_residente_dw": rid, "id_nivel_dw": niveles["Media"], "estado_final": "atendida",
                        "segundos_respuesta": int(rng.uniform(60, 400)), "falsa": False})
    for k in np.where(rng.random(len(horas)) < 0.0006)[0]:  # falsas alarmas
        al.append({"ts": horas[k], "id_residente_dw": rid, "id_nivel_dw": niveles["Media"], "estado_final": "falsa_alarma",
                        "segundos_respuesta": int(rng.uniform(30, 300)), "falsa": True})
    return df, chq, al, n_ev


def simular(n_res: int, meses: int, semilla: int, dias_reales: int = 0):
    rng = np.random.default_rng(semilla)
    fin = pd.Timestamp.now(tz='America/Tijuana').tz_localize(None).floor('h').to_pydatetime() - timedelta(hours=1)
    ini = fin - timedelta(days=30 * meses)
    horas = pd.date_range(ini, fin, freq="h")
    dias = (fin - ini).days

    # Dimensión de tiempo para todo el periodo
    ejecutar("SELECT dw.cargar_dim_tiempo(:a, :b)", a=ini - timedelta(days=1), b=fin + timedelta(days=1))

    # Residentes simulados
    inicio_id = valor("SELECT count(*) FROM dw.dim_residente WHERE clave_anonima LIKE 'SIM%'") or 0
    res = []
    for i in range(n_res):
        perfil = str(rng.choice(list(PERFILES), p=[p[0] for p in PERFILES.values()]))
        clave = "SIM" + hashlib.sha256(f"sim-{semilla}-{inicio_id + i}".encode()).hexdigest()[:61]
        res.append(nuevo_residente(rng, perfil, clave))
    dim = pd.DataFrame([{"clave_anonima": r["clave"], "rango_edad": r["edad"], "genero": r["genero"],
                         "tiene_afecciones": r["afec"]} for r in res])
    copiar(dim, "dw.dim_residente", ["clave_anonima", "rango_edad", "genero", "tiene_afecciones"])
    ids = consulta("SELECT clave_anonima, id_residente_dw FROM dw.dim_residente WHERE clave_anonima LIKE 'SIM%'")
    ids = dict(zip(ids.clave_anonima.str.strip(), ids.id_residente_dw))
    niveles = dict(consulta("SELECT nombre, id_nivel_dw FROM dw.dim_nivel_alerta").values)

    fc_rows, chq_rows, al_rows = [], [], []
    total_eventos = 0
    for r in res:
        df, chq, al, n_ev = generar(r, ids[r["clave"]], horas, rng, niveles)
        fc_rows.append(df); chq_rows += chq; al_rows += al; total_eventos += n_ev

    # Historial para los residentes reales (solo para pruebas y la demostración)
    reales = consulta("SELECT id_residente_dw, tiene_afecciones FROM dw.dim_residente WHERE clave_anonima NOT LIKE 'SIM%' ORDER BY 1")
    if dias_reales and not reales.empty:
        horas_r = horas[horas >= fin - timedelta(days=dias_reales)]
        existentes = consulta("SELECT id_tiempo, id_residente_dw FROM dw.hecho_frecuencia_cardiaca_hora")
        existentes = set(zip(existentes.id_tiempo, existentes.id_residente_dw))
        orden = ["alto", "medio", "bajo", "bajo", "medio"]
        for i, f in enumerate(reales.itertuples()):
            perfil = orden[i % len(orden)]
            r = nuevo_residente(rng, perfil, clave=None)
            df, chq, al, _ = generar(r, f.id_residente_dw, horas_r, rng, niveles, eventos=False, episodio_actual=(perfil == "alto"), chequeos=False)
            df = df[[(t, f.id_residente_dw) not in existentes for t in id_tiempo(df.ts)]]
            fc_rows.append(df); chq_rows += chq; al_rows += al
        print(f"Historial de {dias_reales} días agregado a {len(reales)} residentes reales (datos de prueba).")

    validos = set(consulta("SELECT id_tiempo FROM dw.dim_tiempo").id_tiempo)   # descarta horas inexistentes por horario de verano
    fc = pd.concat(fc_rows, ignore_index=True); fc["id_tiempo"] = id_tiempo(fc.ts); fc = fc[fc.id_tiempo.isin(validos)]
    copiar(fc, "dw.hecho_frecuencia_cardiaca_hora",
           ["id_tiempo", "id_residente_dw", "fc_promedio", "fc_minima", "fc_maxima", "desviacion", "lecturas", "lecturas_fuera_rango"])
    chq = pd.DataFrame(chq_rows); chq["id_tiempo"] = id_tiempo(chq.ts); chq = chq[chq.id_tiempo.isin(validos)]
    copiar(chq, "dw.hecho_chequeo", ["id_tiempo", "id_residente_dw", "frecuencia_cardiaca", "temperatura_corporal", "peso", "imc"])
    al = pd.DataFrame(al_rows); al["id_tiempo"] = id_tiempo(al.ts); al = al[al.id_tiempo.isin(validos)].copy()
    al["origen"] = "biometrica"; al["id_area_dw"] = None
    al["segundos_cierre"] = al.segundos_respuesta + rng.integers(120, 900, len(al))
    al["es_falsa_alarma"] = al.falsa
    copiar(al, "dw.hecho_alerta", ["id_tiempo", "id_residente_dw", "id_area_dw", "id_nivel_dw", "origen", "estado_final",
                                   "segundos_respuesta", "segundos_cierre", "es_falsa_alarma"])

    perf = {k: int(v) for k, v in pd.Series([str(r["perfil"]) for r in res]).value_counts().items()}
    print(f"Simulación cargada: {n_res} residentes {perf}, {dias} días ({ini:%d/%m/%Y} a {fin:%d/%m/%Y}).")
    print(f"  {len(fc):,} horas de frecuencia cardiaca, {len(chq):,} chequeos, {len(al):,} alertas "
          f"({total_eventos} complicaciones).")
    print("Siguiente paso: python entrenar.py")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Genera historial simulado en el Data Warehouse.")
    ap.add_argument("--residentes", type=int, default=50)
    ap.add_argument("--meses", type=int, default=6)
    ap.add_argument("--semilla", type=int, default=42)
    ap.add_argument("--reales", type=int, default=14, metavar="DIAS",
                    help="Días de historial de prueba para los residentes reales (0 para no generar). Por omisión 14.")
    ap.add_argument("--borrar", action="store_true", help="Elimina los datos simulados y termina.")
    a = ap.parse_args()
    if a.borrar:
        borrar()
    else:
        if (valor("SELECT count(*) FROM dw.dim_residente WHERE clave_anonima LIKE 'SIM%'") or 0) > 0:
            raise SystemExit("Ya hay datos simulados. Usa --borrar primero si quieres generarlos de nuevo.")
        simular(a.residentes, a.meses, a.semilla, a.reales)
