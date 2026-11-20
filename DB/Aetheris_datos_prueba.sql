-- =====================================================================
-- Proyecto Aetheris - Sistema de monitoreo de asilos
-- Datos de prueba (PostgreSQL 16) · ejecutar después de Aetheris_BD.sql y Aetheris_BD_logica.sql
--
--   psql -d aetheris -f Aetheris_datos_prueba.sql
--
-- Las fechas son relativas a now(), así que los datos siempre se ven "recientes".
-- Solo para desarrollo y pruebas: NO cargar en producción.
--
-- Contraseña de todos los usuarios de prueba: Aetheris2026!
--   admin@nuevaesperanza.mx        administrador (Juan Pérez González, director)
--   enfermera1@nuevaesperanza.mx   personal
--   enfermero2@nuevaesperanza.mx   personal
--   cuidadora3@nuevaesperanza.mx   personal
--   laura.ramos@correo.com         familiar (hija de Carmen López)
--   pedro.soto@correo.com          familiar (nieto de Roberto Soto)
--   agente@aetheris.local          agente (token de servicio del servidor MCP)
--
-- Los dispositivos envían la llave fija IOT_API_KEY del .env en el encabezado X-API-Key.
-- (api_key_hash queda con valores de ejemplo y no es necesario usarlo.)
--
-- IMPORTANTE: la llave de cifrado de abajo debe ser la misma que LLAVE_DATOS
-- del .env del backend; si no, el backend no podrá descifrar los datos.
-- =====================================================================

\set ON_ERROR_STOP on
SET app.llave_datos = 'llave_de_pruebas_cambiar';
SET app.id_usuario = '';

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM asilo) THEN
        RAISE EXCEPTION 'La base ya tiene datos. Ejecuta este script sobre una base recién creada.';
    END IF;
END $$;

BEGIN;

-- ---------------------------------------------------------------------
-- Asilo y áreas
-- ---------------------------------------------------------------------
INSERT INTO asilo (nombre, direccion, ciudad, entidad, codigo_postal, telefono, correo)
VALUES ('Asilo Nueva Esperanza', 'Calle Esperanza 123, Col. Centro', 'Tijuana', 'Baja California', '22000', '6640000000', 'contacto@nuevaesperanza.mx');

INSERT INTO area (id_asilo, nombre, tipo, descripcion, temperatura_min, temperatura_max, humedad_min, humedad_max) VALUES
(1, 'Habitación 101', 'habitacion', 'Habitación doble, planta baja', 19.0, 27.0, 30.0, 65.0),   -- 1
(1, 'Habitación 102', 'habitacion', 'Habitación doble, planta baja', 19.0, 27.0, 30.0, 65.0),   -- 2
(1, 'Habitación 103', 'habitacion', 'Habitación individual',        19.0, 27.0, 30.0, 65.0),   -- 3
(1, 'Comedor',        'comun',      'Comedor principal',            18.0, 28.0, 30.0, 70.0),   -- 4
(1, 'Enfermería',     'servicio',   'Consultorio y chequeos',       20.0, 26.0, 35.0, 60.0);   -- 5

-- ---------------------------------------------------------------------
-- Usuarios (bcrypt generado con pgcrypto; compatible con passlib/bcrypt)
-- ---------------------------------------------------------------------
INSERT INTO usuario (correo, password_hash, rol, ultimo_acceso) VALUES
('admin@nuevaesperanza.mx',      crypt('Aetheris2026!', gen_salt('bf', 12)), 'administrador', now() - INTERVAL '1 hour'),  -- 1
('enfermera1@nuevaesperanza.mx', crypt('Aetheris2026!', gen_salt('bf', 12)), 'personal',      now() - INTERVAL '20 minutes'), -- 2
('enfermero2@nuevaesperanza.mx', crypt('Aetheris2026!', gen_salt('bf', 12)), 'personal',      now() - INTERVAL '3 hours'),  -- 3
('cuidadora3@nuevaesperanza.mx', crypt('Aetheris2026!', gen_salt('bf', 12)), 'personal',      NULL),                        -- 4
('laura.ramos@correo.com',       crypt('Aetheris2026!', gen_salt('bf', 12)), 'familiar',      now() - INTERVAL '1 day'),    -- 5
('pedro.soto@correo.com',        crypt('Aetheris2026!', gen_salt('bf', 12)), 'familiar',      NULL),                        -- 6
('agente@aetheris.local',        crypt('Aetheris2026!', gen_salt('bf', 12)), 'agente',        NULL);                        -- 7

