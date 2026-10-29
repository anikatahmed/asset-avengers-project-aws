# RDS maintenance and recovery

RDS is still the live PostgreSQL store. ECS replaced application orchestration;
it did not replace the databases. Keep the schemas under `DB/` and these tools
for new environments or recovery. None is part of routine ECS startup.

| File | Purpose |
| --- | --- |
| `bootstrap.compose.yml` | Runs a one-shot PostgreSQL client |
| `create-databases.sql` | Creates empty restore targets and service roles through the reviewed helper |
| `../../scripts/create-rds-databases.sh` | Explicit provisioning helper; `--help` describes inputs and reset behavior |

Do not run provisioning/reset commands against the working databases as a
startup step. Database/schema changes and demo-data loading require separate
review. Never put administrator passwords into commands or source control.

## Current ownership and access model

| Database | Intended owner |
| --- | --- |
| `Endgame_Trading` | `thor_trading` |
| `auth` | `natasha_auth` |
| `admin_analytics` | `fury_reporting_owner` |
| `superset_metadata` | `jarvis_metadata` |

The deployed reporting logins are `tony_admin` (analytics_admin), `bruce_etl`
(analytics_etl), and `vision_reader` (analytics_analyst). Group roles contain
permissions; they are not application logins. `DB/admin_analytics_db.schema.sql`
defines the reporting grants. Do not switch services to the postgres administrator.

## Completed repair history

Ownership-repair SQL and its original instructions are archived in
[completed RDS repairs](../archive/rds-repairs/README.md). These are historical
maintenance records, not pending migrations. The larger restored-ownership
script did not produce the expected result during the original manual attempt;
smaller repairs and catalog checks were used instead. Do not blindly rerun it.
Inspect the connected database, roles, ownership and effective permissions before
planning any further repair.

See [current ECS operations](../ecs/README.md) for startup, secrets and rollback,
and the [historical provisioning guide](../archive/aws-compose-runtime.md) for
older first-time setup context.
