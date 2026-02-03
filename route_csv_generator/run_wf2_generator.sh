#!/bin/bash
# Regenerate pre_generated_routes_WF2.tsv for WF2 0GU.
# Output format: Postcode, Duration (min), Route Index, Name, Description, Waypoint Count,
# Waypoint 1, Waypoint 2, Waypoint 3, Distance (m), Duration (sec), Polyline,
# Actual Duration (min), Timing source — compatible with build_postcode_json_from_tsv.
set -e
cd "$(dirname "$0")"
echo "Generating WF2 routes (OSRM). This may take a while..."
python3 generate_routes_csv.py \
  -i pois_WF2_0GU.tsv \
  -o pre_generated_routes_WF2.tsv \
  --durations "5,10,15,20,30,45,60"
echo "Done. Output: pre_generated_routes_WF2.tsv"
echo "Then from repo root, build JSON and upload:"
echo "  python3 build_postcode_json_from_tsv.py --district WF2 --routes-tsv route_csv_generator/pre_generated_routes_WF2.tsv --poi-json prepopulated_pois_WF2.json --output prepopulated_pois_WF2.json"
echo "  python3 upload_all_postcodes_to_firebase.py"
