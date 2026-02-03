#!/usr/bin/env bash
# Start route generation for the smallest next postcode (by POI count) in the background.
# Skips areas that already have a pre_generated_routes_<area>.tsv.
#
# Run from repo root:  bash route_csv_generator/run_next_smallest_background.sh
#
# Monitor progress:   tail -f route_csv_generator/progress.txt
# Watch full log:     tail -f route_csv_generator/background_run.log

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOG="route_csv_generator/background_run.log"
RUNNER="route_csv_generator/run_all_postcodes.sh"

echo "Starting next-smallest postcode route generation in background..."
echo "  Log: $LOG"
echo "  Progress: tail -f route_csv_generator/progress.txt"
echo ""

nohup env NEXT_SMALLEST=1 SKIP_EXISTING=1 bash "$RUNNER" >> "$LOG" 2>&1 &
PID=$!
echo "PID $PID — check $LOG or route_csv_generator/progress.txt"
echo "Only one run at a time (lock in route_csv_generator/.route_generate.lock)."