-- Cuenta bloqueada para probar el bloqueo por intentos (RF-14)
INSERT INTO usuario (correo, password_hash, rol, activo, intentos_fallidos) VALUES
('bloqueado@nuevaesperanza.mx', crypt('Aetheris2026!', gen_salt('bf', 12)), 'personal', FALSE, 10);                    -- 8

-- ---------------------------------------------------------------------
-- Personal
-- ---------------------------------------------------------------------
INSERT INTO personal (id_asilo, id_usuario, nombre, apellido, fecha_nacimiento, genero, telefono, puesto) VALUES
(1, 1, 'Juan',     'Pérez González', '1975-04-12', 'Masculino', cifrar('6641112233'), 'Director'),     -- 1
(1, 2, 'Andrea',   'Castillo Ruiz',  '1992-08-03', 'Femenino',  cifrar('6642223344'), 'Enfermera'),    -- 2
(1, 3, 'Luis',     'Navarro Peña',   '1988-01-25', 'Masculino', cifrar('6643334455'), 'Enfermero'),    -- 3
(1, 4, 'Patricia', 'Gómez Lara',     '1995-11-17', 'Femenino',  cifrar('6644445566'), 'Cuidadora'),    -- 4
(1, 8, 'Mario',    'Ortiz Vega',     '1990-06-30', 'Masculino', cifrar('6645556677'), 'Cuidador');     -- 5
UPDATE personal SET activo = FALSE WHERE id_personal = 5;

-- ---------------------------------------------------------------------
-- Residentes (condiciones médicas cifradas)
-- ---------------------------------------------------------------------
INSERT INTO residente (id_asilo, id_area, nombre, apellido, fecha_nacimiento, genero, condiciones_medicas,
                       frecuencia_cardiaca_reposo, frecuencia_cardiaca_activo, frecuencia_cardiaca_agitado, fecha_ingreso) VALUES
(1, 1, 'Carmen',   'López Ramos',   '1944-03-15', 'Femenino',  cifrar('Hipertensión arterial'),             68, 95, 115, '2025-02-10'),  -- 1
(1, 1, 'Roberto',  'Soto Medina',   '1940-09-02', 'Masculino', cifrar('Insuficiencia cardiaca, diabetes'), 72, 98, 118, '2024-07-01'),  -- 2
(1, 2, 'Elena',    'Martínez Cruz', '1948-12-20', 'Femenino',  NULL,                                     70, 100, 120, '2025-09-15'), -- 3
(1, 2, 'Francisco','Ruiz Delgado',  '1938-05-08', 'Masculino', cifrar('EPOC'),                            75, 102, 122, '2023-11-20'), -- 4
(1, 3, 'Rosa',     'Herrera Díaz',  '1950-07-27', 'Femenino',  cifrar('Hipotiroidismo'),                  66, 92, 112, '2026-01-05');  -- 5

-- Residente dado de baja (baja lógica)
INSERT INTO residente (id_asilo, id_area, nombre, apellido, fecha_nacimiento, genero, fecha_ingreso, activo)
VALUES (1, 3, 'Alberto', 'Vargas Luna', '1936-02-14', 'Masculino', '2022-05-01', FALSE);                                                   -- 6

