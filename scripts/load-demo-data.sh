#!/usr/bin/env bash
# Opt-in development data. Run after start-project.sh; never resets existing records.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo 'Usage: bash scripts/load-demo-data.sh'
  echo 'Loads dedicated demo clients, banks, funding, holdings, watchlists and audit evidence.'
  echo 'Waits for live ingestion and publishes reports. Existing demo balances are not reset.'
  exit 0
fi
if [[ $# -ne 0 ]]; then echo 'Usage: bash scripts/load-demo-data.sh' >&2; exit 1; fi
if [[ ! -f .env ]]; then echo 'Missing root .env.' >&2; exit 1; fi
if ! docker info >/dev/null 2>&1; then echo 'Start Docker first.' >&2; exit 1; fi
CLIENT=(docker compose --env-file .env)
STAFF=(docker compose -p asset-avengers-internal --env-file .env -f deployment/admin-analytics/admin-analyst-stack.compose.yml)
"${CLIENT[@]}" config >/dev/null
"${STAFF[@]}" config >/dev/null
for service in auth-db postgres; do
  if ! "${CLIENT[@]}" exec -T "$service" sh -c 'psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT 1"' >/dev/null; then
    echo 'Start the full project first: bash scripts/start-project.sh' >&2; exit 1
  fi
done
# Do not load disconnected reporting fixtures: Kafka copies these source records.
echo 'Loading opt-in synthetic demo data. No existing financial records are reset.'
"${CLIENT[@]}" exec -T auth-db sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/auth_db_test_data.sql
"${CLIENT[@]}" exec -T auth-db sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/demo/auth.sql
"${CLIENT[@]}" exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/instruments.seed.sql
"${CLIENT[@]}" exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/demo/trading.sql
"${CLIENT[@]}" exec -T auth-db sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/demo/expanded-auth.sql
"${CLIENT[@]}" exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/demo/expanded-trading.sql
"${CLIENT[@]}" exec -T auth-db sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/demo/presentation-auth.sql
"${CLIENT[@]}" exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/demo/presentation-trading.sql
# Closed synthetic pairs exercise all seven asset filters, including existing demo installs.
"${CLIENT[@]}" exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/demo/asset-types-trading.sql
# Count the actual saved demo records, including upgrades and later demo trades.
# Do not publish based on a stale hard-coded minimum from an older fixture version.
expected_counts=$("${CLIENT[@]}" exec -T postgres sh -c 'psql -X -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
SELECT json_build_object(
 'fills',(SELECT count(*) FROM trade_fills WHERE account_id::text LIKE 'de200000-%'),
 'accounts',(SELECT count(*) FROM accounts WHERE account_id::text LIKE 'de200000-%'),
 'orders',(SELECT count(*) FROM orders WHERE account_id::text LIKE 'de200000-%'),
 'movements',(SELECT count(*) FROM cash_ledger WHERE account_id::text LIKE 'de200000-%'));
SQL
)
echo 'Waiting for the publisher/consumer, then publishing daily reports…'
"${STAFF[@]}" exec -T reporting-job python - "$expected_counts" <<'PYTHON'
import time
import json
import sys
from datetime import datetime,timedelta,time as daytime
from pipeline import connect
from reports import build_report,ZONE
expected=json.loads(sys.argv[1])
with connect() as target:
    cutoff=datetime.now(ZONE)
    for attempt in range(450):
        actual=dict(zip(('fills','accounts','orders','movements'),target.execute("""SELECT
          (SELECT count(*) FROM cash_holding_changes WHERE change_type='trade' AND account_id::text LIKE 'de200000-%'),
          (SELECT count(*) FROM client_accounts WHERE account_id::text LIKE 'de200000-%'),
          (SELECT count(*) FROM trade_records WHERE account_id::text LIKE 'de200000-%'),
          (SELECT count(*) FROM cash_holding_changes WHERE account_id::text LIKE 'de200000-%')""").fetchone()))
        heartbeat=target.execute("SELECT source_heartbeat_at FROM integration.pipeline_status WHERE pipeline='trading'").fetchone()
        if all(actual[key] >= value for key,value in expected.items()) and heartbeat and heartbeat[0] and heartbeat[0] >= cutoff: break
        if attempt % 15 == 0:
            print(f"Copied {actual['fills']}/{expected['fills']} demo fills; waiting for complete ingestion…",flush=True)
        time.sleep(2)
    else:
        raise SystemExit('Demo source data is saved, but ingestion is not ready. Check publisher/consumer logs and rerun this script.')
    days=target.execute("SELECT DISTINCT (occurred_at AT TIME ZONE 'America/New_York')::date FROM cash_holding_changes WHERE change_type='trade' AND account_id::text LIKE 'de200000-%'").fetchall()
    for day in sorted({item[0] for item in days}|{cutoff.date()}):
        end=cutoff if day==cutoff.date() else datetime.combine(day+timedelta(days=1),daytime.min,ZONE)-timedelta(microseconds=1)
        build_report(target,day,cutoff_at=end)
        print('Published report:',day)
PYTHON
cat <<'USAGE'
Demo ready. Password for newly created demo logins: EndgameDemo123!
Client: cameron.demo@example.com | carol.demo@example.com | daniel.demo@example.com
Admin: david.admin@example.com | Analyst: priya.analyst@example.com
Fresh fixture totals: 99 clients, 100 investment accounts, 2,540 fills, 13 rejected orders, 12 disputes; up to 90 days of activity.
Portfolio boundaries: client.201.demo@example.com through client.204.demo@example.com.
Additional logins: client.205.demo@example.com through client.272.demo@example.com.
Some additional clients are deliberately suspended; use Ultron to remove suspension before a trading demonstration.
Asset type filters: equity, etf, crypto, bond, option, future and mutual_fund.
Daniel Reed has closed synthetic example trades for all seven; DEMO-* instruments are inactive.
Open Reports for populated dashboards and PDFs; search "ca" for name suggestions.
Quotes in seeded audit evidence are synthetic. New trades still use the normal pricing provider.
USAGE
