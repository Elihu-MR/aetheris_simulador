-- =====================================================================
-- Proyecto Aetheris - Sistema de monitoreo de asilos
-- Script de creación de la base de datos (PostgreSQL 16)
-- Versión 3.0 · noviembre de 2026 · alcance final del SRS definido
--
-- 21 tablas en el esquema public + 12 tablas en el esquema dw (ECBD)
--
-- Uso (base de datos nueva y vacía):
--   createdb aetheris
--   psql -d aetheris -f Aetheris_BD.sql
--   psql -d aetheris -f Aetheris_BD_logica.sql      (triggers, funciones y procedimientos)
--   psql -d aetheris -f Aetheris_datos_prueba.sql   (opcional, datos de prueba)
--
-- Cambios contra la versión 2.0:
--   - Se quitó SpO2 (chequeo, rango_alerta, dw.hecho_chequeo).
--   - Se quitó el tipo de dispositivo 'estacion_chequeo'.
--   - Se eliminó comando_dispositivo (comandos al dispositivo descartados).
--   - Nueva tabla suscripcion_push (Web Push, RF-05).
--   - Nuevo rol 'agente' (token de servicio de solo lectura para el servidor MCP, RF-30).
--   - dw: anomalia_fc, riesgo_residente, modelo_version y etl_corrida (RF-23 a RF-27).
-- =====================================================================

\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE asilo (
    id_asilo INTEGER GENERATED ALWAYS AS IDENTITY,
    nombre VARCHAR(100) NOT NULL,
    direccion VARCHAR(255) NOT NULL,
    ciudad VARCHAR(100) NOT NULL,
    entidad VARCHAR(100),
    pais VARCHAR(50) DEFAULT 'México' NOT NULL,
    codigo_postal VARCHAR(10),
    telefono VARCHAR(20),
    correo VARCHAR(120),
    fecha_registro TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_asilo)
);

CREATE TABLE usuario (
    id_usuario INTEGER GENERATED ALWAYS AS IDENTITY,
    correo VARCHAR(120) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    rol VARCHAR(15) NOT NULL CHECK (rol IN ('administrador','personal','familiar','agente')),
    activo BOOLEAN DEFAULT TRUE NOT NULL,
    intentos_fallidos SMALLINT DEFAULT 0 NOT NULL,
    ultimo_acceso TIMESTAMPTZ,
    fecha_creacion TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_usuario)
);

CREATE TABLE refresh_token (
    id_token BIGINT GENERATED ALWAYS AS IDENTITY,
    id_usuario INTEGER NOT NULL REFERENCES usuario(id_usuario) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL UNIQUE,
    fecha_expiracion TIMESTAMPTZ NOT NULL,
    revocado BOOLEAN DEFAULT FALSE NOT NULL,
    fecha_creacion TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_token)
);

CREATE TABLE personal (
    id_personal INTEGER GENERATED ALWAYS AS IDENTITY,
    id_asilo INTEGER NOT NULL REFERENCES asilo(id_asilo),
    id_usuario INTEGER NOT NULL UNIQUE REFERENCES usuario(id_usuario),
    nombre VARCHAR(100) NOT NULL,
    apellido VARCHAR(100) NOT NULL,
    fecha_nacimiento DATE,
    genero VARCHAR(15),
    telefono BYTEA,
    puesto VARCHAR(60),
    activo BOOLEAN DEFAULT TRUE NOT NULL,
    PRIMARY KEY (id_personal)
);

CREATE TABLE area (
    id_area INTEGER GENERATED ALWAYS AS IDENTITY,
    id_asilo INTEGER NOT NULL REFERENCES asilo(id_asilo),
    nombre VARCHAR(100) NOT NULL,
    tipo VARCHAR(20) NOT NULL CHECK (tipo IN ('habitacion','comun','servicio')),
    descripcion TEXT,
    temperatura_min NUMERIC(4,1) DEFAULT 18.0,
    temperatura_max NUMERIC(4,1) DEFAULT 28.0,
    humedad_min NUMERIC(4,1) DEFAULT 30.0,
    humedad_max NUMERIC(4,1) DEFAULT 70.0,
    PRIMARY KEY (id_area),
    UNIQUE (id_asilo, nombre)
);

