#!/usr/bin/env bash
# Live check of all four auth routes and the session rules, against the real auth DB.
# Unlike integration-test.sh, it doesn't need Spring.
#
# Needs: npm run db:up (root compose's auth-db) and npm run start:dev (which also builds
# dist/, used here to decode tokens with the real TokenService). Restart the server
# before running it twice within 15 minutes: it sends 15 logins, and the rate limit is 20.
#
# Usage: npm run test:sessions [-- <path to the server's log file>]
#   With a log file, it also checks that no token, password or email was logged.
set -uo pipefail

AUTH="http://localhost:${AUTH_SERVICE_PORT:-3000}"
EMAIL="sessions-$(date +%s)@example.com"
UPPER=$(tr '[:lower:]' '[:upper:]' <<<"$EMAIL")
PASSWORD='a-long-enough-password'
LOG="${1:-}"
# Test-only recovery state. Never use these scripts with a real user's identity.
MFA_STATE=$(mktemp)
trap 'rm -f "$MFA_STATE"' EXIT
mfa_login() {
  AUTH_TEST_URL="$AUTH" AUTH_TEST_EMAIL="${1:-$EMAIL}" AUTH_TEST_PASSWORD="$PASSWORD" AUTH_TEST_STATE="$MFA_STATE" node scripts/mfa-test-login.mjs
}
failures=0

