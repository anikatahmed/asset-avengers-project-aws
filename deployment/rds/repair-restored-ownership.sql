-- Run this whole file as postgres, separately in each database:
-- Endgame_Trading, admin_analytics, superset_metadata.
-- Run the SAME file three times, changing the connected database each time.
-- Do not edit role names between runs. See deployment/rds/README.md.
-- BEGIN and COMMIT are already included; run through the end of the file.
-- It changes ownership/grants only; it does not insert, delete, or reset data.
-- Object scope: application schemas and objects owned by postgres, excluding extensions.
BEGIN;

DO $repair$
DECLARE
    target_owner name;
    app_schemas text[];
    obj record;
BEGIN
    CASE current_database()
        WHEN 'Endgame_Trading' THEN
            target_owner := 'thor_trading';
            app_schemas := ARRAY['public'];
        WHEN 'admin_analytics' THEN
            target_owner := 'fury_reporting_owner';
            app_schemas := ARRAY['public','admin','reporting','audit','analytics','integration'];
        WHEN 'superset_metadata' THEN
            target_owner := 'jarvis_metadata';
            app_schemas := ARRAY['public'];
        ELSE
            RAISE EXCEPTION 'Wrong database: %. Connect to one of the three listed databases.', current_database();
    END CASE;

    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run this repair as postgres, not %.', current_user;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = target_owner) THEN
        RAISE EXCEPTION 'Expected owner role % does not exist.', target_owner;
    END IF;

    -- Allow the migration administrator to assign objects to their intended owner.
    -- This does not grant any service account membership in postgres.
    EXECUTE format('GRANT %I TO postgres', target_owner);

    FOR obj IN
        SELECT n.oid, n.nspname
        FROM pg_namespace n
        WHERE n.nspname = ANY(app_schemas)
    LOOP
        EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', obj.nspname, target_owner);
        IF obj.nspname <> 'public'
           AND pg_get_userbyid((SELECT nspowner FROM pg_namespace WHERE oid = obj.oid)) = 'postgres'
           AND NOT EXISTS (SELECT FROM pg_depend WHERE classid = 'pg_namespace'::regclass
                           AND objid = obj.oid AND deptype = 'e') THEN
            EXECUTE format('ALTER SCHEMA %I OWNER TO %I', obj.nspname, target_owner);
        END IF;
    END LOOP;

    FOR obj IN
        SELECT c.oid, n.nspname, c.relname,
               CASE c.relkind
                   WHEN 'r' THEN 'TABLE' WHEN 'p' THEN 'TABLE'
                   WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
                   WHEN 'S' THEN 'SEQUENCE' WHEN 'f' THEN 'FOREIGN TABLE'
               END AS kind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY(app_schemas)
          AND c.relkind IN ('r','p','v','m','S','f')
          AND pg_get_userbyid(c.relowner) = 'postgres'
          AND NOT EXISTS (SELECT FROM pg_depend WHERE classid = 'pg_class'::regclass
                          AND objid = c.oid AND deptype = 'e')
        ORDER BY CASE WHEN c.relkind IN ('r','p','f') THEN 0
                      WHEN c.relkind = 'S' THEN 2 ELSE 1 END, n.nspname, c.relname
    LOOP
        EXECUTE format('ALTER %s %I.%I OWNER TO %I', obj.kind, obj.nspname, obj.relname, target_owner);
    END LOOP;

    FOR obj IN
        SELECT p.oid, n.nspname, p.proname,
               pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ANY(app_schemas)
          AND p.prokind IN ('f','p','w')
          AND pg_get_userbyid(p.proowner) = 'postgres'
          AND NOT EXISTS (SELECT FROM pg_depend WHERE classid = 'pg_proc'::regclass
                          AND objid = p.oid AND deptype = 'e')
    LOOP
        EXECUTE format('ALTER ROUTINE %I.%I(%s) OWNER TO %I', obj.nspname, obj.proname, obj.args, target_owner);
    END LOOP;

    FOR obj IN
        SELECT t.oid, n.nspname, t.typname,
               CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END AS kind
        FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = ANY(app_schemas) AND t.typtype IN ('e','d')
          AND pg_get_userbyid(t.typowner) = 'postgres'
          AND NOT EXISTS (SELECT FROM pg_depend WHERE classid = 'pg_type'::regclass
                          AND objid = t.oid AND deptype = 'e')
    LOOP
        EXECUTE format('ALTER %s %I.%I OWNER TO %I', obj.kind, obj.nspname, obj.typname, target_owner);
    END LOOP;

    RAISE NOTICE 'Application objects restored to owner % in database %.', target_owner, current_database();
END
$repair$;

