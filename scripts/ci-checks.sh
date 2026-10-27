#!/usr/bin/env bash
# Required CI checks fail on command errors, including commands piped into tee.
# Keep this script executable with Bash: Jenkins' default /bin/sh lacks pipefail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# A deadline bounds readiness waits; retries end as soon as the service responds.
# Use Docker/Compose primitives supported by older VMs, rather than up --wait.
start_readiness() {
  local timeout="${CI_READY_TIMEOUT_SECONDS:-180}"
  [[ "$timeout" =~ ^[1-9][0-9]{0,2}$ ]] || { echo 'Invalid CI_READY_TIMEOUT_SECONDS (1-999)' >&2; return 1; }
  DEADLINE=$((SECONDS + timeout))
}
container_running() {
  local container state
  container="$(bash scripts/ci-compose.sh ps -q "$1")"
  [[ -n "$container" ]] || { echo "Missing CI service: $1" >&2; return 1; }
  state="$(docker inspect -f '{{.State.Status}}' "$container")"
  [[ "$state" == running ]] || { echo "CI service $1 is $state, not running" >&2; return 1; }
}
wait_healthy() {
  local service="$1" container health
  echo "[readiness] Waiting for $service database/dependency health..."
  container="$(bash scripts/ci-compose.sh ps -q "$service")"
  [[ -n "$container" ]] || { echo "Missing CI service: $service" >&2; return 1; }
  while true; do
    container_running "$service"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container")"
    if [[ "$health" == healthy ]]; then echo "[readiness] $service is healthy"; return 0; fi
    [[ "$health" != missing ]] || { echo "No healthcheck configured for $service" >&2; return 1; }
    [[ $SECONDS -lt $DEADLINE ]] || { echo "Timed out waiting for $service (health: $health)" >&2; return 1; }
    sleep 2
  done
}
wait_http() {
  local service="$1" label="$2"
  shift 2
  echo "[readiness] Waiting for $label..."
  while true; do
    container_running "$service"
    if "$@" >/dev/null 2>&1; then echo "[readiness] $label is ready"; return 0; fi
    [[ $SECONDS -lt $DEADLINE ]] || { echo "Timed out waiting for $label" >&2; return 1; }
    sleep 2
  done
}
verify_services() {
  start_readiness
  for service in postgres auth-db auth-server; do wait_healthy "$service"; done
  # Probe Spring from a peer on the CI network, without adding curl to the Java image.
  wait_http backend 'Trading API and database' bash scripts/ci-compose.sh exec -T auth-server node -e \
    "fetch('http://backend:8080/actuator/health/readiness', {signal: AbortSignal.timeout(5000)}).then(async r => process.exit(r.ok && (await r.json()).status === 'UP' ? 0 : 1)).catch(() => process.exit(1))"
  wait_http frontend 'Client HTML through Nginx' bash scripts/ci-compose.sh exec -T frontend \
    wget -q -T 5 -O /dev/null http://127.0.0.1/index.html
}
case "${1:-}" in
  secrets)
    docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
      detect --source /repo --config /repo/.gitleaks.toml --gitleaks-ignore-path /repo/.gitleaksignore --verbose --redact 2>&1 | tee gitleaks-output.txt
    ;;
  services)
    # errexit stops this group immediately if startup fails; pipefail propagates it.
    {
      bash scripts/ci-compose.sh up -d --build
      verify_services
      bash scripts/ci-compose.sh ps --services
      bash scripts/ci-compose.sh ps
    } 2>&1 | tee services-output.txt
    ;;
  database)
    start_readiness
    wait_healthy postgres
    ;;
  ready)
    verify_services 2>&1 | tee readiness-output.txt
    ;;
  staff-build|staff-integration|staff-cleanup)
    [[ "${CI_PROJECT_NAME:-}" =~ ^endgame-ci-[a-f0-9]{16}$ ]] || { echo 'Valid CI project name required for staff checks' >&2; exit 1; }
    if [[ "$1" == staff-build ]]; then
      {
        for item in internal-backend:asset-internal-backend internal-frontend:asset-internal-frontend admin-analytics/pipeline:asset-analytics-pipeline admin-analytics/superset:asset-analytics-superset; do
          context="${item%%:*}"; image="${item#*:}:$CI_PROJECT_NAME"
          echo "[build] $context -> $image"
          docker build -t "$image" "$context"
        done
      } 2>&1 | tee staff-build-output.txt
    elif [[ "$1" == staff-integration ]]; then
      auth_container="$(bash scripts/ci-compose.sh ps -q auth-server)"
      auth_image="$(docker inspect -f '{{.Image}}' "$auth_container")"
      python3 scripts/verify-admin-stack.py --project-name "$CI_PROJECT_NAME-staff" \
        --browser --auth-image "$auth_image" --image-tag "$CI_PROJECT_NAME" --ci-env-file "$ROOT/.env" --log-file "$ROOT/staff-docker-logs.txt" 2>&1 | tee staff-integration-output.txt
    else
      python3 scripts/verify-admin-stack.py --project-name "$CI_PROJECT_NAME-staff" \
        --browser --auth-image unused-for-cleanup --image-tag "$CI_PROJECT_NAME" --cleanup --log-file "$ROOT/staff-docker-logs.txt"
    fi
    ;;
  sonar)
    : "${SONAR_TOKEN:?Jenkins must supply SONAR_TOKEN}"
    # Never silently scan without the reports required from the preceding test stages.
    for report in backend/target/site/jacoco/jacoco.xml internal-backend/target/site/jacoco/jacoco.xml \
      auth-server/coverage/lcov.info frontend/coverage/frontend/lcov.info internal-frontend/coverage/staff/lcov.info coverage/python/coverage.xml; do
      [[ -s "$report" ]] || { echo "Missing required coverage report: $report" >&2; exit 1; }
    done
    # Forward the token by environment name, not a command-line credential.
    # Scanner waits for the gate itself, so no Jenkins Sonar plugin/webhook is needed.
    docker run --rm --network host -v "$PWD:/usr/src" \
      -e SONAR_HOST_URL=http://localhost:8089 -e SONAR_TOKEN \
      sonarsource/sonar-scanner-cli:latest \
      -Dsonar.projectKey=asset-avengers \
      '-Dsonar.projectName=Asset Avengers' \
      -Dsonar.sources=. \
      '-Dsonar.exclusions=**/node_modules/**,**/target/**,**/dist/**,**/coverage/**,**/test-results/**,**/src/test/**,**/*.spec.ts,**/test/**,**/tests/**,**/test_*.py' \
      '-Dsonar.tests=backend/src/test,internal-backend/src/test,auth-server/test' \
      '-Dsonar.coverage.jacoco.xmlReportPaths=backend/target/site/jacoco/jacoco.xml,internal-backend/target/site/jacoco/jacoco.xml' \
      '-Dsonar.javascript.lcov.reportPaths=auth-server/coverage/lcov.info,frontend/coverage/frontend/lcov.info,internal-frontend/coverage/staff/lcov.info' \
      -Dsonar.java.binaries=backend/target/classes,internal-backend/target/classes \
      -Dsonar.python.coverage.reportPaths=coverage/python/coverage.xml \
      '-Dsonar.java.libraries=backend/target/dependency/*.jar,internal-backend/target/dependency/*.jar' \
      -Dsonar.qualitygate.wait=true \
      -Dsonar.qualitygate.timeout=300 2>&1 | tee sonar-output.txt
    ;;
  *) echo 'Usage: ci-checks.sh secrets|services|database|ready|staff-build|staff-integration|staff-cleanup|sonar' >&2; exit 2 ;;
esac
