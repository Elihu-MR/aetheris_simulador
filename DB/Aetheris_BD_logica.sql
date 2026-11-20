-- =====================================================================
-- Proyecto Aetheris - Sistema de monitoreo de asilos
-- Lógica de la base de datos: triggers, funciones y procedimientos (PostgreSQL 16)
-- Versión 1.0 · noviembre de 2026
--
-- Orden de ejecución en una base nueva:
--   1. psql -d aetheris -f Aetheris_BD.sql
--   2. psql -d aetheris -f Aetheris_BD_logica.sql
--   3. psql -d aetheris -f Aetheris_datos_prueba.sql   (opcional)
--
-- Cómo se usa desde el backend:
--   - Al abrir cada conexión: SET app.llave_datos = '<LLAVE_DATOS del .env>';
--   - Las funciones fn_* se llaman con SELECT:  SELECT * FROM fn_login('correo', 'contraseña');
--   - Los procedimientos sp_* se llaman con CALL: CALL sp_etl_cargar();
--   - Los errores de validación se lanzan con RAISE EXCEPTION y SQLSTATE 'P0001';
--     el backend los devuelve como 400/422 con el mensaje tal cual.
--   - Las operaciones sencillas (listar áreas, editar un nombre, etc.) se hacen
--     con SELECT/UPDATE normales; aquí solo está la lógica que toca varias tablas
--     o reglas del negocio.
--
-- Contenido
--   A. Triggers
--   B. Usuarios y sesión (RF-11, RF-14)
--   C. Personal, familiares y residentes (RF-10, RF-15)
--   D. Telemetría y motor de alertas (RF-01, RF-02, RF-09)
--   E. Gestión de alertas y notificaciones (RF-04, RF-05)
--   F. Chequeos (RF-06, RF-07)
--   G. Mensajería (RF-13)
--   H. Consultas para pantallas, dashboard y analítica (RF-03, RF-28, RF-29)
--   I. ECBD: ETL al Data Warehouse (RF-23, RF-24)
--   J. Mantenimiento
-- =====================================================================

\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- Valores por defecto del motor de alertas (se pueden cambiar aquí)
CREATE OR REPLACE FUNCTION fn_config(p_clave TEXT) RETURNS NUMERIC AS $$
    SELECT CASE p_clave
        WHEN 'fc_min_defecto'        THEN 50     -- rango de FC si el residente no tiene uno propio
        WHEN 'fc_max_defecto'        THEN 120
        WHEN 'fc_critica_min'        THEN 40     -- debajo de este valor la alerta es Crítica
        WHEN 'fc_critica_max'        THEN 140    -- arriba de este valor la alerta es Crítica
        WHEN 'fc_desviacion_critica' THEN 20     -- lpm fuera del rango para considerarla Crítica
        WHEN 'fc_lecturas_seguidas'  THEN 3      -- lecturas fuera de rango seguidas para alertar
        WHEN 'amb_lecturas_seguidas' THEN 2
        WHEN 'intentos_bloqueo'      THEN 10     -- intentos fallidos para bloquear la cuenta
        WHEN 'min_fc_para_chequeo'   THEN 15     -- antigüedad máxima de la lectura que precarga el chequeo
    END;
$$ LANGUAGE sql IMMUTABLE;


-- =====================================================================
-- A. TRIGGERS
-- =====================================================================

-- A1. Alertas: valida los cambios de estado y llena las fechas automáticamente
CREATE OR REPLACE FUNCTION fn_tg_alerta_estado() RETURNS trigger AS $$
BEGIN
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        IF OLD.estado IN ('atendida', 'falsa_alarma') THEN
            RAISE EXCEPTION 'La alerta % ya está cerrada (%).', OLD.id_alerta, OLD.estado;
        END IF;
        IF OLD.estado = 'en_atencion' AND NEW.estado IN ('pendiente', 'escalada') THEN
            RAISE EXCEPTION 'Una alerta en atención solo puede cerrarse como atendida o falsa alarma.';
        END IF;
        IF NEW.estado IN ('en_atencion', 'atendida', 'falsa_alarma') AND NEW.fecha_atencion IS NULL THEN
            NEW.fecha_atencion := now();
        END IF;
        IF NEW.estado IN ('atendida', 'falsa_alarma') AND NEW.fecha_cierre IS NULL THEN
            NEW.fecha_cierre := now();
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS tg_alerta_estado ON alerta;
CREATE TRIGGER tg_alerta_estado BEFORE UPDATE OF estado ON alerta
    FOR EACH ROW EXECUTE FUNCTION fn_tg_alerta_estado();

-- A2. Asignación de pulseras: al asignar una nueva, cierra la anterior del residente y de la pulsera
CREATE OR REPLACE FUNCTION fn_tg_asignacion_dispositivo() RETURNS trigger AS $$
DECLARE
    v_tipo VARCHAR; v_estado VARCHAR; v_activo BOOLEAN;
BEGIN
    IF NEW.fecha_retiro IS NOT NULL THEN
        RETURN NEW;   -- registro histórico: no se valida
    END IF;
    SELECT tipo, estado INTO v_tipo, v_estado FROM dispositivo WHERE id_dispositivo = NEW.id_dispositivo;
    IF v_tipo IS DISTINCT FROM 'pulsera' THEN
        RAISE EXCEPTION 'El dispositivo % no es una pulsera.', NEW.id_dispositivo;
    END IF;
    IF v_estado <> 'activo' THEN
        RAISE EXCEPTION 'La pulsera % no está activa (estado: %).', NEW.id_dispositivo, v_estado;
    END IF;
    SELECT activo INTO v_activo FROM residente WHERE id_residente = NEW.id_residente;
    IF NOT coalesce(v_activo, FALSE) THEN
        RAISE EXCEPTION 'El residente % no existe o está dado de baja.', NEW.id_residente;
    END IF;
    UPDATE asignacion_dispositivo SET fecha_retiro = NEW.fecha_asignacion
     WHERE fecha_retiro IS NULL AND (id_residente = NEW.id_residente OR id_dispositivo = NEW.id_dispositivo);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS tg_asignacion_dispositivo ON asignacion_dispositivo;
CREATE TRIGGER tg_asignacion_dispositivo BEFORE INSERT ON asignacion_dispositivo
    FOR EACH ROW EXECUTE FUNCTION fn_tg_asignacion_dispositivo();

-- A3. Baja de residente: retira su pulsera
CREATE OR REPLACE FUNCTION fn_tg_residente_baja() RETURNS trigger AS $$
BEGIN
    IF OLD.activo AND NOT NEW.activo THEN
        UPDATE asignacion_dispositivo SET fecha_retiro = now()
         WHERE id_residente = NEW.id_residente AND fecha_retiro IS NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS tg_residente_baja ON residente;
CREATE TRIGGER tg_residente_baja AFTER UPDATE OF activo ON residente
    FOR EACH ROW EXECUTE FUNCTION fn_tg_residente_baja();

-- A4. Usuario desactivado: revoca sus sesiones; al reactivarlo reinicia los intentos fallidos
CREATE OR REPLACE FUNCTION fn_tg_usuario_activo() RETURNS trigger AS $$
BEGIN
    IF OLD.activo AND NOT NEW.activo THEN
        UPDATE refresh_token SET revocado = TRUE WHERE id_usuario = NEW.id_usuario AND NOT revocado;
    ELSIF NOT OLD.activo AND NEW.activo THEN
        NEW.intentos_fallidos := 0;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS tg_usuario_activo ON usuario;
CREATE TRIGGER tg_usuario_activo BEFORE UPDATE OF activo ON usuario
    FOR EACH ROW EXECUTE FUNCTION fn_tg_usuario_activo();

-- A5. Personal y familiar deben ligarse a un usuario con el rol correcto
CREATE OR REPLACE FUNCTION fn_tg_valida_rol() RETURNS trigger AS $$
DECLARE v_rol VARCHAR;
BEGIN
    SELECT rol INTO v_rol FROM usuario WHERE id_usuario = NEW.id_usuario;
    IF TG_TABLE_NAME = 'personal' AND v_rol NOT IN ('administrador', 'personal') THEN
        RAISE EXCEPTION 'El usuario % tiene rol %, no puede registrarse como personal.', NEW.id_usuario, v_rol;
    ELSIF TG_TABLE_NAME = 'familiar' AND v_rol <> 'familiar' THEN
        RAISE EXCEPTION 'El usuario % tiene rol %, no puede registrarse como familiar.', NEW.id_usuario, v_rol;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS tg_personal_rol ON personal;
CREATE TRIGGER tg_personal_rol BEFORE INSERT OR UPDATE OF id_usuario ON personal
    FOR EACH ROW EXECUTE FUNCTION fn_tg_valida_rol();
DROP TRIGGER IF EXISTS tg_familiar_rol ON familiar;
CREATE TRIGGER tg_familiar_rol BEFORE INSERT OR UPDATE OF id_usuario ON familiar
    FOR EACH ROW EXECUTE FUNCTION fn_tg_valida_rol();

