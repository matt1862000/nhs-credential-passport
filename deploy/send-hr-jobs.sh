#!/usr/bin/env bash
# Daily HR jobs: email digests + automatic training expiry in-app reminders.
#
# Install on Oracle VM, e.g. cron at 07:00 (server TZ):
#   0 7 * * * /var/lib/docpass/send-hr-jobs.sh >> /var/log/docpass-hr-jobs.log 2>&1
#
# CRON_SECRET resolution order:
#   1. Already-exported CRON_SECRET in the environment, else
#   2. CRON_ENV_FILE (default /var/lib/docpass/cron.env). This file is sourced
#      with auto-export, so it works whether or not it uses the `export` keyword.
#
# NOTE: the cron user must be able to write the log path. /var/log is root-owned,
# so pre-create it once:
#   sudo touch /var/log/docpass-hr-jobs.log && sudo chown "$USER" /var/log/docpass-hr-jobs.log
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"

ENV_FILE="${CRON_ENV_FILE:-/var/lib/docpass/cron.env}"
if [[ -z "${CRON_SECRET:-}" && -f "$ENV_FILE" ]]; then
  # Auto-export everything in the env file so a missing `export` keyword
  # (a previous production foot-gun) cannot silently break the cron job.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

SECRET="${CRON_SECRET:-}"

if [[ -z "$SECRET" ]]; then
  echo "CRON_SECRET is not set (checked environment and $ENV_FILE)" >&2
  exit 1
fi

curl -sf -X POST \
  -H "X-Cron-Secret: ${SECRET}" \
  "${BASE_URL%/}/api/internal/cron/hr-jobs"

echo
