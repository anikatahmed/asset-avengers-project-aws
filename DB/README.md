# Database reference

Read this alongside [the project guide](../docs/project-guide.md). Database names
are configurable; the names below are the local defaults. Host ports are for
tools running outside Docker. Containers use service names and port 5432.

## Ownership and connections

| Database | Docker service / host port | Writer | Readers and purpose |
|---|---|---|---|
| `auth` | `auth-db` / 5433 | Nest auth service | Auth repositories validate credentials, sessions and token rotation |
| `Endgame_Trading` | `postgres` / 5432 | Trading API; SQL triggers; publisher marks outbox delivery | Trading JPA repositories and publisher snapshots/outbox |
| `admin_analytics` | `reporting-db` / 5434 | Consumer, report job; internal API appends view audits; initializer registers dashboards | Internal API investigates clients/orders; Superset reads approved views |
| `superset_metadata` | Same reporting PostgreSQL instance | Superset migrations, initializer and web app | Superset manages its users, chart definitions, dashboard layouts and permissions |

The internal API has no trading database credentials. Its suspension commands go
through the trading HTTP API with the original staff JWT. Superset metadata is
managed by Superset migrations, not by a hand-written application schema here.

## Files and when to use them

| File | Purpose and behavior |
|---|---|
| `auth_db.schema.sql` | Creates credentials/session tables; fresh auth storage loads it automatically |
| `auth_db_test_data.sql` | Nine development credential fixtures (demo staff and clients, the super admin, the dev-switch accounts); no funded portfolios |
| `endgame_db.schema.sql` | Authoritative trading DDL, incremental additions, constraints, triggers and historical cash-ledger backfill |
| `instruments.seed.sql` | Canonical catalogue of 577 tickers with stable UUIDs; metadata only, no prices or client holdings |
| `endgame_db_test_data.sql` | Generated copy of the catalogue for legacy setup/test consumers; regenerate from the canonical seed |
| `admin_analytics_db.schema.sql` | Reporting mirrors, audit facts, report batches, views and capability roles |
| `admin_analytics_db_test_data.sql` | Standalone reporting fixtures for schema/API tests; normal staff Compose startup does not load them |
| `admin_analytics_db_app_user.sh` | Older single-login initializer; retained for older setups, replaced in current staff Compose by `deployment/admin-analytics/init-databases.sql` |
| `docker-compose-proddb.yml` | Separate database-container configuration; does not provision the complete app or apply these schemas automatically |

Initialization SQL runs only when PostgreSQL storage is empty. Restarting a
container preserves data and does not reapply edited SQL. Use the migration
commands in [staff setup](../docs/admin-analytics/setup.md) for existing databases.
`IF NOT EXISTS` prevents duplicate objects; it is not a substitute for explicit
`ALTER` statements when changing an existing definition. The trading schema's
backfill copies immutable facts into `cash_ledger` without changing balances.

`python3 scripts/generate-instrument-seed.py` synchronizes the catalogue fixture;
`--check` verifies it. `setup-test-db.sh` applies trading schema/catalogue to the
local database; its explicit `--reset` option is destructive. The verification
scripts create disposable databases instead; see [the code map](../docs/code-map.md).

## Auth tables

| Table | Relationships and reason |
|---|---|
| `users` | UUID is JWT `sub` and the logical trading user ID; email is unique; first/last names are authoritative here; password is a bcrypt hash; default role is CLIENT |
| `sessions` | Many logins per user; FK to users; independent idle and absolute expiry plus revocation; `mfa_verified_at` gates refresh |
| `refresh_tokens` | SHA-256 hash primary key; FK to session; `used_at` detects replay of a rotated token |
| `superset_sso_grants` | Auth-only single-use ticket hash, auth session FK, expiry/consumption and revocable lease hash; never replicated |
| `user_mfa` | One per user; encrypted authenticator secret, enrollment timestamp, replay prevention and failed-attempt lockout |
| `mfa_challenges` | Hashed five-minute login/enrollment/replacement tokens; encrypted pending replacement secret, attempts and consumption timestamp |
| `mfa_recovery_codes` | Hashed one-use recovery codes with consumption timestamps; no plaintext recovery codes |
| `password_reset_requests` | Hashed request token and verified reset grant, HMAC-protected email code/email throttle key, user UUID, separate code/grant expiries, verification, attempts and consumption |
| `auth_email_outbox` | Encrypted reset-email delivery payload, attempts/lease, provider email ID and safe delivery status |

