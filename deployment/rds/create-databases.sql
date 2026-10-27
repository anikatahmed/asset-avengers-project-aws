-- Run via scripts/create-rds-databases.sh, connected as the RDS administrator.
-- CREATE DATABASE must run outside a transaction. All validation precedes mutations.
\set reset false
\getenv reset RDS_RESET_DATABASES
\getenv trading_db POSTGRES_DB
\getenv trading_user DB_USERNAME
\getenv trading_password DB_PASSWORD
\getenv auth_db AUTH_DB_NAME
\getenv auth_user AUTH_DB_USER
\getenv auth_password AUTH_DB_PASSWORD
\getenv reporting_db ADMIN_DB_NAME
\getenv owner_user ADMIN_DB_SUPERUSER
\getenv owner_password ADMIN_DB_SUPERUSER_PASSWORD
\getenv api_user ADMIN_DB_USERNAME
\getenv api_password ADMIN_DB_PASSWORD
\getenv etl_user ETL_DB_USERNAME
\getenv etl_password ETL_DB_PASSWORD
\getenv reader_user SUPERSET_REPORTING_USER
\getenv reader_password SUPERSET_REPORTING_PASSWORD
\getenv metadata_db SUPERSET_METADATA_DB
\getenv metadata_user SUPERSET_METADATA_USER
\getenv metadata_password SUPERSET_METADATA_PASSWORD

CREATE FUNCTION pg_temp.bootstrap_fail(message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '%', message; END $$;
CREATE TEMP TABLE bootstrap_logins (name text, secret text);
INSERT INTO bootstrap_logins VALUES
  (:'trading_user', :'trading_password'), (:'auth_user', :'auth_password'),
  (:'owner_user', :'owner_password'), (:'api_user', :'api_password'),
  (:'etl_user', :'etl_password'), (:'reader_user', :'reader_password'),
  (:'metadata_user', :'metadata_password');
CREATE TEMP TABLE bootstrap_databases (name text, owner_name text);
INSERT INTO bootstrap_databases VALUES
  (:'trading_db', :'trading_user'), (:'auth_db', :'auth_user'),
  (:'reporting_db', :'owner_user'), (:'metadata_db', :'metadata_user');
SELECT pg_temp.bootstrap_fail('Use seven distinct service logins, separate from the RDS administrator and analytics group roles.')
WHERE (SELECT count(DISTINCT name) FROM bootstrap_logins) <> 7
   OR EXISTS (SELECT FROM bootstrap_logins WHERE name = current_user
      OR name LIKE 'pg\_%' ESCAPE '\' OR name IN ('analytics_admin','analytics_etl','analytics_analyst','rdsadmin','rds_superuser'));
SELECT pg_temp.bootstrap_fail('Database names must be distinct and cannot be postgres, template0, template1 or rdsadmin.')
WHERE (SELECT count(DISTINCT name) FROM bootstrap_databases) <> 4
   OR EXISTS (SELECT FROM bootstrap_databases WHERE name IN ('postgres','template0','template1','rdsadmin'));
SELECT pg_temp.bootstrap_fail('Names/passwords must be nonempty, and names cannot exceed 63 bytes.')
WHERE EXISTS (SELECT FROM bootstrap_logins WHERE name = '' OR secret = '' OR octet_length(name) > 63)
   OR EXISTS (SELECT FROM bootstrap_databases WHERE name = '' OR octet_length(name) > 63);
\if :reset
\else
SELECT pg_temp.bootstrap_fail(format('Existing database %I has a different owner. Review its data, then assign the intended owner %I explicitly before retrying.', b.name, b.owner_name))
FROM bootstrap_databases b JOIN pg_database d ON d.datname = b.name
WHERE pg_get_userbyid(d.datdba) <> b.owner_name;
\endif

-- Existing login passwords are never changed; only explicit reset deletes database contents.
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', name, secret)
FROM bootstrap_logins b WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = b.name) \gexec
SELECT format('CREATE ROLE %I NOLOGIN', name)
FROM (VALUES ('analytics_admin'), ('analytics_etl'), ('analytics_analyst')) AS groups(name)
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = groups.name) \gexec
GRANT analytics_admin TO :"api_user";
GRANT analytics_etl TO :"etl_user";
GRANT analytics_analyst TO :"reader_user";
-- Permit pg_restore --role=OWNER while authenticated as this migration administrator.
SELECT format('GRANT %I TO %I', owner_name, current_user) FROM bootstrap_databases \gexec
\if :reset
\echo 'RESET: dropping the following configured databases and disconnecting their sessions:'
SELECT name AS database_to_reset FROM bootstrap_databases ORDER BY name;
SELECT format('DROP DATABASE %I WITH (FORCE)', name)
FROM bootstrap_databases b WHERE EXISTS (SELECT FROM pg_database WHERE datname = b.name) \gexec
\endif
SELECT format('CREATE DATABASE %I OWNER %I', name, owner_name)
FROM bootstrap_databases b WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = b.name) \gexec
\if :reset
\echo 'RDS databases recreated empty. Existing login passwords were preserved.'
\else
\echo 'RDS databases and roles prepared. Existing passwords/data were preserved.'
\endif
\echo 'Restore each dump with --no-owner --no-privileges --role=its_database_owner.'
\echo 'After restoring reporting, reapply DB/admin_analytics_db.schema.sql as its owner to restore reporting grants.'
SELECT b.name AS database, b.owner_name AS restore_role FROM bootstrap_databases b ORDER BY b.name;
