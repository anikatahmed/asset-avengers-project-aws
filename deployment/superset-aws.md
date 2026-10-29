# Superset on AWS

Current orchestration: [ECS on EC2](ecs/README.md).

Verified endpoint: `https://analytics.assetavengers.top`.

- Spaceship A record: `analytics` -> `54.237.94.203`.
- Host Nginx configuration: `/etc/nginx/conf.d/asset-avengers-analytics.conf`.
- Reviewed configuration: `deployment/analytics-nginx.conf`.
- Nginx terminates TLS and forwards to `http://127.0.0.1:8088`.
- ECS publishes host port 8088; the security group denies public ingress to that port.
  Nginx reaches it through localhost. No public database port was opened.
- Certbot certificate name: `analytics.assetavengers.top`; renewal is scheduled.

The application secret supplies these settings to ECS by reference:

```dotenv
SUPERSET_PUBLIC_URL=https://analytics.assetavengers.top
SUPERSET_EMBED_ORIGINS=https://admin.assetavengers.top,https://analyst.assetavengers.top
SUPERSET_COOKIE_SECURE=true
```

The Superset ECS task receives the secure-cookie flag from Secrets Manager. Both Flask
and Talisman use it; cookies are HttpOnly and SameSite=Lax. Staff and analytics
use HTTPS subdomains of the same site. Existing encryption, guest-token and SSO
keys were preserved.

Metadata is in `superset_metadata` as `jarvis_metadata`. Reporting reads use
`vision_reader` in `analytics_analyst`. Only the bootstrap receives
`fury_reporting_owner` for writing the three dashboard registry entries.

The original bootstrap failed with `permission denied for schema integration`.
After ownership repair, running only `/app/bootstrap.py` succeeded. Metadata
migrations were not rerun. Existing passwords and dashboard layouts were verified
unchanged. Bootstrap also refreshed the dashboard embedding allowlists.

## Initialization and upgrades

The current web task does not run bootstrap or metadata migrations. Superset
remains on patched 6.0.0 with the reviewed safeguards. The 6.1 candidate is recorded
in [the upgrade review](ecs/superset-upgrade-review/README.md).

Any future bootstrap or metadata migration is a deliberate maintenance operation
requiring the correct owner credentials, a backup and reviewed scope. Do not use
the old Compose initializer on the ECS-managed host or add its privileges to the
ordinary web/reporting-reader task. See the [ECS operations guide](ecs/README.md)
for current images, storage, secrets and rollback.
