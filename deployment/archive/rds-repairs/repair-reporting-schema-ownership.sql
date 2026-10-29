-- Run this complete, small batch in admin_analytics as postgres.
-- Changes only the five named schema owners. Tables, views, routines and data
-- are untouched. Existing service-role grants remain in place.
-- psql: use -X -v ON_ERROR_STOP=1. On error, ROLLBACK and stop.
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $$
BEGIN
    IF current_database() <> 'admin_analytics' OR current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Connect to admin_analytics as postgres; current database %, login %',
            current_database(), current_user;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'fury_reporting_owner') THEN
        RAISE EXCEPTION 'Expected owner role fury_reporting_owner is missing';
    END IF;
    IF (SELECT count(*) FROM pg_namespace
        WHERE nspname IN ('admin','analytics','audit','integration','reporting')
          AND pg_get_userbyid(nspowner) IN ('postgres','fury_reporting_owner')) <> 5 THEN
        RAISE EXCEPTION 'Schema set or ownership changed; inspect before proceeding';
    END IF;
END $$;
ALTER SCHEMA admin OWNER TO fury_reporting_owner;
ALTER SCHEMA analytics OWNER TO fury_reporting_owner;
ALTER SCHEMA audit OWNER TO fury_reporting_owner;
ALTER SCHEMA integration OWNER TO fury_reporting_owner;
ALTER SCHEMA reporting OWNER TO fury_reporting_owner;
COMMIT;

SELECT nspname AS schema, pg_get_userbyid(nspowner) AS owner,
       has_schema_privilege('fury_reporting_owner',oid,'USAGE') AS owner_usage,
       has_schema_privilege('fury_reporting_owner',oid,'CREATE') AS owner_create
FROM pg_namespace
WHERE nspname IN ('admin','analytics','audit','integration','reporting')
ORDER BY nspname;
