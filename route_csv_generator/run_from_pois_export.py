#!/usr/bin/env python3
"""
Run the route generator for every postcode from the canonical POI export.
Source of POIs is ONLY the xlsx below (first tab). No prepopulated_pois_*.json.

Reads the xlsx first tab, writes one TSV per postcode, then runs generate_routes_csv.py for each.
Requires: openpyxl (pip install openpyxl)

Usage:
  # Default: use POI_SOURCE_XLSX (first tab only)
  python3 run_from_pois_export.py

  # Override path (still first tab only)
  python3 run_from_pois_export.py /path/to/pois_export.xlsx

  # Skip areas that already have a pre_generated_routes_<area>.tsv
  SKIP_EXISTING=1 python3 run_from_pois_export.py

  # Run only one area (e.g. S36); only that postcode from the xlsx is used
  RUN_AREA=S36 python3 run_from_pois_export.py

  # Run only the next smallest area (by POI count) that doesn't yet have output
  NEXT_SMALLEST=1 SKIP_EXISTING=1 python3 run_from_pois_export.py
"""

# Canonical POI source — route generator MUST use only this file (first tab).
POI_SOURCE_XLSX = "/Users/raihant/Downloads/pois_export-4.xlsx"

import csv
import os
import subprocess
import sys
from pathlib import Path

try:
    import openpyxl
except ImportError:
    print("This script needs openpyxl to read .xlsx files.", file=sys.stderr)
    print("Install with: pip3 install openpyxl", file=sys.stderr)
    sys.exit(1)

# TSV columns expected by generate_routes_csv.py (load_pois_from_tsv)
TSV_HEADER = ["postcode", "placeId", "name", "latitude", "longitude", "types", "vicinity", "source"]
# Excel columns we expect (case-insensitive match)
XL_COLS = ["postcode", "placeId", "name", "latitude", "longitude", "types", "vicinity", "source", "rating"]


def load_xlsx_by_postcode(path):
    """Read xlsx first tab only; return dict postcode -> list of row dicts (postcode, placeId, name, lat, lon, types, vicinity, source)."""
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb.worksheets[0]  # first tab only
    rows = list(ws.iter_rows(values_only=True))
    wb.close()
    if not rows:
        return {}
    raw_headers = [str(h or "").strip() for h in rows[0]]
    # map lowercase header -> index
    header_idx = {}
    for i, h in enumerate(raw_headers):
        hl = h.lower()
        if hl not in header_idx:
            header_idx[hl] = i
    # normalize expected column names to indices
    col_map = {}
    for name in ["postcode", "placeid", "name", "latitude", "longitude", "types", "vicinity", "source"]:
        for k, i in header_idx.items():
            if name in k or k in name.replace("_", ""):
                col_map[name] = i
                break
    if "postcode" not in col_map or "latitude" not in col_map or "longitude" not in col_map:
        raise ValueError(f"Cannot find required columns (postcode, latitude, longitude) in {raw_headers}")

    by_postcode = {}
    def _cell(r, key, default=""):
        i = col_map.get(key)
        if i is None or i >= len(r):
            return default
        v = r[i]
        return str(v).strip() if v is not None else default

    for r in rows[1:]:
        if not r or r[col_map["postcode"]] is None:
            continue
        postcode = str(r[col_map["postcode"]]).strip()
        if not postcode:
            continue
        lat = r[col_map["latitude"]]
        lon = r[col_map["longitude"]]
        if lat is None or lon is None:
            continue
        try:
            float(lat)
            float(lon)
        except (TypeError, ValueError):
            continue
        row = {
            "postcode": postcode,
            "placeId": _cell(r, "placeid"),
            "name": _cell(r, "name"),
            "latitude": float(lat),
            "longitude": float(lon),
            "types": _cell(r, "types"),
            "vicinity": _cell(r, "vicinity"),
            "source": _cell(r, "source"),
        }
        by_postcode.setdefault(postcode, []).append(row)
    return by_postcode


