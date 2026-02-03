# Routes sheet: what the generators do

## Where route data comes from

1. **Apps Script – Export Routes to Sheet** (`exportRoutesToSheet`)
   - Used after "Convert to JSON" / "Regenerate Routes".
   - Writes: Postcode, Duration (min), Route Index, **Waypoints** (combined "A → B → C"), Waypoint Count, Distance, Duration (sec), Duration (formatted), Name, Description, **Polyline**.
   - **Change:** Polyline is now written in full (no 100‑char truncation) so the sheet can be re-imported correctly.

2. **Apps Script – Edit POIs and Routes** (`exportRoutesForManualEditing`)
   - Writes: Postcode, Duration (min), Route Index, Name, Description, Waypoint Count, Waypoint 1, Waypoint 2, Waypoint 3, Distance, Duration (sec), **Polyline** (full), Generate Polyline.
   - Metadata (duration, name, description, waypoints) is short text; only the Polyline column has long strings.

3. **Python – route_csv_generator** (`generate_routes_csv.py`, `_write_routes_tsv`)
   - TSV columns: Postcode, Duration (min), Route Index, Name, Description, Waypoint Count, Waypoint 1, Waypoint 2, Waypoint 3, Distance (m), Duration (sec), **Polyline**, Generate Polyline.
   - Puts short values in name, description, waypoint_1/2/3 and **full polyline only in the Polyline column**.

4. **Apps Script – Generate Polyline for Selected Route** (`generatePolylineForRoute`)
   - Updates one row: Polyline column (L), Distance (J), Duration sec (K) from OSRM.

## Why "huge cells" happened

The **Polyline column** was being read in the same column-by-column loop as the metadata columns. Reading many rows of full polylines in one `getValues()` call hit Google’s size limit.

**Fix in `updateJSONForPostcode`:**
- The Polyline column (1-based `polylineColR + 1`) is **skipped** in the left-cols loop.
- Polyline is read only in the existing batched polyline read (20 rows at a time).
- Metadata columns (including Duration (sec) before Polyline) are still read in the loop; only the Polyline column is excluded.

So you **don’t need to shorten polylines**. They stay in one column and are read in small batches. The generators already keep polylines only in the Polyline column; the script was just including that column in the heavy read by mistake.

## Summary

| Source                    | Polyline column      | Other columns (duration, name, waypoints) |
|---------------------------|----------------------|------------------------------------------|
| exportRoutesToSheet       | Full (was truncated) | Short                                    |
| exportRoutesForManualEditing | Full               | Short                                    |
| Python TSV                | Full                 | Short                                    |

Polylines stay full length and only in the Polyline column. No change needed in the generators.
