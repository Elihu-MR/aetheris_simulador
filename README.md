# Aetheris · Módulo ECBD

Scripts de Python de la sección 7 de la Guía de desarrollo: ETL, detección de anomalías,
modelo de riesgo, evaluación y reentrenamiento (RF-23 a RF-27). El panel analítico
(RF-28, RF-29) lee los resultados con las funciones de la base de datos
(`fn_kpis`, `fn_riesgo_residentes`, `fn_anomalias_fc`).

## Archivos

| Archivo | Qué hace | RF |
|---|---|---|
| `simulador.py` | Genera el historial simulado (50 residentes, 6 meses) en el Data Warehouse y, para pruebas, 14 días de historial a los residentes reales. | 7.3 |
| `etl.py` | Ejecuta `sp_etl_cargar()` (carga incremental, limpieza y anonimización) y evalúa las anomalías de las horas nuevas. | RF-23, RF-24, RF-25 |
| `anomalias.py` | Isolation Forest sobre la frecuencia cardiaca normalizada por residente; guarda `dw.anomalia_fc`. | RF-25 |
| `entrenar.py` | Entrena el Isolation Forest y el Random Forest, elige el umbral para recall ≥ 0.80, evalúa (precisión, recall, F1, AUC) y publica el modelo si cumple. | RF-26, RF-27 |
| `riesgo.py` | Calcula cada día la probabilidad, el nivel (Bajo, Medio, Alto) y los factores principales de cada residente. | RF-26 |
| `programador.py` | Tareas programadas: ETL cada hora, riesgo a las 02:00 y particiones cada mes. | — |
| `comun/` | Configuración, conexión a la base, construcción de variables (Tabla 9) y registro de modelos. | — |

## Instalación

```bash
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env               # y llenar DATABASE_URL y LLAVE_DATOS
```

La base de datos debe estar creada con `Aetheris_BD.sql`, `Aetheris_BD_logica.sql`
y (para pruebas) `Aetheris_datos_prueba.sql`. `LLAVE_DATOS` debe ser la misma del backend.

## Primera vez

```bash
python etl.py            # carga al Data Warehouse lo que ya haya en la base
python simulador.py      # historial simulado para entrenar
python entrenar.py       # entrena, evalúa y publica los modelos
python riesgo.py         # calcula el riesgo de los residentes
```

`entrenar.py` muestra las métricas en pantalla y guarda un reporte en `modelos/reporte_<versión>.json`
(útil para la presentación). Las versiones quedan en `dw.modelo_version`.

## En el servidor

```bash
python programador.py    # dejarlo corriendo (systemd, pm2, screen...)
```

O con cron:

```
5 * * * *  cd /ruta/ecbd && .venv/bin/python etl.py
0 2 * * *  cd /ruta/ecbd && .venv/bin/python riesgo.py
```

Reentrenar (a mano o una vez al mes): `python entrenar.py`. El modelo nuevo solo se publica si
tiene recall ≥ 0.80 y no empeora al vigente (`--forzar` para publicarlo de todos modos).

## Notas

- Los residentes simulados se identifican en `dw.dim_residente` porque su `clave_anonima` empieza con `SIM`.
  `python simulador.py --borrar` los elimina.
- El historial de prueba que el simulador agrega a los residentes reales (`--reales 14`) no se borra con
  `--borrar`; no usarlo con datos reales del piloto (`--reales 0`).
- Las métricas del modelo son sobre datos de prueba; en la presentación se aclara que se entrenó con datos simulados.
- Los resultados son un apoyo para priorizar la atención, no un diagnóstico.

## Antes de presentar

- Borrar de `modelos/` los archivos `.joblib` y reportes de versiones viejas (dejar solo el vigente).
- No subir `.env` al repositorio.
- Quitar notebooks de exploración y `print` de depuración que se hayan agregado.
