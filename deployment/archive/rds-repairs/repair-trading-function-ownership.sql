-- Run this entire DO statement in Endgame_Trading as postgres.
-- Changes only the eleven reviewed application function owners.
-- Definitions, grants, triggers, balances and data remain unchanged.
-- With autocommit enabled, no separate BEGIN or COMMIT is needed.
DO $repair_trading_functions$
DECLARE
    expected text[] := ARRAY[
        'public.block_audit_fact_mutation()',
        'public.block_trade_fill_mutation()',
        'public.block_transaction_mutation()',
        'public.enqueue_audit_change()',
        'public.prevent_staff_account()',
        'public.prevent_staff_role_with_account()',
        'public.record_cash_ledger()',
        'public.record_order_lifecycle()',
        'public.set_updated_at()',
        'public.touch_account_on_order()',
        'public.touch_account_on_transaction()'
    ];
    signature text;
    obj oid;
BEGIN
    IF current_database() <> 'Endgame_Trading' OR current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Connect to Endgame_Trading as postgres before running this batch';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='thor_trading') THEN
        RAISE EXCEPTION 'Expected owner role thor_trading is missing';
    END IF;
    PERFORM set_config('lock_timeout','5s',true);
    -- Validate the entire explicit function list before making any changes.
    FOREACH signature IN ARRAY expected LOOP
        obj := to_regprocedure(signature)::oid;
        IF obj IS NULL OR NOT EXISTS (
            SELECT FROM pg_proc p WHERE p.oid=obj AND p.prokind='f'
              AND pg_get_userbyid(p.proowner) IN ('postgres','thor_trading')
              AND NOT EXISTS (SELECT FROM pg_depend d WHERE d.classid='pg_proc'::regclass
                              AND d.objid=p.oid AND d.deptype='e')
        ) THEN
            RAISE EXCEPTION 'Expected function % is missing or ownership changed; inspect first',signature;
        END IF;
    END LOOP;
    FOREACH signature IN ARRAY expected LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO thor_trading',signature);
    END LOOP;
    RAISE NOTICE 'Changed 11 trading function owners to thor_trading';
END
$repair_trading_functions$;
