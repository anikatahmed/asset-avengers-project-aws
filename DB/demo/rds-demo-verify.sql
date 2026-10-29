BEGIN;
SET LOCAL search_path TO pg_catalog, public, pg_temp;

CREATE TEMP TABLE rds_demo_checks (
    metric text,
    expected bigint,
    actual bigint
) ON COMMIT DROP;

CREATE TEMP TABLE rds_demo_publication (
    metric text,
    expected bigint,
    actual bigint
) ON COMMIT DROP;

DO $verify$
BEGIN
    IF current_database() = 'auth' THEN
        INSERT INTO pg_temp.rds_demo_checks
        SELECT 'demo clients', 200, count(*) FROM public.users WHERE id::text LIKE 'ed3f0001-%'
        UNION ALL
        SELECT 'disabled demo logins', 200, count(*) FROM public.users
            WHERE id::text LIKE 'ed3f0001-%' AND disabled_at IS NOT NULL
        UNION ALL
        SELECT 'non-client demo roles', 0, count(*) FROM public.users
            WHERE id::text LIKE 'ed3f0001-%' AND roles <> ARRAY['CLIENT']::text[];

    ELSIF current_database() = 'Endgame_Trading' THEN
        INSERT INTO pg_temp.rds_demo_checks
        SELECT 'demo clients', 200, count(*) FROM public.users WHERE user_id::text LIKE 'ed3f0001-%'
        UNION ALL
        SELECT 'investment accounts', 200, count(*) FROM public.accounts WHERE account_id::text LIKE 'ed3f0002-%'
        UNION ALL
        SELECT 'bank links', 200, count(*) FROM public.bank_accounts WHERE user_id::text LIKE 'ed3f0001-%'
        UNION ALL
        SELECT 'watchlists', 200, count(*) FROM public.watchlists WHERE user_id::text LIKE 'ed3f0001-%'
        UNION ALL
        SELECT 'watchlist items', 1200, count(*) FROM public.watchlist_items item
            JOIN public.watchlists list USING(watchlist_id) WHERE list.user_id::text LIKE 'ed3f0001-%'
        UNION ALL
        SELECT 'holding rows', 2000, count(*) FROM public.holdings WHERE account_id::text LIKE 'ed3f0002-%'
        UNION ALL
        SELECT 'positive positions', 1200, count(*) FROM public.holdings
            WHERE account_id::text LIKE 'ed3f0002-%' AND quantity > 0
        UNION ALL
        SELECT 'orders', 21600, count(*) FROM public.orders WHERE order_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'filled orders', 21200, count(*) FROM public.orders
            WHERE order_id::text LIKE 'ed3f0003-%' AND status = 'filled'
        UNION ALL
        SELECT 'rejected orders', 400, count(*) FROM public.orders
            WHERE order_id::text LIKE 'ed3f0003-%' AND status = 'rejected'
        UNION ALL
        SELECT 'pending orders', 0, count(*) FROM public.orders
            WHERE order_id::text LIKE 'ed3f0003-%' AND status IN ('submitted','accepted')
        UNION ALL
        SELECT 'trade fills', 21200, count(*) FROM public.trade_fills WHERE fill_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'traded asset categories', 7, count(DISTINCT instrument.security_type)
            FROM public.trade_fills fill JOIN public.instruments instrument USING(instrument_id)
            WHERE fill.fill_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'deposits', 600, count(*) FROM public.transactions
            WHERE transaction_id::text LIKE 'ed3f0005-%' AND txn_type = 'deposit'
        UNION ALL
        SELECT 'withdrawals', 200, count(*) FROM public.transactions
            WHERE transaction_id::text LIKE 'ed3f0005-%' AND txn_type = 'withdrawal'
        UNION ALL
        SELECT 'dividends', 200, count(*) FROM public.transactions
            WHERE transaction_id::text LIKE 'ed3f0005-%' AND txn_type = 'dividend'
        UNION ALL
        SELECT 'cash ledger movements', 22200, count(*) FROM public.cash_ledger
            WHERE account_id::text LIKE 'ed3f0002-%'
        UNION ALL
        SELECT 'order lifecycle events', 43200, count(*) FROM public.order_audit_events
            WHERE order_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'pricing evidence', 21600, count(*) FROM public.order_pricing_evidence
            WHERE order_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'disputes', 400, count(*) FROM public.client_disputes WHERE dispute_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'dispute statuses', 3, count(DISTINCT status) FROM public.client_disputes
            WHERE dispute_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'suspended accounts', 20, count(*) FROM public.accounts
            WHERE account_id::text LIKE 'ed3f0002-%' AND is_suspended
        UNION ALL
        SELECT 'suspension audit entries', 20, count(*) FROM public.staff_audit_events
            WHERE audit_id::text LIKE 'ed3f0002-%'
        UNION ALL
        SELECT 'cash reconciliation mismatches', 0, count(*) FROM public.accounts account_row
            LEFT JOIN (
                SELECT account_id, sum(cash_delta) AS ledger_cash FROM public.cash_ledger
                WHERE account_id::text LIKE 'ed3f0002-%' GROUP BY account_id
            ) ledger USING(account_id)
            WHERE account_row.account_id::text LIKE 'ed3f0002-%'
              AND account_row.cash_balance IS DISTINCT FROM ledger.ledger_cash
        UNION ALL
        SELECT 'holding reconciliation mismatches', 0, count(*) FROM (
            SELECT account_id, instrument_id, quantity FROM public.holdings
            WHERE account_id::text LIKE 'ed3f0002-%'
        ) position_row FULL JOIN (
            SELECT account_id, instrument_id, sum(holding_delta) AS ledger_quantity
            FROM public.cash_ledger WHERE account_id::text LIKE 'ed3f0002-%' AND instrument_id IS NOT NULL
            GROUP BY account_id, instrument_id
        ) ledger USING(account_id,instrument_id)
        WHERE coalesce(position_row.quantity,0) <> coalesce(ledger.ledger_quantity,0)
        UNION ALL
        SELECT 'negative historical cash balances', 0, count(*) FROM (
            SELECT sum(cash_delta) OVER (
                PARTITION BY account_id ORDER BY occurred_at, movement_id ROWS UNBOUNDED PRECEDING
            ) AS running_cash
            FROM public.cash_ledger WHERE account_id::text LIKE 'ed3f0002-%'
        ) history WHERE running_cash < 0
        UNION ALL
        SELECT 'negative historical share balances', 0, count(*) FROM (
            SELECT sum(holding_delta) OVER (
                PARTITION BY account_id, instrument_id ORDER BY occurred_at, movement_id ROWS UNBOUNDED PRECEDING
            ) AS running_quantity
            FROM public.cash_ledger WHERE account_id::text LIKE 'ed3f0002-%' AND movement_type = 'trade'
        ) history WHERE running_quantity < 0
        UNION ALL
        SELECT 'fill/order mismatches', 0, count(*) FROM public.trade_fills fill
            JOIN public.orders source_order USING(order_id)
            WHERE fill.fill_id::text LIKE 'ed3f0003-%' AND (
                source_order.status <> 'filled' OR source_order.price <> fill.price
                OR source_order.quantity <> fill.quantity OR source_order.order_side <> fill.order_side
                OR source_order.account_id <> fill.account_id OR source_order.instrument_id <> fill.instrument_id
                OR source_order.date_finalized <> fill.executed_at
                OR fill.cash_amount <> CASE WHEN fill.order_side = 'buy'
                    THEN ceil(fill.quantity * fill.price * 100) / 100
                    ELSE floor(fill.quantity * fill.price * 100) / 100 END
            );

    ELSIF current_database() = 'admin_analytics' THEN
        INSERT INTO pg_temp.rds_demo_checks
        SELECT 'demo client directory', 200, count(*) FROM reporting.client_directory WHERE client_id::text LIKE 'ed3f0001-%'
        UNION ALL
        SELECT 'investment accounts', 200, count(*) FROM public.client_accounts WHERE account_id::text LIKE 'ed3f0002-%'
        UNION ALL
        SELECT 'position rows', 2000, count(*) FROM public.client_positions WHERE account_id::text LIKE 'ed3f0002-%'
        UNION ALL
        SELECT 'positive positions', 1200, count(*) FROM public.client_positions
            WHERE account_id::text LIKE 'ed3f0002-%' AND quantity > 0
        UNION ALL
        SELECT 'orders', 21600, count(*) FROM public.trade_records WHERE order_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'filled order states', 21200, count(*) FROM audit.order_state
            WHERE order_id::text LIKE 'ed3f0003-%' AND status = 'filled'
        UNION ALL
        SELECT 'rejected order states', 400, count(*) FROM audit.order_state
            WHERE order_id::text LIKE 'ed3f0003-%' AND status = 'rejected'
        UNION ALL
        SELECT 'copied fills', 21200, count(*) FROM public.cash_holding_changes
            WHERE change_id::text LIKE 'ed3f0003-%' AND change_type = 'trade'
        UNION ALL
        SELECT 'copied cash movements', 22200, count(*) FROM public.cash_holding_changes
            WHERE account_id::text LIKE 'ed3f0002-%'
        UNION ALL
        SELECT 'recorded lifecycle events', 43200, count(*) FROM public.trade_lifecycle_events
            WHERE order_id::text LIKE 'ed3f0003-%' AND provenance = 'recorded'
        UNION ALL
        SELECT 'terminal order rejections', 400, count(*) FROM public.trade_lifecycle_events
            WHERE order_id::text LIKE 'ed3f0003-%' AND event_type = 'rejected' AND terminal
        UNION ALL
        SELECT 'pricing evidence', 21600, count(*) FROM audit.pricing_evidence
            WHERE order_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'suspended accounts', 20, count(*) FROM public.client_accounts
            WHERE account_id::text LIKE 'ed3f0002-%' AND is_suspended
        UNION ALL
        SELECT 'copied suspension audit entries', 20, count(*) FROM public.admin_audit_log
            WHERE audit_id::text LIKE 'ed3f0002-%'
        UNION ALL
        SELECT 'cash reconciliation mismatches', 0, count(*) FROM public.client_accounts account_row
            LEFT JOIN (
                SELECT account_id, sum(cash_delta) AS ledger_cash FROM public.cash_holding_changes
                WHERE account_id::text LIKE 'ed3f0002-%' GROUP BY account_id
            ) ledger USING(account_id)
            WHERE account_row.account_id::text LIKE 'ed3f0002-%'
              AND account_row.cash_balance IS DISTINCT FROM ledger.ledger_cash;

        INSERT INTO pg_temp.rds_demo_publication
        SELECT 'published demo fills', 21200, count(*) FROM analytics.published_trades
            WHERE fill_id::text LIKE 'ed3f0003-%'
        UNION ALL
        SELECT 'published demo report requests', (
                SELECT count(DISTINCT (occurred_at AT TIME ZONE 'America/New_York')::date)
                FROM public.cash_holding_changes
                WHERE change_id::text LIKE 'ed3f0003-%' AND change_type = 'trade'
            ), count(*) FROM integration.report_requests
            WHERE request_id::text LIKE 'ed3f000c-%' AND status = 'published'
        UNION ALL
        SELECT 'queued demo report requests', 0, count(*) FROM integration.report_requests
            WHERE request_id::text LIKE 'ed3f000c-%' AND status = 'queued'
        UNION ALL
        SELECT 'failed demo report requests', 0, count(*) FROM integration.report_requests
            WHERE request_id::text LIKE 'ed3f000c-%' AND status = 'failed';

    ELSIF current_database() = 'superset_metadata' THEN
        RAISE NOTICE 'No demo inserts belong in Superset metadata. Dashboard data is verified in admin_analytics.';
    ELSE
        RAISE EXCEPTION 'Choose auth, Endgame_Trading, admin_analytics or superset_metadata; connected to %', current_database();
    END IF;
END
$verify$;

SELECT current_database() AS database_name, metric, expected, actual, actual = expected AS passed
FROM pg_temp.rds_demo_checks ORDER BY metric;

SELECT 'Optional Historical Report Publication' AS stage, metric, expected, actual, actual = expected AS passed
FROM pg_temp.rds_demo_publication ORDER BY metric;

SELECT datname AS database_name, pg_size_pretty(pg_database_size(oid)) AS total_database_size
FROM pg_database WHERE datname IN ('auth','Endgame_Trading','admin_analytics','superset_metadata')
ORDER BY datname;

COMMIT;