-- Proposed migration: run ONLY in Endgame_Trading, as postgres or thor_trading.
-- psql: use -X -v ON_ERROR_STOP=1. On an error, ROLLBACK and stop.
-- Adds timestamp enforcement only; does not change balances or replay events.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL search_path = public, pg_catalog;
DO $$
BEGIN
    IF current_database() <> 'Endgame_Trading' THEN
        RAISE EXCEPTION 'Connect to Endgame_Trading, not %', current_database();
    END IF;
    IF EXISTS (
        SELECT FROM pg_trigger
        WHERE tgrelid = 'public.accounts'::regclass
          AND tgname = 'trg_accounts_set_updated_at'
    ) THEN
        RAISE EXCEPTION 'Timestamp trigger already exists; inspect it before changing it';
    END IF;
END $$;
CREATE TRIGGER trg_accounts_set_updated_at
    BEFORE UPDATE ON public.accounts
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
COMMIT;
SELECT tgname, tgenabled, pg_get_triggerdef(oid)
FROM pg_trigger
WHERE tgrelid = 'public.accounts'::regclass
  AND tgname = 'trg_accounts_set_updated_at';
