#!/bin/sh
set -e
# Xcode Cloud runs from ci_scripts/; repo root is parent or $CI_WORKSPACE.
REPO_ROOT="${CI_WORKSPACE:-/Volumes/workspace/repository}"
[ -d "$REPO_ROOT" ] || REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# Secrets.xcconfig is gitignored; create from example so the project can build.
if [ ! -f "Secrets.xcconfig" ] && [ -f "Secrets.xcconfig.example" ]; then
  cp Secrets.xcconfig.example Secrets.xcconfig
  echo "Created Secrets.xcconfig from example for Xcode Cloud build."
fi
