#!/usr/bin/env bash
# Run route generator for every postcode. POI source is ONLY the xlsx (first tab).
# Uses run_from_pois_export.py; no prepopulated_pois_*.json.
#
# Run from repo root:  bash route_csv_generator/run_all_postcodes.sh
# Skip areas that already have output:  SKIP_EXISTING=1 bash route_csv_generator/run_all_postcodes.sh
# Run only the next smallest (by POI count) area:  NEXT_SMALLEST=1 SKIP_EXISTING=1 bash route_csv_generator/run_all_postcodes.sh
# Run one area by name (e.g. S36):                 RUN_AREA=S36 bash route_csv_generator/run_all_postcodes.sh

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Canonical POI source — first tab only (must match POI_SOURCE_XLSX in run_from_pois_export.py)
POI_XLSX="${POI_SOURCE_XLSX:-/Users/raihant/Downloads/pois_export-4.xlsx}"

python3 route_csv_generator/run_from_pois_export.py "$POI_XLSX"
