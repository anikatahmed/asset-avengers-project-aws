#!/usr/bin/env bash
# Stop application stacks without deleting persistent data.
# Stop staff first because its services use the client stack's trading network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  echo 'Usage: bash scripts/stop-project.sh'
  echo 'Stops client, admin, analyst, reporting and Superset services.'
  echo 'Preserves RDS data, Kafka volumes and old local database storage.'
  echo 'Keeps source files, root .env and Docker images.'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo 'Usage: bash scripts/stop-project.sh [--help]' >&2
  exit 1
fi
if [[ ! -f .env ]]; then
  echo 'Missing root .env. Recreate it with: bash scripts/fetch-env-aws.sh' >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo 'Docker is unavailable. Start Docker Desktop and try again.' >&2
  exit 1
fi
CLIENT=(docker compose --env-file .env)
STAFF=(docker compose -p asset-avengers-internal --env-file .env
       -f deployment/admin-analytics/admin-analyst-stack.compose.yml)
# Validate both configurations before removing anything; never print secrets.
"${CLIENT[@]}" config >/dev/null
"${STAFF[@]}" config >/dev/null
# Preserve Kafka storage and any old local database storage during the migration.
echo 'Stopping both application stacks…'
"${STAFF[@]}" down
"${CLIENT[@]}" down
echo 'Application stacks stopped. RDS data, Kafka storage and old local volumes are preserved.'
echo 'Restart with: bash scripts/start-project.sh'
