#!/bin/bash
# Build app-format JSON from all pre_generated_routes_*.tsv using existing prepopulated_pois_*.json,
# then upload all prepopulated_pois_*.json to Firebase Storage.
# Run from repo root. Requires: Python 3, firebase-admin for upload.

set -e
cd "$(dirname "$0")"

DISTRICTS="S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14 S17 S20 S21 S25 S26 S35 S36 WF2"

echo "Building JSON from TSVs..."
for d in $DISTRICTS; do
  tsv="route_csv_generator/pre_generated_routes_${d}.tsv"
  if [ "$d" = "WF2" ]; then
    tsv="route_csv_generator/pre_generated_routes_WF2.tsv"
  fi
  if [ ! -f "$tsv" ]; then
    echo "  Skip $d (no $tsv)"
    continue
  fi
  if [ ! -f "prepopulated_pois_${d}.json" ]; then
    echo "  Skip $d (no prepopulated_pois_${d}.json)"
    continue
  fi
  python3 build_postcode_json_from_tsv.py \
    --district "$d" \
    --routes-tsv "$tsv" \
    --poi-json "prepopulated_pois_${d}.json" \
    --output "prepopulated_pois_${d}.json"
done

echo ""
echo "Uploading all prepopulated_pois_*.json to Firebase..."
python3 upload_all_postcodes_to_firebase.py

echo ""
echo "Done. App can load postcode data from Firebase."