-- ---------------------------------------------------------------------
-- Familiares
-- ---------------------------------------------------------------------
INSERT INTO familiar (id_usuario, id_residente, id_parentesco, nombre, apellido, telefono, contacto_emergencia) VALUES
(5, 1, (SELECT id_parentesco FROM parentesco WHERE nombre = 'Hijo(a)'),  'Laura', 'Ramos López', cifrar('6647778899'), TRUE),
(6, 2, (SELECT id_parentesco FROM parentesco WHERE nombre = 'Nieto(a)'), 'Pedro', 'Soto Ríos',   cifrar('6648889900'), FALSE);

-- ---------------------------------------------------------------------
-- Dispositivos: 4 pulseras CooSpo HW807 y 2 nodos ambientales ESP32-S3 + DHT22
-- ---------------------------------------------------------------------
INSERT INTO dispositivo (id_asilo, id_area, tipo, modelo, direccion_mac, api_key_hash, estado, ultima_conexion) VALUES
(1, NULL, 'pulsera',        'CooSpo HW807',    'AA:BB:CC:00:00:01', crypt('AETH-DEV-1', gen_salt('bf')), 'activo',        now()),                       -- 1
(1, NULL, 'pulsera',        'CooSpo HW807',    'AA:BB:CC:00:00:02', crypt('AETH-DEV-2', gen_salt('bf')), 'activo',        now()),                       -- 2
(1, NULL, 'pulsera',        'CooSpo HW807',    'AA:BB:CC:00:00:03', crypt('AETH-DEV-3', gen_salt('bf')), 'activo',        now()),                       -- 3
(1, NULL, 'pulsera',        'CooSpo HW807',    'AA:BB:CC:00:00:04', crypt('AETH-DEV-4', gen_salt('bf')), 'mantenimiento', now() - INTERVAL '5 days'),   -- 4
(1, 1,    'nodo_ambiental', 'ESP32-S3 + DHT22','AA:BB:CC:00:01:01', crypt('AETH-DEV-5', gen_salt('bf')), 'activo',        now()),                       -- 5
(1, 4,    'nodo_ambiental', 'ESP32-S3 + DHT22','AA:BB:CC:00:01:02', crypt('AETH-DEV-6', gen_salt('bf')), 'activo',        now());                       -- 6

-- Asignaciones: 3 vigentes y 1 histórica (la pulsera 4 se retiró de Carmen y se le dio la 1)
INSERT INTO asignacion_dispositivo (id_dispositivo, id_residente, fecha_asignacion, fecha_retiro) VALUES
(4, 1, now() - INTERVAL '30 days', now() - INTERVAL '5 days'),
(1, 1, now() - INTERVAL '5 days',  NULL),
(2, 2, now() - INTERVAL '30 days', NULL),
(3, 3, now() - INTERVAL '20 days', NULL);

-- ---------------------------------------------------------------------
-- Rangos de alerta personalizados (residentes 4 y 5 usan el rango por defecto 50–120)
-- ---------------------------------------------------------------------
INSERT INTO rango_alerta (id_residente, variable, valor_min, valor_max, id_personal) VALUES
(1, 'frecuencia_cardiaca',  55, 110, 2),
(2, 'frecuencia_cardiaca',  55, 105, 2),
(3, 'frecuencia_cardiaca',  60, 100, 3),   -- rango estrecho para probar RF-02
(2, 'temperatura_corporal', 35.5, 37.8, 2),
(2, 'imc',                  18.5, 30.0, 2);

-- ---------------------------------------------------------------------
-- Lecturas de frecuencia cardiaca: última hora, cada minuto, 3 pulseras (180 filas)
-- Elena (residente 3) sube a 105–112 lpm en los últimos 5 minutos -> fuera de su rango 60–100
-- ---------------------------------------------------------------------
INSERT INTO lectura_frecuencia_cardiaca (id_residente, id_dispositivo, frecuencia_cardiaca, fecha_hora, fecha_recepcion)
SELECT a.id_residente, a.id_dispositivo,
       CASE WHEN a.id_residente = 3 AND m < 5 THEN 105 + (m % 3) * 3
            ELSE base + round(6 * sin(m / 7.0) + (m % 4))::int END,
       date_trunc('minute', now()) - m * INTERVAL '1 minute',
       date_trunc('minute', now()) - m * INTERVAL '1 minute' + INTERVAL '1 second'
