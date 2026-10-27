# Setup and verification

Run commands from the repository root. Java builds require Java 25 and Maven.
Use the `docker compose` plugin command. Install a current Docker Compose plugin compatible with the host Docker Engine. Verification uses explicit readiness checks and no `!reset` or `up --wait`.
Manual staff commands must include `-p asset-avengers-internal`, as shown below.
The normal staff stack uses no test fixture data.

## Quick start after initial configuration

After the root `.env` is configured, start the full project from the repository root:

```bash
bash scripts/start-project.sh
```

The helper validates configuration, builds/starts the client stack, then starts the
staff stack. It preserves database volumes, applies the current idempotent schemas and missing
service logins, and never resets data. Docker Desktop must be running. Optional `--client` starts only the
client stack; `--staff` starts only the staff stack and assumes client/auth/trading
are already running. `--help` explains the options. It does not create secrets.

Open `http://localhost:8086/admin.html` for **admin** or
`http://localhost:8086/analyst.html` for **analyst**. With the local auth
fixtures installed, use `david.admin@example.com` for admin or
`priya.analyst@example.com` for analyst; development password `EndgameDemo123!`.
These accounts come from the auth fixture, not normal client signup. Admin sees
Orders, Clients, Actions and Reports; analyst sees Reports. The client app remains
at `http://localhost:8084`. Port 8088 is Superset authoring, which uses its separately
configured login, rather than the staff-console login.

First-time setup still needs the environment configuration below. The helper applies
the schema updates; manual Compose startup requires the migration commands below. If a config file already exists, edit it instead of copying over your secrets.

## Start the existing trading stack

Use the existing root `.env` and `docker compose up -d --build`. The staff API
reuses its auth issuer and JWT secret, and accepts only tokens with the staff audience
(`STAFF_JWT_AUDIENCE`, default `endgame-staff`). It connects to the existing
`trading_platform_network`. Client endpoints remain on port 8080; the internal API
runs on 8085. Nginx routes `/api/v1/admin/` and `/api/v1/analytics/` to the internal
service and the remaining client APIs to the trading service.

For an **existing trading database** started with manual Compose commands, apply the
current schema explicitly. The startup helper performs this step automatically;
restarting containers alone does not execute PostgreSQL initialization SQL:

```bash
docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/endgame_db.schema.sql
```

This creates audit/outbox tables and triggers and backfills the linked cash ledger
from existing fills/transactions. It does not reset balances, orders or holdings.
The publisher needs this migration before it can start. Rebuild/restart the trading
backend after migration so quote evidence and JWT-protected admin commands are active.

## Configure the separate staff stack

Both stacks read the **single root `.env`**. For a new checkout, copy root
`.env.example` to `.env` and fill the blank credentials/API key. If `.env` already
exists, add missing keys from the root example without replacing existing values.
All reporting, ETL, Superset and staff-port keys are included in that same example.
Generate independent secret values with `openssl rand -hex 32`.

```bash
docker compose -p asset-avengers-internal --env-file .env \
  -f deployment/admin-analytics/admin-analyst-stack.compose.yml up -d --build
```

The first startup initializes the reporting schema, separate component logins and
Superset metadata database. It does **not** seed `admin_analytics_db_test_data.sql`.
Superset initialization creates three prepared dashboards and saves their embedded
UUIDs in the dashboard registry. The publisher snapshots existing records, then
publishes ongoing outbox events. The consumer and configurable report scheduler run continuously.

| URL | Purpose |
|---|---|
| `http://localhost:8085/swagger-ui/index.html` | Internal API documentation |
| `http://localhost:8086/admin.html` | Admin login and workspace |
| `http://localhost:8086/analyst.html` | Analyst login and workspace |
| `http://localhost:8088` | Superset authoring; use the configured dashboard-author account |
| `http://localhost:8084/api/v1/analytics/status` | Authenticated status through Nginx |

