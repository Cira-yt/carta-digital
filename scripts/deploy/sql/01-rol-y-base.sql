-- =====================================================================
-- Carta Digital — paso 1 de la inicialización de RDS (lo ejecuta el
-- user-data de cada instancia, conectado como el usuario MAESTRO de RDS a
-- la base "postgres"). Idempotente: si el rol/la base ya existen, no hace
-- nada destructivo (solo re-sincroniza la contraseña del rol de la app).
--
-- Variables psql (las pasa el script con -v):
--   app_user, app_pass, app_db
-- =====================================================================

-- Varias instancias del Auto Scaling arrancan a la vez: el candado evita
-- que dos intenten crear el rol/la base al mismo tiempo.
SET client_min_messages = warning;  -- oculta avisos inofensivos ("ya era miembro", etc.)
SELECT pg_advisory_lock(7310001);

SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') AS crear_rol \gset
\if :crear_rol
  CREATE ROLE :"app_user" LOGIN PASSWORD :'app_pass';
\else
  ALTER ROLE :"app_user" WITH LOGIN PASSWORD :'app_pass';
\endif

-- En RDS el usuario maestro no es superusuario: para crear una base cuyo
-- dueño es otro rol, tiene que ser miembro de ese rol.
GRANT :"app_user" TO CURRENT_USER;

SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') AS crear_db \gset
\if :crear_db
  CREATE DATABASE :"app_db" OWNER :"app_user";
\endif

SELECT pg_advisory_unlock(7310001);
