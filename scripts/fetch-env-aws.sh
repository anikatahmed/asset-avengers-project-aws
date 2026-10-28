#!/usr/bin/env bash
# Write the root .env from the app's JSON secret in AWS Secrets Manager.
# Usage: bash scripts/fetch-env-from-aws.sh <secret-arn>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
umask 077
region=$(cut -d: -f4 <<< "$1")
secret=$(aws secretsmanager get-secret-value --secret-id "$1" --region "$region" \
  --query SecretString --output text)
if [[ -f .env ]]; then cp -p .env .env.previous; fi
# Single-quote every value so Compose keeps $ and newlines; Compose wants ' as \'.
printf '%s' "$secret" | jq -r --arg q "'" 'to_entries[]
  | .value |= tostring
  | if (.value | contains("\\")) then error("\(.key) contains a backslash") else . end
  | "\(.key)=\($q)\(.value | gsub($q; "\\" + $q))\($q)"' > .env.tmp
mv .env.tmp .env
echo "Wrote .env with: $(printf '%s' "$secret" | jq -r 'keys | join(" ")')"
