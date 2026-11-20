"""Conexión a PostgreSQL. Cada conexión establece app.llave_datos, que necesitan
las funciones de cifrado y dw.clave_residente()."""
import io

import pandas as pd
from sqlalchemy import create_engine, event, text

from . import config

engine = create_engine(config.DATABASE_URL, pool_pre_ping=True, future=True)


@event.listens_for(engine, "connect")
def _al_conectar(dbapi_conn, _):
    with dbapi_conn.cursor() as cur:
        cur.execute("SELECT set_config('app.llave_datos', %s, false)", (config.LLAVE_DATOS,))
        cur.execute("SET TIME ZONE 'America/Tijuana'")
    dbapi_conn.commit()


def consulta(sql: str, **params) -> pd.DataFrame:
    """Ejecuta un SELECT y devuelve un DataFrame."""
    with engine.connect() as c:
        return pd.read_sql(text(sql), c, params=params)


def ejecutar(sql: str, **params):
    """Ejecuta una instrucción (INSERT, UPDATE, CALL...) en su propia transacción."""
    with engine.begin() as c:
        return c.execute(text(sql), params)


def valor(sql: str, **params):
    """Devuelve el primer valor de una consulta (en su propia transacción, que se confirma)."""
    with engine.begin() as c:
        return c.execute(text(sql), params).scalar()


def copiar(df: pd.DataFrame, tabla: str, columnas: list[str]):
    """Carga masiva con COPY (mucho más rápido que INSERT fila por fila)."""
    if df.empty:
        return
    buf = io.StringIO()
    df[columnas].to_csv(buf, index=False, header=False, na_rep="\\N")
    buf.seek(0)
    raw = engine.raw_connection()
    try:
        with raw.cursor() as cur:
            cur.copy_expert(f"COPY {tabla} ({', '.join(columnas)}) FROM STDIN WITH (FORMAT csv, NULL '\\N')", buf)
        raw.commit()
    finally:
        raw.close()
