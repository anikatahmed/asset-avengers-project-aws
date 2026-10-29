-- Run this entire DO statement in admin_analytics as postgres.
-- Changes only these three function owners. Definitions, grants and data remain.
-- With autocommit enabled, no separate BEGIN or COMMIT is needed.
DO $repair_functions$
BEGIN
    IF current_database() <> 'admin_analytics' OR current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Connect to admin_analytics as postgres before running this batch';
    END IF;
    PERFORM set_config('lock_timeout','5s',true);
    IF (SELECT count(*) FROM pg_proc p
        WHERE p.oid IN (
            'public.block_admin_analytics_mutation()'::regprocedure,
            'reporting.instrument_activity(date,date)'::regprocedure,
            'reporting.portfolio_class(numeric)'::regprocedure
        ) AND pg_get_userbyid(p.proowner) IN ('postgres','fury_reporting_owner')
          AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid='pg_proc'::regclass
                          AND d.objid=p.oid AND d.deptype='e')) <> 3 THEN
        RAISE EXCEPTION 'Expected function set or ownership changed; inspect before proceeding';
    END IF;

    ALTER FUNCTION public.block_admin_analytics_mutation() OWNER TO fury_reporting_owner;
    ALTER FUNCTION reporting.instrument_activity(date,date) OWNER TO fury_reporting_owner;
    ALTER FUNCTION reporting.portfolio_class(numeric) OWNER TO fury_reporting_owner;

    RAISE NOTICE 'Changed 3 reporting function owners to fury_reporting_owner';
END
$repair_functions$;
