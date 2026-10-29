-- Disposable PostgreSQL regression only. Caller loads the trading schema first.
BEGIN;
DO $$
DECLARE
    client uuid := gen_random_uuid();
    account uuid;
    stale_time timestamptz := '2000-01-01T00:00:00Z';
    previous_time timestamptz;
    event record;
    projected_cash numeric := 0;
    projected_time timestamptz := stale_time;
BEGIN
    INSERT INTO users(user_id, role) VALUES(client, 'client');
    INSERT INTO accounts(user_id, cash_balance, updated_at)
    VALUES(client, 0, stale_time) RETURNING account_id INTO account;

    -- Match JPA: load account, insert transaction (which touches it in SQL),
    -- then flush the changed balance along with the stale loaded timestamp.
    INSERT INTO transactions(account_id, txn_type, amount) VALUES(account, 'deposit', 1000);
    UPDATE accounts SET cash_balance = 1000, updated_at = stale_time WHERE account_id = account;
    SELECT updated_at INTO previous_time FROM accounts WHERE account_id = account;
    IF previous_time <= stale_time THEN
        RAISE EXCEPTION 'Deposit regressed the account timestamp';
    END IF;

    -- Replay account events with the real consumer's >= timestamp rule.
    FOR event IN
        SELECT payload->'row' AS body FROM audit_outbox
        WHERE record_type = 'accounts' AND payload->'row'->>'account_id' = account::text
        ORDER BY sequence_id
    LOOP
        IF (event.body->>'updated_at')::timestamptz >= projected_time THEN
            projected_time := (event.body->>'updated_at')::timestamptz;
            projected_cash := (event.body->>'cash_balance')::numeric;
        END IF;
    END LOOP;
    IF projected_cash <> 1000 THEN
        RAISE EXCEPTION 'Deposit reporting balance is %, expected 1000', projected_cash;
    END IF;

    INSERT INTO transactions(account_id, txn_type, amount) VALUES(account, 'withdrawal', 250);
    UPDATE accounts SET cash_balance = 750, updated_at = stale_time WHERE account_id = account;
    IF (SELECT updated_at FROM accounts WHERE account_id = account) < previous_time THEN
        RAISE EXCEPTION 'Withdrawal regressed the account timestamp';
    END IF;
    FOR event IN
        SELECT payload->'row' AS body FROM audit_outbox
        WHERE record_type = 'accounts' AND payload->'row'->>'account_id' = account::text
        ORDER BY sequence_id
    LOOP
        IF (event.body->>'updated_at')::timestamptz >= projected_time THEN
            projected_time := (event.body->>'updated_at')::timestamptz;
            projected_cash := (event.body->>'cash_balance')::numeric;
        END IF;
    END LOOP;
    IF projected_cash <> 750 THEN
        RAISE EXCEPTION 'Withdrawal reporting balance is %, expected 750', projected_cash;
    END IF;
    IF (SELECT sum(cash_delta) FROM cash_ledger WHERE account_id = account) <> 750 THEN
        RAISE EXCEPTION 'Ledger does not match committed cash';
    END IF;
END $$;
ROLLBACK;
