#!/bin/bash
# Setup automatic updates from Google Sheets
# This creates a configuration file and sets up easy commands

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.sheets_config"

echo "🔧 Setting up automatic Google Sheets updates..."
echo ""

# Get Google Sheets URL
if [ -z "$1" ]; then
    echo "Enter your Google Sheets URL:"
    echo "  (Format: https://docs.google.com/spreadsheets/d/SHEET_ID/edit)"
    read -r SHEETS_URL
else
    SHEETS_URL="$1"
fi

# Save configuration
cat > "$CONFIG_FILE" << EOF
# Google Sheets Auto-Update Configuration
GOOGLE_SHEETS_URL="$SHEETS_URL"
OUTPUT_JSON="WalkingWR/prepopulated_pois.json"
EOF

echo "✅ Configuration saved to: $CONFIG_FILE"
echo ""
echo "Now you can use these commands:"
echo ""
echo "  # Update once:"
echo "  python3 auto_update_from_sheets.py --url '$SHEETS_URL'"
echo ""
echo "  # Watch for changes (auto-updates every 5 minutes):"
echo "  python3 auto_update_from_sheets.py --url '$SHEETS_URL' --watch"
echo ""
echo "  # Or set environment variable and use:"
echo "  export GOOGLE_SHEETS_URL='$SHEETS_URL'"
echo "  python3 auto_update_from_sheets.py --watch"
echo ""

# Create a simple alias script
cat > "$SCRIPT_DIR/update_pois" << 'UPDATE_SCRIPT'
#!/bin/bash
# Quick update command - loads config and updates
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f ".sheets_config" ]; then
    source .sheets_config
    python3 auto_update_from_sheets.py --url "$GOOGLE_SHEETS_URL"
else
    echo "❌ Configuration not found. Run: ./setup_auto_update.sh YOUR_SHEETS_URL"
    exit 1
fi
UPDATE_SCRIPT

chmod +x "$SCRIPT_DIR/update_pois"
echo "✅ Created quick update command: ./update_pois"
echo ""
echo "Usage:"
echo "  ./update_pois  # Updates once from configured Google Sheet"