CREATE TABLE residente (
    id_residente INTEGER GENERATED ALWAYS AS IDENTITY,
    id_asilo INTEGER NOT NULL REFERENCES asilo(id_asilo),
    id_area INTEGER REFERENCES area(id_area),
    nombre VARCHAR(100) NOT NULL,
    apellido VARCHAR(100) NOT NULL,
    fecha_nacimiento DATE NOT NULL,
    genero VARCHAR(15),
    condiciones_medicas BYTEA,
    foto VARCHAR(255),
    frecuencia_cardiaca_reposo SMALLINT,
    frecuencia_cardiaca_activo SMALLINT,
    frecuencia_cardiaca_agitado SMALLINT,
    fecha_ingreso DATE DEFAULT CURRENT_DATE NOT NULL,
    activo BOOLEAN DEFAULT TRUE NOT NULL,
    PRIMARY KEY (id_residente)
);

CREATE TABLE parentesco (
    id_parentesco SMALLINT GENERATED ALWAYS AS IDENTITY,
    nombre VARCHAR(50) NOT NULL UNIQUE,
    PRIMARY KEY (id_parentesco)
);

CREATE TABLE familiar (
    id_familiar INTEGER GENERATED ALWAYS AS IDENTITY,
    id_usuario INTEGER NOT NULL UNIQUE REFERENCES usuario(id_usuario),
    id_residente INTEGER NOT NULL REFERENCES residente(id_residente),
    id_parentesco SMALLINT NOT NULL REFERENCES parentesco(id_parentesco),
    nombre VARCHAR(100) NOT NULL,
    apellido VARCHAR(100) NOT NULL,
    telefono BYTEA,
    contacto_emergencia BOOLEAN DEFAULT FALSE NOT NULL,
    PRIMARY KEY (id_familiar)
);

CREATE TABLE dispositivo (
    id_dispositivo INTEGER GENERATED ALWAYS AS IDENTITY,
    id_asilo INTEGER NOT NULL REFERENCES asilo(id_asilo),
    id_area INTEGER REFERENCES area(id_area),
    tipo VARCHAR(20) NOT NULL CHECK (tipo IN ('pulsera','nodo_ambiental')),
    modelo VARCHAR(40) NOT NULL,
    direccion_mac VARCHAR(17) NOT NULL UNIQUE,
    api_key_hash VARCHAR(255),
    estado VARCHAR(15) DEFAULT 'activo' NOT NULL CHECK (estado IN ('activo','inactivo','mantenimiento')),
    ultima_conexion TIMESTAMPTZ,
    fecha_registro TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_dispositivo)
);

CREATE TABLE asignacion_dispositivo (
    id_asignacion INTEGER GENERATED ALWAYS AS IDENTITY,
    id_dispositivo INTEGER NOT NULL REFERENCES dispositivo(id_dispositivo) ON DELETE CASCADE,
    id_residente INTEGER NOT NULL REFERENCES residente(id_residente) ON DELETE CASCADE,
    fecha_asignacion TIMESTAMPTZ DEFAULT now() NOT NULL,
    fecha_retiro TIMESTAMPTZ,
    PRIMARY KEY (id_asignacion)
);

CREATE TABLE rango_alerta (
    id_rango INTEGER GENERATED ALWAYS AS IDENTITY,
    id_residente INTEGER NOT NULL REFERENCES residente(id_residente) ON DELETE CASCADE,
    variable VARCHAR(30) NOT NULL CHECK (variable IN ('frecuencia_cardiaca','temperatura_corporal','imc')),
    valor_min NUMERIC(5,1) NOT NULL,
    valor_max NUMERIC(5,1) NOT NULL,
    id_personal INTEGER REFERENCES personal(id_personal) ON DELETE CASCADE,
    fecha_actualizacion TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_rango),
    UNIQUE (id_residente, variable),
    CHECK (valor_min < valor_max)
);

