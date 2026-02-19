# Menu Options Guide - When to Use Each

## "Convert to JSON" vs "Convert & Show JSON"

### "Convert to JSON" 
**Use this for regular updates** ✅

**When to use:**
- You've finished editing your POIs (ratings, names, etc.)
- You want to convert and save to Drive
- You don't need to see the JSON output
- **This is your main option** - use this 90% of the time

**What happens:**
1. Converts your sheet data to JSON format
2. Saves to Google Drive folder "WalkingWR Database"
3. Shows a success popup with stats:
   - Number of postcode areas
   - Total POIs converted
   - New version number
4. Done! JSON is saved and ready to download

**Example:**
```
You edit 5 POI ratings → Click "Convert to JSON" → 
✅ Success popup shows "12083 POIs, Version 2" → 
JSON saved to Drive → Download and upload to Firebase
```

---

### "Convert & Show JSON"
**Use this for debugging/preview** 🔍

**When to use:**
- You want to preview the JSON before saving
- You're checking if the conversion worked correctly
- You want to see a snippet of the output
- You're testing or debugging
- You want to copy part of the JSON

**What happens:**
1. Converts your sheet data to JSON format
2. Saves to Google Drive (same as above)
3. **Opens a dialog window** showing the first 5000 characters of JSON
4. You can scroll through and see the structure
5. Close the dialog when done

**Example:**
```
You edit POIs → Click "Convert & Show JSON" → 
Dialog opens showing JSON preview → 
You verify it looks correct → Close dialog → 
JSON is already saved to Drive
```

---

## Quick Decision

**Just want to convert?** → Use **"Convert to JSON"**

**Want to see what it looks like?** → Use **"Convert & Show JSON"**

---

## Typical Workflow

### Normal Day-to-Day Editing:
1. Edit POIs in Google Sheets
2. Click **"Convert to JSON"** (quick and simple)
3. Download from Drive
4. Upload to Firebase

### First Time or Testing:
1. Edit a few POIs
2. Click **"Convert & Show JSON"** (see the output)
3. Verify it looks correct
4. Close dialog
5. Download from Drive
6. Upload to Firebase

---

## Both Options Do the Same Thing

**Important:** Both options:
- ✅ Convert your sheet to JSON
- ✅ Save to Google Drive
- ✅ Auto-increment version
- ✅ Preserve existing routes

**The only difference:**
- "Convert to JSON" = Shows success popup
- "Convert & Show JSON" = Shows success popup + JSON preview dialog

---

## Recommendation

**Start with "Convert & Show JSON"** the first few times to see what the output looks like.

**Then switch to "Convert to JSON"** for regular use - it's faster and cleaner.
