#!/usr/bin/env bash
# Daily HR email digest — install on Oracle and cron at 07:00 UK (adjust TZ as needed).
# Example: 0 7 * * * /var/lib/docpass/send-hr-digest.sh >> /var/log/docpass-hr-digest.log 2>&1
set -euo pipefail
docker exec docpass python -m backend.hr_email_cli daily