CREATE TABLE lectura_frecuencia_cardiaca (
    id_lectura BIGINT GENERATED ALWAYS AS IDENTITY,
    id_residente INTEGER NOT NULL REFERENCES residente(id_residente),
    id_dispositivo INTEGER NOT NULL REFERENCES dispositivo(id_dispositivo),
    frecuencia_cardiaca SMALLINT NOT NULL CHECK (frecuencia_cardiaca BETWEEN 30 AND 220),
    fecha_hora TIMESTAMPTZ NOT NULL,
    fecha_recepcion TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_lectura, fecha_hora)
) PARTITION BY RANGE (fecha_hora);

CREATE TABLE lectura_ambiental (
    id_lectura BIGINT GENERATED ALWAYS AS IDENTITY,
    id_area INTEGER NOT NULL REFERENCES area(id_area),
    id_dispositivo INTEGER NOT NULL REFERENCES dispositivo(id_dispositivo),
    temperatura NUMERIC(4,1) NOT NULL,
    humedad NUMERIC(4,1) NOT NULL CHECK (humedad BETWEEN 0 AND 100),
    fecha_hora TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (id_lectura, fecha_hora)
) PARTITION BY RANGE (fecha_hora);

CREATE TABLE chequeo (
    id_chequeo INTEGER GENERATED ALWAYS AS IDENTITY,
    id_residente INTEGER NOT NULL REFERENCES residente(id_residente),
    id_personal INTEGER NOT NULL REFERENCES personal(id_personal),
    id_dispositivo INTEGER REFERENCES dispositivo(id_dispositivo),
    fecha TIMESTAMPTZ DEFAULT now() NOT NULL,
    frecuencia_cardiaca SMALLINT CHECK (frecuencia_cardiaca BETWEEN 30 AND 220),
    temperatura_corporal NUMERIC(4,1) CHECK (temperatura_corporal BETWEEN 30.0 AND 45.0),
    peso NUMERIC(5,2) CHECK (peso BETWEEN 20 AND 300),
    altura NUMERIC(3,2) CHECK (altura BETWEEN 0.50 AND 2.50),
    imc NUMERIC(4,1) GENERATED ALWAYS AS (ROUND(peso / NULLIF(altura * altura, 0), 1)) STORED,
    observaciones BYTEA,
    PRIMARY KEY (id_chequeo)
);

CREATE TABLE observacion (
    id_observacion INTEGER GENERATED ALWAYS AS IDENTITY,
    id_residente INTEGER NOT NULL REFERENCES residente(id_residente),
    id_personal INTEGER NOT NULL REFERENCES personal(id_personal),
    observacion BYTEA NOT NULL,
    fecha TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_observacion)
);

CREATE TABLE nivel_alerta (
    id_nivel SMALLINT GENERATED ALWAYS AS IDENTITY,
    nombre VARCHAR(20) NOT NULL UNIQUE,
    descripcion VARCHAR(255),
    tiempo_objetivo_min SMALLINT NOT NULL,
    PRIMARY KEY (id_nivel)
);

