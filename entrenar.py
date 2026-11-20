"""Entrenamiento y evaluación de los modelos (RF-25, RF-26, RF-27; Guía de desarrollo 7.2 a 7.4).

Pasos:
  1. Entrena el Isolation Forest y evalúa todo el historial (dw.anomalia_fc).
  2. Construye el conjunto de datos: un residente por semana (Tabla 9).
  3. Separa entrenamiento y prueba 80/20 estratificado.
  4. Elige el umbral de decisión con validación cruzada en el entrenamiento para
     llegar a recall >= 0.80 (OE-6) con la mayor precisión posible.
  5. Entrena el Random Forest (class_weight="balanced") y lo evalúa en prueba:
     precisión, recall, F1 y AUC.
  6. Lo registra en dw.modelo_version y lo publica como vigente solo si cumple
     recall >= 0.80 y no empeora el recall del modelo vigente.

Uso:
  python entrenar.py                  # entrena todo
  python entrenar.py --solo-riesgo    # no vuelve a entrenar el Isolation Forest
  python entrenar.py --forzar         # publica el modelo aunque no cumpla la regla
"""
import argparse
import json

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import confusion_matrix, f1_score, precision_score, recall_score, roc_auc_score
from sklearn.model_selection import StratifiedKFold, cross_val_predict, train_test_split

import anomalias
from comun import config
from comun.modelos import nueva_version, registrar, ruta_archivo, vigente
from comun.variables import DESCRIPCION, VARIABLES, cargar_datos, construir, cortes_semanales


def elegir_umbral(y, prob) -> float:
    """Umbral más alto que todavía alcanza el recall mínimo (así se maximiza la precisión)."""
    mejor = 0.05
    for u in np.arange(0.05, 0.96, 0.01):
        if recall_score(y, (prob >= u).astype(int), zero_division=0) >= config.RECALL_MINIMO:
            mejor = u
    return round(float(mejor), 2)


def main(solo_riesgo=False, forzar=False):
    if not solo_riesgo:
        anomalias.evaluar_pendientes(anomalias.entrenar())
    else:
        anomalias.evaluar_pendientes()

    print("Construyendo el conjunto de datos...")
    datos = cargar_datos()
    df = construir(datos, cortes_semanales(datos), con_etiqueta=True)
    if df.empty or df.etiqueta.sum() < 10:
        raise SystemExit(f"Datos insuficientes: {len(df)} filas y {int(df.etiqueta.sum()) if len(df) else 0} complicaciones. "
                         "Ejecuta primero simulador.py.")
    origen = "mixto" if df.simulado.any() and (~df.simulado.astype(bool)).any() else ("simulado" if df.simulado.all() else "piloto")
    print(f"  {len(df):,} filas (residente-semana), {int(df.etiqueta.sum())} con complicación "
          f"({100 * df.etiqueta.mean():.1f} %), datos: {origen}.")

    X, y = df[VARIABLES].astype(float), df.etiqueta.astype(int)
    X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, stratify=y, random_state=config.SEMILLA)
    rf = RandomForestClassifier(n_estimators=300, min_samples_leaf=3, class_weight="balanced",
                                random_state=config.SEMILLA, n_jobs=-1)
    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=config.SEMILLA)
    prob_cv = cross_val_predict(rf, X_tr, y_tr, cv=cv, method="predict_proba")[:, 1]
    umbral = elegir_umbral(y_tr, prob_cv)

    rf.fit(X_tr, y_tr)
    prob = rf.predict_proba(X_te)[:, 1]
    pred = (prob >= umbral).astype(int)
    m = {"precision": round(precision_score(y_te, pred, zero_division=0), 3),
         "recall": round(recall_score(y_te, pred, zero_division=0), 3),
         "f1": round(f1_score(y_te, pred, zero_division=0), 3),
         "auc": round(roc_auc_score(y_te, prob), 3)}
    tn, fp, fn, tp = confusion_matrix(y_te, pred).ravel()

    print(f"\nResultados en el conjunto de prueba ({len(y_te)} filas, umbral {umbral}):")
    print(f"  Precisión {m['precision']}   Recall {m['recall']}   F1 {m['f1']}   AUC {m['auc']}")
    print(f"  Matriz de confusión: VP={tp}  FN={fn}  FP={fp}  VN={tn}")
    imp = pd.Series(rf.feature_importances_, index=VARIABLES).sort_values(ascending=False)
    print("  Variables más importantes: " + ", ".join(f"{DESCRIPCION[v][0]} ({w:.2f})" for v, w in imp.head(5).items()))

    # Modelo final con todos los datos (las métricas reportadas son las del conjunto de prueba)
    rf.fit(X, y)
    referencia = {v: (float(X[v].mean()), float(X[v].std() or 1.0)) for v in VARIABLES}

    fila_vig, _ = vigente("riesgo")
    recall_vig = float(fila_vig.recall) if fila_vig is not None and pd.notna(fila_vig.recall) else 0.0
    cumple = m["recall"] >= config.RECALL_MINIMO and m["recall"] >= recall_vig
    publicar = cumple or forzar

    version = nueva_version("riesgo")
    ruta = ruta_archivo("riesgo", version)
    joblib.dump({"modelo": rf, "variables": VARIABLES, "umbral": umbral, "version": version,
                 "referencia": referencia, "metricas": m}, ruta)
    registrar("riesgo", version, origen, ruta, vigente=publicar, umbral=umbral, **m)
    reporte = {"version": version, "datos": origen, "filas": int(len(df)), "complicaciones": int(y.sum()), "umbral": umbral,
               **m, "matriz_confusion": {"vp": int(tp), "fn": int(fn), "fp": int(fp), "vn": int(tn)},
               "importancia": {k: round(float(v), 3) for k, v in imp.items()}, "publicado": publicar}
    (config.CARPETA_MODELOS / f"reporte_{version}.json").write_text(json.dumps(reporte, indent=2, ensure_ascii=False))

    if publicar:
        print(f"\nModelo {version} publicado como vigente{' (forzado)' if not cumple else ''}.")
    else:
        print(f"\nModelo {version} registrado pero NO publicado: recall {m['recall']} "
              f"(mínimo {config.RECALL_MINIMO}, vigente {recall_vig}). Usa --forzar si quieres publicarlo.")
    print("Siguiente paso: python riesgo.py")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Entrena y evalúa los modelos del módulo ECBD.")
    ap.add_argument("--solo-riesgo", action="store_true", help="No reentrena el Isolation Forest.")
    ap.add_argument("--forzar", action="store_true", help="Publica el modelo aunque no cumpla la regla de recall.")
    a = ap.parse_args()
    main(a.solo_riesgo, a.forzar)
