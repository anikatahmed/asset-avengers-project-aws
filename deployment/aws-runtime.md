# AWS runtime: S3 frontends and RDS databases

The root `docker-compose.yml` runs only the trading API and auth server.
`deployment/admin-analytics/admin-analyst-stack.compose.yml` runs Kafka, reporting
workers, the staff API and Superset. Neither deployment file runs PostgreSQL or
Angular. CI retains disposable local services in `deployment/ci/ci.compose.yml`
and `deployment/admin-analytics/admin-analyst-ci.compose.yml`; never point CI at RDS.

## Before starting

Create or migrate these separate PostgreSQL databases in RDS:

| Database | Consumers |
| --- | --- |
| `Endgame_Trading` | Trading API and outbox publisher |
| `auth` | Auth server |
| `admin_analytics` | Staff API, reporting workers and Superset reporting reader |
| `superset_metadata` | Superset configuration and dashboard metadata |

They can share one RDS instance/endpoint. Use separate service users and preserve
the reporting roles in `DB/admin_analytics_db.schema.sql`. Restore existing data
before switching traffic. For empty databases, apply `DB/auth_db.schema.sql`,
`DB/endgame_db.schema.sql` and `DB/admin_analytics_db.schema.sql` to their respective
databases using an authorized migration login; apply `DB/instruments.seed.sql`
to trading. Create reporting service logins and the Superset metadata owner/database
using `deployment/admin-analytics/init-databases.sql` with its documented environment
variables and a PostgreSQL client supporting `\getenv` (15+). That script preserves
existing passwords; database owners/role memberships must match the restored schema.
Do not automatically apply demo fixtures to shared RDS databases.

Normal startup no longer creates databases, schemas or logins. `superset-init` still
runs Superset metadata migrations and dashboard bootstrap, so its migration login
needs reporting registry write permissions. It must not be the ordinary reader login.

Copy `.env.example` to `.env`. Replace every `YOUR-RDS-ENDPOINT` with the actual DNS
endpoint, fill all credentials and supply the public frontend/Superset URLs.
`DB_URL` and `ADMIN_DB_URL` are complete JDBC URLs. `SOURCE_DB_HOST`, `AUTH_DB_HOST`,
`ADMIN_DB_HOST` and `SUPERSET_METADATA_HOST` are DNS hostnames without URL schemes.
All database ports default to 5432. Keep RDS private and allow its security group
to receive PostgreSQL connections from the EC2 application's security group.

JDBC and Python connections default to encrypted connections (`sslmode=require` /
`PGSSLMODE=require`). Auth verifies the server certificate; supply the current
[AWS RDS CA bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)
as `AUTH_DB_SSL_CA`, using a single-quoted multiline PEM value in `.env`:

```dotenv
AUTH_DB_SSL=true
AUTH_DB_SSL_CA='-----BEGIN CERTIFICATE-----
...actual CA certificate contents, including any additional certificates...
-----END CERTIFICATE-----'
```

For full server identity verification on JDBC/Python connections, configure the
RDS CA trust file in those containers and use `sslmode=verify-full`. Never disable
certificate verification in the auth client to work around a missing CA.

## Deploy Angular separately

Build `frontend` and `internal-frontend` in CI or on a development machine:

```bash
(cd frontend && npm ci && npm run build)
(cd internal-frontend && npm ci && npm run build)
```

Upload `frontend/dist/frontend/browser/` and
`internal-frontend/dist/staff/browser/` to their respective S3 buckets. Supply
`LOGOKIT_PUBLISHABLE_TOKEN` to the client build if using company logos.
Use private buckets behind CloudFront with HTTPS and Angular route fallback.
These Compose changes do not provision buckets, distributions or API ingress.

The removed Nginx containers also supplied API routing. Preserve that routing in
CloudFront/your HTTPS ingress before using the hosted frontends:

| Browser path | Backend |
| --- | --- |
| Client `/api/` | Trading API, port 8080 |
| Client `/api/v1/admin/`, `/api/v1/analytics/` | Staff API, port 8085 (more specific routes take precedence) |
| Staff `/api/v1/` | Staff API, port 8085 |
| Both `/auth/` | Auth server, port 3000 |

Preserve cookies, query strings and authorization headers; disable API/auth caching.
Apply Angular fallback only to frontend routes, not failed API/auth requests.
Prefer same-origin routing so both apps can keep their existing relative API URLs.
Configure Superset's public HTTPS endpoint and set `SUPERSET_EMBED_ORIGINS` to the
staff CloudFront origin. The staff API remains bound to loopback on EC2; expose it
through an ingress on that host or explicitly configure a private ingress binding.

## Start and stop

```bash
bash scripts/start-project.sh           # both API/service stacks
bash scripts/start-project.sh --client  # trading API and auth only
bash scripts/start-project.sh --staff   # staff services; start client stack first
bash scripts/stop-project.sh
```

Builds run one image at a time. Stopping preserves RDS, Kafka storage and old local
storage. Existing containers removed from the Compose files become orphans;
stop the old frontend/database containers explicitly after verifying the migration.
Do not delete their data until the RDS restore is verified. The local demo loader
is disabled; `setup-test-db.sh` remains a local-only tool and does not configure RDS.
