#!/usr/bin/env bash
# Apply the current endgame SQL schema and catalogue seed without resetting saved data.
set -euo pipefail

RESET_DB=false
case "${1:-}" in
  '') ;;
  --reset) RESET_DB=true ;;
  *) echo 'Usage: bash setup-test-db.sh [--reset]'; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_CONTAINER_NAME="${ENDGAME_DB_CONTAINER:-}"
if [[ -z "$DB_CONTAINER_NAME" ]]; then
  if docker container inspect endgame_postgres >/dev/null 2>&1; then
    DB_CONTAINER_NAME=endgame_postgres
  else
    DB_CONTAINER_NAME=endgame_test_db
  fi
fi
DB_PORT="${ENDGAME_DB_PORT:-5432}"
DB_USERNAME="${ENDGAME_DB_USER:-admin}"
DB_PASSWORD="${ENDGAME_DB_PASSWORD:-admin123}"
DB_NAME="${ENDGAME_DB_NAME:-Endgame_Trading}"
VOLUME_PATH="${ENDGAME_DB_VOLUME:-$HOME/.asset_postgres_test_data}"

if docker container inspect "$DB_CONTAINER_NAME" >/dev/null 2>&1; then
  if [[ "$(docker inspect --format '{{.State.Running}}' "$DB_CONTAINER_NAME")" != true ]]; then
    docker start "$DB_CONTAINER_NAME" >/dev/null
  fi
else
  mkdir -p "$VOLUME_PATH"
  docker run -d --name "$DB_CONTAINER_NAME" --restart unless-stopped \
    -e POSTGRES_USER="$DB_USERNAME" -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB="$DB_NAME" \
    -p "$DB_PORT:5432" -v "$VOLUME_PATH:/var/lib/postgresql" postgres:18.6-trixie >/dev/null
fi

# An existing Compose container supplies its own configured database/user.
DB_USERNAME="$(docker exec "$DB_CONTAINER_NAME" sh -c 'printf %s "$POSTGRES_USER"')"
DB_NAME="$(docker exec "$DB_CONTAINER_NAME" sh -c 'printf %s "$POSTGRES_DB"')"
READY=false
for attempt in {1..60}; do
  if docker exec "$DB_CONTAINER_NAME" pg_isready -h 127.0.0.1 -U "$DB_USERNAME" -d "$DB_NAME" >/dev/null 2>&1; then
    READY=true; break
  fi
  sleep 1
done
if [[ "$READY" != true ]]; then
  echo "PostgreSQL did not become ready: $DB_CONTAINER_NAME" >&2; exit 1
fi

if [[ "$RESET_DB" == true ]]; then
  # Explicitly destructive; no reset occurs without --reset. Active app connections
  # prevent DROP DATABASE, so stop the backend before intentionally resetting it.
  docker exec -i "$DB_CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -v database_name="$DB_NAME" \
    -U "$DB_USERNAME" -d postgres <<'SQL'
DROP DATABASE IF EXISTS :"database_name";
CREATE DATABASE :"database_name";
SQL
fi

python3 "$SCRIPT_DIR/scripts/generate-instrument-seed.py" --check
docker exec -i "$DB_CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U "$DB_USERNAME" -d "$DB_NAME" \
  < "$SCRIPT_DIR/DB/endgame_db.schema.sql"
docker exec -i "$DB_CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U "$DB_USERNAME" -d "$DB_NAME" \
  < "$SCRIPT_DIR/DB/endgame_db_test_data.sql"

echo "Endgame schema and instrument catalogue are up to date."
echo "Container: $DB_CONTAINER_NAME; database: $DB_NAME; user: $DB_USERNAME"
echo 'No users, cash, bank accounts, holdings, orders or stars were seeded.'
echo 'Existing records remain intact unless you explicitly requested --reset.'