CREATE TABLE alerta (
    id_alerta BIGINT GENERATED ALWAYS AS IDENTITY,
    id_nivel SMALLINT NOT NULL REFERENCES nivel_alerta(id_nivel),
    origen VARCHAR(15) NOT NULL CHECK (origen IN ('biometrica','ambiental')),
    id_residente INTEGER REFERENCES residente(id_residente),
    id_area INTEGER REFERENCES area(id_area),
    id_dispositivo INTEGER REFERENCES dispositivo(id_dispositivo),
    valor_registrado NUMERIC(6,1),
    mensaje VARCHAR(255) NOT NULL,
    estado VARCHAR(15) DEFAULT 'pendiente' NOT NULL CHECK (estado IN ('pendiente','en_atencion','atendida','falsa_alarma','escalada')),
    fecha_generacion TIMESTAMPTZ DEFAULT now() NOT NULL,
    fecha_atencion TIMESTAMPTZ,
    fecha_cierre TIMESTAMPTZ,
    id_personal_atiende INTEGER REFERENCES personal(id_personal),
    notas_atencion TEXT,
    tiempo_respuesta INTERVAL GENERATED ALWAYS AS (fecha_atencion - fecha_generacion) STORED,
    PRIMARY KEY (id_alerta)
);

CREATE TABLE alerta_historial (
    id_historial BIGINT GENERATED ALWAYS AS IDENTITY,
    id_alerta BIGINT NOT NULL REFERENCES alerta(id_alerta) ON DELETE CASCADE,
    estado_anterior VARCHAR(15),
    estado_nuevo VARCHAR(15) NOT NULL,
    id_usuario INTEGER REFERENCES usuario(id_usuario) ON DELETE CASCADE,
    fecha TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_historial)
);

CREATE TABLE mensaje (
    id_mensaje BIGINT GENERATED ALWAYS AS IDENTITY,
    id_residente INTEGER NOT NULL REFERENCES residente(id_residente),
    id_usuario_emisor INTEGER NOT NULL REFERENCES usuario(id_usuario),
    contenido TEXT NOT NULL,
    fecha_envio TIMESTAMPTZ DEFAULT now() NOT NULL,
    leido BOOLEAN DEFAULT FALSE NOT NULL,
    PRIMARY KEY (id_mensaje)
);

CREATE TABLE suscripcion_push (
    id_suscripcion INTEGER GENERATED ALWAYS AS IDENTITY,
    id_usuario INTEGER NOT NULL REFERENCES usuario(id_usuario) ON DELETE CASCADE,
    endpoint TEXT NOT NULL UNIQUE,
    p256dh TEXT NOT NULL,
    auth TEXT NOT NULL,
    fecha_registro TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_suscripcion)
);

CREATE TABLE bitacora (
    id_bitacora BIGINT GENERATED ALWAYS AS IDENTITY,
    id_usuario INTEGER REFERENCES usuario(id_usuario),
    id_dispositivo INTEGER REFERENCES dispositivo(id_dispositivo),
    accion VARCHAR(60) NOT NULL,
    detalle JSONB,
    ip_origen INET,
    fecha TIMESTAMPTZ DEFAULT now() NOT NULL,
    PRIMARY KEY (id_bitacora)
);

-- Particiones mensuales (se crean por adelantado con la función crear_particiones_mes)
CREATE OR REPLACE FUNCTION crear_particiones_mes(p_mes DATE) RETURNS void AS $$
DECLARE
    ini DATE := date_trunc('month', p_mes);
    fin DATE := (date_trunc('month', p_mes) + INTERVAL '1 month')::date;
    sufijo TEXT := to_char(ini, 'YYYY_MM');
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['lectura_frecuencia_cardiaca', 'lectura_ambiental'] LOOP
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                       t || '_' || sufijo, t, ini, fin);
    END LOOP;
END;
$$ LANGUAGE plpgsql;
DO $$ BEGIN PERFORM crear_particiones_mes(d::date) FROM generate_series('2026-11-01'::date, '2027-06-01'::date, INTERVAL '1 month') AS d; END $$;
CREATE TABLE lectura_frecuencia_cardiaca_default PARTITION OF lectura_frecuencia_cardiaca DEFAULT;
CREATE TABLE lectura_ambiental_default PARTITION OF lectura_ambiental DEFAULT;

