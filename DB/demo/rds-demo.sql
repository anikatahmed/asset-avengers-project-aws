DO $demo$
DECLARE
    client_number integer;
    client_id uuid;
    client_email text;
    client_first_name text;
    client_last_name text;
    first_names text[] := ARRAY['Avery','Cameron','Casey','Jordan','Morgan','Riley','Sam','Taylor','Alex','Jamie'];
    last_names text[] := ARRAY['Adams','Bennett','Clark','Davis','Ellis','Franklin','Garcia','Hayes','Ibrahim','Jones','Kim','Lewis','Martin','Nguyen','Owens','Patel','Quinn','Rivera','Singh','Turner'];
    account_uuid uuid;
    order_uuid uuid;
    instrument_uuid uuid;
    transaction_uuid uuid;
    trade_number integer;
    symbol_number integer;
    rejection_number integer;
    required_trigger record;
    trade_side text;
    trade_quantity numeric(18,4);
    trade_price numeric(18,4);
    settled_cash numeric(18,2);
    initial_funding numeric(18,2);
    execution_time timestamptz;
    seed_today date := (clock_timestamp() AT TIME ZONE 'America/New_York')::date;
    symbols text[] := ARRAY['AAPL','MSFT','NVDA','JPM','VOO','X:BTC-USD','RDS-DEMO-BOND','RDS-DEMO-OPTION','RDS-DEMO-FUTURE','RDS-DEMO-FUND'];
    security_types text[] := ARRAY['equity','equity','equity','equity','etf','crypto','bond','option','future','mutual_fund'];
    base_prices numeric[] := ARRAY[110,240,130,220,500,50000,100,10,75,25];
    instrument_ids uuid[] := ARRAY[]::uuid[];
    rejection_text text;
    loaded_clients integer := 0;
    queued_reports integer;