-- A6. Cada lectura actualiza la última conexión del dispositivo
CREATE OR REPLACE FUNCTION fn_tg_ultima_conexion() RETURNS trigger AS $$
BEGIN
    UPDATE dispositivo SET ultima_conexion = greatest(coalesce(ultima_conexion, NEW.fecha_hora), NEW.fecha_hora)
     WHERE id_dispositivo = NEW.id_dispositivo;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS tg_lfc_ultima_conexion ON lectura_frecuencia_cardiaca;
CREATE TRIGGER tg_lfc_ultima_conexion AFTER INSERT ON lectura_frecuencia_cardiaca
    FOR EACH ROW EXECUTE FUNCTION fn_tg_ultima_conexion();
DROP TRIGGER IF EXISTS tg_lamb_ultima_conexion ON lectura_ambiental;
CREATE TRIGGER tg_lamb_ultima_conexion AFTER INSERT ON lectura_ambiental
    FOR EACH ROW EXECUTE FUNCTION fn_tg_ultima_conexion();

-- A7. Chequeo: si no traen frecuencia cardiaca, se toma la última lectura de la pulsera
CREATE OR REPLACE FUNCTION fn_tg_chequeo_fc() RETURNS trigger AS $$
BEGIN
    IF NEW.frecuencia_cardiaca IS NULL THEN
        SELECT l.frecuencia_cardiaca, l.id_dispositivo INTO NEW.frecuencia_cardiaca, NEW.id_dispositivo
          FROM lectura_frecuencia_cardiaca l
         WHERE l.id_residente = NEW.id_residente
           AND l.fecha_hora >= NEW.fecha - make_interval(mins => fn_config('min_fc_para_chequeo')::int)
         ORDER BY l.fecha_hora DESC LIMIT 1;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS tg_chequeo_fc ON chequeo;
CREATE TRIGGER tg_chequeo_fc BEFORE INSERT ON chequeo
    FOR EACH ROW EXECUTE FUNCTION fn_tg_chequeo_fc();

-- A8. Rango de alerta: actualiza la fecha al modificarlo
CREATE OR REPLACE FUNCTION fn_tg_rango_fecha() RETURNS trigger AS $$
BEGIN
    NEW.fecha_actualizacion := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS tg_rango_fecha ON rango_alerta;
CREATE TRIGGER tg_rango_fecha BEFORE UPDATE ON rango_alerta
    FOR EACH ROW EXECUTE FUNCTION fn_tg_rango_fecha();


-- =====================================================================
-- B. USUARIOS Y SESIÓN
-- =====================================================================

-- B1. Inicio de sesión: verifica la contraseña, cuenta intentos y bloquea al llegar al límite.
--     resultado: 'ok' | 'credenciales_invalidas' | 'bloqueado'
--     El backend genera el JWT solo si resultado = 'ok'.
CREATE OR REPLACE FUNCTION fn_login(p_correo VARCHAR, p_password TEXT)
RETURNS TABLE (resultado VARCHAR, id_usuario INTEGER, rol VARCHAR, nombre TEXT, id_personal INTEGER, id_familiar INTEGER) AS $$
#variable_conflict use_column
DECLARE u usuario%ROWTYPE;
BEGIN
    SELECT * INTO u FROM usuario WHERE lower(correo) = lower(trim(p_correo));
    IF NOT FOUND THEN
        RETURN QUERY SELECT 'credenciales_invalidas'::VARCHAR, NULL::INTEGER, NULL::VARCHAR, NULL::TEXT, NULL::INTEGER, NULL::INTEGER;
        RETURN;
    END IF;
    IF NOT u.activo THEN
        RETURN QUERY SELECT 'bloqueado'::VARCHAR, u.id_usuario, u.rol, NULL::TEXT, NULL::INTEGER, NULL::INTEGER;
        RETURN;
    END IF;
    IF u.password_hash <> crypt(p_password, u.password_hash) THEN
        UPDATE usuario SET intentos_fallidos = intentos_fallidos + 1,
               activo = (intentos_fallidos + 1) < fn_config('intentos_bloqueo')
         WHERE usuario.id_usuario = u.id_usuario;
        RETURN QUERY SELECT CASE WHEN u.intentos_fallidos + 1 >= fn_config('intentos_bloqueo') THEN 'bloqueado' ELSE 'credenciales_invalidas' END::VARCHAR,
                            NULL::INTEGER, NULL::VARCHAR, NULL::TEXT, NULL::INTEGER, NULL::INTEGER;
        RETURN;
    END IF;
    UPDATE usuario SET intentos_fallidos = 0, ultimo_acceso = now() WHERE usuario.id_usuario = u.id_usuario;
    RETURN QUERY
    SELECT 'ok'::VARCHAR, u.id_usuario, u.rol,
           coalesce(p.nombre || ' ' || p.apellido, f.nombre || ' ' || f.apellido, 'Agente Aetheris'),
           p.id_personal, f.id_familiar
      FROM (SELECT 1) x
      LEFT JOIN personal p ON p.id_usuario = u.id_usuario
      LEFT JOIN familiar f ON f.id_usuario = u.id_usuario;
END;
$$ LANGUAGE plpgsql;

-- B2. Crea un usuario con la contraseña cifrada con bcrypt (uso interno y para el rol agente)
CREATE OR REPLACE FUNCTION fn_crear_usuario(p_correo VARCHAR, p_password TEXT, p_rol VARCHAR)
RETURNS INTEGER AS $$
DECLARE v_id INTEGER;
BEGIN
    IF length(coalesce(p_password, '')) < 8 THEN
        RAISE EXCEPTION 'La contraseña debe tener al menos 8 caracteres.';
    END IF;
    IF EXISTS (SELECT 1 FROM usuario WHERE lower(correo) = lower(trim(p_correo))) THEN
        RAISE EXCEPTION 'El correo % ya está registrado.', p_correo;
    END IF;
    INSERT INTO usuario (correo, password_hash, rol)
    VALUES (lower(trim(p_correo)), crypt(p_password, gen_salt('bf', 10)), p_rol)
    RETURNING id_usuario INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- B3. Cambiar contraseña
