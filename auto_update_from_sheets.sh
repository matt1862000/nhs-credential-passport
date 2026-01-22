#!/bin/bash
# Auto-update POI database from Google Sheets
# Run this script periodically or set up as a cron job

# Configuration
GOOGLE_SHEETS_URL="YOUR_GOOGLE_SHEETS_URL_HERE"
OUTPUT_JSON="WalkingWR/prepopulated_pois.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPT_DIR"

echo "🔄 Auto-updating from Google Sheets..."
python3 google_sheets_to_json.py --via-csv "$GOOGLE_SHEETS_URL" --output "$OUTPUT_JSON"

if [ $? -eq 0 ]; then
    echo "✅ Update successful!"
    
    # Optional: Auto-upload to Firebase Storage
    # Uncomment the lines below if you want to auto-upload after conversion
    # echo "📤 Uploading to Firebase Storage..."
    # python3 upload_to_firebase_storage.py
else
    echo "❌ Update failed"
    exit 1
fi
