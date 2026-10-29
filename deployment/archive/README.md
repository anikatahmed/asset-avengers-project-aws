# Historical deployment material

The live deployment is documented in [ECS operations](../ecs/README.md).
This folder keeps completed migration work out of the active deployment directory.
Archived files are reference material, not instructions to rerun against production.

- `browser-to-backend-guide.md`: initial CloudFront/Nginx migration walkthrough;
  its October 28 starting state has been superseded.
- `aws-compose-runtime.md`: former Compose-based AWS setup and provisioning guide.
- `analytics-http-challenge.conf`: temporary HTTP-only certificate-bootstrap template;
  the active HTTPS template remains at `../analytics-nginx.conf`.
- `rds-repairs/`: completed ownership/permission repair scripts and original notes.

## Cleanup record

The following unchanged, unused legacy files were removed; Git history retains them:

- `DB/docker-compose-proddb.yml`: standalone PostgreSQL container configuration,
  unused by current ECS deployment and CI.
- `DB/admin_analytics_db_app_user.sh`: older single-login initializer, superseded
  by the maintained schema and provisioning tools.

The old frontend implementation plan moved from the root to
[docs/archive/admin-frontend-plan.md](../../docs/archive/admin-frontend-plan.md).
Schemas, demo fixtures, database tests, CI files, Docker build sources, current
ECS definitions, security evidence, image history and rollback records were retained.
No AWS resources, running services or database contents were changed by this cleanup.
