-- =====================================================================
-- Carta Digital — paso 2 de la inicialización de RDS (conectado como el
-- usuario de la APP a su propia base). Carga db/init.sql (esquema + datos
-- + usuarios de prueba) SOLO si la base está vacía: en un redeploy, o
-- cuando arranca una instancia nueva del Auto Scaling, no toca nada.
-- =====================================================================
SELECT pg_advisory_lock(7310002);

SELECT to_regclass('public.restaurantes') IS NULL AS base_vacia \gset
\if :base_vacia
  \echo '== Base vacía: cargando db/init.sql =='
  BEGIN;
  \i /sql-db/init.sql
  COMMIT;
\else
  \echo '== La base ya tiene datos: no se toca =='
\endif

SELECT pg_advisory_unlock(7310002);
