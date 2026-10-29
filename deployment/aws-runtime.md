# AWS runtime: ECS, ECR, RDS and S3/CloudFront

The live application is managed by ECS on EC2. The current source of deployment
and rollback instructions is the [ECS operations guide](ecs/README.md).

## Normal startup

1. Start `asset-avengers-db` in `us-east-1`, if stopped, and wait for `available`.
2. Start EC2 `i-0058f31de51e5c5c8`, if stopped, and wait for status checks.
3. Verify the ECS agent is active and all eight `asset-avengers` services are healthy.

The agent reconnects automatically. Do not run `scripts/start-project.sh` or
Compose on this host; the startup helper is guarded to prevent duplicate services.
Routine startup does not provision databases, run migrations, bootstrap Superset
or load demo data. Do not recreate a database because an application is unhealthy.

## Configuration and storage

- Secrets: `matrix/production/credentials`, injected into ECS tasks by reference.
- Frontends: S3/CloudFront; [staff hosting](staff-cloudfront.md).
- Host ingress: Nginx; [analytics endpoint](superset-aws.md).
- PostgreSQL: private RDS; [maintenance and recovery tools](rds/README.md).
- Kafka: its existing persistent host volume; backup details are recorded under
  `ecs/state/`. Do not remove that volume or run two brokers against it.

Refreshing root `.env` does not update ECS tasks. Changing secrets requires a
reviewed service deployment. Preserve existing encryption keys and service-role
separation.

## Development and historical setup

CI uses disposable local stacks under `deployment/ci/` and
`deployment/admin-analytics/`; never point them at shared RDS.
The [former Compose runtime guide](archive/aws-compose-runtime.md) is retained
for provisioning/migration reference. It is not the live startup procedure.