The [simple test UI](../../internal-frontend/README.md) provides audit lookups,
commands and embedded dashboards now. The final Angular staff pages remain the
frontend teammate's work. `ADMIN_FRONTEND_TODO.md` and the [API contract](frontend-api.md)
provide the handoff. Existing auth development fixtures include staff roles. New
staff accounts come from auth-server's staff routes: the super admin
(`super.admin@example.com`) creates admins, and admins create analysts, from the admin
page's **Staff** tab or Swagger (see [staff sign-in and staff accounts](frontend-api.md#staff-sign-in-and-staff-accounts)).
Signup always creates a client. A refreshed/login token must carry `ADMIN`,
`SUPER_ADMIN` or `ANALYST`.

In the root `.env`, append `http://localhost:8086` (and
`http://localhost:5174` for Angular development) to `SUPERSET_EMBED_ORIGINS`, then run
the build/start command again. The updated initializer refreshes existing
dashboard allowlists, and the Superset web container uses the matching frame policy.

If you previously used the root Compose `admin-db`, stop its old
`endgame_admin_db` container before starting this stack; otherwise it may still
occupy port 5434. Its old volume is retained but is not automatically imported into
this new Compose project. The new reporting store can be rebuilt from source facts.
Historical hand-entered demo rows are not copied. Do not delete old volumes if you
need their contents.

## Operations

Use the same `--env-file` and `-f` arguments above for each command below:

```bash
# Inspect services/logs (never print rendered Compose config containing secrets).
docker compose -p asset-avengers-internal --env-file .env \
  -f deployment/admin-analytics/admin-analyst-stack.compose.yml ps

# Rebuild a particular day's report, after that day's configured cutoff.
docker compose -p asset-avengers-internal --env-file .env \
  -f deployment/admin-analytics/admin-analyst-stack.compose.yml run --rm reporting-job report --date 2026-10-01

# Reimport the source snapshot if needed; event/fact IDs prevent duplicate effects.
docker compose -p asset-avengers-internal --env-file .env \
  -f deployment/admin-analytics/admin-analyst-stack.compose.yml run --rm publisher backfill

# Apply an updated reporting schema to existing storage (no reset).
docker compose -p asset-avengers-internal --env-file .env \
  -f deployment/admin-analytics/admin-analyst-stack.compose.yml exec -T reporting-db \
  sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < DB/admin_analytics_db.schema.sql
```

The pipeline stops on an invalid message and retries it after restart. Inspect the
source event and destination schema when this happens; do not skip the Kafka offset
to hide the error. A reporting failure preserves the previous successful batch.
The scheduler retries at 30-second intervals. Missed previous dates can be generated
with the explicit `report --date` command.

Superset bootstrap preserves existing chart layouts. To change author/service
passwords on an initialized instance, update the account through Superset's trusted
administration tools; changing an env value alone does not rotate an existing hash.
The database login initialization scripts likewise run only on an empty volume.

## Tests

```bash
# Both Java projects, including JWT/role enforcement. Use a test-only secret.
mvn test -DJWT_SECRET=test-only-secret-at-least-thirty-two-characters

# Staff backend alone; no trading source, build or credentials needed for its tests.
mvn -f internal-backend/pom.xml clean package

# Trading regressions and actual SQL validation, using a disposable database.
python3 scripts/run-backend-postgres-tests.py

# Build the Python image, then test projection, replay, rounding and configurable cutoff/DST.
docker build -t asset-analytics-pipeline:local admin-analytics/pipeline
python3 scripts/verify-admin-analytics.py

# Build the independent staff service for the isolated full-stack test.
docker build -t asset-internal-backend:local internal-backend
docker build -t asset-internal-frontend:local internal-frontend
docker build -t asset-analytics-superset:local admin-analytics/superset
python3 scripts/verify-admin-stack.py

# Optional browser check against the real, disposable stack (Linux Docker host).
# First install the UI's npm dependencies and Playwright Chromium; see its README.
python3 scripts/verify-admin-stack.py --browser
```

