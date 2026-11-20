"""Configuración del módulo ECBD (se lee del archivo .env)."""
import os
from pathlib import Path

from dotenv import load_dotenv

RAIZ = Path(__file__).resolve().parent.parent
load_dotenv(RAIZ / ".env")

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql+psycopg2://postgres@localhost:5432/aetheris")
LLAVE_DATOS = os.getenv("LLAVE_DATOS", "")
CARPETA_MODELOS = RAIZ / os.getenv("CARPETA_MODELOS", "modelos")
ZONA_HORARIA = "America/Tijuana"

# Reglas del modelo de riesgo (Guía de desarrollo, sección 7.3)
RECALL_MINIMO = 0.80          # OE-6
NIVEL_MEDIO = 0.30            # probabilidad desde la que el riesgo es Medio
NIVEL_ALTO = 0.60             # probabilidad desde la que el riesgo es Alto
VENTANA_DIAS = 7              # días de historial que usa cada fila y días que se predicen
MIN_HORAS_VENTANA = 72        # horas mínimas con lecturas en la ventana para usar la fila

# Isolation Forest (sección 7.2)
CONTAMINACION = 0.05
SEMILLA = 42

CARPETA_MODELOS.mkdir(parents=True, exist_ok=True)

if not LLAVE_DATOS:
    raise SystemExit("Falta LLAVE_DATOS en el archivo .env (debe ser la misma del backend).")
