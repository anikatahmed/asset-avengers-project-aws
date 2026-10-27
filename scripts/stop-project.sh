#!/usr/bin/env bash
# Stop both project stacks; ask before deleting volumes and trading bind-mount data.
# Stop staff first because its services use the client stack's trading network.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  echo 'Usage: bash scripts/stop-project.sh'
  echo 'Stops client, admin, analyst, reporting and Superset services.'
  echo 'Asks whether to delete saved data: y deletes it; no or Enter preserves it.'
  echo 'Keeps source files, root .env and Docker images.'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo 'Usage: bash scripts/stop-project.sh [--help]' >&2
  exit 1
fi
if [[ ! -f .env ]]; then
  echo 'Missing root .env. Restore it so Compose can identify the configured project.' >&2
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
# Deletion requires an explicit y. Empty input or EOF preserves all saved data.
echo 'Deleting saved data permanently removes users, trades, portfolios, reports and dashboards.'
DELETE_DATA=false
while true; do
  ANSWER=''
  if ! read -r -p 'Delete project volumes and trading data? (y/no) [no]: ' ANSWER; then
    ANSWER=no
  fi
  case "$ANSWER" in
    y|Y) DELETE_DATA=true; break ;;
    no|No|NO|'') break ;;
    *) echo 'Please enter y or no.' ;;
  esac
done
DOWN=(down --remove-orphans)
if [[ "$DELETE_DATA" == true ]]; then DOWN+=(--volumes); fi
echo 'Stopping both project stacks…'
"${STAFF[@]}" "${DOWN[@]}"
"${CLIENT[@]}" "${DOWN[@]}"
if [[ "$DELETE_DATA" == true ]]; then
  # down --volumes cannot clear a bind mount. Clear only this project's fixed
  # trading directory, after both stacks stop and deletion was explicitly chosen.
  TRADING_DATA_DIR="${HOME:?}/.asset_postgres_test_data"
  if [[ -d "$TRADING_DATA_DIR" ]]; then
    echo 'Deleting saved trading data from ~/.asset_postgres_test_data…'
    docker run --rm --network none --user 0:0 \
      --mount "type=bind,source=$TRADING_DATA_DIR,target=/reset-data" \
      --entrypoint sh postgres:18.6-trixie -c \
      'find /reset-data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
  fi
  echo 'Project stopped. Database/Kafka volumes and trading bind-mount data deleted.'
else
  echo 'Project stopped. Saved volumes and trading data preserved.'
fi
echo 'Restart with: bash scripts/start-project.sh'