def area_to_filename(postcode):
    """Turn postcode into a safe filename segment (e.g. S1 -> S1, WF2 0GU -> WF2_0GU)."""
    return postcode.replace(" ", "_").strip()


def main():
    script_dir = Path(__file__).resolve().parent
    root = script_dir.parent
    xlsx_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(POI_SOURCE_XLSX)
    skip_existing = os.environ.get("SKIP_EXISTING", "0").strip() == "1"

    if not xlsx_path.exists():
        print(f"File not found: {xlsx_path}", file=sys.stderr)
        print("POI source must be that xlsx (first tab). Override with:", file=sys.stderr)
        print("  python3 route_csv_generator/run_from_pois_export.py /path/to/pois_export-4.xlsx", file=sys.stderr)
        sys.exit(1)

    print(f"POI source: {xlsx_path} (first tab only)")
    by_postcode = load_xlsx_by_postcode(xlsx_path)
    # Exclude WF2 0GU (already done)
    exclude = {"WF2 0GU", "WF2_0GU"}
    all_areas = sorted(
        pc for pc in by_postcode
        if pc not in exclude and pc.replace(" ", "_") not in exclude
    )
    run_area = (os.environ.get("RUN_AREA") or "").strip()
    next_smallest = os.environ.get("NEXT_SMALLEST", "0").strip() == "1"
    if run_area:
        # Match postcode (allow "S36" or "S36 " etc.)
        areas = [pc for pc in all_areas if area_to_filename(pc) == area_to_filename(run_area)]
        if not areas:
            print(f"RUN_AREA={run_area}: no such postcode in xlsx. Postcodes in file: {all_areas}", file=sys.stderr)
            sys.exit(1)
        print(f"Running single area: {areas[0]} ({len(by_postcode[areas[0]])} POIs)")
    elif next_smallest and skip_existing:
        script_dir = Path(__file__).resolve().parent
        pending = [
            (pc, len(by_postcode[pc]))
            for pc in all_areas
            if not (script_dir / f"pre_generated_routes_{area_to_filename(pc)}.tsv").exists()
            or (script_dir / f"pre_generated_routes_{area_to_filename(pc)}.tsv").stat().st_size == 0
        ]
        if not pending:
            print("NEXT_SMALLEST=1: no remaining areas (all have output).")
            return
        pending.sort(key=lambda x: (x[1], x[0]))
        pc, n = pending[0]
        areas = [pc]
        print(f"Next smallest: {pc} ({n} POIs)")
    else:
        areas = all_areas
        print(f"Postcodes in file: {len(by_postcode)}; excluding WF2 0GU -> {len(areas)} areas: {areas}")

    generator = script_dir / "generate_routes_csv.py"
    if not generator.exists():
        print(f"Generator script not found: {generator}", file=sys.stderr)
        sys.exit(1)

    for postcode in areas:
        area_id = area_to_filename(postcode)
        out_tsv = script_dir / f"pre_generated_routes_{area_id}.tsv"
        if skip_existing and out_tsv.exists() and out_tsv.stat().st_size > 0:
            print(f"Skip {postcode}: {out_tsv.name} already exists")
            continue

        poi_tsv = script_dir / f"pois_{area_id}.tsv"
        rows = by_postcode[postcode]
        with open(poi_tsv, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=TSV_HEADER, delimiter="\t", extrasaction="ignore")
            w.writeheader()
            w.writerows(rows)
        # Default durations in generator = 11, so candidate routes = len(rows)*11 (much smaller than 406k)
        cand = len(rows) * 11
        print(f"\n=== {postcode} ({len(rows)} POIs, ~{cand} candidate routes) -> {out_tsv.name} ===")
        subprocess.run([
            sys.executable, str(generator),
            "-i", str(poi_tsv),
            "-o", str(out_tsv),
            "--progress-file", str(script_dir / "progress.txt"),
        ], cwd=str(root), check=True)

    print("\nDone.")


if __name__ == "__main__":
    main()