-- Índices
CREATE INDEX ix_lfc_residente_fecha ON lectura_frecuencia_cardiaca (id_residente, fecha_hora DESC);
CREATE INDEX ix_lamb_area_fecha ON lectura_ambiental (id_area, fecha_hora DESC);
CREATE INDEX ix_chequeo_residente_fecha ON chequeo (id_residente, fecha DESC);
CREATE INDEX ix_alerta_pendiente ON alerta (estado, fecha_generacion) WHERE estado IN ('pendiente','en_atencion','escalada');
CREATE INDEX ix_alerta_residente ON alerta (id_residente, fecha_generacion DESC);
CREATE INDEX ix_mensaje_residente ON mensaje (id_residente, fecha_envio);
CREATE INDEX ix_alerta_area ON alerta (id_area, fecha_generacion DESC);
CREATE INDEX ix_familiar_residente ON familiar (id_residente);
CREATE INDEX ix_suscripcion_usuario ON suscripcion_push (id_usuario);
CREATE UNIQUE INDEX ux_asignacion_vigente ON asignacion_dispositivo (id_dispositivo) WHERE fecha_retiro IS NULL;
CREATE UNIQUE INDEX ux_asignacion_residente_vigente ON asignacion_dispositivo (id_residente) WHERE fecha_retiro IS NULL;

-- Cifrado de columnas sensibles: la llave se lee de la configuración de la sesión (app.llave_datos),
-- que el backend establece desde una variable de entorno; nunca se guarda en la base de datos.
CREATE OR REPLACE FUNCTION cifrar(p_texto TEXT) RETURNS BYTEA AS $$
    SELECT CASE WHEN p_texto IS NULL THEN NULL
                ELSE pgp_sym_encrypt(p_texto, current_setting('app.llave_datos'), 'cipher-algo=aes256') END;
$$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION descifrar(p_dato BYTEA) RETURNS TEXT AS $$
    SELECT CASE WHEN p_dato IS NULL THEN NULL
                ELSE pgp_sym_decrypt(p_dato, current_setting('app.llave_datos')) END;
$$ LANGUAGE sql;

-- Vista que sustituye los contadores de la tabla asilo
CREATE VIEW v_asilo_resumen AS
SELECT a.id_asilo, a.nombre,
       (SELECT count(*) FROM residente r WHERE r.id_asilo = a.id_asilo AND r.activo) AS residentes_activos,
       (SELECT count(*) FROM personal p WHERE p.id_asilo = a.id_asilo AND p.activo)  AS empleados_activos
FROM asilo a;

-- Historial automático de estados de alerta
CREATE OR REPLACE FUNCTION fn_alerta_historial() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO alerta_historial (id_alerta, estado_anterior, estado_nuevo, id_usuario)
        VALUES (NEW.id_alerta, CASE WHEN TG_OP = 'UPDATE' THEN OLD.estado END, NEW.estado,
                NULLIF(current_setting('app.id_usuario', true), '')::int);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER tg_alerta_historial AFTER INSERT OR UPDATE OF estado ON alerta FOR EACH ROW EXECUTE FUNCTION fn_alerta_historial();

-- Catálogos iniciales
INSERT INTO nivel_alerta (nombre, descripcion, tiempo_objetivo_min) VALUES ('Baja', 'Requiere revisión en el turno', 60), ('Media', 'Requiere atención pronta', 15), ('Crítica', 'Riesgo inmediato para el residente', 3);
INSERT INTO parentesco (nombre) VALUES ('Hijo(a)'), ('Nieto(a)'), ('Sobrino(a)'), ('Hermano(a)'), ('Cónyuge'), ('Tutor legal');

-- Data Warehouse (esquema dw) para el módulo ECBD
CREATE SCHEMA IF NOT EXISTS dw;
CREATE TABLE dw.dim_tiempo (id_tiempo INTEGER PRIMARY KEY, fecha DATE NOT NULL, hora SMALLINT NOT NULL, dia_semana SMALLINT NOT NULL,
    semana SMALLINT NOT NULL, mes SMALLINT NOT NULL, anio SMALLINT NOT NULL, turno VARCHAR(10) NOT NULL);
