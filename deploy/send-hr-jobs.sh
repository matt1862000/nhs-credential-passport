#!/usr/bin/env bash
# Daily HR jobs: email digests + automatic training expiry in-app reminders.
# Install on Oracle VM, e.g. cron at 07:00 UTC:
#   0 7 * * * CRON_SECRET=... /var/lib/docpass/send-hr-jobs.sh >> /var/log/docpass-hr-jobs.log 2>&1
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
SECRET="${CRON_SECRET:-}"

if [[ -z "$SECRET" ]]; then
  echo "CRON_SECRET is not set" >&2
  exit 1
fi

curl -sf -X POST \
  -H "X-Cron-Secret: ${SECRET}" \
  "${BASE_URL%/}/api/internal/cron/hr-jobs"

echo