-- Reporting logins inherit the existing, deliberately scoped group permissions.
DO $memberships$
BEGIN
    IF current_database() = 'admin_analytics' THEN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'analytics_admin') THEN
            CREATE ROLE analytics_admin NOLOGIN;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'analytics_etl') THEN
            CREATE ROLE analytics_etl NOLOGIN;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'analytics_analyst') THEN
            CREATE ROLE analytics_analyst NOLOGIN;
        END IF;
        GRANT analytics_admin TO endgame_admin WITH INHERIT TRUE;
        GRANT analytics_etl TO analytics_worker WITH INHERIT TRUE;
        GRANT analytics_analyst TO superset_reader WITH INHERIT TRUE;
    END IF;
END
$memberships$;

-- Reapply exactly the reporting GRANT statements from the repository schema.
-- No blanket reporting writes or reader ownership grants are introduced.
DO $reporting_grants$
BEGIN
    IF current_database() = 'admin_analytics' THEN
        GRANT USAGE ON SCHEMA public TO analytics_etl;
        GRANT SELECT, INSERT, UPDATE, DELETE ON client_accounts, client_positions,
            instruments TO analytics_etl;
        GRANT SELECT, INSERT ON trade_records, trade_lifecycle_events, cash_holding_changes,
            monthly_client_segments TO analytics_etl;
        GRANT USAGE ON SCHEMA public, admin, reporting TO analytics_admin;
        GRANT SELECT ON ALL TABLES IN SCHEMA public, admin, reporting TO analytics_admin;
        GRANT INSERT ON admin_audit_log TO analytics_admin;
        GRANT USAGE ON SCHEMA reporting TO analytics_analyst;
        GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO analytics_analyst;
        GRANT EXECUTE ON FUNCTION reporting.instrument_activity(DATE, DATE) TO analytics_analyst, analytics_admin;
        GRANT USAGE ON SCHEMA audit,integration,analytics TO analytics_etl,analytics_admin;
        GRANT SELECT,INSERT ON audit.ingested_events,audit.pricing_evidence TO analytics_etl;
        GRANT SELECT,INSERT,UPDATE ON audit.order_state,integration.pipeline_status,
            integration.report_batches,integration.published_reports TO analytics_etl;
        GRANT SELECT,INSERT ON analytics.trade_facts,admin_audit_log TO analytics_etl;
        GRANT SELECT ON ALL TABLES IN SCHEMA audit,integration,analytics TO analytics_admin;
        GRANT USAGE ON SCHEMA analytics TO analytics_analyst;
        GRANT SELECT ON analytics.published_trades,analytics.business_overview,
            analytics.instrument_activity,analytics.client_activity TO analytics_analyst;
        GRANT SELECT ON integration.dashboard_registry TO analytics_admin;
        GRANT USAGE ON SCHEMA admin TO analytics_etl;
        GRANT SELECT ON ALL TABLES IN SCHEMA admin TO analytics_etl;
        GRANT SELECT ON analytics.published_trades,analytics.business_overview,
            analytics.instrument_activity,analytics.client_activity TO analytics_etl;
        GRANT SELECT,INSERT ON integration.report_schedules TO analytics_admin;
        GRANT SELECT ON integration.report_schedules TO analytics_etl;
        GRANT SELECT,INSERT ON integration.report_requests TO analytics_admin;
        GRANT SELECT,UPDATE ON integration.report_requests TO analytics_etl;
        GRANT SELECT ON reporting.client_directory TO analytics_admin,analytics_analyst;
        GRANT USAGE ON SCHEMA reporting TO analytics_etl;
        GRANT SELECT,INSERT,UPDATE ON reporting.client_directory TO analytics_etl;
        GRANT SELECT,INSERT,UPDATE ON reporting.instrument_marks TO analytics_etl;
        GRANT SELECT ON reporting.client_portfolios,reporting.monthly_client_classifications TO analytics_admin,analytics_analyst,analytics_etl;
        GRANT SELECT ON analytics.named_published_trades TO analytics_analyst,analytics_admin,analytics_etl;
        GRANT SELECT ON reporting.database_guide TO analytics_admin,analytics_analyst,analytics_etl;
        GRANT SELECT ON reporting.instrument_marks TO analytics_admin,analytics_analyst;
        GRANT SELECT ON reporting.investment_accounts TO analytics_admin,analytics_analyst,analytics_etl;
    END IF;
END
$reporting_grants$;

COMMIT;

-- Verification: database owner plus relation owners in application schemas.
SELECT current_database() AS database, pg_get_userbyid(datdba) AS database_owner
FROM pg_database WHERE datname = current_database();

SELECT n.nspname AS schema, c.relname AS object, c.relkind,
       pg_get_userbyid(c.relowner) AS owner
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('public','admin','reporting','audit','analytics','integration')
  AND c.relkind IN ('r','p','v','m','S','f')
  AND NOT EXISTS (SELECT FROM pg_depend WHERE classid = 'pg_class'::regclass
                  AND objid = c.oid AND deptype = 'e')
ORDER BY n.nspname, c.relname;
