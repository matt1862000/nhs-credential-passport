# POI Database Spreadsheet Editing Guide

## Overview

You can now edit the POI database in spreadsheet format (CSV or Excel), add ratings, and convert back to JSON.

## Quick Start

### 1. Export to Spreadsheet

**CSV (works without extra packages):**
```bash
python3 json_to_spreadsheet.py --to-csv
```
Output: `pois_export.csv`

**Excel (requires pandas):**
```bash
pip3 install pandas openpyxl
python3 json_to_spreadsheet.py --to-excel
```
Output: `pois_export.xlsx`

### 2. Edit in Spreadsheet

Open the CSV/Excel file in:
- **Excel** (Windows/Mac)
- **Numbers** (Mac)
- **Google Sheets** (online)
- Any spreadsheet application

**Columns available:**
- `postcode` - Postcode area
- `placeId` - Unique POI identifier
- `name` - POI name
- `latitude` - GPS latitude
- `longitude` - GPS longitude
- `types` - Comma-separated types (e.g., "post_box, monument")
- `vicinity` - Address/vicinity (usually empty)
- `source` - Data source ("osm" or "geograph")
- **`rating`** - **NEW!** Optional rating (1.0 to 5.0, or leave empty)

### 3. Add Ratings

In the `rating` column, you can:
- Leave empty (no rating)
- Add a number from 1.0 to 5.0 (e.g., `4.5`)
- Use decimals (e.g., `3.7`)

**Example:**
```
name                    | rating
War Memorial           | 4.5
Hawthorne Close        | 3.0
Unnamed                | (empty)
```

### 4. Convert Back to JSON

After editing, convert back:
```bash
# From CSV
python3 json_to_spreadsheet.py --from-csv pois_export.csv

# From Excel
python3 json_to_spreadsheet.py --from-excel pois_edited.xlsx
```

This will update `WalkingWR/prepopulated_pois.json` with your changes.

### 5. Upload Updated Database

After converting back to JSON:
1. Upload the updated `prepopulated_pois.json` to Firebase Storage
2. Increment the `version` number in the JSON (e.g., `"version": 1` → `"version": 2`)
3. The app will automatically download the new version

## Important Notes

⚠️ **Don't change these fields:**
- `placeId` - Used for deduplication (changing breaks matching)
- `postcode` - Must match existing postcode areas
- `source` - Should remain "osm" or "geograph"

✅ **Safe to edit:**
- `name` - POI names
- `rating` - Add ratings (new field)
- `types` - POI types (comma-separated)
- `vicinity` - Address information

## Example Workflow

1. **Export:**
   ```bash
   python3 json_to_spreadsheet.py --to-csv
   ```

2. **Edit in Excel/Google Sheets:**
   - Add ratings to interesting POIs
   - Fix any incorrect names
   - Save as `pois_edited.csv`

3. **Convert back:**
   ```bash
   python3 json_to_spreadsheet.py --from-csv pois_edited.csv
   ```

4. **Update version and upload:**
   - Edit `WalkingWR/prepopulated_pois.json`
   - Change `"version": 1` to `"version": 2`
   - Upload to Firebase Storage

5. **Test:**
   - Clear database in app (debug button)
   - Restart app
   - Verify ratings are loaded

## Using Ratings in the App

The rating field is now available in `PrePopulatedPOI`. You can:
- Filter POIs by minimum rating
- Sort POIs by rating
- Display ratings in the UI
- Use ratings for route scoring/selection

Example code to access rating:
```swift
if let rating = poi.rating {
    // POI has a rating
    print("\(poi.name): \(rating) stars")
}
```