BEGIN
    PERFORM set_config('search_path', 'pg_catalog, public, pg_temp', true);
    PERFORM set_config('lock_timeout', '5s', true);
    PERFORM pg_advisory_xact_lock(721921);

    IF current_database() NOT IN ('auth', 'Endgame_Trading', 'admin_analytics') THEN
        RAISE EXCEPTION 'Run this script in auth, then Endgame_Trading. Optional report requests run in admin_analytics after ingestion, not %. Superset metadata must not be seeded.', current_database();
    END IF;

    IF current_database() = 'admin_analytics' THEN
        IF (SELECT count(*) FROM public.client_accounts WHERE account_id::text LIKE 'ed3f0002-%') <> 200
            OR (SELECT count(*) FROM public.client_positions WHERE account_id::text LIKE 'ed3f0002-%') <> 2000
            OR (SELECT count(*) FROM public.cash_holding_changes WHERE account_id::text LIKE 'ed3f0002-%') <> 22200
            OR (SELECT count(*) FROM public.trade_records WHERE order_id::text LIKE 'ed3f0003-%') <> 21600
            OR (SELECT count(*) FROM audit.order_state WHERE order_id::text LIKE 'ed3f0003-%' AND status = 'filled') <> 21200
            OR (SELECT count(*) FROM audit.order_state WHERE order_id::text LIKE 'ed3f0003-%' AND status = 'rejected') <> 400
            OR (SELECT count(*) FROM public.trade_lifecycle_events WHERE order_id::text LIKE 'ed3f0003-%' AND event_type = 'filled') <> 21200
            OR (SELECT count(*) FROM public.admin_audit_log WHERE audit_id::text LIKE 'ed3f0002-%') <> 20
            OR EXISTS (
                SELECT 1 FROM public.client_accounts account_row
                LEFT JOIN (
                    SELECT account_id, sum(cash_delta) AS ledger_cash FROM public.cash_holding_changes
                    WHERE account_id::text LIKE 'ed3f0002-%' GROUP BY account_id
                ) ledger USING(account_id)
                WHERE account_row.account_id::text LIKE 'ed3f0002-%'
                  AND account_row.cash_balance IS DISTINCT FROM ledger.ledger_cash
            ) THEN
            RAISE EXCEPTION 'Demo ingestion is not complete. Wait for the pipeline and run rds-demo-verify.sql in admin_analytics before retrying; no report requests inserted.';
        END IF;

        IF EXISTS (SELECT 1 FROM integration.report_requests WHERE request_id::text LIKE 'ed3f000c-%' AND status = 'failed') THEN
            RAISE EXCEPTION 'A previous demo report request failed. Inspect its error and pipeline logs before retrying; existing requests preserved.';
        END IF;

        INSERT INTO integration.report_requests(request_id, requested_by, cutoff_at)
        SELECT ('ed3f000c-0000-0000-0000-' || lpad(to_char(report_day, 'YYYYMMDD'),12,'0'))::uuid,
            'ed3f000a-0000-0000-0000-000000000001'::uuid,
            (report_day + time '23:59:59.999999') AT TIME ZONE 'America/New_York'
        FROM (
            SELECT DISTINCT (occurred_at AT TIME ZONE 'America/New_York')::date AS report_day
            FROM public.cash_holding_changes WHERE change_id::text LIKE 'ed3f0003-%' AND change_type = 'trade'
        ) demo_days
        ON CONFLICT (request_id) DO NOTHING;
        GET DIAGNOSTICS queued_reports = ROW_COUNT;
        RAISE NOTICE 'Queued % new full-day demo report requests. Existing reporting worker publishes them; prior published versions are retained. No financial facts inserted directly.', queued_reports;
        RETURN;
    END IF;

    IF current_database() = 'Endgame_Trading' THEN
        FOR required_trigger IN
            SELECT * FROM (VALUES
                ('users','trg_outbox'), ('instruments','trg_outbox'),
                ('accounts','trg_outbox'), ('accounts','trg_accounts_set_updated_at'),
                ('orders','trg_outbox'), ('orders','trg_audit_order_lifecycle'),
                ('orders','trg_touch_account_on_order'), ('holdings','trg_outbox'),
                ('transactions','trg_outbox'), ('transactions','trg_cash_ledger_transaction'),
                ('trade_fills','trg_outbox'), ('trade_fills','trg_cash_ledger_fill'),
                ('cash_ledger','trg_outbox'), ('order_audit_events','trg_outbox'),
                ('order_pricing_evidence','trg_outbox'), ('staff_audit_events','trg_outbox')
            ) AS required(table_name, trigger_name)
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM pg_trigger
                WHERE tgrelid = to_regclass('public.' || required_trigger.table_name)
                  AND tgname = required_trigger.trigger_name AND tgenabled IN ('O','A')
            ) THEN
                RAISE EXCEPTION 'Required trigger %.% is missing or disabled; no changes committed',
                    required_trigger.table_name, required_trigger.trigger_name;
            END IF;
        END LOOP;

        FOR symbol_number IN 1..10 LOOP
            IF symbol_number > 6 THEN
                INSERT INTO public.instruments(instrument_id, symbol, name, security_type, exchange, currency, is_active)
                VALUES (
                    ('ed3f000b-0000-0000-0000-' || lpad(symbol_number::text, 12, '0'))::uuid,
                    symbols[symbol_number], 'Synthetic RDS demo ' || security_types[symbol_number],
                    security_types[symbol_number], 'SYNTHETIC', 'USD', false
                ) ON CONFLICT (symbol) DO NOTHING;
            END IF;

            SELECT instrument_id INTO instrument_uuid FROM public.instruments
            WHERE symbol = symbols[symbol_number] AND security_type = security_types[symbol_number]
              AND currency = 'USD' AND is_active = (symbol_number <= 6)
              AND (symbol_number <= 6 OR instrument_id =
                  ('ed3f000b-0000-0000-0000-' || lpad(symbol_number::text, 12, '0'))::uuid);
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Required instrument % is missing or has incompatible metadata; no changes committed', symbols[symbol_number];
            END IF;
            instrument_ids := array_append(instrument_ids, instrument_uuid);
        END LOOP;
    END IF;

    FOR client_number IN 1..200 LOOP
        client_id := ('ed3f0001-0000-0000-0000-' || lpad(client_number::text, 12, '0'))::uuid;
        client_email := 'rds.demo.' || lpad(client_number::text, 3, '0') || '@example.invalid';
        client_first_name := first_names[(client_number - 1) % 10 + 1];
        client_last_name := last_names[(client_number - 1) / 10 + 1];

        IF current_database() = 'auth' THEN
            IF EXISTS (
                SELECT 1 FROM public.users
                WHERE (id = client_id OR email = client_email)
                  AND (id <> client_id OR email <> client_email OR roles <> ARRAY['CLIENT']::text[])
            ) THEN
                RAISE EXCEPTION 'Demo identity collision for %; no changes committed', client_email;
            END IF;

            INSERT INTO public.users(id, email, password_hash, roles, first_name, last_name, disabled_at)
            VALUES (
                client_id, client_email,
                '$2b$10$XJ2SvU5yMBYQfPZP55.1l.Q0T5wIGOynaICT8JuG0vyNgIm92Eby2',
                ARRAY['CLIENT']::text[], client_first_name, client_last_name, clock_timestamp()
            ) ON CONFLICT (id) DO NOTHING;
            CONTINUE;
        END IF;

        account_uuid := ('ed3f0002-0000-0000-0000-' || lpad(client_number::text, 12, '0'))::uuid;
        initial_funding := (ARRAY[5000,50000,250000])[((client_number - 1) % 3) + 1];
        transaction_uuid := ('ed3f0005-0000-0000-0000-' || lpad((client_number * 10 + 1)::text, 12, '0'))::uuid;

        IF EXISTS (SELECT 1 FROM public.accounts WHERE account_id = account_uuid) THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.accounts account_row
                JOIN public.users client_row ON client_row.user_id = account_row.user_id
                JOIN public.transactions funding ON funding.account_id = account_row.account_id
                WHERE account_row.account_id = account_uuid AND client_row.user_id = client_id
                  AND client_row.email = client_email AND client_row.role = 'client'
                  AND funding.transaction_id = transaction_uuid
                  AND funding.txn_type = 'deposit' AND funding.amount = initial_funding
            ) OR (
                SELECT count(*) FROM public.trade_fills
                WHERE account_id = account_uuid AND fill_id::text LIKE 'ed3f0003-%'
            ) <> 106 THEN
                RAISE EXCEPTION 'Demo account collision or incomplete seed for %; existing records preserved', client_email;
            END IF;
            CONTINUE;
        END IF;

        IF EXISTS (SELECT 1 FROM public.users WHERE user_id = client_id OR email = client_email) THEN
            RAISE EXCEPTION 'Trading identity already exists without the expected demo account: %', client_email;
        END IF;

        INSERT INTO public.users(user_id, email, name, first_name, last_name, role)
        VALUES (client_id, client_email, client_first_name || ' ' || client_last_name,
            client_first_name, client_last_name, 'client');
        INSERT INTO public.accounts(account_id, user_id, account_name, account_type, cash_balance)
        VALUES (account_uuid, client_id, 'RDS Demo ' || lpad(client_number::text, 3, '0'),
            (ARRAY['Individual Brokerage','Roth IRA','Traditional IRA','Health Savings Account (HSA)'])[(client_number - 1) % 4 + 1], 0);
        INSERT INTO public.bank_accounts(bank_account_id, user_id, bank_name, routing_number, account_number)
        VALUES (account_uuid, client_id, 'SYNTHETIC DEMO BANK', '000000000', 'NOT-A-REAL-ACCOUNT-' || client_number);
        INSERT INTO public.watchlists(watchlist_id, user_id) VALUES (client_id, client_id);
        INSERT INTO public.watchlist_items(watchlist_id, instrument_id)
        SELECT client_id, unnest(instrument_ids[1:6]);

        INSERT INTO public.transactions(transaction_id, account_id, instrument_id, txn_type, amount, created_at)
        SELECT ('ed3f0005-0000-0000-0000-' || lpad((client_number * 10 + cash_event.number)::text, 12, '0'))::uuid,
            account_uuid, CASE WHEN cash_event.kind = 'dividend' THEN instrument_ids[1] END,
            cash_event.kind, cash_event.amount,
            ((seed_today - cash_event.days_ago) + time '08:00') AT TIME ZONE 'America/New_York'
        FROM (VALUES (1,'deposit',initial_funding,100), (2,'deposit',1000,31),
            (3,'withdrawal',250,20), (4,'dividend',25,10), (5,'deposit',500,5)
        ) AS cash_event(number, kind, amount, days_ago);

        FOR trade_number IN 1..106 LOOP
            IF trade_number <= 100 THEN
                symbol_number := ((trade_number - 1) / 2) % 10 + 1;
                trade_side := CASE WHEN trade_number % 2 = 1 THEN 'buy' ELSE 'sell' END;
                execution_time := ((seed_today - (1 + (client_number * 7 + ((trade_number + 1) / 2) * 3) % 90))
                    + time '09:00') AT TIME ZONE 'America/New_York';
                execution_time := execution_time + make_interval(mins => trade_number);
            ELSE
                symbol_number := trade_number - 100;
                trade_side := 'buy';
                execution_time := ((seed_today - 1) + time '12:00') AT TIME ZONE 'America/New_York';
                execution_time := execution_time + make_interval(mins => symbol_number);
            END IF;
            instrument_uuid := instrument_ids[symbol_number];
            trade_quantity := CASE WHEN symbol_number = 6 THEN 0.01 ELSE 0.25 END * (client_number % 4 + 1);
            trade_price := base_prices[symbol_number] *
                CASE WHEN trade_side = 'sell' THEN 1 + (client_number % 3 - 1) * 0.01 ELSE 1 END;
            settled_cash := CASE WHEN trade_side = 'buy' THEN ceil(trade_quantity * trade_price * 100) / 100
                ELSE floor(trade_quantity * trade_price * 100) / 100 END;
            order_uuid := ('ed3f0003-0000-0000-0000-' || lpad((client_number * 1000 + trade_number)::text, 12, '0'))::uuid;

            INSERT INTO public.orders(order_id, account_id, instrument_id, quantity, order_side, order_type,
                status, reserved_cash, date_placed)
            VALUES (order_uuid, account_uuid, instrument_uuid, trade_quantity, trade_side, 'market',
                'submitted', 0, execution_time - interval '1 second');
            INSERT INTO public.order_pricing_evidence(evidence_id, order_id, phase, decision, reason, quote_json, observed_at)
            VALUES (order_uuid, order_uuid, 'execution', 'accepted', 'Synthetic RDS demo; not a provider quote',
                jsonb_build_object('symbol', symbols[symbol_number], 'price', trade_price,
                    'ask', trade_price, 'bid', trade_price, 'currency', 'USD', 'asOf', execution_time,
                    'stale', false, 'source', 'rds-demo-seed', 'synthetic', true)::text, execution_time);
            INSERT INTO public.trade_fills(fill_id, order_id, account_id, instrument_id, order_side,
                quantity, price, cash_amount, executed_at)
            VALUES (order_uuid, order_uuid, account_uuid, instrument_uuid, trade_side,
                trade_quantity, trade_price, settled_cash, execution_time);
            UPDATE public.orders SET status = 'filled', price = trade_price, date_finalized = execution_time
            WHERE order_id = order_uuid;
        END LOOP;

        INSERT INTO public.holdings(account_id, instrument_id, quantity)
        SELECT account_uuid, instrument_id,
            sum(CASE WHEN order_side = 'buy' THEN quantity ELSE -quantity END)
        FROM public.trade_fills WHERE account_id = account_uuid GROUP BY instrument_id;

        FOR rejection_number IN 1..2 LOOP
            symbol_number := CASE WHEN rejection_number = 1 THEN 1 ELSE 5 END;
            order_uuid := ('ed3f0003-0000-0000-0000-' || lpad((client_number * 1000 + 106 + rejection_number)::text, 12, '0'))::uuid;
            execution_time := ((seed_today - 1) + time '13:00') AT TIME ZONE 'America/New_York';
            execution_time := execution_time + make_interval(mins => rejection_number);
            rejection_text := CASE WHEN rejection_number = 1 THEN 'Synthetic demo: insufficient available cash'
                ELSE 'Synthetic demo: stale execution quote' END;

            INSERT INTO public.orders(order_id, account_id, instrument_id, quantity, order_side, order_type,
                status, reserved_cash, date_placed)
            VALUES (order_uuid, account_uuid, instrument_ids[symbol_number],
                CASE WHEN rejection_number = 1 THEN 1000000 ELSE 1 END, 'buy', 'market',
                'submitted', 0, execution_time - interval '1 second');
            INSERT INTO public.order_pricing_evidence(evidence_id, order_id, phase, decision, reason, quote_json, observed_at)
            VALUES (order_uuid, order_uuid, 'execution', 'observed', rejection_text,
                jsonb_build_object('symbol', symbols[symbol_number], 'price', base_prices[symbol_number],
                    'ask', base_prices[symbol_number], 'bid', base_prices[symbol_number], 'currency', 'USD',
                    'asOf', CASE WHEN rejection_number = 2 THEN execution_time - interval '1 day' ELSE execution_time END,
                    'stale', rejection_number = 2, 'source', 'rds-demo-seed', 'synthetic', true)::text, execution_time);
            UPDATE public.orders SET status = 'rejected', rejection_reason = rejection_text,
                date_finalized = execution_time WHERE order_id = order_uuid;
            INSERT INTO public.client_disputes(dispute_id, account_id, order_id, category, description, status, created_at)
            VALUES (order_uuid, account_uuid, order_uuid,
                CASE WHEN rejection_number = 1 THEN 'funding' ELSE 'pricing' END,
                'Synthetic RDS demo dispute: please review this rejected order. No real money or provider execution is involved.',
                (ARRAY['submitted','in_review','resolved'])[(client_number + rejection_number) % 3 + 1],
                execution_time + interval '1 hour');
        END LOOP;

        UPDATE public.accounts SET cash_balance = (
            SELECT sum(cash_delta) FROM public.cash_ledger WHERE account_id = account_uuid
        ), is_suspended = (client_number % 10 = 0),
            suspension_reason = CASE WHEN client_number % 10 = 0 THEN 'Synthetic RDS demo suspension for staff review' END
        WHERE account_id = account_uuid;

        IF client_number % 10 = 0 THEN
            INSERT INTO public.staff_audit_events(audit_id, actor_id, actor_email, action, target_account_id, reason)
            VALUES (account_uuid, 'ed3f000a-0000-0000-0000-000000000001', 'rds-demo-seeder@example.invalid',
                'suspend_client', account_uuid,
                'Synthetic RDS demo: seed-generated suspension, not an action by a real staff member');
        END IF;
        loaded_clients := loaded_clients + 1;
        IF loaded_clients % 25 = 0 THEN
            RAISE NOTICE 'Prepared % new demo clients; changes commit only when the whole script succeeds', loaded_clients;
        END IF;
    END LOOP;

    IF current_database() = 'auth' THEN
        RAISE NOTICE 'Auth seed complete: 200 dedicated demo clients. New demo logins are disabled; existing identities were not changed.';
    ELSE
        RAISE NOTICE 'Trading seed complete: % new clients; expected seed totals: 200 clients, 200 accounts, 21200 fills, 400 rejections, 400 disputes, 20 suspended accounts. Existing accounts preserved.', loaded_clients;
    END IF;
END
$demo$;