> Historical repair instructions, retained for reference. These repairs have already been handled and verified; do not treat the commands below as pending work. See [current RDS maintenance](../../rds/README.md), including the caveat about the larger script and the actual deployed login names.

# Repair permissions after restoring RDS databases

Use `repair-restored-ownership.sql` for the three databases below. The auth
database was handled separately and is intentionally not included.

## Using your SQL editor

1. Connect to RDS as `postgres` and select **Endgame_Trading** as the database.
2. Open `deployment/archive/rds-repairs/repair-restored-ownership.sql` in that connection's SQL
   editor. Run the **entire file**, not just the selected statement.
3. Confirm execution succeeds through `COMMIT` and the verification queries.
   If an error occurs, stop and send the error. If your editor leaves the
   transaction open after an error, run `ROLLBACK;` before retrying.
4. Open a connection to **admin_analytics**, still as `postgres`, and run the
   **same entire file** there.
5. Open a connection to **superset_metadata**, still as `postgres`, and run the
   **same entire file** there.

You do not edit the script between databases. It uses `current_database()` to
choose the intended owner:

| Connected database | Intended application object owner |
| --- | --- |
| Endgame_Trading | thor_trading |
| admin_analytics | fury_reporting_owner |
| superset_metadata | jarvis_metadata |

Do not run the file while connected to `postgres` or `auth` as the database.
`postgres` is the login account; the selected database must be one in the table.
The file rejects other databases.

## What the script does

- Transfers application tables, views, sequences, routines, and enum/domain types
  owned by `postgres` to the intended owner, within the listed application schemas.
- Grants the intended owner schema usage/create access and transfers applicable
  non-public application schemas owned by `postgres`.
- Excludes extension-owned objects.
- Grants the migration administrator membership in the intended owner role, as
  the repository's database bootstrap does; it never grants services the postgres role.
- In `admin_analytics`, restores these inherited memberships:
  `endgame_admin -> analytics_admin`, `analytics_worker -> analytics_etl`, and
  `superset_reader -> analytics_analyst`.
- Reapplies the 33 reporting GRANT statements from
  `DB/admin_analytics_db.schema.sql`, preserving the intended read/write boundaries.

The file contains `BEGIN` and `COMMIT`. A SQL error prevents the transaction from
committing successfully. It does not insert, delete, or reset application data,
create application tables, or create login accounts. Missing expected reporting
objects cause an error rather than being silently skipped. Empty databases remain
empty. These changes restore the repository's ownership/grant model; verify each
service afterward to discover any unrelated deployment or schema problems.

## Using psql instead (optional)

From the repository root on a machine with psql and RDS connectivity, run each
command separately. `-W` prompts for the postgres password; do not put it in the
command or share it in chat.

```bash
psql -X -W -v ON_ERROR_STOP=1 "host=asset-avengers-db.c8xuasgw2vz5.us-east-1.rds.amazonaws.com port=5432 user=postgres dbname=Endgame_Trading sslmode=require" -f deployment/archive/rds-repairs/repair-restored-ownership.sql
```

After that succeeds:

```bash
psql -X -W -v ON_ERROR_STOP=1 "host=asset-avengers-db.c8xuasgw2vz5.us-east-1.rds.amazonaws.com port=5432 user=postgres dbname=admin_analytics sslmode=require" -f deployment/archive/rds-repairs/repair-restored-ownership.sql
```

After that succeeds:

```bash
psql -X -W -v ON_ERROR_STOP=1 "host=asset-avengers-db.c8xuasgw2vz5.us-east-1.rds.amazonaws.com port=5432 user=postgres dbname=superset_metadata sslmode=require" -f deployment/archive/rds-repairs/repair-restored-ownership.sql
```

The script has not been executed against RDS by the assistant. Catalog/grant
checks in the file help verify the result; SQL execution still needs to be
performed and checked in your environment.
