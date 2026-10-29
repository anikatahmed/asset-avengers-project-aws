# RDS demo data through DBeaver

This is a separate, additive dataset for the existing RDS schemas. It does not
enable the disabled shell loader, recreate schemas, change permissions, or reset
existing portfolios. Take an RDS snapshot first and keep the normal ECS trading,
publisher, Kafka, consumer, and reporting services running.

## Run order

Use the **active database** selector in the SQL editor, not just its schema
selector. Alternatively, expand the connection's databases and open an SQL
editor from the required database. PostgreSQL has no ordinary SQL `USE database`
statement: connecting as `postgres` does not make one editor span all databases.
Check the target with:

```sql
SELECT current_database(), current_user;
```

Open [rds-demo.sql](rds-demo.sql) in DBeaver on your existing RDS connection.
Enable auto-commit and execute the **entire script**, not a highlighted fragment.
Each execution is one atomic statement: an error rolls back that database's
seed, but the auth and trading executions are separate transactions. Do not
cancel the trading load while it is running.

1. Select **auth** and run the entire seed once. Then run the entire
   [rds-demo-verify.sql](rds-demo-verify.sql). All three auth checks should pass.
2. Select **Endgame_Trading** and run the same seed once. This can take several
   minutes on RDS. Run the verifier there; all 28 source checks should pass.
3. Select **admin_analytics** and run the verifier only. Wait for all 15 ingestion
   checks in the first result set to pass. Recheck as needed; a large pipeline
   backlog can take considerably longer than the SQL insert. Do not reload or
   reset databases to fix ingestion lag.
4. Optional, for historical Superset charts: run the seed in **admin_analytics**
   after step 3. Here it inserts only 90 report requests, not financial facts.
   The existing reporting worker builds them. Rebuilding these dates includes
   existing clients' trades too and replaces each date's selected published
   batch, while retaining prior immutable batches. These requests use a full-day
   New York cutoff of 23:59:59.999999, not the normal scheduled cutoff; the saved
   schedule is unchanged. The requester is an explicitly synthetic seeder UUID,
   not an impersonated real staff user.
5. Run the verifier again in **admin_analytics**. Its separate optional publication
   result should eventually show 21,200 published demo fills, 90 published demo
   requests, zero queued requests, and zero failed requests. Before publication,
   false results in this second result set are expected. The worker processes
   requests in groups; keep it running and check its logs if requests fail.

Do not run the seed in **superset_metadata**. Superset manages that database;
charts read the published facts in admin_analytics. The verifier may be run in
superset_metadata for its informational message and database-size results.

For charts, select the last 90 days (including yesterday) and clear other filters.
The seed creates no trades dated today, so a today-only chart can remain empty.

## Exact initial demo counts

The verifier filters this seed's `ed3f...` IDs rather than counting other users'
data. Existing demo fixtures use different IDs and do not affect these totals.

| Record | Expected |
| --- | ---: |
| Client identities and investment accounts | 200 each |
| Bank links and watchlists | 200 each |
| Watchlist items | 1,200 |
| Holding rows / positive positions | 2,000 / 1,200 |
| Orders / fills / rejected orders | 21,600 / 21,200 / 400 |
| Deposits / withdrawals / dividends | 600 / 200 / 200 |
| Cash ledger movements | 22,200 |
| Order lifecycle facts / pricing evidence | 43,200 / 21,600 |
| Disputes / suspended accounts / suspension audits | 400 / 20 / 20 |
| Traded asset categories / historical report dates | 7 / 90 |

Cash and holdings reconcile to immutable movements. Initial balances are never
negative, including when reconstructed chronologically. Closed synthetic pairs
cover all seven categories; retained positions and watchlists use the six normal
catalogue instruments. Four new `RDS-DEMO-*` instruments are inactive and have
zero final holdings. No pending orders or provider calls are created by the seed.
It does not create sessions, MFA credentials, email deliveries, live market marks,
or Superset metadata just to fill tables.

New auth logins are deliberately **disabled**. Emails range from
`rds.demo.001@example.invalid` to `rds.demo.200@example.invalid`; the non-deliverable
domain and disabled status prevent creating publicly usable shared demo accounts.
Use your existing staff accounts to inspect them. Enabling client demo login
requires a separate reviewed password/account-provisioning step.

Rerunning skips existing seeded trading accounts without resetting later deposits,
names, positions, passwords, MFA, or suspension changes. Report requests also
deduplicate. Initial exact counts can change after intentional user activity;
the cash/holding reconciliation checks remain useful. Identity collisions or
missing required triggers cause an error rather than overwriting existing data.
An ingestion guard error is safe to retry after fixing the pipeline; a failed
report request requires investigation rather than automatic destructive repair.

## Storage and validation limits

On isolated PostgreSQL 18 with the repository's schema, the initial full trading
load grew the database from about 9.5 MiB to 356 MiB, roughly **347 MiB added**.
About 311 MiB was durable outbox storage. RDS allocation, indexes, copied analytics
envelopes, report versions, and temporary WAL usage make total instance growth
larger. Do not treat 347 MiB as a cap or as a measurement of your RDS instance.
The verifier's database-size results exclude WAL and other instance-level usage;
watch RDS FreeStorageSpace during and after loading.

Local validation covered full source counts and reconciliation, safe reruns with
later user changes, and reporting queries/queueing against source-derived rows.
Live RDS, Kafka consumption, and the reporting worker were not exercised. If the
live schema or catalogue differs, the seed should abort; do not reapply schemas,
disable triggers, or reset databases to bypass an error without inspecting it.