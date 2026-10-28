#!/usr/bin/env bash
# Write root .env from the application's JSON secret in AWS Secrets Manager.
# start-project.sh runs this on every start; the EC2 instance's IAM role grants read access.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# A secret's name and region are not credentials. Override both to use a different secret.
SECRET_ID="${ENV_SECRET_ID:-matrix/production/credentials}"
SECRET_REGION="${ENV_SECRET_REGION:-us-east-1}"
for tool in aws jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required to fetch .env from AWS Secrets Manager." >&2; exit 1; }
done
umask 077
secret=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$SECRET_REGION" \
  --query SecretString --output text)
if [[ -f .env ]]; then cp -p .env .env.previous; fi
# Single-quote every value so Compose keeps $ and newlines; Compose wants ' as \'.
printf '%s' "$secret" | jq -r --arg q "'" 'to_entries[]
  | .value |= tostring
  | if (.value | contains("\\")) then error("\(.key) contains a backslash") else . end
  | "\(.key)=\($q)\(.value | gsub($q; "\\" + $q))\($q)"' > .env.tmp
mv .env.tmp .env
# Compose defaults these to empty, so a missing key would only fail later at runtime.
for key in MFA_ENCRYPTION_KEY SUPERSET_SSO_SECRET RESEND_API_KEY; do
  grep -q "^$key=" .env || echo "Warning: $key is not in the secret; that feature will not work." >&2
done
echo "Wrote .env from AWS secret $SECRET_ID."