Client signup stores its MFA opt-in in `users.mfa_required` (default false).
Staff roles and already enrolled accounts require MFA before session creation;
password-only clients have `sessions.mfa_verified_at = NULL`. Its encryption key stays outside the database in the root environment.
No fixture enables MFA or contains a shared authenticator secret. See the
[MFA guide](../docs/mfa.md) for setup and migration details.

Deleting an auth user cascades to its auth sessions/tokens. There is no
cross-database cascade into financial records. The trading service lazily creates
its user row from the verified JWT UUID. Auth owns the role claims used for API
authorization; editing a reporting mirror does not grant application permissions.

## Trading tables

| Table | Owner, relationships and reason |
|---|---|
| `users` | `CurrentUserService` bridges verified auth UUID to local trading identity; contains no password |
| `accounts` | FK to trading user; authoritative cash/suspension; account row locks serialize competing cash commitments |
| `bank_accounts` | FK to user; links simulated funding sources; responses mask account numbers, but stored values are not encrypted |
| `instruments` | Shared catalogue; unique symbol; currency, security class and eligibility are checked before trading |
| `watchlists` | One list per user; FK to user; survives logout |
| `watchlist_items` | FKs to list and instrument; unique pair makes repeated starring idempotent |
| `client_disputes` | Trading-owned client submissions: dispute UUID, account FK, optional order FK, category, description, status and creation timestamp; defined in `endgame_db.schema.sql` |
| `orders` | FKs to account/instrument; mutable operational terms/status, cash reservation and finalization time |
| `trade_fills` | One immutable full fill per order; stores quantity, actual execution price and rounded cash amount |
| `transactions` | Immutable non-order cash events: deposit, withdrawal or dividend; account FK and optional instrument |
| `holdings` | Current quantity, unique per account/instrument; can change as new fills execute |
| `order_audit_events` | Immutable submitted/rejected/filled facts linked to an order; source lifecycle used by staff |
| `order_pricing_evidence` | Immutable actual quote JSON with phase, outcome and observation time; failed attempts survive execution rollback |
| `cash_ledger` | Unified signed cash/share movement; movement UUID is original fill/transaction UUID, enabling replay-safe backfill |
| `staff_audit_events` | Staff UUID/email, target and reason written in the transaction that changes suspension state |
| `audit_outbox` | Durable event envelope plus delivery timestamp; inserted within source transactions and delivered asynchronously |

Money uses SQL `NUMERIC` and Java `BigDecimal`. Cash settles to two decimals;
quantity and execution price use four. Buys round cost upward and sells round
proceeds downward. Reports use the recorded cash amount, not a second multiplication
that might round differently. Account cash and holdings are current balances;
fills/transactions/ledger entries explain how they changed.

There is deliberately no order FK on `order_pricing_evidence`: an invalid execution
quote commits in a separate transaction while the caller holds the order lock.
An FK check could wait on that same uncommitted order operation. This design
requires the application to supply the correct order UUID; evidence is not proof
that an order filled. A submission quote, when present, commits with its order.

### Trading triggers and constraints

| Mechanism | Why it exists |
|---|---|
| `set_updated_at`, account-touch triggers | Keep source freshness visible when orders, cash events or positions change |
| `prevent_staff_account`, `prevent_staff_role_with_account` | Keep staff identities separate from client trading accounts |
| Uniqueness and numeric/status checks | Reject duplicate positions/fills/stars and invalid financial state even outside Java |
| Fill/transaction mutation blockers | Prevent editing/deleting recorded financial facts |
| `record_order_lifecycle` | Emit submitted at insertion and terminal filled/rejected transitions without requiring every writer to remember them |
| `record_cash_ledger` | Link actual fill/transaction UUIDs to signed cash/share changes |
| `enqueue_audit_change` | Copy allowed source changes and relevant order/account/instrument context into outbox atomically |
| Audit mutation blockers | Reject update, delete and truncate on source audit facts |

