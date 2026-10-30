# Admin and analyst local deployment

This is the entry point for the staff-facing work. A simple test console is
available in `internal-frontend/`; the final Angular staff screens remain a
separate frontend task.

- [Architecture and data meaning](architecture.md)
- [Setup, commands and verification](setup.md)
- [Frontend API contract](frontend-api.md)
- [Simple test UI](../../internal-frontend/README.md)

| Folder | Responsibility |
|---|---|
| `internal-backend/` | Independent Spring API with its own admin, analytics and security packages; no client-backend dependency |
| `internal-frontend/` | Simple staff test UI, served separately on port 8086 |
| `admin-analytics/pipeline/` | Python outbox publisher, Kafka consumer, backfill and nightly reporting |
| `admin-analytics/superset/` | Pinned Superset image, configuration and initial dashboards |
| `deployment/admin-analytics/` | Separate Compose stack and database login initialization; uses root `.env` |
| `DB/admin_analytics_db.schema.sql` | Reporting database tables, views and grants |
| `backend/` | Client trading service; produces audit evidence and executes source-state commands in `tradingcontrol/` |

The repository-root Compose file starts the existing client/auth/trading system.
The staff stack has its own Compose project, network and persistent volumes.

See the [analyst dashboard user guide](analyst-dashboard-guide.md) for filtering, reporting dates, traded notional, and dashboard troubleshooting.

For self-service chart creation and typed filters, see [Trade Explorer](trade-explorer.md).
