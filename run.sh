#!/usr/bin/env bash
# Run the app (local or production). Uses PORT from env if set.
set -e
cd "$(dirname "$0")"
export PORT="${PORT:-8000}"
# Use BASE_URL in Render/Fly dashboard; default for local.
export BASE_URL="${BASE_URL:-http://localhost:${PORT}}"
python3 -m uvicorn backend.main:app --host 0.0.0.0 --port "$PORT"