FROM (VALUES (1, 1, 72), (2, 2, 78), (3, 3, 74)) AS a(id_residente, id_dispositivo, base),
     generate_series(0, 59) AS m;

-- ---------------------------------------------------------------------
-- Lecturas ambientales: últimas 24 h, cada 30 min, 2 nodos (96 filas)
-- El comedor pasa de 29 °C a media tarde -> alerta ambiental
-- ---------------------------------------------------------------------
INSERT INTO lectura_ambiental (id_area, id_dispositivo, temperatura, humedad, fecha_hora)
SELECT n.id_area, n.id_dispositivo,
       CASE WHEN n.id_area = 4 AND k BETWEEN 40 AND 41 THEN 29.4
            ELSE round((22.5 + 2.5 * sin(k / 7.6))::numeric, 1) END,
       round((45 + 8 * cos(k / 9.0))::numeric, 1),
       date_trunc('hour', now()) - k * INTERVAL '30 minutes'
FROM (VALUES (1, 5), (4, 6)) AS n(id_area, id_dispositivo), generate_series(0, 47) AS k;

-- ---------------------------------------------------------------------
-- Chequeos semanales: 3 semanas x 5 residentes (15 filas). El IMC lo calcula la base.
-- ---------------------------------------------------------------------
INSERT INTO chequeo (id_residente, id_personal, id_dispositivo, fecha, frecuencia_cardiaca, temperatura_corporal, peso, altura, observaciones)
SELECT r.id, CASE WHEN s % 2 = 0 THEN 2 ELSE 3 END, r.disp,
       date_trunc('day', now()) - (s * 7) * INTERVAL '1 day' + INTERVAL '9 hours',
       r.fc + s, r.temp + (s * 0.1), r.peso + s * 0.4, r.altura,
       CASE WHEN r.id = 2 AND s = 0 THEN cifrar('Edema leve en tobillos, se avisa al médico') END
FROM (VALUES (1, 1,    70, 36.5, 62.0, 1.58),
             (2, 2,    80, 37.2, 84.5, 1.70),
             (3, 3,    72, 36.6, 58.0, 1.55),
             (4, NULL, 76, 36.4, 66.0, 1.68),
             (5, NULL, 68, 36.7, 55.5, 1.60)) AS r(id, disp, fc, temp, peso, altura),
     generate_series(0, 2) AS s;

INSERT INTO observacion (id_residente, id_personal, observacion, fecha) VALUES
(2, 2, cifrar('Se queja de cansancio al caminar.'),        now() - INTERVAL '2 days'),
(4, 3, cifrar('Usa oxígeno por la noche según indicación.'), now() - INTERVAL '6 days'),
(1, 4, cifrar('Comió bien, buen ánimo.'),                   now() - INTERVAL '1 day');

-- ---------------------------------------------------------------------
-- Alertas: una de cada estado (el trigger llena alerta_historial)
-- ---------------------------------------------------------------------
INSERT INTO alerta (id_nivel, origen, id_residente, id_area, id_dispositivo, valor_registrado, mensaje, estado,
                    fecha_generacion, fecha_atencion, fecha_cierre, id_personal_atiende, notas_atencion) VALUES
-- 1 pendiente: Elena fuera de rango ahora mismo
(2, 'biometrica', 3, 2, 3, 112, 'Frecuencia cardiaca alta: 112 lpm (rango 60–100)', 'pendiente',
    now() - INTERVAL '1 minute', NULL, NULL, NULL, NULL),
-- 2 en atención
(3, 'biometrica', 2, 1, 2, 146, 'Frecuencia cardiaca crítica: 146 lpm', 'pendiente',
    now() - INTERVAL '25 minutes', NULL, NULL, NULL, NULL),