The extraction allowlist excludes bank account details and the entire auth
database. Outbox payloads do include trading client emails for authorized admin
lookup. A single partition preserves Kafka stream order in this local deployment; it does not
turn SQL sequence allocation into a guaranteed global commit order.

## Reporting tables and views

| Object | Writer and consumers |
|---|---|
| `client_accounts`, `client_positions`, `instruments` | Consumer updates current mirrors; source timestamps stop older state from overwriting newer state |
| `trade_records` | Consumer inserts original order terms once; amendments are not reconstructed here |
| `trade_lifecycle_events` | Consumer appends recorded lifecycle and known snapshot states; `terminal` and `provenance` distinguish failed attempts/imports |
| `cash_holding_changes` | Consumer copies source movement IDs and actual deltas; unknown after-balances remain null |
| `admin_audit_log` | Internal API appends detail-view audits; consumer copies staff command audits from trading |
| `monthly_client_segments` | Legacy proposed month-end segmentation; no current production job populates it |
| `audit.order_state` | Consumer's mutable current status, including changes outside the dedicated lifecycle audit scope |
| `audit.ingested_events` | Original envelopes; event UUID deduplicates an entire destination transaction |
| `audit.pricing_evidence` | Original quote observations and failures; staff timeline/pricing/export endpoints read them |
| `integration.pipeline_status` | Last consumed source heartbeat, receipt and event; drives UI freshness and report readiness |
| `integration.report_schedules` | Append-only shared cutoff/run-time versions, actor and effective local date; default 19:00 |
| `integration.report_batches` | Every running/published/failed attempt, coverage boundaries and heartbeat |
| `integration.published_reports` | One chosen batch per date; switched only after successful reconciliation |
| `integration.dashboard_registry` | Initializer maps approved UI keys to Superset embedded UUIDs; API reads it |
| `analytics.trade_facts` | Immutable batch/fill facts; repeated builds retain prior versions |

`admin.client_accounts`, `admin.client_positions`, `admin.client_cash_history`,
`admin.trades`, `admin.trade_timeline` and `admin.audit_log` join reporting facts
into staff lookup shapes. The enhanced timeline endpoint reads original event
fields directly to preserve `terminal` and `provenance` information.

`analytics.published_trades` joins facts to the published pointer. The business,
instrument and client activity views aggregate those published facts. Superset's
prepared dataset uses `published_trades` so failed/incomplete/replaced batches
cannot be added together accidentally.

The older `reporting.fills`, daily-volume and daily-instrument views and
`reporting.instrument_activity(from,to)` aggregate copied lifecycle facts
directly, without a published-batch cutoff. Monthly views depend on
`monthly_client_segments`, which remains unpopulated in the normal stack. These
compatibility views are not the source of the prepared scheduled dashboards.

The consumer writes the deduplication row and all projections in one transaction,
then commits the Kafka offset. The publisher marks delivery only after Kafka
acknowledges. A crash between either pair of steps causes a replay, so stable
event/movement IDs are essential. Snapshot imports identify known state as
`provenance=snapshot`; missing historical quotes or steps are never invented.

### Database roles versus application roles

| Database capability role | Used by | Permissions |
|---|---|---|
| `analytics_etl` | Consumer and report job | Maintain mutable mirrors/status, append immutable facts and audit copies, publish report pointers |
| `analytics_admin` | Internal API login | Read reporting/audit objects; append `admin_audit_log` view entries and report-schedule versions |
| `analytics_analyst` | Superset reporting login | Read approved `reporting` and `analytics` views; no client-email mirror or admin log access |
| Separate metadata owner | Superset | Manage its own metadata database |

These PostgreSQL roles are not JWT roles. `ADMIN` and `ANALYST` are checked by
Spring before API access; both use the internal service's configured connection.
Initializers create deployment logins with these capability memberships. Changing
an env password after initialization does not rotate the already-created DB role.

