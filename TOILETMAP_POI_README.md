# Toilet Map → Google Sheet POIs

Add [Great British Public Toilet Map](https://www.toiletmap.org.uk/) toilets as POIs in your sheet format.

## Sheet columns (output)

`postcode` | `placeId` | `name` | `latitude` | `longitude` | `types` | `vicinity` | `source` | `rating`

## Usage

**Option A – Filter by postcode (center + radius)**  
Uses your postcode centers (e.g. WF2 0GU). Toilets within the radius are included.

```bash
python3 toiletmap_to_poi_sheet.py --postcode "WF2 0GU"
```

**Option B – Filter by area name**  
Uses Toilet Map’s area name (e.g. Wakefield). Good for whole district.

```bash
python3 toiletmap_to_poi_sheet.py --area "Wakefield" --postcode "WF2 0GU"
```

**Option C – Use a local JSON file**  
If the download fails (large file), download the JSON from [toiletmap.org.uk/dataset](https://www.toiletmap.org.uk/dataset) and run:

```bash
python3 toiletmap_to_poi_sheet.py --file /path/to/toilets-....json --postcode "WF2 0GU"
# or by area:
python3 toiletmap_to_poi_sheet.py --file /path/to/toilets-....json --area "Wakefield" --postcode "WF2 0GU"
```

**Output TSV (e.g. for paste into Sheets):**

```bash
python3 toiletmap_to_poi_sheet.py --postcode "WF2 0GU" --tsv
```

## Pasting into Google Sheets

1. Run the script and copy the output (including the header row).
2. In your POI sheet (e.g. `pois_export`), paste into the first empty row so the columns line up: **postcode, placeId, name, latitude, longitude, types, vicinity, source, rating**.
3. If your sheet uses different column order, paste into a spare sheet and reorder, or adjust the script’s column order.

## Data mapping

| Toilet Map field     | Sheet column |
|----------------------|-------------|
| areas.name / filter  | postcode    |
| id (prefixed)        | placeId     |
| name (or "Public toilet") | name   |
| location.coordinates[1] | latitude  |
| location.coordinates[0] | longitude |
| public_toilet + accessible + baby_change | types |
| areas.name           | vicinity    |
| "toiletmap"          | source      |
| (none)               | rating      |

Dataset licence: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) – credit: “Contains data from the Toilet Map © 2025 – CC BY 4.0”.
