#!/usr/bin/env bash
# Create empty RDS restore targets and service roles; never restore or delete data.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo 'Usage: bash scripts/create-rds-databases.sh [path/to/.env]'
  echo 'Reads service database credentials from root .env by default.'
  echo 'Set RDS_ADMIN_USER and optionally RDS_HOST; administrator password is prompted.'
  echo 'Creates empty databases and roles only. Does not load schemas, restore dumps or rotate passwords.'
  exit 0
fi
if [[ $# -gt 1 ]]; then echo 'Expected at most one .env path.' >&2; exit 1; fi
ENV_FILE="${1:-$ROOT/.env}"
if [[ ! -f "$ENV_FILE" ]]; then echo 'Missing .env file. Copy .env.example and fill database credentials.' >&2; exit 1; fi
command -v docker >/dev/null || { echo 'Docker with the Compose plugin is required.' >&2; exit 1; }
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
