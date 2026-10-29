> For the current ECS/RDS/S3 deployment, follow [AWS runtime setup](../deployment/aws-runtime.md). Local database/container commands below apply only to local testing.

# Admin and analyst reporting infrastructure

This folder holds the staff data pipeline and Superset configuration. The shared
admin/analyst Spring Boot API lives in [internal-backend](../internal-backend/README.md),
and its test UI lives in [internal-frontend](../internal-frontend/README.md).

| Folder | Contents | Role |
| --- | --- | --- |
| `pipeline/` | Python code, dependency list, Dockerfile and verification scripts | Publish committed trading outbox records to Kafka, consume them into reporting data, backfill existing facts and build scheduled reports |
| `superset/` | Superset Dockerfile, configuration and initialization scripts | Create dashboards and configure reporting access and embedding |

**Admin** is the staff role that investigates trades and issues permitted commands.
**Analyst** is the staff role that views reports. **Analytics** means the reporting
features and infrastructure used by those roles. The name `admin-analytics` groups
that shared infrastructure; it is not another Java backend.

The pipeline runs as separate publisher, consumer and reporting-job containers.
Their startup configuration is in
[deployment/admin-analytics/admin-analyst-stack.compose.yml](../deployment/admin-analytics/admin-analyst-stack.compose.yml).
Database schemas are maintained in [DB](../DB/README.md).

For startup commands, environment settings and verification, use the
[staff setup guide](../docs/admin-analytics/setup.md). For the whole feature, see
[admin and analyst documentation](../docs/admin-analytics/README.md).