-- 3 atendida
(2, 'biometrica', 1, 1, 1, 118, 'Frecuencia cardiaca alta: 118 lpm (rango 55–110)', 'pendiente',
    now() - INTERVAL '2 days', NULL, NULL, NULL, NULL),
-- 4 falsa alarma
(2, 'biometrica', 2, 1, 2, 41, 'Frecuencia cardiaca baja: 41 lpm', 'pendiente',
    now() - INTERVAL '4 days', NULL, NULL, NULL, NULL),
-- 5 escalada (sin atender más de 60 min)
(1, 'ambiental', NULL, 4, 6, 29.4, 'Temperatura alta en Comedor: 29.4 °C (máx. 28.0)', 'pendiente',
    now() - INTERVAL '3 hours', NULL, NULL, NULL, NULL),
-- 6 atendida hace una semana (crítica, para el modelo de riesgo)
(3, 'biometrica', 2, 1, 2, 38, 'Frecuencia cardiaca crítica: 38 lpm', 'pendiente',
    now() - INTERVAL '8 days', NULL, NULL, NULL, NULL);

-- Cambios de estado como los haría el backend (quedan en el historial con el usuario)
SET app.id_usuario = '2';
UPDATE alerta SET estado = 'en_atencion', fecha_atencion = fecha_generacion + INTERVAL '2 minutes', id_personal_atiende = 2
 WHERE id_alerta IN (2, 3, 4, 6);
UPDATE alerta SET estado = 'atendida', fecha_cierre = fecha_generacion + INTERVAL '12 minutes',
       notas_atencion = 'Se le indicó reposo; la frecuencia volvió a su rango.' WHERE id_alerta = 3;
UPDATE alerta SET estado = 'falsa_alarma', fecha_cierre = fecha_generacion + INTERVAL '5 minutes',
       notas_atencion = 'La pulsera estaba floja; lectura incorrecta.' WHERE id_alerta = 4;
UPDATE alerta SET estado = 'atendida', fecha_cierre = fecha_generacion + INTERVAL '20 minutes',
       notas_atencion = 'Se llamó al médico de guardia; se estabilizó.' WHERE id_alerta = 6;
SET app.id_usuario = '';
UPDATE alerta SET estado = 'escalada' WHERE id_alerta = 5;   -- lo hace la tarea de escalamiento

-- ---------------------------------------------------------------------
-- Mensajes familiar–personal
-- ---------------------------------------------------------------------
INSERT INTO mensaje (id_residente, id_usuario_emisor, contenido, fecha_envio, leido) VALUES
(1, 5, 'Hola, ¿cómo amaneció mi mamá hoy?',                           now() - INTERVAL '3 hours',           TRUE),
(1, 2, 'Buenos días, Laura. Amaneció bien y desayunó completo.',       now() - INTERVAL '2 hours 50 minutes', TRUE),
(1, 5, 'Gracias. El sábado paso a visitarla.',                         now() - INTERVAL '2 hours 45 minutes', FALSE),
(2, 2, 'Pedro, su abuelo tuvo una alerta hace un momento; ya lo estamos atendiendo.', now() - INTERVAL '20 minutes', FALSE);

-- ---------------------------------------------------------------------
-- Web Push (suscripción de ejemplo; el endpoint es ficticio)
-- ---------------------------------------------------------------------
INSERT INTO suscripcion_push (id_usuario, endpoint, p256dh, auth) VALUES
(2, 'https://fcm.googleapis.com/fcm/send/prueba-andrea-001', 'BPruebaClavePublicaP256dh_EJEMPLO', 'PruebaAuth_EJEMPLO');

