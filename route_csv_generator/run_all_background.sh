#!/usr/bin/env bash
# Run route generation for ALL postcodes (from xlsx first tab) in the background.
# POI source: /Users/raihant/Downloads/pois_export-4.xlsx (first tab).
#
# Run from repo root:  bash route_csv_generator/run_all_background.sh
#
# Monitor progress in terminal:   tail -f route_csv_generator/background_run.log
# Or one-line progress:         tail -f route_csv_generator/progress.txt
#
# Rough duration: ~1 s per candidate route. Total candidates ≈ (sum of POIs) × 11 durations.
# With 5,299 POIs (21 areas): ~58k candidates → about 16 hours for a full run.
# Single area: e.g. S11 (9 POIs) ~2 min, S36 (45 POIs) ~8 min, S1 (2533 POIs) ~7–8 hours.

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOG="route_csv_generator/background_run.log"

echo "Starting route generation for ALL areas in background..."
echo "  Log: $LOG"
echo "  Live progress: tail -f $LOG"
echo "  One-line status: tail -f route_csv_generator/progress.txt"
echo "  Estimated total time: ~16 hours (21 areas, ~58k candidate routes)"
echo ""

nohup env PYTHONUNBUFFERED=1 bash route_csv_generator/run_all_postcodes.sh >> "$LOG" 2>&1 &
PID=$!
echo "PID $PID — tail -f $LOG to watch live progress."
echo "Only one run at a time (lock: route_csv_generator/.route_generate.lock)."
