#!/usr/bin/env bash
# Start the client stack, the staff stack, or both, using RDS databases.
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
    echo 'Prepare RDS databases and schemas first; see deployment/aws-runtime.md.'
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
# RDS databases, roles and schemas must be prepared before starting applications.
# Startup never creates databases or applies fixture data to RDS.
if [[ "$MODE" != --staff ]]; then
  # Build one service at a time to reduce peak disk usage on small hosts.
  for service in auth-server backend; do
    docker compose build "$service"
  done
  docker compose up -d --no-build
fi
if [[ "$MODE" != --client ]]; then
  # Shared image tags let subsequent pipeline/Superset services reuse these builds.
  for service in publisher internal-backend superset; do
    "${STAFF[@]}" build "$service"
  done
  "${STAFF[@]}" up -d --no-build
fi
echo 'API containers started. Angular applications are deployed separately to S3/CloudFront.'
echo 'Trading API: port 8080. Auth: port 3000. Staff API: port 8085.'
echo 'Services may need a moment to connect to the configured RDS databases.'