-- ---------------------------------------------------------------------
-- Bitácora
-- ---------------------------------------------------------------------
INSERT INTO bitacora (id_usuario, id_dispositivo, accion, detalle, ip_origen, fecha) VALUES
(1, NULL, 'inicio_sesion',      '{"resultado": "ok"}',                     '192.168.1.10', now() - INTERVAL '1 hour'),
(8, NULL, 'cuenta_bloqueada',   '{"intentos_fallidos": 10}',               '192.168.1.22', now() - INTERVAL '1 day'),
(NULL, 1, 'autenticacion_iot',  '{"resultado": "ok"}',                     '192.168.1.50', now() - INTERVAL '10 minutes'),
(2, NULL, 'cambio_rango',       '{"id_residente": 3, "variable": "frecuencia_cardiaca"}', '192.168.1.11', now() - INTERVAL '3 days');

-- ---------------------------------------------------------------------
-- ECBD: carga inicial del DW (equivale a una corrida del ETL) y resultados de ejemplo
-- ---------------------------------------------------------------------
DO $$ BEGIN PERFORM dw.cargar_dim_tiempo(now() - INTERVAL '30 days', now() + INTERVAL '1 day'); END $$;

INSERT INTO dw.dim_residente (clave_anonima, rango_edad, genero, tiene_afecciones)
SELECT dw.clave_residente(id_residente),
       CASE WHEN date_part('year', age(fecha_nacimiento)) >= 85 THEN '85+'
            WHEN date_part('year', age(fecha_nacimiento)) >= 80 THEN '80-84'
            WHEN date_part('year', age(fecha_nacimiento)) >= 75 THEN '75-79' ELSE '<75' END,
       genero, condiciones_medicas IS NOT NULL
FROM residente WHERE activo ORDER BY id_residente;

INSERT INTO dw.dim_area (nombre, tipo) SELECT nombre, tipo FROM area ORDER BY id_area;

INSERT INTO dw.hecho_frecuencia_cardiaca_hora
SELECT dw.id_tiempo(l.fecha_hora), dr.id_residente_dw, round(avg(l.frecuencia_cardiaca), 1), min(l.frecuencia_cardiaca), max(l.frecuencia_cardiaca),
       round(coalesce(stddev(l.frecuencia_cardiaca), 0), 2), count(*),
       count(*) FILTER (WHERE l.frecuencia_cardiaca NOT BETWEEN coalesce(ra.valor_min, 50) AND coalesce(ra.valor_max, 120))
FROM lectura_frecuencia_cardiaca l
JOIN dw.dim_residente dr ON dr.clave_anonima = dw.clave_residente(l.id_residente)
LEFT JOIN rango_alerta ra ON ra.id_residente = l.id_residente AND ra.variable = 'frecuencia_cardiaca'
GROUP BY 1, 2;

INSERT INTO dw.hecho_ambiental_hora
SELECT dw.id_tiempo(la.fecha_hora), da.id_area_dw, round(avg(la.temperatura), 1), round(avg(la.humedad), 1),
       (count(*) FILTER (WHERE la.temperatura NOT BETWEEN a.temperatura_min AND a.temperatura_max
                            OR la.humedad NOT BETWEEN a.humedad_min AND a.humedad_max) * 30)::smallint
FROM lectura_ambiental la JOIN area a ON a.id_area = la.id_area
JOIN dw.dim_area da ON da.nombre = a.nombre
GROUP BY 1, 2;

INSERT INTO dw.hecho_chequeo (id_tiempo, id_residente_dw, frecuencia_cardiaca, temperatura_corporal, peso, imc)
SELECT dw.id_tiempo(c.fecha), dr.id_residente_dw, c.frecuencia_cardiaca, c.temperatura_corporal, c.peso, c.imc
FROM chequeo c JOIN dw.dim_residente dr ON dr.clave_anonima = dw.clave_residente(c.id_residente);

INSERT INTO dw.hecho_alerta
SELECT dw.id_tiempo(al.fecha_generacion), dr.id_residente_dw, da.id_area_dw, al.id_nivel, al.origen, al.estado,
       extract(epoch FROM al.fecha_atencion - al.fecha_generacion)::int,
       extract(epoch FROM al.fecha_cierre - al.fecha_generacion)::int,
       al.estado = 'falsa_alarma'