CREATE TABLE dw.dim_residente (id_residente_dw INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, clave_anonima CHAR(64) NOT NULL UNIQUE,
    rango_edad VARCHAR(10) NOT NULL, genero VARCHAR(15), tiene_afecciones BOOLEAN NOT NULL);
CREATE TABLE dw.dim_area (id_area_dw INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, nombre VARCHAR(100) NOT NULL, tipo VARCHAR(20) NOT NULL);
CREATE TABLE dw.dim_nivel_alerta (id_nivel_dw SMALLINT PRIMARY KEY, nombre VARCHAR(20) NOT NULL, tiempo_objetivo_min SMALLINT NOT NULL);
CREATE TABLE dw.hecho_frecuencia_cardiaca_hora (id_tiempo INTEGER REFERENCES dw.dim_tiempo, id_residente_dw INTEGER REFERENCES dw.dim_residente,
    fc_promedio NUMERIC(5,1), fc_minima SMALLINT, fc_maxima SMALLINT, desviacion NUMERIC(5,2), lecturas INTEGER, lecturas_fuera_rango INTEGER,
    PRIMARY KEY (id_tiempo, id_residente_dw));
CREATE TABLE dw.hecho_ambiental_hora (id_tiempo INTEGER REFERENCES dw.dim_tiempo, id_area_dw INTEGER REFERENCES dw.dim_area,
    temperatura_promedio NUMERIC(4,1), humedad_promedio NUMERIC(4,1), minutos_fuera_rango SMALLINT, PRIMARY KEY (id_tiempo, id_area_dw));
CREATE TABLE dw.hecho_chequeo (id_tiempo INTEGER REFERENCES dw.dim_tiempo, id_residente_dw INTEGER REFERENCES dw.dim_residente,
    frecuencia_cardiaca SMALLINT, temperatura_corporal NUMERIC(4,1), peso NUMERIC(5,2), imc NUMERIC(4,1));
CREATE TABLE dw.hecho_alerta (id_tiempo INTEGER REFERENCES dw.dim_tiempo, id_residente_dw INTEGER REFERENCES dw.dim_residente,
    id_area_dw INTEGER REFERENCES dw.dim_area, id_nivel_dw SMALLINT REFERENCES dw.dim_nivel_alerta, origen VARCHAR(15), estado_final VARCHAR(15),
    segundos_respuesta INTEGER, segundos_cierre INTEGER, es_falsa_alarma BOOLEAN);

-- Resultados del módulo ECBD
CREATE TABLE dw.anomalia_fc (id_tiempo INTEGER REFERENCES dw.dim_tiempo, id_residente_dw INTEGER REFERENCES dw.dim_residente,
    puntaje NUMERIC(6,4) NOT NULL, es_anomalia BOOLEAN NOT NULL, PRIMARY KEY (id_tiempo, id_residente_dw));
CREATE TABLE dw.modelo_version (id_modelo INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, version VARCHAR(20) NOT NULL,
    tipo VARCHAR(15) NOT NULL CHECK (tipo IN ('anomalias','riesgo')), fecha_entrenamiento TIMESTAMPTZ DEFAULT now() NOT NULL,
    datos_entrenamiento VARCHAR(20) NOT NULL CHECK (datos_entrenamiento IN ('simulado','piloto','mixto')),
    precision NUMERIC(4,3), recall NUMERIC(4,3), f1 NUMERIC(4,3), auc NUMERIC(4,3), umbral NUMERIC(4,3),
    vigente BOOLEAN DEFAULT FALSE NOT NULL, ruta_archivo VARCHAR(255) NOT NULL, UNIQUE (tipo, version));
