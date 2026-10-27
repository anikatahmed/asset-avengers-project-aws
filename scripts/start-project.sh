#!/usr/bin/env bash
# Start the client stack, the staff stack, or both, preserving database volumes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MODE="${1:---all}"
case "$MODE" in
  --all|--client|--staff) ;;
  --help|-h)
    echo 'Usage: bash scripts/start-project.sh [--all|--client|--staff]'
    echo 'Default: --all. Start --client before using --staff by itself.'
    echo 'Configure the single root .env from .env.example before starting.'
    echo 'Staff startup applies current database schemas and missing service logins.'
    exit 0 ;;
  *) echo 'Usage: bash scripts/start-project.sh [--all|--client|--staff]' >&2; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then
  echo 'Choose one option: --all, --client or --staff.' >&2; exit 1
fi
if [[ ! -f .env ]]; then
  echo 'Missing .env. Copy .env.example to .env and fill its credentials and API key.' >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo 'Docker is unavailable. Start Docker Desktop and try again.' >&2; exit 1
fi
STAFF=(docker compose -p asset-avengers-internal --env-file .env
       -f deployment/admin-analytics/admin-analyst-stack.compose.yml)
# Validate requested configuration before starting either stack; no secrets printed.
if [[ "$MODE" != --staff ]]; then docker compose config >/dev/null; fi
if [[ "$MODE" != --client ]]; then "${STAFF[@]}" config >/dev/null; fi
# Check SQL connections directly: pg_isready can succeed for a missing database.
# Explicit SQL checks also verify the configured database and login.
wait_for_database() {
  local label="$1"
  shift
  local attempt
  for ((attempt=1; attempt<=60; attempt++)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "$label was not ready within 120 seconds. Check its container logs." >&2
  return 1
}
# A failed first initialization can leave PG_VERSION present but no app database.
# Connect to postgres first, create only a missing database, then verify its SQL login.
prepare_database() {
  local label="$1" service="$2"
  shift 2
  wait_for_database "$label server" "$@" exec -T "$service" sh -c 'psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -Atc "SELECT 1"'
  "$@" exec -T "$service" sh -c 'psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres --set=database="$POSTGRES_DB" --set=owner="$POSTGRES_USER"' < DB/ensure-database.sql
  wait_for_database "$label" "$@" exec -T "$service" sh -c 'psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT 1"'
}
if [[ "$MODE" != --staff ]]; then
  # Apply identity columns and MFA tables to existing auth volumes before starting auth.
  docker compose up -d auth-db postgres
  prepare_database 'Auth database' auth-db docker compose
  prepare_database 'Trading database' postgres docker compose
  docker compose exec -T auth-db sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/auth_db.schema.sql
  docker compose exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/endgame_db.schema.sql
  # Seed the catalogue even after recovery; upserts preserve saved instruments and suspensions.
  docker compose exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/instruments.seed.sql
  # Build one service at a time to reduce peak disk usage on small hosts.
  for service in auth-server backend frontend; do
    docker compose build "$service"
  done
  docker compose up -d --no-build
fi
if [[ "$MODE" != --client ]]; then
  # Initialization directories run only once. Apply current idempotent schemas and
  # missing logins explicitly for existing volumes; never reset saved data.
  "${STAFF[@]}" up -d reporting-db
  prepare_database 'Trading database' postgres docker compose
  prepare_database 'Reporting database' reporting-db "${STAFF[@]}"
  docker compose exec -T postgres sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/endgame_db.schema.sql
  "${STAFF[@]}" exec -T reporting-db sh -c 'psql -X -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < DB/admin_analytics_db.schema.sql
  "${STAFF[@]}" exec -T reporting-db sh -c 'psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/02-logins.sql'
  # Shared image tags let subsequent pipeline/Superset services reuse these builds.
  for service in internal-frontend publisher internal-backend superset; do
    "${STAFF[@]}" build "$service"
  done
  "${STAFF[@]}" up -d --no-build
fi
if [[ "$MODE" != --staff ]]; then echo 'Client app: http://localhost:8084'; fi
if [[ "$MODE" != --client ]]; then
  echo 'Admin login: http://localhost:8086/admin.html'
  echo 'Analyst login: http://localhost:8086/analyst.html'
  echo 'Superset authoring: http://localhost:8088 (separate configured Superset login).'
fi
echo 'Services may need a moment to become ready. Saved database volumes are preserved.'