FROM alerta al
LEFT JOIN dw.dim_residente dr ON dr.clave_anonima = dw.clave_residente(al.id_residente)
LEFT JOIN area a ON a.id_area = al.id_area
LEFT JOIN dw.dim_area da ON da.nombre = a.nombre
WHERE al.estado IN ('atendida', 'falsa_alarma');

INSERT INTO dw.etl_corrida (fecha_inicio, fecha_fin, cargado_hasta, registros_cargados, registros_descartados, estado, detalle)
VALUES (now() - INTERVAL '2 minutes', now() - INTERVAL '1 minute', now() - INTERVAL '2 minutes', 291, 2, 'ok',
        'Carga inicial de prueba; 2 lecturas descartadas (fuera de rango físico y duplicada).');

-- Modelos (métricas de ejemplo: sustituir por las reales al entrenar)
INSERT INTO dw.modelo_version (version, tipo, datos_entrenamiento, precision, recall, f1, auc, umbral, vigente, ruta_archivo) VALUES
('1.0', 'anomalias', 'simulado', NULL,  NULL,  NULL,  NULL,  NULL,  TRUE,  'modelos/isolation_forest_v1.joblib'),
('1.0', 'riesgo',    'simulado', 0.610, 0.780, 0.685, 0.840, 0.400, FALSE, 'modelos/random_forest_v1.joblib'),
('1.1', 'riesgo',    'mixto',    0.640, 0.830, 0.723, 0.870, 0.350, TRUE,  'modelos/random_forest_v1_1.joblib');

-- Anomalías: la última hora de Elena (subida de frecuencia)
INSERT INTO dw.anomalia_fc (id_tiempo, id_residente_dw, puntaje, es_anomalia)
SELECT h.id_tiempo, h.id_residente_dw,
       CASE WHEN h.id_residente_dw = 3 AND h.fc_maxima > 100 THEN -0.1820 ELSE 0.0950 END,
       h.id_residente_dw = 3 AND h.fc_maxima > 100
FROM dw.hecho_frecuencia_cardiaca_hora h;

-- Riesgo actual por residente (un nivel de cada tipo para probar el panel)
INSERT INTO dw.riesgo_residente (id_residente_dw, probabilidad, nivel_riesgo, factores, id_modelo)
SELECT dr.id_residente_dw, v.p, v.nivel, v.factores::jsonb, (SELECT id_modelo FROM dw.modelo_version WHERE tipo = 'riesgo' AND vigente)
FROM (VALUES
  (1, 0.240, 'Bajo',  '[{"variable": "alertas_30d", "valor": 1}]'),
  (2, 0.810, 'Alto',  '[{"variable": "alertas_criticas_30d", "valor": 2}, {"variable": "fc_desviacion", "valor": 9.4}, {"variable": "imc", "valor": 29.2}]'),
  (3, 0.470, 'Medio', '[{"variable": "pct_fuera_rango", "valor": 8.3}, {"variable": "horas_anomalas", "valor": 1}]'),
  (4, 0.330, 'Medio', '[{"variable": "edad", "valor": 88}, {"variable": "tiene_afecciones", "valor": true}]'),
  (5, 0.090, 'Bajo',  '[]')
) AS v(id_residente, p, nivel, factores)
JOIN dw.dim_residente dr ON dr.clave_anonima = dw.clave_residente(v.id_residente);

COMMIT;

-- Resumen de lo cargado
SELECT 'residentes activos' AS dato, count(*)::text AS valor FROM residente WHERE activo
UNION ALL SELECT 'lecturas FC', count(*)::text FROM lectura_frecuencia_cardiaca
UNION ALL SELECT 'lecturas ambientales', count(*)::text FROM lectura_ambiental
UNION ALL SELECT 'chequeos', count(*)::text FROM chequeo
UNION ALL SELECT 'alertas', count(*)::text FROM alerta
UNION ALL SELECT 'historial de alertas', count(*)::text FROM alerta_historial
UNION ALL SELECT 'residentes con riesgo calculado', count(*)::text FROM dw.riesgo_residente;
