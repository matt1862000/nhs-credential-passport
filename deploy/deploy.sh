#!/usr/bin/env bash
# DocPass production deploy — self-hosted Raspberry Pi (Docker + Caddy).
#
# Usage (on the Pi):
#   ~/docpass/app/deploy/deploy.sh
#
# Optional overrides:
#   APP_DIR=~/docpass/app  BRANCH=main
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/docpass/app}"
BRANCH="${BRANCH:-main}"
ENV_FILE="${ENV_FILE:-/var/lib/docpass/docpass.env}"
DATA_DIR="${DATA_DIR:-/var/lib/docpass/data}"
KEYS_DIR="${KEYS_DIR:-/var/lib/docpass/keys}"

if [[ ! -d "$APP_DIR/.git" ]]; then
  echo "APP_DIR is not a git repo: $APP_DIR" >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi
if [[ ! -d "$DATA_DIR" || ! -d "$KEYS_DIR" ]]; then
  echo "Missing data or keys dir (expected $DATA_DIR and $KEYS_DIR)" >&2
  exit 1
fi

cd "$APP_DIR"
echo "==> Pulling origin/$BRANCH"
git pull origin "$BRANCH"

echo "==> Building Docker image (native arm64 on Pi)"
sudo docker build -t docpass .

echo "==> Replacing container (data/keys unchanged — mounted from host)"
sudo docker rm -f docpass 2>/dev/null || true
sudo docker run -d --name docpass --restart unless-stopped \
  -p 127.0.0.1:8000:8000 \
  --env-file "$ENV_FILE" \
  -v "$DATA_DIR:/app/data" \
  -v "$KEYS_DIR:/app/keys" \
  docpass

echo "==> Waiting for app"
sleep 2
if curl -sf "http://127.0.0.1:8000/static/manifest.webmanifest" >/dev/null; then
  echo "OK — DocPass is up (PWA manifest reachable)."
else
  echo "WARN — container started but health check failed. Run: sudo docker logs docpass" >&2
  exit 1
fi
