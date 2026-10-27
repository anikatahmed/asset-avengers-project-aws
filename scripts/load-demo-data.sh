#!/usr/bin/env bash
# Local fixture loading must not implicitly write synthetic data to shared RDS.
set -euo pipefail
echo 'The local demo loader is disabled for RDS. See deployment/aws-runtime.md.' >&2
exit 1
