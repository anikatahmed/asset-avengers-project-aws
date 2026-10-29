-- Run this entire DO statement in admin_analytics as postgres.
-- One atomic statement: no separate BEGIN or COMMIT needed with autocommit.
-- Changes only the 20 reviewed views; no functions, grants, or data changes.
DO $repair_views$
DECLARE
    expected text[] := ARRAY[
        'admin.audit_log', 'admin.client_accounts', 'admin.client_cash_history',
        'admin.client_positions', 'admin.trade_timeline', 'admin.trades',
        'analytics.business_overview', 'analytics.client_activity',
        'analytics.instrument_activity', 'analytics.named_published_trades',
        'analytics.published_trades', 'reporting.client_portfolios',
        'reporting.daily_instrument_activity', 'reporting.daily_trading_volume',
        'reporting.database_guide', 'reporting.fills', 'reporting.investment_accounts',
        'reporting.monthly_client_classifications', 'reporting.monthly_exec_summary',
        'reporting.monthly_segment_activity'
    ];
    obj record;
    changed integer := 0;
BEGIN
    IF current_database() <> 'admin_analytics' OR current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Connect to admin_analytics as postgres before running this batch';
    END IF;
    PERFORM set_config('lock_timeout', '5s', true);
    IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname || '.' || c.relname = ANY(expected)
          AND c.relkind='v'
          AND pg_get_userbyid(c.relowner) IN ('postgres','fury_reporting_owner')
          AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid='pg_class'::regclass
                          AND d.objid=c.oid AND d.deptype='e')) <> 20 THEN
        RAISE EXCEPTION 'Expected view set or ownership changed; inspect before proceeding';
    END IF;
    FOR obj IN
        SELECT n.nspname, c.relname
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname || '.' || c.relname = ANY(expected)
          AND c.relkind='v' AND pg_get_userbyid(c.relowner)='postgres'
        ORDER BY n.nspname,c.relname
    LOOP
        EXECUTE format('ALTER VIEW %I.%I OWNER TO fury_reporting_owner',obj.nspname,obj.relname);
        changed := changed + 1;
    END LOOP;
    RAISE NOTICE 'Changed % view owners to fury_reporting_owner',changed;
END
$repair_views$;
