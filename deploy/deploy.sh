#!/usr/bin/env bash
# DocPass production deploy — self-hosted Raspberry Pi (Docker + Caddy).
#
# Usage (on the Pi):
#   ~/docpass/app/deploy/deploy.sh
#
# Optional overrides:
#   APP_DIR=~/docpass/app  BRANCH=main
#   ENV_FILE=...  DATA_DIR=...  KEYS_DIR=...
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/docpass/app}"
BRANCH="${BRANCH:-main}"

_resolve_paths() {
  # Reuse mounts from an existing docpass container when paths were not set explicitly.
  if [[ -z "${ENV_FILE:-}" || -z "${DATA_DIR:-}" || -z "${KEYS_DIR:-}" ]]; then
    if sudo docker inspect docpass >/dev/null 2>&1; then
      while IFS= read -r line; do
        src="${line%%:*}"
        dst="${line#*:}"
        if [[ "$dst" == "/app/data" && -z "${DATA_DIR:-}" ]]; then
          DATA_DIR="$src"
        elif [[ "$dst" == "/app/keys" && -z "${KEYS_DIR:-}" ]]; then
          KEYS_DIR="$src"
        fi
      done < <(sudo docker inspect docpass --format '{{range .Mounts}}{{.Source}}:{{.Destination}}{{"\n"}}{{end}}')
    fi
  fi

  DATA_DIR="${DATA_DIR:-/var/lib/docpass/data}"
  KEYS_DIR="${KEYS_DIR:-/var/lib/docpass/keys}"

  if [[ -z "${ENV_FILE:-}" ]]; then
    local candidates=(
      "/var/lib/docpass/docpass.env"
      "$HOME/docpass/docpass.env"
      "$HOME/docpass/app/docpass.env"
      "$APP_DIR/docpass.env"
      "$APP_DIR/.env"
      "$(dirname "$DATA_DIR")/docpass.env"
      "$(dirname "$DATA_DIR")/cron.env"
    )
    for f in "${candidates[@]}"; do
      if [[ -f "$f" ]]; then
        ENV_FILE="$f"
        break
      fi
    done
  fi

  ENV_FILE="${ENV_FILE:-/var/lib/docpass/docpass.env}"
}

_resolve_paths

if [[ ! -d "$APP_DIR/.git" ]]; then
  echo "APP_DIR is not a git repo: $APP_DIR" >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  echo "Hint: locate it with: find ~/docpass /var/lib/docpass -name '*.env' 2>/dev/null" >&2
  echo "Then run: ENV_FILE=/path/to/docpass.env ~/docpass/app/deploy/deploy.sh" >&2
  exit 1
fi
if [[ ! -d "$DATA_DIR" || ! -d "$KEYS_DIR" ]]; then
  echo "Missing data or keys dir (expected $DATA_DIR and $KEYS_DIR)" >&2
  echo "Hint: sudo docker inspect docpass --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'" >&2
  exit 1
fi

echo "Using ENV_FILE=$ENV_FILE"
echo "Using DATA_DIR=$DATA_DIR"
echo "Using KEYS_DIR=$KEYS_DIR"

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
