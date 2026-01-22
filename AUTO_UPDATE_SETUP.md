# Automated Google Sheets Update Setup

## Quick Setup (One Time)

### Option 1: Simple Setup Script
```bash
./setup_auto_update.sh 'YOUR_GOOGLE_SHEETS_URL'
```

This will:
- Save your Google Sheets URL to a config file
- Create a quick update command

### Option 2: Manual Setup
```bash
export GOOGLE_SHEETS_URL='YOUR_GOOGLE_SHEETS_URL'
```

## Usage

### Update Once (Manual)
```bash
python3 auto_update_from_sheets.py --url 'YOUR_GOOGLE_SHEETS_URL'
```

Or if you set the environment variable:
```bash
python3 auto_update_from_sheets.py
```

Or use the quick command (after setup):
```bash
./update_pois
```

### Watch Mode (Auto-updates)
```bash
python3 auto_update_from_sheets.py --url 'YOUR_GOOGLE_SHEETS_URL' --watch --interval 300
```

This will:
- Check Google Sheets every 5 minutes (300 seconds)
- Auto-convert to JSON when changes detected
- Run until you press Ctrl+C

### Custom Interval
```bash
# Check every 1 minute
python3 auto_update_from_sheets.py --url 'YOUR_URL' --watch --interval 60

# Check every 10 minutes
python3 auto_update_from_sheets.py --url 'YOUR_URL' --watch --interval 600
```

## Automation Options

### Option 1: Run in Background (macOS/Linux)
```bash
# Start watching in background
nohup python3 auto_update_from_sheets.py --url 'YOUR_URL' --watch > update.log 2>&1 &

# Check if running
ps aux | grep auto_update_from_sheets

# Stop it
pkill -f auto_update_from_sheets
```

### Option 2: Cron Job (Scheduled Updates)
```bash
# Edit crontab
crontab -e

# Add this line to check every hour:
0 * * * * cd /Users/raihant/Documents/WalkingWR && python3 auto_update_from_sheets.py --url 'YOUR_URL' >> /tmp/poi_update.log 2>&1
```

### Option 3: Launch Agent (macOS - Auto-start on boot)
Create `~/Library/LaunchAgents/com.walkingwr.poiupdate.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.walkingwr.poiupdate</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/raihant/Documents/WalkingWR/auto_update_from_sheets.py</string>
        <string>--url</string>
        <string>YOUR_GOOGLE_SHEETS_URL</string>
        <string>--watch</string>
        <string>--interval</string>
        <string>300</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

Then load it:
```bash
launchctl load ~/Library/LaunchAgents/com.walkingwr.poiupdate.plist
```

## Workflow

1. **Edit in Google Sheets** - Add ratings, fix names, etc.
2. **Auto-update runs** - Script detects changes and converts
3. **Upload to Firebase** - (Manual step) Upload updated JSON
4. **App downloads** - App automatically gets new version

## Example: Full Automation

```bash
# 1. Setup once
./setup_auto_update.sh 'YOUR_GOOGLE_SHEETS_URL'

# 2. Start watching (runs in background)
nohup python3 auto_update_from_sheets.py --url 'YOUR_URL' --watch > update.log 2>&1 &

# 3. Edit in Google Sheets
# Changes auto-convert every 5 minutes

# 4. When ready, upload to Firebase Storage
# (Manual step - upload the updated JSON file)
```
