# Google Apps Script Setup Guide

## Overview

Use Google Apps Script (built into Google Sheets) to automatically convert your POI data to JSON format. This runs entirely within Google Sheets - no external scripts needed!

## Setup Steps

### Step 1: Open Apps Script

1. Open your Google Sheet with POI data
2. Click **Extensions** → **Apps Script**
3. A new tab opens with the script editor

### Step 2: Paste the Script

1. Delete any default code in the editor
2. Copy the entire contents of `GOOGLE_APPS_SCRIPT.js`
3. Paste into the Apps Script editor
4. Click **Save** (💾 icon) or press `Cmd+S` / `Ctrl+S`
5. Name your project: "WalkingWR POI Converter"

### Step 3: Configure (Optional)

Edit the `CONFIG` object at the top of the script:

```javascript
const CONFIG = {
  SAVE_TO_DRIVE: true,              // Save JSON to Google Drive
  DRIVE_FOLDER_NAME: 'WalkingWR Database',
  DRIVE_FILE_NAME: 'prepopulated_pois.json',
  AUTO_INCREMENT_VERSION: true      // Auto-increment version on each conversion
};
```

### Step 4: Run the Script

1. Click **Run** button (▶️) or press `Cmd+Enter` / `Ctrl+Enter`
2. First time: Authorize the script
   - Click "Review Permissions"
   - Choose your Google account
   - Click "Advanced" → "Go to [Project Name] (unsafe)"
   - Click "Allow"
3. The script will convert your sheet to JSON

### Step 5: Use the Menu

After running once, you'll see a new menu in Google Sheets:
- **WalkingWR POI Database** → **Convert to JSON**
- **WalkingWR POI Database** → **Convert & Show JSON**
- **WalkingWR POI Database** → **About**

## Features

### ✅ Automatic Conversion
- Converts sheet data to JSON format
- Preserves existing routes (if database exists in Drive)
- Auto-increments version number
- Saves to Google Drive automatically

### ✅ Smart Grouping
- Groups POIs by postcode
- Maintains database structure
- Handles optional rating field

### ✅ Easy Access
- Menu item in Google Sheets
- One-click conversion
- Shows success message with stats

## Auto-Convert on Edit (Optional)

To automatically convert when you edit the sheet, uncomment the `onEdit()` function at the bottom of the script:

```javascript
function onEdit(e) {
  // Auto-convert when rating or name is edited
  const range = e.range;
  const column = range.getColumn();
  const header = SpreadsheetApp.getActiveSheet().getRange(1, column).getValue();
  
  if (header && (header.toLowerCase() === 'rating' || header.toLowerCase() === 'name')) {
    Utilities.sleep(2000); // Wait 2 seconds after last edit
    convertSheetToJSON();
  }
}
```

**Note:** This will convert every time you edit, which might be too frequent. Better to use manual conversion or a time-based trigger.

## Time-Based Triggers (Recommended)

Set up automatic conversion on a schedule:

1. In Apps Script editor, click **Triggers** (⏰ icon) on the left
2. Click **+ Add Trigger** (bottom right)
3. Configure:
   - **Function:** `convertSheetToJSON`
   - **Event source:** Time-driven
   - **Type:** Hour timer / Day timer
   - **Time:** Choose your preference
4. Click **Save**

Now the script will automatically convert your sheet to JSON on the schedule you set!

## Workflow

1. **Edit in Google Sheets** - Add ratings, fix names, etc.
2. **Auto-convert runs** - Script converts to JSON (manual or scheduled)
3. **JSON saved to Drive** - File saved in "WalkingWR Database" folder
4. **Download from Drive** - Get the JSON file
5. **Upload to Firebase** - Replace file in Firebase Storage
6. **App downloads** - App automatically gets new version

## Output

The script creates/updates:
- **File:** `prepopulated_pois.json`
- **Location:** Google Drive folder "WalkingWR Database"
- **Format:** Matches your app's JSON structure exactly
- **Version:** Auto-incremented on each conversion

## Troubleshooting

**"Missing required column" error:**
- Make sure your sheet has these columns: postcode, placeId, name, latitude, longitude, types, source

**"Permission denied" error:**
- Re-authorize: Run → Review Permissions → Allow

**JSON structure issues:**
- Make sure first row contains column headers
- Check that data types are correct (numbers for lat/lon, text for names)

## Advanced: Firebase Upload

To automatically upload to Firebase Storage, you'd need to:
1. Set up Firebase Admin SDK credentials
2. Implement the `uploadToFirebase()` function
3. Enable `UPLOAD_TO_FIREBASE: true` in config

For now, saving to Drive and manual upload works great!
