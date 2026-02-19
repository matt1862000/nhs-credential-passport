# Route CSV Generator

Pre-generates walking loop routes (anchor → nearest POIs → anchor) using **OSRM walking only**. No haversine fallback — routes are skipped if all OSRM mirrors fail. Tries every mirror in `OSRM_MIRRORS` until one returns a route (distance, duration, polyline).

**Rules:**
- **Waypoints ≥100 m apart** — Each waypoint (and the anchor) must be at least 100 m from every other chosen point. Greedy selection by distance from anchor enforces this.
- **Duration → waypoint count:** 10 min = 1 waypoint, 15 min = 2, 20 min = 3, 25 min = 4, … 60 min = 10. (5 min = 0 waypoints, i.e. anchor→anchor.)
- **OSRM only** — Distance, duration, and polyline come from OSRM walking; routes where all mirrors fail are skipped.
- **Mirrors** — `OSRM_MIRRORS` in the script lists bases (e.g. `http://router.project-osrm.org/route/v1/walking`, `.../foot`); add more public OSRM URLs there if needed.

## Output headers

- Anchor Postcode  
- Duration (min)  
- Route Index  
- Waypoints  
- Waypoint Count  
- Distance (m)  
- Duration (sec)  
- Duration (formatted)

## Usage

**Default (built-in S5 sample, 12 POIs):**

```bash
python3 generate_routes_csv.py
```

Output: `pre_generated_routes.csv` in the current directory.

**Custom output path:**

```bash
python3 generate_routes_csv.py -o my_routes.csv
```

**POIs from Firebase / Google Sheets (curated ~5k POIs the app uses):**

Use the Firebase Storage download URL for `prepopulated_pois.json`. Get it from Firebase Console → Storage → prepopulated_pois.json → “Get download URL”, or from the URL the app uses when it downloads the DB.

```bash
python3 generate_routes_csv.py -i "https://firebasestorage.googleapis.com/v0/b/doctorwaittimes.firebasestorage.app/o/prepopulated_pois.json?alt=media&token=YOUR_TOKEN" -o pre_generated_routes_all.tsv
```

**How the WF2 0GU routes were created**

The WF2 routes in `pre_generated_routes_WF2.tsv` were made by running the script with **only WF2 0GU POIs** as input (124 POIs in `pois_WF2_0GU.tsv` or in `prepopulated_pois_WF2.json`):

```bash
python3 generate_routes_csv.py -i pois_WF2_0GU.tsv -o pre_generated_routes_WF2.tsv
# or:  -i prepopulated_pois_WF2.json  -o pre_generated_routes_WF2.tsv
```

The script then:

1. Loads the POI list (all with postcode WF2 0GU).
2. For each POI as **anchor** (start/end of the loop) and each **duration** (5, 10, 15, … 60 min), builds one loop: **anchor → nearest N other POIs (≥100 m apart) → back to anchor**.
3. Calls OSRM walking to get real distance, duration, and polyline. Skips the route if OSRM fails.
4. Writes one TSV row per successful route. The “Postcode” column is the anchor’s postcode (WF2 0GU); Waypoint 1/2/3 are anchor + up to 2 selected POIs.

So WF2 was done with a **single-area** input (TSV or JSON containing only WF2 0GU POIs). The TSV (`pois_WF2_0GU.tsv`) can be an export from Google Sheets or from the Firebase/Sheets `prepopulated_pois.json` filtered to that postcode.

**Regenerate WF2 TSV (from this directory):** `./run_wf2_generator.sh` — output format matches `build_postcode_json_from_tsv` (Waypoint 1/2/3, Distance (m), Duration (sec), Polyline, Actual Duration (min), Timing source).

**POIs from a TSV file:**

TSV columns: `postcode`, `placeId`, `name`, `latitude`, `longitude`, `types`, `vicinity`, `source` (tab-separated, first row = header).

```bash
python3 generate_routes_csv.py -i pois_s5.tsv -o pre_generated_routes.csv
```

**Custom durations (comma-separated minutes):**

```bash
python3 generate_routes_csv.py --durations "5,10,15,20,30,60" -o routes.csv
```

**Haversine-only (no OSRM, no polylines, fast):**

```bash
python3 generate_routes_csv.py --no-osrm -o routes.csv
```

**Run the same process for all postcodes (one output file per area):**

From the **project root**:

```bash
bash route_csv_generator/run_all_postcodes.sh
```

POI source is **only** the xlsx (first tab; see `POI_SOURCE_XLSX` in `run_from_pois_export.py`). This runs `run_from_pois_export.py`, which reads the xlsx, splits by postcode, and runs the generator once per area. Outputs: `route_csv_generator/pre_generated_routes_<area>.tsv`.
To skip areas that already have a `.tsv` file, run with `SKIP_EXISTING=1`:

```bash
SKIP_EXISTING=1 bash route_csv_generator/run_all_postcodes.sh
```

**Run from pois_export-4.xlsx (canonical POI source, first tab only):**

POI source is **only** `/Users/raihant/Downloads/pois_export-4.xlsx` (first tab). The script reads that xlsx, splits by postcode, **excludes WF2 0GU** (already done), and runs the generator once per area. Requires **openpyxl** (`pip install openpyxl`).

From the **project root**:

```bash
python3 route_csv_generator/run_from_pois_export.py
```

Default input: that path (see `POI_SOURCE_XLSX` in the script). Override with a path:

```bash
python3 route_csv_generator/run_from_pois_export.py /path/to/pois_export-4.xlsx
```

Skip areas that already have `pre_generated_routes_<area>.tsv`:

```bash
SKIP_EXISTING=1 python3 route_csv_generator/run_from_pois_export.py
```

Outputs: `route_csv_generator/pois_<area>.tsv` (per-area POIs) and `route_csv_generator/pre_generated_routes_<area>.tsv` (routes).

**Watch progress:** Progress is written to `route_csv_generator/progress.txt`. In another terminal run:

```bash
tail -f route_csv_generator/progress.txt
```

**Run next smallest postcode in the background:**

From the **project root**, start route generation for the smallest area that doesn’t yet have a `.tsv` (skips existing, runs one area only):

```bash
bash route_csv_generator/run_next_smallest_background.sh
```

Output goes to `route_csv_generator/background_run.log`. Only one run at a time (lock file); if one is already running, the new process exits. To run “next smallest” in the foreground instead:

```bash
NEXT_SMALLEST=1 SKIP_EXISTING=1 bash route_csv_generator/run_all_postcodes.sh
```

Each area can take a long time (POIs × duration buckets × OSRM delay).

## Requirements

Python 3.6+; no extra packages for `generate_routes_csv.py`. Default mode uses OSRM walking only (no haversine fallback).

For **run_from_pois_export.py** (xlsx input): `pip install openpyxl`.