CREATE UNIQUE INDEX ux_modelo_vigente ON dw.modelo_version (tipo) WHERE vigente;
CREATE TABLE dw.riesgo_residente (id_riesgo BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_residente_dw INTEGER NOT NULL REFERENCES dw.dim_residente, fecha_calculo TIMESTAMPTZ DEFAULT now() NOT NULL,
    probabilidad NUMERIC(4,3) NOT NULL CHECK (probabilidad BETWEEN 0 AND 1),
    nivel_riesgo VARCHAR(5) NOT NULL CHECK (nivel_riesgo IN ('Bajo','Medio','Alto')),
    factores JSONB, id_modelo INTEGER REFERENCES dw.modelo_version(id_modelo));
CREATE INDEX ix_riesgo_residente_fecha ON dw.riesgo_residente (id_residente_dw, fecha_calculo DESC);
CREATE TABLE dw.etl_corrida (id_corrida INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, fecha_inicio TIMESTAMPTZ DEFAULT now() NOT NULL,
    fecha_fin TIMESTAMPTZ, cargado_hasta TIMESTAMPTZ NOT NULL, registros_cargados INTEGER DEFAULT 0 NOT NULL,
    registros_descartados INTEGER DEFAULT 0 NOT NULL, estado VARCHAR(10) DEFAULT 'en_curso' NOT NULL CHECK (estado IN ('en_curso','ok','error')),
    detalle TEXT);

-- Funciones de apoyo del ECBD
-- Clave anónima del residente: HMAC con la llave del backend; solo quien tiene la llave puede ligar el DW con el residente.
CREATE OR REPLACE FUNCTION dw.clave_residente(p_id_residente INTEGER) RETURNS CHAR(64) AS $$
    SELECT encode(hmac(p_id_residente::text, current_setting('app.llave_datos'), 'sha256'), 'hex');
$$ LANGUAGE sql STABLE;
-- id_tiempo con formato AAAAMMDDHH en hora de Tijuana
CREATE OR REPLACE FUNCTION dw.id_tiempo(p_fecha TIMESTAMPTZ) RETURNS INTEGER AS $$
    SELECT to_char(p_fecha AT TIME ZONE 'America/Tijuana', 'YYYYMMDDHH24')::int;
$$ LANGUAGE sql IMMUTABLE;
CREATE OR REPLACE FUNCTION dw.cargar_dim_tiempo(p_desde TIMESTAMPTZ, p_hasta TIMESTAMPTZ) RETURNS void AS $$
    INSERT INTO dw.dim_tiempo (id_tiempo, fecha, hora, dia_semana, semana, mes, anio, turno)
    SELECT dw.id_tiempo(t), l::date, extract(hour FROM l), extract(isodow FROM l), extract(week FROM l), extract(month FROM l), extract(year FROM l),
           CASE WHEN extract(hour FROM l) BETWEEN 7 AND 14 THEN 'matutino' WHEN extract(hour FROM l) BETWEEN 15 AND 22 THEN 'vespertino' ELSE 'nocturno' END
    FROM generate_series(date_trunc('hour', p_desde), p_hasta, INTERVAL '1 hour') AS t, LATERAL (SELECT t AT TIME ZONE 'America/Tijuana' AS l) x
    ON CONFLICT (id_tiempo) DO NOTHING;
$$ LANGUAGE sql;

-- Vista de apoyo para la API: pulsera vigente de cada residente
CREATE VIEW v_pulsera_vigente AS
SELECT ad.id_residente, ad.id_dispositivo, d.direccion_mac, d.estado, d.ultima_conexion, ad.fecha_asignacion
FROM asignacion_dispositivo ad JOIN dispositivo d ON d.id_dispositivo = ad.id_dispositivo
WHERE ad.fecha_retiro IS NULL AND d.tipo = 'pulsera';

-- Catálogo del DW
INSERT INTO dw.dim_nivel_alerta (id_nivel_dw, nombre, tiempo_objetivo_min) SELECT id_nivel, nombre, tiempo_objetivo_min FROM nivel_alerta;