The database verification scripts create and remove only their own temporary
databases. The full-stack runner generates temporary secrets and starts a unique
Compose project with a fresh source database; it does not connect to live trading
storage. It verifies source changes through Kafka, exact reporting totals, real
staff JWT authorization, quote/timeline APIs, restricted guest tokens and a real
Superset chart-data query, then removes its own containers and volumes.

## Choose the daily report time

Sign in through the matching `/admin.html` or `/analyst.html` page on port 8086. Open **Reports**, choose
**Report time (New York)**, and click **Save report time**. The shared time controls
both when the batch runs and which same-day trades are included. It takes effect
tomorrow; the screen shows today's time and the upcoming effective date. Client data
continues copying to reporting throughout the day. A saved setting needs no restart.

For an existing reporting database, apply its current schema before deploying the
updated internal API and reporting-job image (this preserves existing records):

```bash
docker compose -p asset-avengers-internal --env-file .env \
  -f deployment/admin-analytics/admin-analyst-stack.compose.yml exec -T reporting-db \
  sh -c 'psql -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < DB/admin_analytics_db.schema.sql
```

New reporting volumes apply the schema automatically. The default 19:00 schedule is
configuration metadata, not a sample client portfolio. No trading seed update is needed.

## One root environment file

The repository-root `.env` configures client, auth, trading, reporting, workers and
Superset. Root `.env.example` documents every deployment key without real secrets.
There is no separate staff `.env` or staff environment template. Both Compose
commands explicitly load root `.env`; `scripts/start-project.sh` does the same.

The previously generated staff settings were merged into root `.env` while preserving
all existing nonblank root values, and the duplicate files were removed. Root `.env`
remains ignored by Git and has permissions 0600. Superset author/service credentials
are deployment credentials, distinct from admin/analyst auth accounts.

Passwords initialize **new** reporting storage. Editing `.env` does not rotate
credentials in an existing database volume. Preserve credentials that match existing
storage rather than deleting data. No running containers or data volumes need to be
renamed when the deployment directory moves: the staff Compose project name and
service/volume names remain unchanged.

## PDF downloads

On either role's Reports page, choose a published report date and click
**Download report PDF**. This exports the business summary and instrument activity
from the saved published batch, including its ID, cutoff, source heartbeat and USD
currency. It is not a screenshot of a live Superset iframe. No published batch gives
a readable 404; wait for a successful report or select another published date.

Admins can open an order and click **Download audit PDF**, alongside the existing
JSON export. In Actions, choose inclusive UTC dates and click
**Download staff audit PDF**. Audit logs are admin-only; analysts cannot download
private admin audit records. The staff-log range is at most 32 days/1,000 entries;
large exports return an error rather than silently omitting records. Instrument-group
report exports also have a 1,000-row limit. PDFs are generated by the staff backend
with Apache PDFBox, paginate automatically and preserve non-ASCII text as explicit
Unicode escapes. Nothing changes client balances or triggers pricing requests.

Staff startup repair: PostgreSQL now loads `init-databases.sql` using psql, avoiding
execution of a mounted shell script on Docker Desktop. The startup helper also
applies source/reporting schemas and missing logins to existing volumes before
starting the staff services. This repairs partial initialization without deleting
client records, reports or volumes. Existing role passwords are not rotated.

## Stop the project, with optional data deletion

```bash
bash scripts/stop-project.sh
```

The script asks `Delete project volumes and trading data? (y/no) [no]:`.
Choose `no` or press Enter to stop both stacks and keep all saved data. Choose `y`
to also delete both stacks’ Compose-managed named and anonymous volumes and the
trading database contents in `~/.asset_postgres_test_data`. Deletion permanently removes saved users,
trades, portfolios, reports, Superset configuration and Kafka data. Source files,
the root `.env`, and Docker images remain. It does not remove unrelated or external
volumes. Docker Desktop must be running and the root `.env` must be present.

Run `bash scripts/start-project.sh` to restart with saved data, or initialize again
after deletion. Only configured initialization data is restored; deleted user data
is not recovered. Use `bash scripts/stop-project.sh --help` for usage.

## Generate a daily report on demand