## Reports and recovery

Reports cover [00:00, configured cutoff) America/New_York on the selected date
(default 19:00), using recorded
execution time. `ZoneInfo` accounts for daylight saving changes. After-cutoff
trades remain in audit; they do not move into tomorrow's report. A failed batch
keeps the prior published pointer intact; a successful manual rerun creates a
new batch. The heartbeat is a local deployment freshness check, not proof of distributed
transaction completeness.

See [staff operations](../docs/admin-analytics/setup.md#operations) for reruns and
reimport commands. Keep source trading records when rebuilding reporting storage.
Backfill cannot recreate quotes/events that predate their capture. Do not treat
container restart or deleting volumes as a migration strategy.

Report-schedule changes are saved through the staff API and become effective the
next New York day. Only SELECT/INSERT are granted on schedule history; triggers
block updates, deletes and truncation. Historical reports retain their cutoff.
Reapply the canonical reporting schema for existing databases before deploying the
new API/worker. No client trading, auth or instrument seed changes are needed.

## Resetting auth and trading data together

The client trading database uses the host bind mount `~/.asset_postgres_test_data`;
auth uses a Docker named volume. `docker compose down --volumes` alone deletes the
auth volume but leaves the trading folder intact. The stop helper asks `y/no` before deletion. Choosing `y` stops both stacks,
removes their volumes, and clears only that fixed trading data folder using a
temporary PostgreSQL container. Choosing `no`, pressing Enter, or receiving no
input preserves the data. Deletion does not run during startup or repair.

Auth UUIDs, not email addresses, identify portfolio owners. Auth retains unique
emails; trading stores email as non-unique searchable metadata. If an auth identity
is recreated while old trading data remains, it gets a separate empty account.
Old portfolios are never attached to a new identity merely because emails match.
The schema migration removes the trading-only email uniqueness constraint without
removing users, balances, banks, holdings or history.

## Signup names and staff name suggestions

Signup requires first and last names (trimmed, 1–100 characters each; international
names, spaces and punctuation are supported). The auth database owns
`users.first_name` and `users.last_name`, alongside credentials and sessions. Login
and refresh issue signed `given_name`, `family_name` and `name` claims. Both client
and staff interfaces display the full name, falling back to email for older users
whose names are unknown. Existing names are not guessed from email addresses.

Spring copies verified name claims into the trading user's name columns on an
authenticated client request. The existing outbox/Kafka consumer projects them into
`reporting.client_directory`. Auth remains authoritative; reporting searches never
query the auth database directly or call a market-price provider. Name availability
has the same short ingestion delay as other copied client data.

Admin Clients and both staff Reports pages offer name suggestions while typing.
After 250 ms without another keystroke, the UI requests up to ten case-insensitive
first-name, last-name or full-name matches. Further typing narrows the matches;
older responses are ignored. Duplicate names remain distinguishable by client UUID.
Selecting a client in Reports shows up to 31 dates of published activity. Analysts
receive names, IDs and published aggregates, without emails, account cash or bank
details. Admin account lookup also accepts names or email (minimum three characters).

Startup now applies auth and trading schemas before rebuilding client services,
including `--client`; staff startup also applies the reporting directory schema.
All name migrations preserve IDs, credentials, sessions and financial records.
Development auth fixtures include explicit names; no sample portfolios are added.

## Opt-in full-project demo data and admin updates

Run `bash scripts/load-demo-data.sh` after `bash scripts/start-project.sh` to load
named demo clients, banks, funds, watchlists, filled and insufficient-cash rejected orders and
synthetic pricing/audit evidence. It waits for the normal Kafka projection and
publishes ready-to-view reports. Reruns preserve subsequent client changes; normal
startup does not load these financial fixtures. See the [demo walkthrough](../docs/demo-walkthrough.md)
for logins, expected balances and a demonstration sequence.

Admin Orders now polls its filtered/current page every three seconds while visible.
It stops when leaving Orders or logging out, skips hidden tabs, ignores superseded
responses and retains existing results during background failures. This reads the
reporting database only; it does not request stock prices.


## Presentation guide and current workspace names

See [presentation guide](../docs/presentation-guide.md) for Ultron (admin), J.A.R.V.I.S. (analyst), development logins, spread/return examples, PDF interpretation and the expanded 99-client / 2,540-fill demo. Staff development images use `:local`. Existing data is preserved; run the demo loader to add the extension.

`ensure-database.sql` is a startup recovery helper, not a schema or fixture. Run it
against maintenance database `postgres` with psql variables `database` and `owner`,
outside a transaction. It safely quotes identifiers and creates only a missing
database. The start script then applies the corresponding schema. Existing
databases are never dropped or recreated.

### Portfolio-size classification and database organization

See [the database guide](../docs/admin-analytics/database-guide.md) for the exact table inventory, schema purposes, joins and examples. Start database exploration with `SELECT * FROM reporting.database_guide ORDER BY schema_name,object_name`.

`reporting.client_portfolios` derives cash plus observed USD market-value holdings: C below $10,000; B $10,000–$100,000 inclusive; A above $100,000. Missing/non-USD prices remain unclassified; stale quotes are labelled. Existing quote fetches produce trading `instrument_marks` records, delivered through the outbox/Kafka to reporting marks, with no additional market-data requests. Current class filters are available in staff Reports and Superset. Historical month-end segments are separate and not populated by the daily report job.

The [schema naming and retirement review](../docs/admin-analytics/schema-review.md) documents which tables are active, which legacy monthly objects are candidates for retirement, and why account balances, movement history, ingestion evidence and versioned report facts are distinct. It includes proposed clearer names; these are recommendations, not applied renames.

Investment-account names/types now flow from trading accounts into the reporting mirror, admin views, `reporting.investment_accounts`, and newly published trade facts. Existing fact rows stay immutable; old named publications use current copied account labels as an explicit fallback. The [investment-account guide](../docs/admin-analytics/investment-account-visibility.md) documents snapshot migration, joins, filters and source ownership. Fresh demo data includes 100 investment accounts for 99 clients.

### Fund-name search metadata

The catalogue includes seven Vanguard ETFs, QQQM (Invesco NASDAQ 100 ETF), and Alcoa (AA), with names checked against the issuer links recorded in the seed. Reapply `instruments.seed.sql` to existing databases to replace ticker-only names and classifications without replacing instrument UUIDs or descriptive names. Unverified discovered tickers remain unchanged. Catalogue presence does not guarantee Fauxnance pricing availability.


### Refreshing the Fauxnance US catalogue

`DB/fauxnance-us-universe.json` is a reviewed snapshot of
https://github.com/canaokar/fauxnance-api/blob/main/data/universes/us-v1.json
(blob SHA `38184280e91283cf6656cc4b3632f1b277ef64e2`). The seed keeps existing
instruments plus every symbol in this snapshot. US is a market label, not a
listing venue. BRK.B and BF.B use pricing symbols BRK-B and BF-B.

To refresh, download and review the updated US JSON into that snapshot file, then run:

```sh
python3 scripts/import-fauxnance-universe.py          # preview additions
python3 scripts/import-fauxnance-universe.py --write # update seed and fixture
python3 scripts/generate-instrument-seed.py --check
git diff -- DB
```

The importer validates currency and security type against each universe before writing. Repeated runs are
idempotent. It preserves existing catalogue IDs and descriptive metadata, adds new
symbols, and never deletes instruments absent from a later snapshot. Review name
changes separately. Apply the seed transactionally to an existing database:

```sh
docker exec -i endgame_postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/instruments.seed.sql
```

Conflict handling preserves live instrument IDs (and therefore holdings/watchlist
references), repairing only ticker-only names. Search ranks exact tickers before
ticker prefixes and company-name matches. Quotes are requested after selection.


The catalogue includes the 12 USD crypto entries from the reviewed
`DB/fauxnance-crypto-universe.json` snapshot. Refresh it using the importer with
`--source DB/fauxnance-crypto-universe.json` (preview first, then `--write`).
Crypto keeps canonical `X:BTC-USD` tickers and type `crypto`. Indian-market and
non-USD instruments are no longer offered. Reapplying `DB/instruments.seed.sql`
deactivates existing foreign-currency/Indian rows while preserving historical records.

### Company logos in client search

Set `LOGOKIT_PUBLISHABLE_TOKEN` in the root `.env` to the **publishable `pk_` Logo API token**.
The placeholder leaves initials visible and sends no logo requests. Never use an `sk_` Brand API secret.
After editing the value, run `docker compose build frontend` followed by
`docker compose up -d --no-build --no-deps frontend`. Compose passes the publishable
token as a build argument; the Angular build embeds it in the browser bundle.
There is no startup script or runtime configuration file. Local `npm run build`
and `npm start` read the root `.env` when the environment variable is not set.
The generated `src/environments/logokit.generated.ts` is ignored by Git.
Only the `pk_` publishable token is bundled; Fauxnance's secret remains on the backend.

Logos are hotlinked directly to LogoKit for displayed search matches and selected stock cards, with lazy image loading,
local initials on error, and a LogoKit attribution link. No logo images are downloaded or persisted by the backend.
Crypto maps `X:BTC-USD` to `/crypto/BTC`; stock tickers retain their listing suffixes (including `.NS`/`.BO`).
See https://docs.logokit.com/api-reference/stock-logo-API and https://docs.logokit.com/authentication.

### Scheduled account suspensions

Apply `DB/account_suspension_schedules.sql` to an existing trading database before
starting the updated backend. New databases include the table in the main schema.
Schedules survive restarts; overdue suspensions execute when the backend resumes.
The worker checks every second (configurable with `admin.suspensions.poll-delay-ms`).
A new schedule replaces the account's previous schedule. Successful immediate
suspension or restoration clears any pending schedule. Scheduled execution uses
the original admin identity and records the existing suspension audit event.
Dates entered by staff use America/New_York (Eastern Time) and are sent as UTC.

The migration also adds `suspension_reason` and `scheduled_suspension_at` to accounts
for the client notice. Reapply the migration if the schedule table was added before
these columns. The client checks status every ten seconds while visible; scheduled
times are displayed in Eastern Time, with a live countdown until suspension. Older suspended accounts without
a saved reason direct the client to contact support.

### Order dates in staff reporting

Apply `DB/analytics_order_dates.sql` to an existing reporting database, then rerun
Superset initialization to refresh dataset columns and add the managed Order details
table to each dashboard. New reporting databases include these fields in the schema.
`placed_at` is the original order submission timestamp; `order_placed_at` displays it
in Eastern Time with an explicit ET label. `year`, `month` (1–12), and `month_name` describe order
placement in America/New_York, rather than execution or report publication time.
Analyst dashboards retain their published-fill scope; these fields do not turn the
reporting dataset into a live feed of pending or rejected orders. Missing historical
order copies yield NULL dates instead of substituting execution time.

### Pricing cache and request budget

Apply `DB/quote_cache.sql` to existing trading databases before starting the updated
backend. It adds `market_quote_cache` (full provider quote plus fetch/observation time)
and `pricing_request_budget` (atomic UTC-day counters and provider cooldowns).
These tables are operational state, owned by the trading API; they are not reporting
facts. Existing quotes and counters are preserved when the script is reapplied.
See [Pricing cache and request budget](../docs/pricing-cache.md).

### Trading database name

The default trading database is `Endgame_Trading`. Set both `POSTGRES_DB` and the
database component of `DB_URL` to this exact spelling in the root `.env`.
The reporting publisher uses the same `POSTGRES_DB` value for its source database.
Mixed-case PostgreSQL identifiers must be quoted in SQL, for example
`ALTER DATABASE endgame_test RENAME TO "Endgame_Trading"`; connection database names
are passed as the exact string without adding SQL quotes.

Changing `.env` does not rename an existing database. For an existing installation,
back up the source database, stop the backend and reporting publisher, and rename
it through the maintenance database `postgres` before restarting with the new
configuration. Preserve Docker volumes. Do not run initialization against an empty
new database as a substitute for renaming the existing one.
