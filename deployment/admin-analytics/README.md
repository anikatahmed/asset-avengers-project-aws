> AWS deployment now uses ECS on EC2, RDS and S3/CloudFront. See the [current runtime guide](../aws-runtime.md); local container startup instructions below are historical.

# Admin and analyst Docker Compose stack

This folder contains deployment configuration for the admin/analyst system.
`admin-analyst-stack.compose.yml` tells Docker how to build and run the staff services together; it
is not application source code. See [which Compose file to use](../README.md).

This folder owns the admin/analyst Docker Compose project. Start the client stack
from the repository root first, then follow [the setup guide](../../docs/admin-analytics/setup.md).

- `admin-analyst-stack.compose.yml`: staff test UI (port 8086), reporting PostgreSQL, Kafka, Python jobs, internal API and Superset.
- Repository-root `.env.example`: shared configuration template for both stacks.
  The real repository-root `.env` supplies all settings; no local env file is needed.
- `init-databases.sql`: separate least-privilege component logins and Superset metadata database.
- `admin-analyst-tests.override.yml`: used by `scripts/verify-admin-stack.py` with a temporary port-free copy of the base configuration; does not use the live trading database.
- `admin-analyst-browser.override.yml`: adds disposable auth services for real browser MFA/SSO tests.
- `test-runtime.Dockerfile`: packages a previously tested jar for the verification stack.


Use the startup/stop scripts, or pass `-p asset-avengers-internal` for manual staff
commands. The project name is explicit in the CLI rather than the newer YAML
`name` field, preserving the existing stack's volume and network names on older
Compose. Do not combine the test override with the unmodified base manually: it
cannot remove inherited host ports on legacy Compose; use the verifier instead.


Images default to `STAFF_IMAGE_TAG=local`. Jenkins uses unique per-build tags and
runs `verify-admin-stack.py --image-tag ...` against those images, so CI builds do
not replace local development image tags. See the [Jenkins guide](../../docs/jenkins-ci.md).