Both admin and analyst Reports pages include **Generate daily report now**. It
queues today's New York report with a fixed cutoff at the instant of the request,
covering local midnight inclusive to that cutoff exclusive. The worker checks the
queue every 30 seconds and waits for a source heartbeat at or after the cutoff
before building and reconciling the report. The UI polls every three seconds while
queued and shows success or failure. Repeated clicks share outstanding work;
successful requests within one minute are reused.

The resulting batch becomes the published version for that date, available to the
existing PDF download and dashboards. Older batches remain stored. Reopen an embedded
dashboard after publication; chart caches can take 30 seconds to expire. Manual
reports do not change the daily schedule, and an early report does not suppress the
scheduled run. No trade database changes or market-price API calls are made.

`integration.report_requests` records the requesting staff UUID, cutoff, status,
resulting batch and completion time. The API can enqueue/read requests; only the
reporting worker can update their outcome. Apply the updated reporting schema
before deploying the API and worker (the startup helper does this automatically).

## Access admin and analyst pages from a VM

Set `STAFF_BIND_ADDRESS=0.0.0.0` in the single root `.env` to expose the staff UI
and Superset ports on the host's network interfaces. Their default binding is
`127.0.0.1`, which accepts connections only from the host computer. The reporting
database and direct staff API ports remain bound locally; browser API requests go
through the staff UI's same-origin Nginx proxy.

Open `http://HOST_IP:8086/admin.html` or `http://HOST_IP:8086/analyst.html` from the
VM. The bare `/` path intentionally has no login page. For embedded dashboards,
keep `SUPERSET_PUBLIC_URL=auto` (or set an explicit URL for a reverse proxy) and add `http://HOST_IP:8086` to
`SUPERSET_EMBED_ORIGINS`, preserving other origins you still use. Run
`bash scripts/start-project.sh --staff` to apply the port/environment settings and
refresh Superset's dashboard origin allowlists. The VM must be able to reach the
host and its firewall must allow ports 8086 and 8088. Replace HOST_IP with the
actual reachable host IP, not the VM's own IP or localhost.

The start/stop helpers use the `docker compose` plugin command for the VM.
Configuration checks redirect stdout to `/dev/null`, keeping rendered secrets out
of terminal output without using the unsupported quiet flag. Startup polls database
readiness directly instead of relying on newer Compose wait options.

## Opt-in full-project demo data and admin updates

Run `bash scripts/load-demo-data.sh` after `bash scripts/start-project.sh` to load
named demo clients, banks, funds, watchlists, filled/rejected/cancelled orders and
synthetic pricing/audit evidence. It waits for the normal Kafka projection and
publishes ready-to-view reports. Reruns preserve subsequent client changes; normal
startup does not load these financial fixtures. See the [demo walkthrough](../demo-walkthrough.md)
for logins, expected balances and a demonstration sequence.

Admin Orders now polls its filtered/current page every three seconds while visible.
It stops when leaving Orders or logging out, skips hidden tabs, ignores superseded
responses and retains existing results during background failures. This reads the
reporting database only; it does not request stock prices.

## Suspend or restore a client by name

In Admin → Actions, select Account and type a first name, last name or email into
**Person name or email**. Suggestions begin with one character after a 250 ms
pause. Each result shows the name, email, account ID and copied suspension status,
so duplicate names are distinguishable. Select the correct account, choose Suspend
or Remove suspension, enter the required reason, and click Apply action. No UUID
needs to be typed. The selected account is shown before submission.

Editing the search or switching resource types clears the account selection and
disables account submission until a new result is selected. Instrument actions
retain the existing instrument UUID field. The backend still applies the action by
account UUID under the verified admin identity and records the existing audit trail.
Analysts cannot access the account picker endpoint. No database migration is needed.


## Presentation guide and current workspace names

See [presentation guide](../presentation-guide.md) for Ultron (admin), J.A.R.V.I.S. (analyst), development logins, spread/return examples, PDF interpretation and the expanded 99-client / 2,540-fill demo. Staff development images use `:local`. Existing data is preserved; run the demo loader to add the extension.