stage() { printf '\n== %s ==\n' "$1"; }
check() { # check <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then printf 'PASS  %s (%s)\n' "$1" "$3"
  else printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
creds() { printf '{"email":"%s","password":"%s"}' "$1" "$2"; }
token_body() { printf '{"refreshToken":"%s"}' "$1"; }
post() { curl -s -w '\n%{http_code}' -X POST "$AUTH$1" -H 'content-type: application/json' -d "$2"; }
code() { tail -n1 <<<"$1"; }
body() { sed '$d' <<<"$1"; }
sql() { docker compose -f ../docker-compose.yml --env-file ../.env exec -T auth-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -v ON_ERROR_STOP=1' <<<"$1"; }
# The refresh_tokens row for a token, matched the same way the app does: by sha256.
by_hash() { printf "token_hash = sha256(convert_to('%s', 'UTF8'))" "$1"; }
session_of() { sql "SELECT session_id FROM refresh_tokens WHERE $(by_hash "$1");"; }
login() { mfa_login; }
login_refresh_token() { body "$(login)" | jq -r .refreshToken; }
refresh() { post /auth/refresh "$(token_body "$1")"; }
logout() { post /auth/logout "$(token_body "$1")"; }
claims() { # decode + verify a JWT with the compiled TokenService (secret, iss, aud from ../.env)
  node --env-file=../.env --input-type=module -e "
    import { TokenService } from './dist/auth/token.service.js';
    const t = new TokenService({ get: (k) => process.env[k] });
    try { console.log(JSON.stringify(t.validateAccessToken(process.argv[1]))); }
    catch (e) { console.log(JSON.stringify({ error: e.name + ': ' + e.message })); }
  " "$1"
}

stage "Health"
check "GET /health/ready" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$AUTH/health/ready")"

stage "Register"
res=$(post /auth/register "$(creds "$EMAIL" "$PASSWORD" | jq '. + {firstName: "Test", lastName: "Client"}')")
check "register a new email" 201 "$(code "$res")"
USER_ID=$(body "$res" | jq -r .id)
res=$(post /auth/register "$(creds "$EMAIL" "$PASSWORD" | jq '. + {firstName: "Test", lastName: "Client"}')")
check "register the same email again" 409 "$(code "$res")"
res=$(post /auth/register "$(creds "$UPPER" "$PASSWORD" | jq '. + {firstName: "Test", lastName: "Client"}')")
check "register the same email in upper case" 409 "$(code "$res")"

stage "Login"
res=$(login)
check "login with the correct password" 200 "$(code "$res")"
ACCESS=$(body "$res" | jq -r .accessToken)
R1=$(body "$res" | jq -r .refreshToken)
check "response has exactly accessToken + refreshToken" '["accessToken","refreshToken"]' "$(body "$res" | jq -c keys)"
[[ "$R1" =~ ^[A-Za-z0-9_-]{43}$ ]] && fmt=yes || fmt=no
check "refresh token is 43 base64url chars (32 random bytes)" yes "$fmt"
check "JWT header alg" HS256 "$(cut -d. -f1 <<<"$ACCESS" | base64 -d 2>/dev/null | jq -r .alg)"
c=$(claims "$ACCESS")
echo "      claims: $c"
check "claims.sub is the user id" "$USER_ID" "$(jq -r .sub <<<"$c")"
check "claims.email" "$EMAIL" "$(jq -r .email <<<"$c")"
check "claims.roles" '["CLIENT"]' "$(jq -c .roles <<<"$c")"
check "claims.iss (contract: endgame-auth)" endgame-auth "$(jq -r .iss <<<"$c")"
check "claims.aud (contract: trading API + auth-server, no staff)" '["endgame-api","endgame-auth"]' "$(jq -c .aud <<<"$c")"
check "exp - iat = 900s (15m)" 900 "$(jq '.exp - .iat' <<<"$c")"
res=$(post /auth/login "$(creds "$EMAIL" 'wrong-password-123')")
check "login with a wrong password" 401 "$(code "$res")"
WRONG=$(body "$res")
res=$(post /auth/login "$(creds "nobody-$(date +%s)@example.com" 'wrong-password-123')")
check "login with an unknown email" 401 "$(code "$res")"
check "unknown email and wrong password get the same body" "$WRONG" "$(body "$res")"
res=$(mfa_login "$UPPER")
check "login with the email in upper case" 200 "$(code "$res")"

stage "Login wrote the right rows"
S1=$(session_of "$R1")
check "refresh_tokens holds sha256(token)" 1 "$(sql "SELECT count(*) FROM refresh_tokens WHERE $(by_hash "$R1");")"
check "idle expiry ~30 min out" 30 "$(sql "SELECT round(extract(epoch FROM idle_expires_at - now()) / 60) FROM sessions WHERE id = '$S1';")"
check "absolute expiry ~12 h out" 12 "$(sql "SELECT round(extract(epoch FROM absolute_expires_at - now()) / 3600) FROM sessions WHERE id = '$S1';")"
check "two successful logins, two sessions" 2 "$(sql "SELECT count(*) FROM sessions WHERE user_id = '$USER_ID';")"

stage "Refresh rotates"
IDLE_BEFORE=$(sql "SELECT idle_expires_at FROM sessions WHERE id = '$S1';")
res=$(refresh "$R1")
check "refresh with R1" 200 "$(code "$res")"
R2=$(body "$res" | jq -r .refreshToken)
[[ "$R2" != "$R1" ]] && rotated=yes || rotated=no
check "R2 differs from R1" yes "$rotated"
check "new access token validates, same sub" "$USER_ID" "$(claims "$(body "$res" | jq -r .accessToken)" | jq -r .sub)"
check "R1 marked used" t "$(sql "SELECT used_at IS NOT NULL FROM refresh_tokens WHERE $(by_hash "$R1");")"
check "R2 stored unused, same session" "$S1 unused" "$(sql "SELECT session_id || CASE WHEN used_at IS NULL THEN ' unused' ELSE ' used' END FROM refresh_tokens WHERE $(by_hash "$R2");")"
check "idle expiry moved forward" t "$(sql "SELECT idle_expires_at > '$IDLE_BEFORE' FROM sessions WHERE id = '$S1';")"

stage "Replaying a used token revokes the session"
check "reuse R1" 401 "$(code "$(refresh "$R1")")"
check "session revoked in the DB" t "$(sql "SELECT revoked_at IS NOT NULL FROM sessions WHERE id = '$S1';")"
check "R2 (the newest) is dead too" 401 "$(code "$(refresh "$R2")")"
check "made-up token" 401 "$(code "$(refresh 'not-a-real-token-xxxxxxxxxxxxxxxxxxxxxxxxxxx')")"

stage "Two refreshes racing with one token"
RR=$(login_refresh_token)
tmp=$(mktemp -d)
refresh "$RR" >"$tmp/a" & refresh "$RR" >"$tmp/b" & wait
check "one wins, one is refused" "200 401" "$(printf '%s\n%s\n' "$(code "$(cat "$tmp/a")")" "$(code "$(cat "$tmp/b")")" | sort | xargs)"
check "the session is revoked" t "$(sql "SELECT revoked_at IS NOT NULL FROM sessions WHERE id = '$(session_of "$RR")';")"
rm -r "$tmp"

stage "Idle and absolute expiry (deadlines moved in the DB)"
RI=$(login_refresh_token)
sql "UPDATE sessions SET idle_expires_at = now() - interval '1 second' WHERE id = '$(session_of "$RI")';" >/dev/null
check "refresh after the idle timeout" 401 "$(code "$(refresh "$RI")")"
RA=$(login_refresh_token)
sql "UPDATE sessions SET absolute_expires_at = now() - interval '1 second' WHERE id = '$(session_of "$RA")';" >/dev/null
check "refresh after the absolute lifetime" 401 "$(code "$(refresh "$RA")")"
RC=$(login_refresh_token)
SC=$(session_of "$RC")
sql "UPDATE sessions SET absolute_expires_at = now() + interval '5 minutes' WHERE id = '$SC';" >/dev/null
check "refresh 5 minutes before the absolute limit" 200 "$(code "$(refresh "$RC")")"
# JS Dates keep milliseconds, Postgres keeps microseconds: compare at millisecond precision.
check "idle expiry capped at the absolute limit" t "$(sql "SELECT idle_expires_at = date_trunc('milliseconds', absolute_expires_at) FROM sessions WHERE id = '$SC';")"

stage "A role change shows up on the next refresh"
RO=$(login_refresh_token)
sql "UPDATE users SET roles = '{CLIENT,ANALYST}' WHERE id = '$USER_ID';" >/dev/null
res=$(refresh "$RO")
check "refresh" 200 "$(code "$res")"
check "new token carries the new roles" '["CLIENT","ANALYST"]' "$(claims "$(body "$res" | jq -r .accessToken)" | jq -c .roles)"
sql "UPDATE users SET roles = '{CLIENT}' WHERE id = '$USER_ID';" >/dev/null

stage "Logout"
RL1=$(login_refresh_token)
RL2=$(login_refresh_token)
res=$(logout "$RL1")
check "logout" 200 "$(code "$res")"
check "logout body" '{"loggedOut":true}' "$(body "$res" | jq -c .)"
check "session revoked in the DB" t "$(sql "SELECT revoked_at IS NOT NULL FROM sessions WHERE id = '$(session_of "$RL1")';")"
check "refresh after logout" 401 "$(code "$(refresh "$RL1")")"
check "logout with the same token again" 200 "$(code "$(logout "$RL1")")"
check "logout with an unknown token" 200 "$(code "$(logout 'not-a-real-token-xxxxxxxxxxxxxxxxxxxxxxxxxxx')")"
check "the other device's session still works" 200 "$(code "$(refresh "$RL2")")"

stage "Validation on refresh/logout bodies"
res=$(post /auth/refresh '{}')
check "refresh with no token" 400 "$(code "$res")"
check "error code" VALIDATION_FAILED "$(body "$res" | jq -r .code)"
check "refresh with an extra field" 400 "$(code "$(post /auth/refresh '{"refreshToken":"abc","userId":"x"}')")"

stage "Forged access tokens are rejected"
forged_payload=$(printf '{"sub":"%s","roles":["ADMIN"]}' "$USER_ID" | base64 | tr '+/' '-_' | tr -d '=\n')
tampered="$(cut -d. -f1 <<<"$ACCESS").$forged_payload.$(cut -d. -f3 <<<"$ACCESS")"
check "tampered payload" "JsonWebTokenError: invalid signature" "$(claims "$tampered" | jq -r .error)"
none_header=$(printf '{"alg":"none","typ":"JWT"}' | base64 | tr '+/' '-_' | tr -d '=\n')
check "alg none" "JsonWebTokenError: jwt signature is required" "$(claims "$none_header.$(cut -d. -f2 <<<"$ACCESS")." | jq -r .error)"

stage "Timing: unknown email vs wrong password (seconds, should be close)"
for i in 1 2; do
  wrong=$(curl -s -o /dev/null -w '%{time_total}' -X POST "$AUTH/auth/login" -H 'content-type: application/json' -d "$(creds "$EMAIL" 'wrong-password-123')")
  unknown=$(curl -s -o /dev/null -w '%{time_total}' -X POST "$AUTH/auth/login" -H 'content-type: application/json' -d "$(creds 'ghost@example.com' 'wrong-password-123')")
  echo "      wrong password: $wrong   unknown email: $unknown"
done

if [[ -n "$LOG" ]]; then
  stage "The server log has no secrets"
  check "no refresh token" 0 "$(grep -c -F "$R1" "$LOG")"
  check "no password" 0 "$(grep -c -F "$PASSWORD" "$LOG")"
  check "no email" 0 "$(grep -c -F "$EMAIL" "$LOG")"
fi

if (( failures == 0 )); then printf '\n== ALL PASSED ==\n'; else printf '\n== %d CHECK(S) FAILED ==\n' "$failures"; exit 1; fi
