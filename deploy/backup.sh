#!/usr/bin/env bash
# DocPass data + keys backup. Install on server: /var/lib/docpass/backup.sh
# Cron example: 0 3 * * * /var/lib/docpass/backup.sh
set -euo pipefail

BACKUP_DIR="/var/lib/docpass/backups"
STAMP="$(date +%Y%m%d)"
ARCHIVE="${BACKUP_DIR}/docpass_${STAMP}.tar.gz"

mkdir -p "${BACKUP_DIR}"
tar -czf "${ARCHIVE}" -C /var/lib/docpass data keys
find "${BACKUP_DIR}" -name 'docpass_*.tar.gz' -mtime +7 -delete
