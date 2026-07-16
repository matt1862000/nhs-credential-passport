#!/usr/bin/env bash
# DocPass production deploy — self-hosted Raspberry Pi (Docker + Cloudflare Tunnel).
#
# Usage (on the Pi):
#   ~/docpass/app/deploy/deploy.sh
#
# Optional overrides:
#   APP_DIR=~/docpass/app  BRANCH=main
#   ENV_FILE=...  DATA_DIR=...  KEYS_DIR=...
#   SKIP_CLOUDFLARED_RESTART=1   # skip tunnel restart (may leave 520 until manual restart)
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

  DATA_DIR="${DATA_DIR:-$HOME/docpass/data}"
  KEYS_DIR="${KEYS_DIR:-$HOME/docpass/keys}"

  if [[ -z "${ENV_FILE:-}" ]]; then
    local candidates=(
      "$HOME/docpass/docpass.env"
      "/var/lib/docpass/docpass.env"
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

  ENV_FILE="${ENV_FILE:-$HOME/docpass/docpass.env}"
}

_curl_origin() {
  local url="http://127.0.0.1:8000/static/manifest.webmanifest"
  if command -v curl >/dev/null 2>&1; then
    curl -sf "$url" >/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null "$url"
  else
    sudo docker inspect -f '{{.State.Running}}' docpass 2>/dev/null | grep -q true
  fi
}

_health_check() {
  local i
  for i in $(seq 1 30); do
    if _curl_origin; then
      return 0
    fi
    sleep 2
  done
  return 1
}

_wait_for_stable_origin() {
  # Two consecutive OK checks — avoids restarting cloudflared while uvicorn is still starting.
  local i
  for i in 1 2; do
    if ! _curl_origin; then
      return 1
    fi
    sleep 2
  done
  return 0
}

_restart_cloudflared() {
  if [[ "${SKIP_CLOUDFLARED_RESTART:-}" == "1" ]]; then
    echo "==> Skipping cloudflared restart (SKIP_CLOUDFLARED_RESTART=1)"
    return 0
  fi
  if ! systemctl list-unit-files cloudflared.service >/dev/null 2>&1; then
    return 0
  fi

  echo "==> Restarting Cloudflare Tunnel (~10s public blip, clears stale connections)"
  sudo systemctl restart cloudflared

  local i
  for i in $(seq 1 15); do
    if systemctl is-active --quiet cloudflared && _curl_origin; then
      echo "OK — cloudflared is running and origin responds locally."
      return 0
    fi
    sleep 1
  done

  echo "WARN — cloudflared or origin not ready after restart." >&2
  echo "Run on the Pi:" >&2
  echo "  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/static/manifest.webmanifest" >&2
  echo "  sudo systemctl status cloudflared --no-pager" >&2
  echo "  sudo systemctl restart cloudflared" >&2
  return 1
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

echo "==> Building Docker image (old container keeps serving until swap)"
sudo docker build -t docpass .

echo "==> Swapping container (brief downtime — usually a few seconds)"
sudo docker rm -f docpass 2>/dev/null || true
sudo docker run -d --name docpass --restart unless-stopped \
  -p 127.0.0.1:8000:8000 \
  --env-file "$ENV_FILE" \
  -v "$DATA_DIR:/app/data" \
  -v "$KEYS_DIR:/app/keys" \
  docpass

echo "==> Waiting for app (up to ~60s on Pi)"
if _health_check; then
  echo "OK — DocPass is up (PWA manifest reachable)."
else
  echo "WARN — health check timed out. Recent container logs:" >&2
  sudo docker logs docpass --tail 40 >&2 || true
  echo "Check manually: curl -s http://127.0.0.1:8000/static/manifest.webmanifest | head" >&2
  exit 1
fi

if ! _wait_for_stable_origin; then
  echo "WARN — origin not stable yet; skipping cloudflared restart." >&2
  exit 1
fi

_restart_cloudflared || true

echo "Deploy complete. If https://docpass.co.uk still shows Error 520, wait 30s and hard-refresh;"
echo "or run: sudo systemctl restart cloudflared"
