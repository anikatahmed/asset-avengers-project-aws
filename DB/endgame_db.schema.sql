-- Authoritative trading schema used by backend/; object ownership and data flows
-- are documented in DB/README.md. Reporting copies never write these balances.
-- Dialect: PostgreSQL (local Compose pins 18.6). Designed for repeated application:
-- uses IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS throughout.

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- for gen_random_uuid()

-- generic helper to keep updated_at columns current on any row change
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- users
-- ============================================================
-- One row per person who has used the trading API. Rows are created by Spring
-- (CurrentUserService.account) on a user's first authenticated request.
-- user_id is the auth service's user id (the JWT's sub). That service has its own
-- database, so there is no foreign key to it.
CREATE TABLE IF NOT EXISTS users (
    user_id     UUID PRIMARY KEY,
    email       VARCHAR(255) UNIQUE,  -- copied display/search metadata; UUID determines ownership
    name        VARCHAR(255),         -- full name copied from verified auth claims
    first_name  VARCHAR(100),
    last_name   VARCHAR(100),
    role        VARCHAR(20) NOT NULL CHECK (role IN ('admin', 'analyst', 'client')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Bring databases created from the older version of this table up to date.
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_user_id_fkey;
ALTER TABLE users ALTER COLUMN name DROP NOT NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS first_name VARCHAR(100);
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_name VARCHAR(100);
ALTER TABLE users ADD COLUMN IF NOT EXISTS email VARCHAR(255) UNIQUE;
-- Auth owns email uniqueness. A recreated auth identity must not collide with a
-- retained trading identity, or inherit its accounts merely by reusing an email.
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_email_key;
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
ALTER TABLE users ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_users_role ON users (role);

-- ============================================================
-- accounts
-- ============================================================
-- Cash and suspension are mutable current state. Banking/orders take an account
-- row lock before competing changes; permanent movements live in separate tables.
CREATE TABLE IF NOT EXISTS accounts (
    account_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users (user_id) ON DELETE RESTRICT,
    account_name    VARCHAR(100) NOT NULL DEFAULT 'Main brokerage',
    account_type    VARCHAR(80) NOT NULL DEFAULT 'Individual Brokerage',
    cash_balance    NUMERIC(18, 2) NOT NULL DEFAULT 0 CHECK (cash_balance >= 0),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_suspended     BOOLEAN NOT NULL DEFAULT FALSE,
    deactivated      BOOLEAN NOT NULL DEFAULT FALSE
);

ALTER TABLE accounts ADD COLUMN IF NOT EXISTS account_name VARCHAR(100) NOT NULL DEFAULT 'Main brokerage';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS account_type VARCHAR(80) NOT NULL DEFAULT 'Individual Brokerage';
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS deactivated BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_accounts_user_id ON accounts (user_id);

-- Transaction/order triggers touch this row before Hibernate flushes its account
-- entity. Restamp every update so a stale entity cannot move updated_at backward
-- and make the reporting consumer discard a committed balance change.
DROP TRIGGER IF EXISTS trg_accounts_set_updated_at ON accounts;
CREATE TRIGGER trg_accounts_set_updated_at
    BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- analysts and admins are staff, not traders, and must never hold a trading account
CREATE OR REPLACE FUNCTION prevent_staff_account()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM users WHERE user_id = NEW.user_id AND role IN ('admin', 'analyst')) THEN
        RAISE EXCEPTION 'staff cannot have trading accounts (user_id: %)', NEW.user_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_staff_account ON accounts;
CREATE TRIGGER trg_prevent_staff_account
    BEFORE INSERT OR UPDATE OF user_id ON accounts
    FOR EACH ROW EXECUTE FUNCTION prevent_staff_account();

-- block promoting a user to staff while they already own an account
CREATE OR REPLACE FUNCTION prevent_staff_role_with_account()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.role IN ('admin', 'analyst') AND EXISTS (SELECT 1 FROM accounts WHERE user_id = NEW.user_id) THEN
        RAISE EXCEPTION 'cannot set role to staff: user_id % already has a trading account', NEW.user_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_staff_role_with_account ON users;
CREATE TRIGGER trg_prevent_staff_role_with_account
    BEFORE INSERT OR UPDATE OF role ON users
    FOR EACH ROW EXECUTE FUNCTION prevent_staff_role_with_account();

-- ============================================================
-- bank_accounts (user's linked bank accounts for deposits/withdrawals)
-- ============================================================
-- Linked funding metadata for simulated banking. API masking is presentation only;
-- these stored numbers are not encrypted and must never enter the audit outbox.
CREATE TABLE IF NOT EXISTS bank_accounts (
    bank_account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
    bank_name       VARCHAR(255) NOT NULL,
    routing_number  VARCHAR(20) NOT NULL,
    account_number  VARCHAR(255) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bank_accounts_user_id ON bank_accounts (user_id);

-- ============================================================
-- instruments (shared catalogue plus verified on-demand discoveries)
-- ============================================================
-- Catalogue metadata, not prices or ownership. Seed IDs stay stable because orders,
-- holdings and stars refer to them; verified unknown tickers can be added later.
CREATE TABLE IF NOT EXISTS instruments (
    instrument_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol          VARCHAR(20) NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    security_type   VARCHAR(30) NOT NULL CHECK (security_type IN ('equity', 'etf', 'bond', 'option', 'future', 'crypto', 'mutual_fund')),
    exchange        VARCHAR(50),
    currency        VARCHAR(10) NOT NULL DEFAULT 'USD',
    isin            VARCHAR(12) CHECK (isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$') UNIQUE, -- International Securities Identification Number
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX IF NOT EXISTS idx_instruments_security_type ON instruments (security_type);
CREATE INDEX IF NOT EXISTS idx_instruments_is_active ON instruments (is_active);

-- ============================================================
-- watchlists
-- ============================================================
-- A list belongs to a user rather than a browser session, so stars survive logout.
CREATE TABLE IF NOT EXISTS watchlists (
    watchlist_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id)
);

CREATE INDEX IF NOT EXISTS idx_watchlists_user_id ON watchlists (user_id);

DROP TRIGGER IF EXISTS trg_watchlists_set_updated_at ON watchlists;
CREATE TRIGGER trg_watchlists_set_updated_at
    BEFORE UPDATE ON watchlists
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- watchlist_items
-- ============================================================
CREATE TABLE IF NOT EXISTS watchlist_items (
    watchlist_item_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    watchlist_id UUID NOT NULL REFERENCES watchlists (watchlist_id) ON DELETE CASCADE,
    instrument_id UUID NOT NULL REFERENCES instruments (instrument_id) ON DELETE CASCADE,
    added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (watchlist_id, instrument_id)
);

CREATE INDEX IF NOT EXISTS idx_watchlist_items_watchlist_id ON watchlist_items (watchlist_id);
CREATE INDEX IF NOT EXISTS idx_watchlist_items_instrument_id ON watchlist_items (instrument_id);

-- ============================================================
-- orders (buy/sell only; execution price comes from a middle-tier API)
-- ============================================================
-- Acceptance saves a commitment; the worker later settles it at a fresh provider
-- quote. reserved_cash is unavailable to other buys/withdrawals but is still cash.
CREATE TABLE IF NOT EXISTS orders (
    order_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id      UUID NOT NULL REFERENCES accounts (account_id) ON DELETE RESTRICT,
    instrument_id   UUID NOT NULL REFERENCES instruments (instrument_id) ON DELETE RESTRICT,
    quantity        NUMERIC(18, 4) NOT NULL CHECK (quantity > 0), -- allow fractional quantities
    order_side      VARCHAR(10) NOT NULL CHECK (order_side IN ('buy', 'sell')),
    order_type      VARCHAR(20) NOT NULL CHECK (order_type IN ('market', 'limit', 'stop', 'stop_limit')),
    limit_price     NUMERIC(18, 4) CHECK (limit_price > 0),
    stop_price      NUMERIC(18, 4) CHECK (stop_price > 0),
    price           NUMERIC(18, 4) CHECK (price > 0), -- execution price, filled in by middle-tier once order fills
    reserved_cash   NUMERIC(38, 2) CHECK (reserved_cash >= 0), -- cash commitment while submitted/accepted
    stop_triggered  BOOLEAN NOT NULL DEFAULT FALSE,
    status          VARCHAR(20) NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted', 'accepted', 'filled', 'cancelled', 'rejected')),
    rejection_reason  VARCHAR(255) CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL), -- reason for order rejection, if applicable
    date_placed      TIMESTAMPTZ NOT NULL DEFAULT now(),
    date_finalized      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (order_type NOT IN ('limit', 'stop_limit') OR limit_price IS NOT NULL),
    CHECK (order_type NOT IN ('stop', 'stop_limit') OR stop_price IS NOT NULL),
    CHECK (status <> 'filled' OR price IS NOT NULL)
);

-- Request-level deduplication: keep these records for the lifetime of their orders.
-- The API locks the caller's user row before lookup/create so concurrent retries serialize.
CREATE TABLE IF NOT EXISTS order_submission_keys (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    request_key UUID NOT NULL,
    fingerprint VARCHAR(64) NOT NULL,
    order_id UUID NOT NULL REFERENCES orders(order_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, request_key)
);

-- Upgrade existing orders without modifying their execution prices or statuses.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS reserved_cash NUMERIC(38, 2) CHECK (reserved_cash >= 0);
ALTER TABLE orders ADD COLUMN IF NOT EXISTS stop_triggered BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_status_check;
ALTER TABLE orders ADD CONSTRAINT orders_status_check
    CHECK (status IN ('submitted', 'accepted', 'filled', 'cancelled', 'rejected'));
ALTER TABLE orders ALTER COLUMN date_finalized DROP NOT NULL;
ALTER TABLE orders ALTER COLUMN date_finalized DROP DEFAULT;
UPDATE orders SET reserved_cash = ceil(quantity * limit_price * 100) / 100
    WHERE reserved_cash IS NULL AND status IN ('submitted', 'accepted') AND order_side = 'buy'
      AND order_type IN ('limit', 'stop_limit');
-- Legacy market/stop buys remain unpriced. Cancel and resubmit them with a fresh
-- quote; validation blocks further buys until their commitments are known.

CREATE INDEX IF NOT EXISTS idx_orders_account_id ON orders (account_id);
CREATE INDEX IF NOT EXISTS idx_orders_instrument_id ON orders (instrument_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders (status);
CREATE INDEX IF NOT EXISTS idx_orders_order_date ON orders (date_placed);
CREATE INDEX IF NOT EXISTS idx_orders_account_id_order_date ON orders (account_id, date_placed DESC);

DROP TRIGGER IF EXISTS trg_orders_set_updated_at ON orders;
CREATE TRIGGER trg_orders_set_updated_at
    BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- trigger to update the account's updated_at timestamp whenever a new order is inserted
CREATE OR REPLACE FUNCTION touch_account_on_order()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE accounts SET updated_at = now() WHERE account_id = NEW.account_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
 
DROP TRIGGER IF EXISTS trg_touch_account_on_order ON orders;
CREATE TRIGGER trg_touch_account_on_order
    AFTER INSERT ON orders
    FOR EACH ROW EXECUTE FUNCTION touch_account_on_order();

-- ============================================================
-- transactions (cash/instrument events not tied to a buy/sell order)
-- ============================================================
CREATE TABLE IF NOT EXISTS transactions (
    transaction_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id      UUID NOT NULL REFERENCES accounts (account_id) ON DELETE RESTRICT,
    instrument_id   UUID REFERENCES instruments (instrument_id) ON DELETE RESTRICT,
    txn_type        VARCHAR(20) NOT NULL CHECK (txn_type IN ('deposit', 'withdrawal', 'dividend')),
    amount          NUMERIC(18, 2) NOT NULL CHECK (amount > 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- only dividends are tied to an instrument; deposits/withdrawals are pure cash movements
    CHECK ((txn_type = 'dividend' AND instrument_id IS NOT NULL) OR (txn_type <> 'dividend' AND instrument_id IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_transactions_account_id ON transactions (account_id);
CREATE INDEX IF NOT EXISTS idx_transactions_txn_type ON transactions (txn_type);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at ON transactions (created_at);
CREATE INDEX IF NOT EXISTS idx_transactions_instrument_id ON transactions (instrument_id) WHERE instrument_id IS NOT NULL;

-- transactions are part of the permanent record (BR-14): no edits, ever
CREATE OR REPLACE FUNCTION block_transaction_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'transactions are append-only and cannot be updated or deleted (transaction_id: %)',
        OLD.transaction_id;
END;
$$ LANGUAGE plpgsql;
 
DROP TRIGGER IF EXISTS trg_block_transaction_update ON transactions;
CREATE TRIGGER trg_block_transaction_update
    BEFORE UPDATE OR DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION block_transaction_mutation();
 
-- stamp the owning account's updated_at the moment a transaction is placed
CREATE OR REPLACE FUNCTION touch_account_on_transaction()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE accounts SET updated_at = now() WHERE account_id = NEW.account_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
 
DROP TRIGGER IF EXISTS trg_touch_account_on_transaction ON transactions;
CREATE TRIGGER trg_touch_account_on_transaction
    AFTER INSERT ON transactions
    FOR EACH ROW EXECUTE FUNCTION touch_account_on_transaction();

-- ============================================================
-- holdings (current position per account/instrument)
-- ============================================================
-- Current position, updated atomically with a fill. Purchase history is read from
-- immutable trade_fills rather than inferred from this changing quantity.
CREATE TABLE IF NOT EXISTS holdings (
    holding_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id      UUID NOT NULL REFERENCES accounts (account_id) ON DELETE RESTRICT,
    instrument_id   UUID NOT NULL REFERENCES instruments (instrument_id) ON DELETE RESTRICT,
    quantity        NUMERIC(18, 4) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (account_id, instrument_id)
);

CREATE INDEX IF NOT EXISTS idx_holdings_instrument_id ON holdings (instrument_id);

DROP TRIGGER IF EXISTS trg_holdings_set_updated_at ON holdings;
CREATE TRIGGER trg_holdings_set_updated_at
    BEFORE UPDATE ON holdings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Permanent execution record; one full fill per order in the quote-based simulator.
CREATE TABLE IF NOT EXISTS trade_fills (
    fill_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL UNIQUE REFERENCES orders (order_id) ON DELETE RESTRICT,
    account_id UUID NOT NULL REFERENCES accounts (account_id) ON DELETE RESTRICT,
    instrument_id UUID NOT NULL REFERENCES instruments (instrument_id) ON DELETE RESTRICT,
    order_side VARCHAR(10) NOT NULL CHECK (order_side IN ('buy', 'sell')),
    quantity NUMERIC(18, 4) NOT NULL CHECK (quantity > 0),
    price NUMERIC(18, 4) NOT NULL CHECK (price > 0),
    cash_amount NUMERIC(18, 2) NOT NULL CHECK (cash_amount > 0),
    executed_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trade_fills_account_time ON trade_fills (account_id, executed_at DESC);

CREATE OR REPLACE FUNCTION block_trade_fill_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'trade fills are append-only (fill_id: %)', OLD.fill_id;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_block_trade_fill_mutation ON trade_fills;
CREATE TRIGGER trg_block_trade_fill_mutation
    BEFORE UPDATE OR DELETE ON trade_fills
    FOR EACH ROW EXECUTE FUNCTION block_trade_fill_mutation();

-- local deployment audit evidence and transactional outbox. No broker calls occur in the
-- trading transaction. Source facts survive Kafka/reporting outages.
CREATE TABLE IF NOT EXISTS audit_outbox (
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sequence_id BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
    aggregate_key TEXT NOT NULL,
    record_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    published_at TIMESTAMPTZ -- publisher sets only after Kafka acknowledgment; replay is possible
);
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON audit_outbox(sequence_id) WHERE published_at IS NULL;

-- Dedicated local deployment lifecycle facts: submitted, terminal business rejection and fill.
-- Operational amendment/cancellation/stop state exists in orders but is not added
-- as a dedicated audit step here. Failed pricing attempts use evidence below.
CREATE TABLE IF NOT EXISTS order_audit_events (
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES orders(order_id),
    event_type VARCHAR(20) NOT NULL CHECK (event_type IN ('submitted','rejected','filled')),
    event_at TIMESTAMPTZ NOT NULL,
    reason TEXT,
    quantity NUMERIC(18,4),
    price NUMERIC(18,4),
    terminal BOOLEAN NOT NULL DEFAULT TRUE
);

-- No order FK here: failed pricing observations are committed separately while
-- the execution transaction holds the order lock. An observation is not a fill.
CREATE TABLE IF NOT EXISTS order_pricing_evidence (
    evidence_id UUID PRIMARY KEY,
    order_id UUID NOT NULL,
    phase VARCHAR(20) NOT NULL,
    decision VARCHAR(30) NOT NULL,
    reason TEXT,
    quote_json TEXT,
    observed_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_order_pricing_order ON order_pricing_evidence(order_id, observed_at);

-- Reuse the original fill/transaction UUID so backfill and live triggers converge.
-- Report notional is abs(cash_delta), preserving actual settlement rounding.
CREATE TABLE IF NOT EXISTS cash_ledger (
    movement_id UUID PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(account_id),
    order_id UUID REFERENCES orders(order_id),
    instrument_id UUID,
    movement_type VARCHAR(20) NOT NULL CHECK (movement_type IN ('trade','deposit','withdrawal','dividend')),
    cash_delta NUMERIC(18,2) NOT NULL,
    holding_delta NUMERIC(18,4) NOT NULL DEFAULT 0,
    occurred_at TIMESTAMPTZ NOT NULL
);

-- TradingAdminAuditSink inserts this with the source command transaction. The
-- consumer later copies it to admin_audit_log; no cross-database write is required.
CREATE TABLE IF NOT EXISTS staff_audit_events (
    audit_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id UUID NOT NULL,
    actor_email TEXT,
    action TEXT NOT NULL,
    target_account_id UUID,
    target_instrument_id UUID,
    target_order_id UUID,
    reason TEXT,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Latest observed provider marks, reused for reporting without additional API calls.
-- These are valuation prices (provider price), never bid/ask execution prices.
CREATE TABLE IF NOT EXISTS instrument_marks (
    symbol TEXT PRIMARY KEY,
    price NUMERIC(24,8) NOT NULL CHECK (price > 0),
    currency TEXT NOT NULL,
    quote_at TIMESTAMPTZ NOT NULL,
    observed_at TIMESTAMPTZ NOT NULL,
    provider_stale BOOLEAN NOT NULL DEFAULT FALSE
);

-- Related context lets the consumer establish account/instrument/order mirrors
-- even when it first sees a dependent fact. No network I/O runs inside a trigger.
CREATE OR REPLACE FUNCTION enqueue_audit_change() RETURNS TRIGGER AS $$
DECLARE
    body JSONB := to_jsonb(NEW);
    order_body JSONB;
    account_body JSONB;
    instrument_body JSONB;
BEGIN
    -- These are trading identities only. Bank numbers/auth credentials are never
    -- included in the extraction allowlist.
    SELECT to_jsonb(o) INTO order_body FROM orders o WHERE order_id = (body->>'order_id')::uuid;
    SELECT to_jsonb(a) || jsonb_build_object('email',u.email) INTO account_body
      FROM accounts a JOIN users u ON u.user_id=a.user_id
      WHERE a.account_id=coalesce(body->>'account_id',order_body->>'account_id')::uuid;
    SELECT to_jsonb(i) INTO instrument_body FROM instruments i
      WHERE instrument_id=coalesce(body->>'instrument_id',order_body->>'instrument_id')::uuid;
    INSERT INTO audit_outbox(aggregate_key, record_type, payload)
    VALUES (coalesce(body->>'order_id', body->>'account_id', body->>'instrument_id', body->>'user_id', body->>'audit_id', body->>'symbol'),
            TG_TABLE_NAME, jsonb_build_object('schema_version',1,'operation',TG_OP,'row',body,
                'order',order_body,'account',account_body,'instrument',instrument_body));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_order_lifecycle() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO order_audit_events(order_id,event_type,event_at,quantity,terminal)
        VALUES (NEW.order_id,'submitted',NEW.date_placed,NEW.quantity,FALSE);
    ELSIF NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('filled','rejected') THEN
        INSERT INTO order_audit_events(order_id,event_type,event_at,reason,quantity,price)
        VALUES (NEW.order_id,NEW.status,coalesce(NEW.date_finalized,clock_timestamp()),
                NEW.rejection_reason,NEW.quantity,NEW.price);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_audit_order_lifecycle ON orders;
CREATE TRIGGER trg_audit_order_lifecycle AFTER INSERT OR UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION record_order_lifecycle();

-- Cash and share signs are from the client's perspective: buys spend cash and
-- add shares; sells do the reverse. Non-trade cash entries have no order ID.
CREATE OR REPLACE FUNCTION record_cash_ledger() RETURNS TRIGGER AS $$
BEGIN
    IF TG_TABLE_NAME = 'trade_fills' THEN
        INSERT INTO cash_ledger VALUES (NEW.fill_id,NEW.account_id,NEW.order_id,NEW.instrument_id,'trade',
            CASE WHEN NEW.order_side='buy' THEN -NEW.cash_amount ELSE NEW.cash_amount END,
            CASE WHEN NEW.order_side='buy' THEN NEW.quantity ELSE -NEW.quantity END,NEW.executed_at)
        ON CONFLICT DO NOTHING;
    ELSE
        INSERT INTO cash_ledger VALUES (NEW.transaction_id,NEW.account_id,NULL,NEW.instrument_id,NEW.txn_type,
            CASE WHEN NEW.txn_type='withdrawal' THEN -NEW.amount ELSE NEW.amount END,0,NEW.created_at)
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_cash_ledger_fill ON trade_fills;
CREATE TRIGGER trg_cash_ledger_fill AFTER INSERT ON trade_fills FOR EACH ROW EXECUTE FUNCTION record_cash_ledger();
DROP TRIGGER IF EXISTS trg_cash_ledger_transaction ON transactions;
CREATE TRIGGER trg_cash_ledger_transaction AFTER INSERT ON transactions FOR EACH ROW EXECUTE FUNCTION record_cash_ledger();

CREATE OR REPLACE FUNCTION block_audit_fact_mutation() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['users','accounts','instruments','holdings','orders',
                             'trade_fills','transactions','order_audit_events','order_pricing_evidence',
                             'cash_ledger','staff_audit_events','instrument_marks'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_outbox ON %I',t);
        EXECUTE format('CREATE TRIGGER trg_outbox AFTER INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION enqueue_audit_change()',t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['order_audit_events','order_pricing_evidence','cash_ledger','staff_audit_events'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_immutable ON %I',t);
        EXECUTE format('CREATE TRIGGER trg_immutable BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION block_audit_fact_mutation()',t);
        EXECUTE format('DROP TRIGGER IF EXISTS trg_no_truncate ON %I',t);
        EXECUTE format('CREATE TRIGGER trg_no_truncate BEFORE TRUNCATE ON %I FOR EACH STATEMENT EXECUTE FUNCTION block_audit_fact_mutation()',t);
    END LOOP;
END $$;

-- Fill the unified ledger from existing immutable facts. No balances are changed.
INSERT INTO cash_ledger
SELECT fill_id,account_id,order_id,instrument_id,'trade',
       CASE WHEN order_side='buy' THEN -cash_amount ELSE cash_amount END,
       CASE WHEN order_side='buy' THEN quantity ELSE -quantity END,executed_at
FROM trade_fills ON CONFLICT DO NOTHING;
INSERT INTO cash_ledger
SELECT transaction_id,account_id,NULL,instrument_id,txn_type,
       CASE WHEN txn_type='withdrawal' THEN -amount ELSE amount END,0,created_at
FROM transactions ON CONFLICT DO NOTHING;
-- Trading DB: client-owned dispute intake, linked to accounts and optional orders.
-- Created by normal startup alongside trading tables; filing does not alter trades or funds.
CREATE TABLE IF NOT EXISTS client_disputes (
    dispute_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(account_id) ON DELETE RESTRICT,
    order_id UUID REFERENCES orders(order_id) ON DELETE RESTRICT,
    category VARCHAR(30) NOT NULL CHECK (category IN ('trade', 'pricing', 'funding', 'other')),
    description VARCHAR(2000) NOT NULL CHECK (length(trim(description)) BETWEEN 20 AND 2000),
    status VARCHAR(20) NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted', 'in_review', 'resolved')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_client_disputes_account ON client_disputes(account_id, created_at DESC);

-- Durable administrative suspension schedules. Apply to existing trading databases too.
CREATE TABLE IF NOT EXISTS account_suspension_schedules (
    schedule_id UUID PRIMARY KEY,
    account_id UUID NOT NULL UNIQUE REFERENCES accounts(account_id) ON DELETE CASCADE,
    suspend_at TIMESTAMPTZ NOT NULL,
    reason VARCHAR(1000) NOT NULL,
    actor_id UUID NOT NULL REFERENCES users(user_id),
    actor_email VARCHAR(320) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_account_suspension_due ON account_suspension_schedules(suspend_at);

-- Client-facing suspension notice, for immediate and scheduled actions.
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS suspension_reason VARCHAR(1000);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS scheduled_suspension_at TIMESTAMPTZ;

-- Full provider quotes and a UTC-day request budget. Reapplying preserves data.
CREATE TABLE IF NOT EXISTS market_quote_cache (
    symbol TEXT PRIMARY KEY,
    quote_json TEXT NOT NULL,
    quote_at TIMESTAMPTZ NOT NULL,
    fetched_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS pricing_request_budget (
    budget_day DATE PRIMARY KEY,
    request_count INTEGER NOT NULL DEFAULT 0 CHECK (request_count >= 0),
    blocked_until TIMESTAMPTZ
);