CREATE OR REPLACE FUNCTION fn_cambiar_password(p_id_usuario INTEGER, p_password_nueva TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    IF length(coalesce(p_password_nueva, '')) < 8 THEN
        RAISE EXCEPTION 'La contraseña debe tener al menos 8 caracteres.';
    END IF;
    UPDATE usuario SET password_hash = crypt(p_password_nueva, gen_salt('bf', 10)), intentos_fallidos = 0
     WHERE id_usuario = p_id_usuario;
    UPDATE refresh_token SET revocado = TRUE WHERE id_usuario = p_id_usuario AND NOT revocado;
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- B4. Refresh tokens: se guarda solo el hash SHA-256 del token
CREATE OR REPLACE FUNCTION fn_guardar_refresh_token(p_id_usuario INTEGER, p_token TEXT, p_dias INTEGER DEFAULT 7)
RETURNS BIGINT AS $$
    INSERT INTO refresh_token (id_usuario, token_hash, fecha_expiracion)
    VALUES (p_id_usuario, encode(digest(p_token, 'sha256'), 'hex'), now() + make_interval(days => p_dias))
    RETURNING id_token;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION fn_validar_refresh_token(p_token TEXT)
RETURNS TABLE (id_usuario INTEGER, rol VARCHAR) AS $$
    SELECT u.id_usuario, u.rol
      FROM refresh_token t JOIN usuario u ON u.id_usuario = t.id_usuario
     WHERE t.token_hash = encode(digest(p_token, 'sha256'), 'hex')
       AND NOT t.revocado AND t.fecha_expiracion > now() AND u.activo;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION fn_revocar_refresh_token(p_token TEXT)
RETURNS BOOLEAN AS $$
    WITH r AS (UPDATE refresh_token SET revocado = TRUE
                WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex') AND NOT revocado RETURNING 1)
    SELECT EXISTS (SELECT 1 FROM r);
$$ LANGUAGE sql;

-- B5. ¿Puede este usuario ver a este residente? (familiar: solo el suyo; personal, admin y agente: todos)
CREATE OR REPLACE FUNCTION fn_puede_ver_residente(p_id_usuario INTEGER, p_id_residente INTEGER)
RETURNS BOOLEAN AS $$
    SELECT CASE u.rol
               WHEN 'familiar' THEN EXISTS (SELECT 1 FROM familiar f WHERE f.id_usuario = u.id_usuario AND f.id_residente = p_id_residente)
               ELSE TRUE END
      FROM usuario u WHERE u.id_usuario = p_id_usuario AND u.activo;
$$ LANGUAGE sql STABLE;


-- =====================================================================
-- C. PERSONAL, FAMILIARES Y RESIDENTES
-- =====================================================================

-- C1. Alta de empleado con su cuenta (una sola transacción)
CREATE OR REPLACE FUNCTION fn_crear_personal(
    p_correo VARCHAR, p_password TEXT, p_rol VARCHAR, p_nombre VARCHAR, p_apellido VARCHAR,
    p_puesto VARCHAR, p_telefono TEXT DEFAULT NULL, p_fecha_nacimiento DATE DEFAULT NULL,
    p_genero VARCHAR DEFAULT NULL, p_id_asilo INTEGER DEFAULT 1)
RETURNS INTEGER AS $$
DECLARE v_usuario INTEGER; v_id INTEGER;
BEGIN
    IF p_rol NOT IN ('administrador', 'personal') THEN
        RAISE EXCEPTION 'Rol no válido para un empleado: %', p_rol;
    END IF;
    v_usuario := fn_crear_usuario(p_correo, p_password, p_rol);
    INSERT INTO personal (id_asilo, id_usuario, nombre, apellido, fecha_nacimiento, genero, telefono, puesto)
    VALUES (p_id_asilo, v_usuario, p_nombre, p_apellido, p_fecha_nacimiento, p_genero, cifrar(p_telefono), p_puesto)
    RETURNING id_personal INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- C2. Alta de familiar con su cuenta, ligado a un residente
CREATE OR REPLACE FUNCTION fn_crear_familiar(
    p_correo VARCHAR, p_password TEXT, p_id_residente INTEGER, p_id_parentesco SMALLINT,
    p_nombre VARCHAR, p_apellido VARCHAR, p_telefono TEXT DEFAULT NULL,
    p_contacto_emergencia BOOLEAN DEFAULT FALSE)
RETURNS INTEGER AS $$
DECLARE v_usuario INTEGER; v_id INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM residente WHERE id_residente = p_id_residente AND activo) THEN
        RAISE EXCEPTION 'El residente % no existe o está dado de baja.', p_id_residente;
    END IF;
    v_usuario := fn_crear_usuario(p_correo, p_password, 'familiar');
    INSERT INTO familiar (id_usuario, id_residente, id_parentesco, nombre, apellido, telefono, contacto_emergencia)
    VALUES (v_usuario, p_id_residente, p_id_parentesco, p_nombre, p_apellido, cifrar(p_telefono), p_contacto_emergencia)
    RETURNING id_familiar INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- C3. Alta de residente (cifra las condiciones médicas) con rango de FC opcional
CREATE OR REPLACE FUNCTION fn_crear_residente(
    p_nombre VARCHAR, p_apellido VARCHAR, p_fecha_nacimiento DATE, p_genero VARCHAR,
    p_id_area INTEGER DEFAULT NULL, p_condiciones_medicas TEXT DEFAULT NULL,
    p_fc_min NUMERIC DEFAULT NULL, p_fc_max NUMERIC DEFAULT NULL, p_id_personal INTEGER DEFAULT NULL,
    p_id_asilo INTEGER DEFAULT 1)
RETURNS INTEGER AS $$
DECLARE v_id INTEGER;
BEGIN
    INSERT INTO residente (id_asilo, id_area, nombre, apellido, fecha_nacimiento, genero, condiciones_medicas)
    VALUES (p_id_asilo, p_id_area, p_nombre, p_apellido, p_fecha_nacimiento, p_genero, cifrar(p_condiciones_medicas))
    RETURNING id_residente INTO v_id;
    IF p_fc_min IS NOT NULL AND p_fc_max IS NOT NULL THEN
        PERFORM fn_guardar_rango(v_id, 'frecuencia_cardiaca', p_fc_min, p_fc_max, p_id_personal);
    END IF;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- C4. Guardar (crear o actualizar) un rango de alerta del residente
CREATE OR REPLACE FUNCTION fn_guardar_rango(p_id_residente INTEGER, p_variable VARCHAR, p_min NUMERIC, p_max NUMERIC, p_id_personal INTEGER DEFAULT NULL)
RETURNS INTEGER AS $$
    INSERT INTO rango_alerta (id_residente, variable, valor_min, valor_max, id_personal)
    VALUES (p_id_residente, p_variable, p_min, p_max, p_id_personal)
    ON CONFLICT (id_residente, variable)
    DO UPDATE SET valor_min = EXCLUDED.valor_min, valor_max = EXCLUDED.valor_max, id_personal = EXCLUDED.id_personal
    RETURNING id_rango;
$$ LANGUAGE sql;

-- C5. Asignar y retirar pulsera (el trigger A2 cierra la asignación anterior)
CREATE OR REPLACE FUNCTION fn_asignar_pulsera(p_id_residente INTEGER, p_id_dispositivo INTEGER)
RETURNS INTEGER AS $$
    INSERT INTO asignacion_dispositivo (id_dispositivo, id_residente) VALUES (p_id_dispositivo, p_id_residente)
    RETURNING id_asignacion;
$$ LANGUAGE sql;

CREATE OR REPLACE FUNCTION fn_retirar_pulsera(p_id_residente INTEGER)
RETURNS BOOLEAN AS $$
    WITH r AS (UPDATE asignacion_dispositivo SET fecha_retiro = now()
                WHERE id_residente = p_id_residente AND fecha_retiro IS NULL RETURNING 1)
    SELECT EXISTS (SELECT 1 FROM r);
$$ LANGUAGE sql;


-- =====================================================================
-- D. TELEMETRÍA Y MOTOR DE ALERTAS
--    El endpoint /iot/telemetria solo llama a una de estas dos funciones.
--    Si alerta_nueva = TRUE, el backend envía la alerta por WebSocket y Web Push.
-- =====================================================================

-- D1. Lectura de frecuencia cardiaca
CREATE OR REPLACE FUNCTION fn_registrar_lectura_fc(p_id_dispositivo INTEGER, p_frecuencia_cardiaca INTEGER,
                                                   p_fecha_hora TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (id_lectura BIGINT, id_residente INTEGER, fuera_de_rango BOOLEAN,
               id_alerta BIGINT, alerta_nueva BOOLEAN, nivel VARCHAR) AS $$
#variable_conflict use_column
DECLARE
    v_res INTEGER; v_area INTEGER; v_estado VARCHAR;
    v_min NUMERIC; v_max NUMERIC; v_seguidas INTEGER; v_desv NUMERIC;
    v_nivel VARCHAR; v_id_nivel SMALLINT; v_alerta BIGINT; v_nivel_actual SMALLINT;
BEGIN
    SELECT d.estado INTO v_estado FROM dispositivo d WHERE d.id_dispositivo = p_id_dispositivo AND d.tipo = 'pulsera';
    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'La pulsera % no existe.', p_id_dispositivo;
    ELSIF v_estado <> 'activo' THEN
        RAISE EXCEPTION 'La pulsera % no está activa (estado: %).', p_id_dispositivo, v_estado;
    END IF;
    SELECT a.id_residente, r.id_area INTO v_res, v_area
      FROM asignacion_dispositivo a JOIN residente r ON r.id_residente = a.id_residente
     WHERE a.id_dispositivo = p_id_dispositivo AND a.fecha_retiro IS NULL;
    IF v_res IS NULL THEN
        RAISE EXCEPTION 'La pulsera % no está asignada a ningún residente.', p_id_dispositivo;
    END IF;
    IF p_frecuencia_cardiaca NOT BETWEEN 30 AND 220 THEN
        RAISE EXCEPTION 'Frecuencia cardiaca fuera de rango físico: % lpm.', p_frecuencia_cardiaca;
    END IF;

    INSERT INTO lectura_frecuencia_cardiaca (id_residente, id_dispositivo, frecuencia_cardiaca, fecha_hora)
    VALUES (v_res, p_id_dispositivo, p_frecuencia_cardiaca, p_fecha_hora)
    RETURNING lectura_frecuencia_cardiaca.id_lectura INTO id_lectura;
    id_residente := v_res;

    SELECT ra.valor_min, ra.valor_max INTO v_min, v_max
      FROM rango_alerta ra WHERE ra.id_residente = v_res AND ra.variable = 'frecuencia_cardiaca';
    v_min := coalesce(v_min, fn_config('fc_min_defecto'));
    v_max := coalesce(v_max, fn_config('fc_max_defecto'));
    fuera_de_rango := p_frecuencia_cardiaca NOT BETWEEN v_min AND v_max;
    alerta_nueva := FALSE;

    IF fuera_de_rango THEN
        -- ¿Las últimas N lecturas (de los últimos 2 minutos) están todas fuera de rango?
        SELECT count(*) FILTER (WHERE x.frecuencia_cardiaca NOT BETWEEN v_min AND v_max) INTO v_seguidas
          FROM (SELECT l.frecuencia_cardiaca FROM lectura_frecuencia_cardiaca l
                 WHERE l.id_residente = v_res AND l.fecha_hora > p_fecha_hora - INTERVAL '2 minutes'
                   AND l.fecha_hora <= p_fecha_hora
                 ORDER BY l.fecha_hora DESC LIMIT fn_config('fc_lecturas_seguidas')::int) x;

        IF v_seguidas >= fn_config('fc_lecturas_seguidas') THEN
            v_desv := greatest(v_min - p_frecuencia_cardiaca, p_frecuencia_cardiaca - v_max);
            v_nivel := CASE WHEN p_frecuencia_cardiaca < fn_config('fc_critica_min')
                              OR p_frecuencia_cardiaca > fn_config('fc_critica_max')
                              OR v_desv >= fn_config('fc_desviacion_critica') THEN 'Crítica' ELSE 'Media' END;
            SELECT na.id_nivel INTO v_id_nivel FROM nivel_alerta na WHERE na.nombre = v_nivel;

            SELECT al.id_alerta, al.id_nivel INTO v_alerta, v_nivel_actual FROM alerta al
             WHERE al.id_residente = v_res AND al.origen = 'biometrica'
               AND al.estado IN ('pendiente', 'en_atencion', 'escalada')
             ORDER BY al.fecha_generacion DESC LIMIT 1;

            IF v_alerta IS NULL THEN
                INSERT INTO alerta (id_nivel, origen, id_residente, id_area, id_dispositivo, valor_registrado, mensaje)
                VALUES (v_id_nivel, 'biometrica', v_res, v_area, p_id_dispositivo, p_frecuencia_cardiaca,
                        format('Frecuencia cardiaca %s: %s lpm (rango %s–%s)',
                               CASE WHEN p_frecuencia_cardiaca > v_max THEN 'alta' ELSE 'baja' END,
                               p_frecuencia_cardiaca, v_min::int, v_max::int))
                RETURNING alerta.id_alerta INTO v_alerta;
                alerta_nueva := TRUE;
            ELSE
                -- Ya hay una alerta abierta: solo se actualiza el valor y, si empeoró, se sube a Crítica
                UPDATE alerta SET valor_registrado = p_frecuencia_cardiaca,
                                  id_nivel = greatest(alerta.id_nivel, v_id_nivel)
                 WHERE alerta.id_alerta = v_alerta;
            END IF;
            id_alerta := v_alerta;
            SELECT na.nombre INTO nivel FROM alerta al JOIN nivel_alerta na ON na.id_nivel = al.id_nivel WHERE al.id_alerta = v_alerta;
        END IF;
    END IF;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- D2. Lectura ambiental (DHT22). Si no se manda p_id_area se usa el área del nodo.
CREATE OR REPLACE FUNCTION fn_registrar_lectura_ambiental(p_id_dispositivo INTEGER, p_temperatura NUMERIC, p_humedad NUMERIC,
                                                          p_fecha_hora TIMESTAMPTZ DEFAULT now(), p_id_area INTEGER DEFAULT NULL)
RETURNS TABLE (id_lectura BIGINT, id_area INTEGER, fuera_de_rango BOOLEAN, id_alerta BIGINT, alerta_nueva BOOLEAN) AS $$
#variable_conflict use_column
DECLARE
    v_area INTEGER; v_estado VARCHAR; a area%ROWTYPE; v_seguidas INTEGER; v_alerta BIGINT; v_msg TEXT;
BEGIN
    SELECT d.estado, coalesce(p_id_area, d.id_area) INTO v_estado, v_area
      FROM dispositivo d WHERE d.id_dispositivo = p_id_dispositivo AND d.tipo = 'nodo_ambiental';
    IF v_estado IS NULL THEN
        RAISE EXCEPTION 'El nodo ambiental % no existe.', p_id_dispositivo;
    ELSIF v_estado <> 'activo' THEN
        RAISE EXCEPTION 'El nodo ambiental % no está activo (estado: %).', p_id_dispositivo, v_estado;
    ELSIF v_area IS NULL THEN
        RAISE EXCEPTION 'El nodo ambiental % no tiene área asignada.', p_id_dispositivo;
    END IF;

    INSERT INTO lectura_ambiental (id_area, id_dispositivo, temperatura, humedad, fecha_hora)
    VALUES (v_area, p_id_dispositivo, p_temperatura, p_humedad, p_fecha_hora)
    RETURNING lectura_ambiental.id_lectura INTO id_lectura;
    id_area := v_area;

    SELECT * INTO a FROM area WHERE area.id_area = v_area;
    fuera_de_rango := p_temperatura NOT BETWEEN a.temperatura_min AND a.temperatura_max
                   OR p_humedad NOT BETWEEN a.humedad_min AND a.humedad_max;
    alerta_nueva := FALSE;

    IF fuera_de_rango THEN
        SELECT count(*) FILTER (WHERE x.temperatura NOT BETWEEN a.temperatura_min AND a.temperatura_max
                                   OR x.humedad NOT BETWEEN a.humedad_min AND a.humedad_max) INTO v_seguidas
          FROM (SELECT la.temperatura, la.humedad FROM lectura_ambiental la
                 WHERE la.id_area = v_area AND la.fecha_hora <= p_fecha_hora
                 ORDER BY la.fecha_hora DESC LIMIT fn_config('amb_lecturas_seguidas')::int) x;

        IF v_seguidas >= fn_config('amb_lecturas_seguidas') THEN
            SELECT al.id_alerta INTO v_alerta FROM alerta al
             WHERE al.id_area = v_area AND al.origen = 'ambiental' AND al.estado IN ('pendiente', 'en_atencion', 'escalada')
             ORDER BY al.fecha_generacion DESC LIMIT 1;
            v_msg := CASE
                WHEN p_temperatura > a.temperatura_max THEN format('Temperatura alta en %s: %s °C (máx. %s)', a.nombre, p_temperatura, a.temperatura_max)
                WHEN p_temperatura < a.temperatura_min THEN format('Temperatura baja en %s: %s °C (mín. %s)', a.nombre, p_temperatura, a.temperatura_min)
                WHEN p_humedad > a.humedad_max THEN format('Humedad alta en %s: %s %% (máx. %s)', a.nombre, p_humedad, a.humedad_max)
                ELSE format('Humedad baja en %s: %s %% (mín. %s)', a.nombre, p_humedad, a.humedad_min) END;
            IF v_alerta IS NULL THEN
                INSERT INTO alerta (id_nivel, origen, id_area, id_dispositivo, valor_registrado, mensaje)
                VALUES ((SELECT na.id_nivel FROM nivel_alerta na WHERE na.nombre = 'Baja'), 'ambiental', v_area, p_id_dispositivo,
                        CASE WHEN p_temperatura NOT BETWEEN a.temperatura_min AND a.temperatura_max THEN p_temperatura ELSE p_humedad END, v_msg)
                RETURNING alerta.id_alerta INTO v_alerta;
                alerta_nueva := TRUE;
            ELSE
                UPDATE alerta SET valor_registrado = CASE WHEN p_temperatura NOT BETWEEN a.temperatura_min AND a.temperatura_max
                                                          THEN p_temperatura ELSE p_humedad END, mensaje = v_msg
                 WHERE alerta.id_alerta = v_alerta;
            END IF;
            id_alerta := v_alerta;
        END IF;
    END IF;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- D3. Rango de FC del residente asignado a una pulsera (el ESP32-S3 lo descarga al iniciar)
CREATE OR REPLACE FUNCTION fn_rango_pulsera(p_id_dispositivo INTEGER)
RETURNS TABLE (id_residente INTEGER, valor_min NUMERIC, valor_max NUMERIC) AS $$
    SELECT a.id_residente,
           coalesce(ra.valor_min, fn_config('fc_min_defecto')),
           coalesce(ra.valor_max, fn_config('fc_max_defecto'))
      FROM asignacion_dispositivo a
      LEFT JOIN rango_alerta ra ON ra.id_residente = a.id_residente AND ra.variable = 'frecuencia_cardiaca'
     WHERE a.id_dispositivo = p_id_dispositivo AND a.fecha_retiro IS NULL;
$$ LANGUAGE sql STABLE;


-- =====================================================================
-- E. GESTIÓN DE ALERTAS Y NOTIFICACIONES
-- =====================================================================

-- E1. Tomar una alerta (pasa a «en_atencion» y guarda quién la atiende)
CREATE OR REPLACE FUNCTION fn_tomar_alerta(p_id_alerta BIGINT, p_id_usuario INTEGER)
RETURNS BOOLEAN AS $$
DECLARE v_personal INTEGER;
BEGIN
    SELECT id_personal INTO v_personal FROM personal WHERE id_usuario = p_id_usuario AND activo;
    IF v_personal IS NULL THEN
        RAISE EXCEPTION 'Solo el personal activo puede tomar alertas.';
    END IF;
    PERFORM set_config('app.id_usuario', p_id_usuario::text, TRUE);
    UPDATE alerta SET estado = 'en_atencion', id_personal_atiende = v_personal
     WHERE id_alerta = p_id_alerta AND estado IN ('pendiente', 'escalada');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La alerta % no existe o ya fue tomada o cerrada.', p_id_alerta;
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- E2. Cerrar una alerta: p_resultado = 'atendida' | 'falsa_alarma'
CREATE OR REPLACE FUNCTION fn_cerrar_alerta(p_id_alerta BIGINT, p_id_usuario INTEGER, p_resultado VARCHAR, p_notas TEXT DEFAULT NULL)
RETURNS BOOLEAN AS $$
DECLARE v_personal INTEGER;
BEGIN
    IF p_resultado NOT IN ('atendida', 'falsa_alarma') THEN
        RAISE EXCEPTION 'Resultado no válido: % (usar atendida o falsa_alarma).', p_resultado;
    END IF;
    SELECT id_personal INTO v_personal FROM personal WHERE id_usuario = p_id_usuario AND activo;
    IF v_personal IS NULL THEN
        RAISE EXCEPTION 'Solo el personal activo puede cerrar alertas.';
    END IF;
    PERFORM set_config('app.id_usuario', p_id_usuario::text, TRUE);
    UPDATE alerta SET estado = p_resultado, notas_atencion = coalesce(p_notas, notas_atencion),
                      id_personal_atiende = coalesce(id_personal_atiende, v_personal)
     WHERE id_alerta = p_id_alerta AND estado IN ('pendiente', 'en_atencion', 'escalada');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La alerta % no existe o ya está cerrada.', p_id_alerta;
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- E3. Escalamiento: el backend la llama cada minuto. Devuelve las alertas que acaba de escalar
--     para notificar al administrador.
CREATE OR REPLACE FUNCTION fn_escalar_alertas()
RETURNS TABLE (id_alerta BIGINT, nivel VARCHAR, mensaje VARCHAR, minutos_sin_atender INTEGER) AS $$
BEGIN
    PERFORM set_config('app.id_usuario', '', TRUE);
    RETURN QUERY
    UPDATE alerta al SET estado = 'escalada'
      FROM nivel_alerta na
     WHERE na.id_nivel = al.id_nivel AND al.estado = 'pendiente'
       AND al.fecha_generacion < now() - make_interval(mins => na.tiempo_objetivo_min)
    RETURNING al.id_alerta, na.nombre, al.mensaje, (extract(epoch FROM now() - al.fecha_generacion) / 60)::int;
END;
$$ LANGUAGE plpgsql;

-- E4. A quién enviar una alerta por Web Push: administrador y personal activos que aceptaron
--     el permiso de notificaciones del navegador. Reciben todas las alertas.
CREATE OR REPLACE FUNCTION fn_destinatarios_push(p_id_alerta BIGINT)
RETURNS TABLE (id_usuario INTEGER, rol VARCHAR, endpoint TEXT, p256dh TEXT, auth TEXT) AS $$
    SELECT u.id_usuario, u.rol, s.endpoint, s.p256dh, s.auth
      FROM alerta al
      JOIN usuario u ON u.activo AND u.rol IN ('administrador', 'personal')
      JOIN suscripcion_push s ON s.id_usuario = u.id_usuario
     WHERE al.id_alerta = p_id_alerta;
$$ LANGUAGE sql STABLE;

-- E5. Guardar la suscripción Web Push del navegador (si ya existe el endpoint, se reasigna al usuario)
CREATE OR REPLACE FUNCTION fn_guardar_suscripcion_push(p_id_usuario INTEGER, p_endpoint TEXT, p_p256dh TEXT, p_auth TEXT)
RETURNS INTEGER AS $$
    INSERT INTO suscripcion_push (id_usuario, endpoint, p256dh, auth) VALUES (p_id_usuario, p_endpoint, p_p256dh, p_auth)
    ON CONFLICT (endpoint) DO UPDATE SET id_usuario = EXCLUDED.id_usuario, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth, fecha_registro = now()
    RETURNING id_suscripcion;
$$ LANGUAGE sql;

-- E6. Alertas para el panel, ordenadas: abiertas primero, Críticas arriba
CREATE OR REPLACE FUNCTION fn_alertas(p_estado VARCHAR DEFAULT NULL, p_id_residente INTEGER DEFAULT NULL,
                                      p_desde TIMESTAMPTZ DEFAULT now() - INTERVAL '7 days', p_hasta TIMESTAMPTZ DEFAULT now(),
                                      p_limite INTEGER DEFAULT 100)
RETURNS TABLE (id_alerta BIGINT, nivel VARCHAR, origen VARCHAR, estado VARCHAR, mensaje VARCHAR, valor_registrado NUMERIC,
               id_residente INTEGER, residente TEXT, area VARCHAR, fecha_generacion TIMESTAMPTZ, fecha_atencion TIMESTAMPTZ,
               fecha_cierre TIMESTAMPTZ, atendio TEXT, notas_atencion TEXT, tiempo_respuesta_seg INTEGER) AS $$
    SELECT al.id_alerta, na.nombre, al.origen, al.estado, al.mensaje, al.valor_registrado,
           al.id_residente, r.nombre || ' ' || r.apellido, ar.nombre,
           al.fecha_generacion, al.fecha_atencion, al.fecha_cierre, p.nombre || ' ' || p.apellido, al.notas_atencion,
           extract(epoch FROM al.tiempo_respuesta)::int
      FROM alerta al
      JOIN nivel_alerta na ON na.id_nivel = al.id_nivel
      LEFT JOIN residente r ON r.id_residente = al.id_residente
      LEFT JOIN area ar ON ar.id_area = al.id_area
      LEFT JOIN personal p ON p.id_personal = al.id_personal_atiende
     WHERE (p_estado IS NULL OR al.estado = p_estado)
       AND (p_id_residente IS NULL OR al.id_residente = p_id_residente)
       AND al.fecha_generacion BETWEEN p_desde AND p_hasta
     ORDER BY (al.estado IN ('pendiente', 'escalada', 'en_atencion')) DESC, na.id_nivel DESC, al.fecha_generacion DESC
     LIMIT p_limite;
$$ LANGUAGE sql STABLE;


-- =====================================================================
-- F. CHEQUEOS
-- =====================================================================

-- F1. Registrar chequeo semanal. Si p_frecuencia_cardiaca es NULL, el trigger A7 la toma de la pulsera.
CREATE OR REPLACE FUNCTION fn_registrar_chequeo(p_id_residente INTEGER, p_id_usuario INTEGER,
        p_temperatura_corporal NUMERIC, p_peso NUMERIC, p_altura NUMERIC,
        p_frecuencia_cardiaca INTEGER DEFAULT NULL, p_observaciones TEXT DEFAULT NULL)
RETURNS TABLE (id_chequeo INTEGER, imc NUMERIC, frecuencia_cardiaca SMALLINT) AS $$
DECLARE v_personal INTEGER;
BEGIN
    SELECT p.id_personal INTO v_personal FROM personal p WHERE p.id_usuario = p_id_usuario AND p.activo;
    IF v_personal IS NULL THEN
        RAISE EXCEPTION 'Solo el personal activo puede registrar chequeos.';
    END IF;
    RETURN QUERY
    INSERT INTO chequeo (id_residente, id_personal, frecuencia_cardiaca, temperatura_corporal, peso, altura, observaciones)
    VALUES (p_id_residente, v_personal, p_frecuencia_cardiaca, p_temperatura_corporal, p_peso, p_altura, cifrar(p_observaciones))
    RETURNING chequeo.id_chequeo, chequeo.imc, chequeo.frecuencia_cardiaca;
END;
$$ LANGUAGE plpgsql;

-- F2. Historial de chequeos de un residente (observaciones descifradas)
CREATE OR REPLACE FUNCTION fn_historial_chequeos(p_id_residente INTEGER, p_desde DATE DEFAULT NULL, p_hasta DATE DEFAULT NULL)
RETURNS TABLE (id_chequeo INTEGER, fecha TIMESTAMPTZ, frecuencia_cardiaca SMALLINT, temperatura_corporal NUMERIC,
               peso NUMERIC, altura NUMERIC, imc NUMERIC, observaciones TEXT, registro TEXT) AS $$
    SELECT c.id_chequeo, c.fecha, c.frecuencia_cardiaca, c.temperatura_corporal, c.peso, c.altura, c.imc,
           descifrar(c.observaciones), p.nombre || ' ' || p.apellido
      FROM chequeo c JOIN personal p ON p.id_personal = c.id_personal
     WHERE c.id_residente = p_id_residente
       AND (p_desde IS NULL OR c.fecha >= p_desde)
       AND (p_hasta IS NULL OR c.fecha < p_hasta + 1)
     ORDER BY c.fecha DESC;
$$ LANGUAGE sql STABLE;


-- =====================================================================
-- G. MENSAJERÍA
-- =====================================================================

-- G1. Enviar mensaje (un familiar solo puede escribir en la conversación de su residente)
CREATE OR REPLACE FUNCTION fn_enviar_mensaje(p_id_residente INTEGER, p_id_usuario INTEGER, p_contenido TEXT)
RETURNS BIGINT AS $$
DECLARE v_id BIGINT;
BEGIN
    IF NOT coalesce(fn_puede_ver_residente(p_id_usuario, p_id_residente), FALSE) THEN
        RAISE EXCEPTION 'El usuario % no tiene acceso a la conversación del residente %.', p_id_usuario, p_id_residente;
    END IF;
    IF length(trim(coalesce(p_contenido, ''))) = 0 THEN
        RAISE EXCEPTION 'El mensaje está vacío.';
    END IF;
    INSERT INTO mensaje (id_residente, id_usuario_emisor, contenido) VALUES (p_id_residente, p_id_usuario, trim(p_contenido))
    RETURNING id_mensaje INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- G2. Conversación de un residente
CREATE OR REPLACE FUNCTION fn_conversacion(p_id_residente INTEGER, p_limite INTEGER DEFAULT 100)
RETURNS TABLE (id_mensaje BIGINT, id_usuario_emisor INTEGER, emisor TEXT, rol VARCHAR, contenido TEXT, fecha_envio TIMESTAMPTZ, leido BOOLEAN) AS $$
    SELECT * FROM (
        SELECT m.id_mensaje, m.id_usuario_emisor,
               coalesce(p.nombre || ' ' || p.apellido, f.nombre || ' ' || f.apellido), u.rol, m.contenido, m.fecha_envio, m.leido
          FROM mensaje m JOIN usuario u ON u.id_usuario = m.id_usuario_emisor
          LEFT JOIN personal p ON p.id_usuario = u.id_usuario
          LEFT JOIN familiar f ON f.id_usuario = u.id_usuario
         WHERE m.id_residente = p_id_residente
         ORDER BY m.fecha_envio DESC LIMIT p_limite) x
    ORDER BY fecha_envio;
$$ LANGUAGE sql STABLE;

-- G3. Marcar como leídos los mensajes que recibió el usuario (los que no envió él)
CREATE OR REPLACE FUNCTION fn_marcar_mensajes_leidos(p_id_residente INTEGER, p_id_usuario INTEGER)
RETURNS INTEGER AS $$
    WITH r AS (UPDATE mensaje SET leido = TRUE
                WHERE id_residente = p_id_residente AND id_usuario_emisor <> p_id_usuario AND NOT leido RETURNING 1)
    SELECT count(*)::int FROM r;
$$ LANGUAGE sql;


-- =====================================================================
-- H. CONSULTAS PARA PANTALLAS, DASHBOARD Y ANALÍTICA
-- =====================================================================

-- H1. Detalle de residentes para la pantalla de residentes y la vista del familiar
CREATE OR REPLACE VIEW v_residente_detalle AS
SELECT r.id_residente, r.nombre, r.apellido, r.nombre || ' ' || r.apellido AS nombre_completo,
       r.fecha_nacimiento, date_part('year', age(r.fecha_nacimiento))::int AS edad, r.genero,
       descifrar(r.condiciones_medicas) AS condiciones_medicas, r.foto, r.fecha_ingreso, r.activo,
       r.id_area, a.nombre AS area,
       pv.id_dispositivo AS id_pulsera, pv.direccion_mac AS mac_pulsera,
       coalesce(ra.valor_min, fn_config('fc_min_defecto')) AS fc_min,
       coalesce(ra.valor_max, fn_config('fc_max_defecto')) AS fc_max,
       ul.frecuencia_cardiaca AS ultima_fc, ul.fecha_hora AS fecha_ultima_fc,
       uc.fecha AS fecha_ultimo_chequeo, uc.imc AS ultimo_imc,
       (SELECT count(*) FROM alerta al WHERE al.id_residente = r.id_residente
                                         AND al.estado IN ('pendiente', 'en_atencion', 'escalada'))::int AS alertas_abiertas
  FROM residente r
  LEFT JOIN area a ON a.id_area = r.id_area
  LEFT JOIN v_pulsera_vigente pv ON pv.id_residente = r.id_residente
  LEFT JOIN rango_alerta ra ON ra.id_residente = r.id_residente AND ra.variable = 'frecuencia_cardiaca'
  LEFT JOIN LATERAL (SELECT l.frecuencia_cardiaca, l.fecha_hora FROM lectura_frecuencia_cardiaca l
                      WHERE l.id_residente = r.id_residente ORDER BY l.fecha_hora DESC LIMIT 1) ul ON TRUE
  LEFT JOIN LATERAL (SELECT c.fecha, c.imc FROM chequeo c
                      WHERE c.id_residente = r.id_residente ORDER BY c.fecha DESC LIMIT 1) uc ON TRUE;

-- H2. Personal y familiares con teléfono descifrado
CREATE OR REPLACE VIEW v_personal_detalle AS
SELECT p.id_personal, p.id_usuario, u.correo, u.rol, p.nombre, p.apellido, p.puesto, descifrar(p.telefono) AS telefono,
       p.fecha_nacimiento, p.genero, p.activo AND u.activo AS activo, u.ultimo_acceso
  FROM personal p JOIN usuario u ON u.id_usuario = p.id_usuario;

CREATE OR REPLACE VIEW v_familiar_detalle AS
SELECT f.id_familiar, f.id_usuario, u.correo, f.nombre, f.apellido, descifrar(f.telefono) AS telefono,
       pa.nombre AS parentesco, f.id_residente, r.nombre || ' ' || r.apellido AS residente,
       f.contacto_emergencia, u.activo
  FROM familiar f JOIN usuario u ON u.id_usuario = f.id_usuario
  JOIN parentesco pa ON pa.id_parentesco = f.id_parentesco
  JOIN residente r ON r.id_residente = f.id_residente;

-- H3. Áreas con su última lectura ambiental
CREATE OR REPLACE VIEW v_area_ambiente AS
SELECT a.id_area, a.nombre, a.tipo, a.temperatura_min, a.temperatura_max, a.humedad_min, a.humedad_max,
       ul.temperatura, ul.humedad, ul.fecha_hora,
       (ul.temperatura NOT BETWEEN a.temperatura_min AND a.temperatura_max
        OR ul.humedad NOT BETWEEN a.humedad_min AND a.humedad_max) AS fuera_de_rango
  FROM area a
  LEFT JOIN LATERAL (SELECT la.temperatura, la.humedad, la.fecha_hora FROM lectura_ambiental la
                      WHERE la.id_area = a.id_area ORDER BY la.fecha_hora DESC LIMIT 1) ul ON TRUE;

-- H4. Lecturas de FC de un residente. p_agrupar_minutos > 0 promedia por bloques (para periodos largos).
CREATE OR REPLACE FUNCTION fn_lecturas_fc(p_id_residente INTEGER, p_desde TIMESTAMPTZ DEFAULT now() - INTERVAL '1 hour',
                                          p_hasta TIMESTAMPTZ DEFAULT now(), p_agrupar_minutos INTEGER DEFAULT 0)
RETURNS TABLE (fecha_hora TIMESTAMPTZ, frecuencia_cardiaca NUMERIC) AS $$
    SELECT CASE WHEN p_agrupar_minutos > 0 THEN date_bin(make_interval(mins => p_agrupar_minutos), l.fecha_hora, TIMESTAMPTZ '2000-01-01')
                ELSE l.fecha_hora END AS t,
           round(avg(l.frecuencia_cardiaca), 1)
      FROM lectura_frecuencia_cardiaca l
     WHERE l.id_residente = p_id_residente AND l.fecha_hora BETWEEN p_desde AND p_hasta
     GROUP BY 1 ORDER BY 1;
$$ LANGUAGE sql STABLE;

-- H5. Lecturas ambientales de un área
CREATE OR REPLACE FUNCTION fn_lecturas_ambientales(p_id_area INTEGER, p_desde TIMESTAMPTZ DEFAULT now() - INTERVAL '24 hours',
                                                   p_hasta TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (fecha_hora TIMESTAMPTZ, temperatura NUMERIC, humedad NUMERIC) AS $$
    SELECT la.fecha_hora, la.temperatura, la.humedad FROM lectura_ambiental la
     WHERE la.id_area = p_id_area AND la.fecha_hora BETWEEN p_desde AND p_hasta ORDER BY la.fecha_hora;
$$ LANGUAGE sql STABLE;

-- H6. Resumen del dashboard principal (JSON listo para el frontend)
CREATE OR REPLACE FUNCTION fn_dashboard_resumen(p_id_asilo INTEGER DEFAULT 1)
RETURNS JSON AS $$
    SELECT json_build_object(
        'residentes_activos', (SELECT count(*) FROM residente WHERE id_asilo = p_id_asilo AND activo),
        'empleados_activos',  (SELECT count(*) FROM personal WHERE id_asilo = p_id_asilo AND activo),
        'pulseras_activas',   (SELECT count(*) FROM v_pulsera_vigente),
        'alertas_abiertas',   (SELECT count(*) FROM alerta WHERE estado IN ('pendiente', 'en_atencion', 'escalada')),
        'alertas_criticas_abiertas', (SELECT count(*) FROM alerta al JOIN nivel_alerta na USING (id_nivel)
                                       WHERE al.estado IN ('pendiente', 'en_atencion', 'escalada') AND na.nombre = 'Crítica'),
        'temperatura_promedio', (SELECT round(avg(temperatura), 1) FROM v_area_ambiente),
        'alertas_hoy_por_origen', (SELECT coalesce(json_object_agg(origen, n), '{}') FROM
                                     (SELECT origen, count(*) n FROM alerta
                                       WHERE fecha_generacion >= date_trunc('day', now() AT TIME ZONE 'America/Tijuana') AT TIME ZONE 'America/Tijuana'
                                       GROUP BY origen) x),
        'alertas_recientes', (SELECT coalesce(json_agg(a), '[]') FROM fn_alertas(NULL, NULL, now() - INTERVAL '24 hours', now(), 5) a)
    );
$$ LANGUAGE sql STABLE;

-- H7. KPIs del panel analítico (RF-28, RF-29). Se calculan sobre la base transaccional para que estén al día.
CREATE OR REPLACE FUNCTION fn_kpis(p_desde TIMESTAMPTZ DEFAULT now() - INTERVAL '30 days', p_hasta TIMESTAMPTZ DEFAULT now(),
                                   p_id_area INTEGER DEFAULT NULL, p_id_residente INTEGER DEFAULT NULL)
RETURNS JSON AS $$
    WITH al AS (
        SELECT a.*, na.nombre AS nivel, ar.nombre AS area
          FROM alerta a JOIN nivel_alerta na ON na.id_nivel = a.id_nivel
          LEFT JOIN area ar ON ar.id_area = a.id_area
         WHERE a.fecha_generacion BETWEEN p_desde AND p_hasta
           AND (p_id_area IS NULL OR a.id_area = p_id_area)
           AND (p_id_residente IS NULL OR a.id_residente = p_id_residente))
    SELECT json_build_object(
        'total_alertas', (SELECT count(*) FROM al),
        'tiempo_promedio_atencion_seg', (SELECT round(avg(extract(epoch FROM tiempo_respuesta))) FROM al WHERE tiempo_respuesta IS NOT NULL),
        'meta_atencion_seg', 180,
        'tasa_falsas_alarmas_pct', (SELECT round(100.0 * count(*) FILTER (WHERE estado = 'falsa_alarma')
                                               / nullif(count(*) FILTER (WHERE estado IN ('atendida', 'falsa_alarma')), 0), 1) FROM al),
        'alertas_por_origen', (SELECT coalesce(json_object_agg(origen, n), '{}') FROM (SELECT origen, count(*) n FROM al GROUP BY origen) x),
        'alertas_por_nivel',  (SELECT coalesce(json_object_agg(nivel, n), '{}') FROM (SELECT nivel, count(*) n FROM al GROUP BY nivel) x),
        'alertas_por_area',   (SELECT coalesce(json_object_agg(area, n), '{}') FROM (SELECT coalesce(area, 'Sin área') area, count(*) n FROM al GROUP BY 1) x),
        'alertas_por_dia',    (SELECT coalesce(json_agg(json_build_object('fecha', d, 'total', n) ORDER BY d), '[]')
                                 FROM (SELECT (fecha_generacion AT TIME ZONE 'America/Tijuana')::date d, count(*) n FROM al GROUP BY 1) x),
        'tiempo_atencion_por_semana', (SELECT coalesce(json_agg(json_build_object('semana', s, 'promedio_seg', p) ORDER BY s), '[]')
                                 FROM (SELECT date_trunc('week', fecha_generacion AT TIME ZONE 'America/Tijuana')::date s,
                                              round(avg(extract(epoch FROM tiempo_respuesta))) p
                                         FROM al WHERE tiempo_respuesta IS NOT NULL GROUP BY 1) x)
    );
$$ LANGUAGE sql STABLE;

-- H8. Riesgo actual de los residentes (último cálculo del modelo), del más alto al más bajo
CREATE OR REPLACE FUNCTION fn_riesgo_residentes(p_nivel VARCHAR DEFAULT NULL)
RETURNS TABLE (id_residente INTEGER, residente TEXT, area VARCHAR, probabilidad NUMERIC, nivel_riesgo VARCHAR,
               factores JSONB, fecha_calculo TIMESTAMPTZ, version_modelo VARCHAR) AS $$
    SELECT r.id_residente, r.nombre || ' ' || r.apellido, a.nombre, rr.probabilidad, rr.nivel_riesgo, rr.factores, rr.fecha_calculo, mv.version
      FROM residente r
      LEFT JOIN area a ON a.id_area = r.id_area
      JOIN dw.dim_residente dr ON dr.clave_anonima = dw.clave_residente(r.id_residente)
      JOIN LATERAL (SELECT * FROM dw.riesgo_residente x WHERE x.id_residente_dw = dr.id_residente_dw
                     ORDER BY x.fecha_calculo DESC LIMIT 1) rr ON TRUE
      LEFT JOIN dw.modelo_version mv ON mv.id_modelo = rr.id_modelo
     WHERE r.activo AND (p_nivel IS NULL OR rr.nivel_riesgo = p_nivel)
     ORDER BY rr.probabilidad DESC;
$$ LANGUAGE sql STABLE;

-- H9. Historial de riesgo de un residente
CREATE OR REPLACE FUNCTION fn_riesgo_historial(p_id_residente INTEGER, p_dias INTEGER DEFAULT 30)
RETURNS TABLE (fecha_calculo TIMESTAMPTZ, probabilidad NUMERIC, nivel_riesgo VARCHAR, factores JSONB) AS $$
    SELECT rr.fecha_calculo, rr.probabilidad, rr.nivel_riesgo, rr.factores
      FROM dw.riesgo_residente rr JOIN dw.dim_residente dr ON dr.id_residente_dw = rr.id_residente_dw
     WHERE dr.clave_anonima = dw.clave_residente(p_id_residente)
       AND rr.fecha_calculo >= now() - make_interval(days => p_dias)
     ORDER BY rr.fecha_calculo;
$$ LANGUAGE sql STABLE;

-- H10. Anomalías de frecuencia cardiaca de un residente
CREATE OR REPLACE FUNCTION fn_anomalias_fc(p_id_residente INTEGER, p_desde TIMESTAMPTZ DEFAULT now() - INTERVAL '7 days',
                                           p_hasta TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (fecha DATE, hora SMALLINT, puntaje NUMERIC, fc_promedio NUMERIC, fc_minima SMALLINT, fc_maxima SMALLINT) AS $$
    SELECT t.fecha, t.hora, an.puntaje, h.fc_promedio, h.fc_minima, h.fc_maxima
      FROM dw.anomalia_fc an
      JOIN dw.dim_residente dr ON dr.id_residente_dw = an.id_residente_dw
      JOIN dw.dim_tiempo t ON t.id_tiempo = an.id_tiempo
      LEFT JOIN dw.hecho_frecuencia_cardiaca_hora h ON h.id_tiempo = an.id_tiempo AND h.id_residente_dw = an.id_residente_dw
     WHERE dr.clave_anonima = dw.clave_residente(p_id_residente) AND an.es_anomalia
       AND an.id_tiempo BETWEEN dw.id_tiempo(p_desde) AND dw.id_tiempo(p_hasta)
     ORDER BY t.fecha, t.hora;
$$ LANGUAGE sql STABLE;

-- H11. Guardar el resultado del modelo de riesgo (lo llama riesgo.py por cada residente)
CREATE OR REPLACE FUNCTION fn_guardar_riesgo(p_id_residente INTEGER, p_probabilidad NUMERIC, p_factores JSONB DEFAULT NULL)
RETURNS BIGINT AS $$
    INSERT INTO dw.riesgo_residente (id_residente_dw, probabilidad, nivel_riesgo, factores, id_modelo)
    SELECT dr.id_residente_dw, round(p_probabilidad, 3),
           CASE WHEN p_probabilidad >= 0.60 THEN 'Alto' WHEN p_probabilidad >= 0.30 THEN 'Medio' ELSE 'Bajo' END,
           p_factores, (SELECT id_modelo FROM dw.modelo_version WHERE tipo = 'riesgo' AND vigente)
      FROM dw.dim_residente dr WHERE dr.clave_anonima = dw.clave_residente(p_id_residente)
    RETURNING id_riesgo;
$$ LANGUAGE sql;

-- H12. Registrar una versión de modelo; si p_vigente = TRUE, desactiva la anterior del mismo tipo (RF-27)
CREATE OR REPLACE FUNCTION fn_registrar_modelo(p_version VARCHAR, p_tipo VARCHAR, p_datos VARCHAR, p_ruta VARCHAR,
        p_precision NUMERIC DEFAULT NULL, p_recall NUMERIC DEFAULT NULL, p_f1 NUMERIC DEFAULT NULL,
        p_auc NUMERIC DEFAULT NULL, p_umbral NUMERIC DEFAULT NULL, p_vigente BOOLEAN DEFAULT FALSE)
RETURNS INTEGER AS $$
DECLARE v_id INTEGER;
BEGIN
    IF p_vigente THEN
        UPDATE dw.modelo_version SET vigente = FALSE WHERE tipo = p_tipo AND vigente;
    END IF;
    INSERT INTO dw.modelo_version (version, tipo, datos_entrenamiento, precision, recall, f1, auc, umbral, vigente, ruta_archivo)
    VALUES (p_version, p_tipo, p_datos, p_precision, p_recall, p_f1, p_auc, p_umbral, p_vigente, p_ruta)
    RETURNING id_modelo INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;


-- =====================================================================
-- I. ECBD: ETL INCREMENTAL AL DATA WAREHOUSE (RF-23, RF-24)
--    Programar cada hora:  CALL sp_etl_cargar();
--    Carga solo horas completas desde la última corrida correcta y deja el registro en dw.etl_corrida.
-- =====================================================================
CREATE OR REPLACE PROCEDURE sp_etl_cargar()
LANGUAGE plpgsql AS $$
DECLARE
    v_desde TIMESTAMPTZ; v_hasta TIMESTAMPTZ := date_trunc('hour', now());
    v_cargados INTEGER := 0; v_descartados INTEGER := 0; v_n INTEGER;
BEGIN
    SELECT coalesce(max(cargado_hasta), '2000-01-01') INTO v_desde FROM dw.etl_corrida WHERE estado = 'ok';
    IF v_desde >= v_hasta THEN
        RETURN;   -- nada nuevo
    END IF;

    BEGIN
        PERFORM dw.cargar_dim_tiempo(greatest(v_desde, now() - INTERVAL '400 days'), v_hasta);

        -- Dimensiones (residentes anonimizados y áreas)
        INSERT INTO dw.dim_residente (clave_anonima, rango_edad, genero, tiene_afecciones)
        SELECT dw.clave_residente(r.id_residente),
               CASE WHEN date_part('year', age(r.fecha_nacimiento)) >= 85 THEN '85+'
                    WHEN date_part('year', age(r.fecha_nacimiento)) >= 80 THEN '80-84'
                    WHEN date_part('year', age(r.fecha_nacimiento)) >= 75 THEN '75-79' ELSE '<75' END,
               r.genero, r.condiciones_medicas IS NOT NULL
          FROM residente r
        ON CONFLICT (clave_anonima) DO UPDATE SET rango_edad = EXCLUDED.rango_edad, tiene_afecciones = EXCLUDED.tiene_afecciones;
        INSERT INTO dw.dim_area (nombre, tipo)
        SELECT a.nombre, a.tipo FROM area a WHERE NOT EXISTS (SELECT 1 FROM dw.dim_area d WHERE d.nombre = a.nombre);

        -- Frecuencia cardiaca: descarta duplicados (mismo dispositivo y fecha_hora) y agrega por hora
        SELECT count(*) - count(DISTINCT (id_dispositivo, fecha_hora)) INTO v_n
          FROM lectura_frecuencia_cardiaca WHERE fecha_hora >= v_desde AND fecha_hora < v_hasta;
        v_descartados := v_descartados + v_n;
        INSERT INTO dw.hecho_frecuencia_cardiaca_hora
        SELECT dw.id_tiempo(l.fecha_hora), dr.id_residente_dw, round(avg(l.frecuencia_cardiaca), 1),
               min(l.frecuencia_cardiaca), max(l.frecuencia_cardiaca), round(coalesce(stddev(l.frecuencia_cardiaca), 0), 2), count(*),
               count(*) FILTER (WHERE l.frecuencia_cardiaca NOT BETWEEN coalesce(ra.valor_min, fn_config('fc_min_defecto'))
                                                                    AND coalesce(ra.valor_max, fn_config('fc_max_defecto')))
          FROM (SELECT DISTINCT ON (id_dispositivo, fecha_hora) * FROM lectura_frecuencia_cardiaca
                 WHERE fecha_hora >= v_desde AND fecha_hora < v_hasta AND frecuencia_cardiaca BETWEEN 30 AND 220) l
          JOIN dw.dim_residente dr ON dr.clave_anonima = dw.clave_residente(l.id_residente)
          LEFT JOIN rango_alerta ra ON ra.id_residente = l.id_residente AND ra.variable = 'frecuencia_cardiaca'
         GROUP BY 1, 2
        ON CONFLICT (id_tiempo, id_residente_dw) DO UPDATE SET fc_promedio = EXCLUDED.fc_promedio, fc_minima = EXCLUDED.fc_minima,
               fc_maxima = EXCLUDED.fc_maxima, desviacion = EXCLUDED.desviacion, lecturas = EXCLUDED.lecturas,
               lecturas_fuera_rango = EXCLUDED.lecturas_fuera_rango;
        GET DIAGNOSTICS v_n = ROW_COUNT; v_cargados := v_cargados + v_n;

        -- Ambiente
        SELECT count(*) - count(DISTINCT (id_dispositivo, fecha_hora)) INTO v_n
          FROM lectura_ambiental WHERE fecha_hora >= v_desde AND fecha_hora < v_hasta;
        v_descartados := v_descartados + v_n;
        INSERT INTO dw.hecho_ambiental_hora
        SELECT dw.id_tiempo(la.fecha_hora), da.id_area_dw, round(avg(la.temperatura), 1), round(avg(la.humedad), 1),
               least(60, sum(CASE WHEN la.temperatura NOT BETWEEN a.temperatura_min AND a.temperatura_max
                                    OR la.humedad NOT BETWEEN a.humedad_min AND a.humedad_max THEN 60.0 / cnt.n ELSE 0 END))::smallint
          FROM (SELECT DISTINCT ON (id_dispositivo, fecha_hora) * FROM lectura_ambiental
                 WHERE fecha_hora >= v_desde AND fecha_hora < v_hasta) la
          JOIN area a ON a.id_area = la.id_area
          JOIN dw.dim_area da ON da.nombre = a.nombre
          JOIN LATERAL (SELECT count(*) n FROM lectura_ambiental x
                         WHERE x.id_area = la.id_area AND date_trunc('hour', x.fecha_hora) = date_trunc('hour', la.fecha_hora)) cnt ON TRUE
         GROUP BY 1, 2
        ON CONFLICT (id_tiempo, id_area_dw) DO UPDATE SET temperatura_promedio = EXCLUDED.temperatura_promedio,
               humedad_promedio = EXCLUDED.humedad_promedio, minutos_fuera_rango = EXCLUDED.minutos_fuera_rango;
        GET DIAGNOSTICS v_n = ROW_COUNT; v_cargados := v_cargados + v_n;

        -- Chequeos
        INSERT INTO dw.hecho_chequeo (id_tiempo, id_residente_dw, frecuencia_cardiaca, temperatura_corporal, peso, imc)
        SELECT dw.id_tiempo(c.fecha), dr.id_residente_dw, c.frecuencia_cardiaca, c.temperatura_corporal, c.peso, c.imc
          FROM chequeo c JOIN dw.dim_residente dr ON dr.clave_anonima = dw.clave_residente(c.id_residente)
         WHERE c.fecha >= v_desde AND c.fecha < v_hasta;
        GET DIAGNOSTICS v_n = ROW_COUNT; v_cargados := v_cargados + v_n;

        -- Alertas cerradas en el periodo
        INSERT INTO dw.hecho_alerta
        SELECT dw.id_tiempo(al.fecha_generacion), dr.id_residente_dw, da.id_area_dw, al.id_nivel, al.origen, al.estado,
               extract(epoch FROM al.fecha_atencion - al.fecha_generacion)::int,
               extract(epoch FROM al.fecha_cierre - al.fecha_generacion)::int, al.estado = 'falsa_alarma'
          FROM alerta al
          LEFT JOIN dw.dim_residente dr ON dr.clave_anonima = dw.clave_residente(al.id_residente)
          LEFT JOIN area a ON a.id_area = al.id_area
          LEFT JOIN dw.dim_area da ON da.nombre = a.nombre
         WHERE al.estado IN ('atendida', 'falsa_alarma') AND al.fecha_cierre >= v_desde AND al.fecha_cierre < v_hasta;
        GET DIAGNOSTICS v_n = ROW_COUNT; v_cargados := v_cargados + v_n;

        INSERT INTO dw.etl_corrida (fecha_fin, cargado_hasta, registros_cargados, registros_descartados, estado, detalle)
        VALUES (now(), v_hasta, v_cargados, v_descartados, 'ok', format('Periodo %s a %s', v_desde, v_hasta));
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO dw.etl_corrida (fecha_fin, cargado_hasta, estado, detalle)
        VALUES (now(), v_desde, 'error', SQLERRM);
    END;
END;
$$;

-- Lecturas por hora listas para el Isolation Forest y el modelo de riesgo (las lee el script de Python)
CREATE OR REPLACE VIEW dw.v_dataset_semanal AS
WITH fc AS (
    SELECT h.id_residente_dw, date_trunc('week', t.fecha)::date AS semana,
           round(avg(h.fc_promedio), 1) AS fc_media, round(avg(h.desviacion), 2) AS fc_desviacion,
           min(h.fc_minima) AS fc_minima, max(h.fc_maxima) AS fc_maxima,
           round(100.0 * sum(h.lecturas_fuera_rango) / nullif(sum(h.lecturas), 0), 2) AS pct_fuera_rango
      FROM dw.hecho_frecuencia_cardiaca_hora h JOIN dw.dim_tiempo t ON t.id_tiempo = h.id_tiempo
     GROUP BY 1, 2),
an AS (
    SELECT a.id_residente_dw, date_trunc('week', t.fecha)::date AS semana, count(*)::int AS horas_anomalas
      FROM dw.anomalia_fc a JOIN dw.dim_tiempo t ON t.id_tiempo = a.id_tiempo
     WHERE a.es_anomalia GROUP BY 1, 2)
SELECT fc.*, coalesce(an.horas_anomalas, 0) AS horas_anomalas, dr.rango_edad, dr.tiene_afecciones
  FROM fc
  JOIN dw.dim_residente dr ON dr.id_residente_dw = fc.id_residente_dw
  LEFT JOIN an ON an.id_residente_dw = fc.id_residente_dw AND an.semana = fc.semana;


-- =====================================================================
-- J. MANTENIMIENTO
-- =====================================================================

-- J1. Crea por adelantado las particiones de los próximos meses (programar una vez al mes)
CREATE OR REPLACE PROCEDURE sp_crear_particiones(p_meses INTEGER DEFAULT 3)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM crear_particiones_mes((date_trunc('month', now()) + make_interval(months => m))::date)
       FROM generate_series(0, p_meses) AS m;
END;
$$;

-- J2. Limpia refresh tokens vencidos o revocados con más de 30 días
CREATE OR REPLACE PROCEDURE sp_limpiar_tokens()
LANGUAGE sql AS $$
    DELETE FROM refresh_token WHERE (revocado OR fecha_expiracion < now()) AND fecha_creacion < now() - INTERVAL '30 days';
$$;
