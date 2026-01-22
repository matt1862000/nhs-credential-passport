# Google Sheets Integration Guide

## Overview

You can now edit your POI database directly in Google Sheets and convert to JSON in real-time!

## Quick Setup

### Step 1: Export Current Database to Google Sheets

1. **Export to CSV:**
   ```bash
   python3 json_to_spreadsheet.py --to-csv
   ```

2. **Upload to Google Sheets:**
   - Go to https://sheets.google.com
   - Click "Blank" to create new spreadsheet
   - File → Import → Upload `pois_export.csv`
   - Or copy/paste the CSV data

3. **Share the Sheet:**
   - Click "Share" button (top right)
   - Click "Change to anyone with the link"
   - Set permission to "Viewer" (they only need to read)
   - Copy the link

### Step 2: Convert Google Sheets to JSON

**One-time conversion:**
```bash
python3 google_sheets_to_json.py --via-csv 'YOUR_GOOGLE_SHEETS_URL'
```

**Auto-watch mode (real-time):**
```bash
python3 google_sheets_to_json.py --watch 'YOUR_GOOGLE_SHEETS_URL' --interval 60
```
This checks every 60 seconds for changes and auto-converts.

### Step 3: Edit in Google Sheets

1. Open your Google Sheet
2. Edit POI names, add ratings, etc.
3. Changes are automatically detected (if using --watch)
4. Or manually run conversion after editing

## Example Workflow

### Initial Setup:
```bash
# 1. Export current database
python3 json_to_spreadsheet.py --to-csv

# 2. Upload pois_export.csv to Google Sheets
# 3. Share sheet and get URL

# 4. Convert from Google Sheets
python3 google_sheets_to_json.py --via-csv 'https://docs.google.com/spreadsheets/d/YOUR_ID/edit'
```

### Daily Editing:
1. Edit POIs in Google Sheets (add ratings, fix names, etc.)
2. Run conversion:
   ```bash
   python3 google_sheets_to_json.py --via-csv 'YOUR_SHEETS_URL'
   ```
3. Upload updated JSON to Firebase Storage
4. App automatically downloads new version

### Real-Time Mode:
```bash
# Start watching (runs in background)
python3 google_sheets_to_json.py --watch 'YOUR_SHEETS_URL' --interval 60

# Edit in Google Sheets
# Changes auto-convert every 60 seconds
# Press Ctrl+C to stop
```

## Google Sheets URL Format

Your Google Sheets URL should look like:
```
https://docs.google.com/spreadsheets/d/SHEET_ID/edit#gid=0
```

The script automatically converts it to CSV export format.

## Column Requirements

Your Google Sheet must have these columns (in order):
- `postcode`
- `placeId`
- `name`
- `latitude`
- `longitude`
- `types` (comma-separated)
- `vicinity`
- `source`
- `rating` (optional, can be empty)

## Tips

1. **Freeze header row** in Google Sheets: View → Freeze → 1 row
2. **Use data validation** for rating column: Data → Data validation → Number between 1-5
3. **Use filters** to find/edit specific POIs: Data → Create a filter
4. **Color code** by rating for visual organization

## Automation Options

### Option 1: Manual Conversion
Edit → Run script → Upload to Firebase

### Option 2: Watch Mode
Script runs in background, auto-converts on changes

### Option 3: Google Apps Script (Advanced)
Create a script in Google Sheets that auto-exports to a webhook/API

## Troubleshooting

**"Access denied" error:**
- Make sure sheet is shared: "Anyone with the link can view"
- Check sharing settings

**"No data found":**
- Make sure first row contains column headers
- Check that data starts from row 2

**"Invalid URL":**
- Use the full Google Sheets URL (with /edit)
- Or use CSV export URL directly
