#!/usr/bin/env bash
# End-to-end proof (lecture 15): a token issued by THIS service is accepted by
# the Spring API, and the session lifecycle behaves as designed.
#
# (npm run start:dev), and the Spring backend on port 8080 with the same JWT_SECRET.
# For the auth service alone (no Spring), scripts/session-test.sh checks more session rules.
#
# Usage: npm run test:integration
set -uo pipefail

AUTH="http://localhost:${AUTH_SERVICE_PORT:-3000}"
API="http://localhost:${SPRING_PORT:-8080}"
PROTECTED="$API/api/v1/me/orders"   # a CLIENT route; a newly registered user gets 200 and []
EMAIL="it-$(date +%s)@example.com"
PASSWORD="integration-test-password"

# Test-only recovery state. Never use these scripts with a real user's identity.
MFA_STATE=$(mktemp)
trap 'rm -f "$MFA_STATE"' EXIT
mfa_login() {
  AUTH_TEST_URL="$AUTH" AUTH_TEST_EMAIL="${1:-$EMAIL}" AUTH_TEST_PASSWORD="$PASSWORD" AUTH_TEST_STATE="$MFA_STATE" node scripts/mfa-test-login.mjs
}
failures=0
stage() { printf '\n== %s ==\n' "$1"; }
pass()  { printf 'PASS: %s\n' "$1"; }
fail()  { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }
expect_status() { # expect_status <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then pass "$1 ($3)"; else fail "$1 (expected $2, got $3)"; fi
}
post() { # post <path> <json>  ->  prints body, then status on the last line
  curl -s -w '\n%{http_code}' -X POST "$AUTH$1" -H 'content-type: application/json' -d "$2"
}
status_of() { tail -n1 <<<"$1"; }
body_of()   { sed '$d' <<<"$1"; }

stage "Readiness"
for _ in $(seq 1 30); do
  curl -sf "$AUTH/health/ready" >/dev/null && break
  sleep 1
done
expect_status "auth service ready" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$AUTH/health/ready")"

stage "Smoke test: no token is rejected by Spring"
expect_status "unauthenticated request" 401 "$(curl -s -o /dev/null -w '%{http_code}' "$PROTECTED")"

stage "Register and log in"
res=$(post /auth/register "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"firstName\":\"Test\",\"lastName\":\"Client\"}")
expect_status "register" 201 "$(status_of "$res")"
res=$(mfa_login)
expect_status "login" 200 "$(status_of "$res")"
ACCESS=$(body_of "$res" | jq -r .accessToken)
REFRESH1=$(body_of "$res" | jq -r .refreshToken)
res=$(post /auth/login "{\"email\":\"$EMAIL\",\"password\":\"wrong-password\"}")
expect_status "login with wrong password" 401 "$(status_of "$res")"

stage "The token works against Spring"
expect_status "authenticated request" 200 \
  "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ACCESS" "$PROTECTED")"

stage "Refresh rotates, and replay kills the session"
res=$(post /auth/refresh "{\"refreshToken\":\"$REFRESH1\"}")
expect_status "refresh" 200 "$(status_of "$res")"
REFRESH2=$(body_of "$res" | jq -r .refreshToken)
[[ "$REFRESH2" != "$REFRESH1" ]] && pass "refresh token rotated" || fail "refresh token was not rotated"
expect_status "reusing the old refresh token" 401 "$(status_of "$(post /auth/refresh "{\"refreshToken\":\"$REFRESH1\"}")")"
expect_status "newest token after replay (session revoked)" 401 \
  "$(status_of "$(post /auth/refresh "{\"refreshToken\":\"$REFRESH2\"}")")"

stage "Logout"
res=$(mfa_login)
REFRESH3=$(body_of "$res" | jq -r .refreshToken)
expect_status "logout" 200 "$(status_of "$(post /auth/logout "{\"refreshToken\":\"$REFRESH3\"}")")"
expect_status "refresh after logout" 401 "$(status_of "$(post /auth/refresh "{\"refreshToken\":\"$REFRESH3\"}")")"

stage "Confirmed in Postgres, not just HTTP"
revoked=$(docker compose -f ../docker-compose.yml --env-file ../.env exec -T auth-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -v ON_ERROR_STOP=1' <<SQL
SELECT count(*) FROM sessions s JOIN users u ON u.id = s.user_id
WHERE u.email = '$EMAIL' AND s.revoked_at IS NOT NULL;
SQL
)
expect_status "revoked sessions for the test user" 2 "$revoked"

if (( failures == 0 )); then
  printf '\n== ALL STAGES PASSED ==\n'
else
  printf '\n== %d CHECK(S) FAILED ==\n' "$failures"
  exit 1
fi
