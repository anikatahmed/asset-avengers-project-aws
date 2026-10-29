# Deployment

## Current production deployment

Use [ECS operations](ecs/README.md) and the [AWS startup guide](aws-runtime.md).
ECS runs eight services on the existing EC2 host; ECR stores their images,
RDS stores PostgreSQL data, and S3/CloudFront serves the Angular applications.

| Path | Purpose |
| --- | --- |
| `ecs/tasks/` | Eight production task-definition inputs |
| `ecs/images/` | Current image digests and source snapshots |
| `ecs/state/` | Cluster/service references, rollback state and backup location |
| `ecs/verification/` | Smoke-test, permission and security evidence |
| `ecs/kafka/` | Kafka image with vendor OS patches |
| `ecs/superset-upgrade-review/` | Separate Superset upgrade assessment |
| `rds/` | First-time provisioning and recovery tools |
| `staff-cloudfront.md`, `superset-aws.md` | Hosting and ingress references |
| `analytics-nginx.conf` | Host Nginx analytics ingress template |
| `archive/` | Completed migrations, old setup instructions and repair records |

## Retained Compose files

These support isolated testing and legacy recovery; they do not start production ECS services.

| Compose file | Purpose |
| --- | --- |
| `../docker-compose.yml` | Legacy trading/auth deployment configuration |
| `admin-analytics/admin-analyst-stack.compose.yml` | Legacy staff/Kafka/reporting/Superset configuration |
| `ci/ci.compose.yml` | Disposable client/auth CI stack |
| `admin-analytics/admin-analyst-ci.compose.yml` | Disposable staff CI stack |
| `rds/bootstrap.compose.yml` | One-shot PostgreSQL provisioning client, not an application service |

Start RDS, then EC2, and verify ECS health. Do not run the Compose start helper
on the ECS-managed server.
