#!/usr/bin/env bash
# Create empty RDS restore targets; deletion requires --reset and typed confirmation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo 'Usage: bash scripts/create-rds-databases.sh [--reset] [path/to/.env]'
  echo 'Reads service database credentials from root .env by default.'
  echo 'Set RDS_ADMIN_USER and optionally RDS_HOST; administrator password is prompted.'
  echo 'Creates empty databases and roles only. Does not load schemas, restore dumps or rotate passwords.'
  echo '--reset permanently drops/recreates the four configured databases after typed confirmation.'
  exit 0
fi
RDS_RESET_DATABASES=false
ENV_FILE="$ROOT/.env"
ENV_FILE_SET=false
for argument in "$@"; do
  case "$argument" in
    --reset) RDS_RESET_DATABASES=true ;;
    -*) echo "Unknown option: $argument" >&2; exit 1 ;;
    *)
      if [[ "$ENV_FILE_SET" == true ]]; then echo 'Expected at most one .env path.' >&2; exit 1; fi
      ENV_FILE="$argument"
      ENV_FILE_SET=true ;;
  esac
done
if [[ ! -f "$ENV_FILE" ]]; then echo 'Missing .env file. Copy .env.example and fill database credentials.' >&2; exit 1; fi
command -v docker >/dev/null || { echo 'Docker with the Compose plugin is required.' >&2; exit 1; }
if [[ "$RDS_RESET_DATABASES" == true ]]; then
  echo "RESET permanently deletes all data in the four databases configured by: $ENV_FILE" >&2
  echo 'Stop application writers and verify your backups before proceeding.' >&2
  read -r -p 'Type RESET to drop and recreate these databases: ' CONFIRM_RESET
  if [[ "$CONFIRM_RESET" != RESET ]]; then echo 'Reset cancelled. No connection was made.' >&2; exit 1; fi
fi
export RDS_RESET_DATABASES
if [[ -z "${RDS_ADMIN_USER:-}" ]]; then
  read -r -p 'RDS administrator username: ' RDS_ADMIN_USER
fi
if [[ -z "${RDS_ADMIN_PASSWORD:-}" ]]; then
  read -r -s -p 'RDS administrator password: ' RDS_ADMIN_PASSWORD
  echo
fi
export RDS_ADMIN_USER RDS_ADMIN_PASSWORD
# Compose parses .env; do not source it as executable shell code.
docker compose --env-file "$ENV_FILE" -p asset-avengers-rds-bootstrap \
  -f "$ROOT/deployment/rds/bootstrap.compose.yml" run --rm --no-deps -T bootstrap
