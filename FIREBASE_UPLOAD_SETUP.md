# Firebase Upload Setup for Google Apps Script

## Overview

The Google Apps Script can now automatically upload your JSON database directly to Firebase Storage! This means you can edit in Google Sheets and have it automatically sync to Firebase.

## Setup Steps

### Step 1: Get Firebase Service Account Key

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Select your project: **doctorwaittimes**
3. Click the **⚙️ Settings** icon → **Project settings**
4. Go to **Service accounts** tab
5. Click **Generate new private key**
6. A JSON file will download - **keep this safe!**
7. Open the JSON file and copy the entire contents

### Step 2: Configure in Google Apps Script

1. Open your Google Sheet
2. Go to **Extensions** → **Apps Script**
3. In the menu, click **WalkingWR POI Database** → **Setup Firebase Upload**
4. Paste the entire JSON content from the service account key
5. Click **OK**

The service account key is now stored securely in Script Properties (encrypted by Google).

### Step 3: Enable Firebase Upload

1. In Apps Script editor, find the `CONFIG` section at the top
2. Change this line:
   ```javascript
   UPLOAD_TO_FIREBASE: false,
   ```
   to:
   ```javascript
   UPLOAD_TO_FIREBASE: true,
   ```
3. Click **Save** (💾)

### Step 4: Test It!

1. In Google Sheets, click **WalkingWR POI Database** → **Convert to JSON**
2. The script will now:
   - Convert your sheet to JSON
   - Save to Google Drive
   - **Upload directly to Firebase Storage** ✅
3. Check the success message - it should say "Uploaded to Firebase Storage"

## How It Works

When you convert your sheet:
1. ✅ Converts sheet data to JSON
2. ✅ Saves to Google Drive (backup)
3. ✅ **Uploads to Firebase Storage** (if enabled)
4. ✅ Auto-increments version
5. ✅ App automatically downloads new version on next launch

## Security

- Service account key is stored in **Script Properties** (encrypted by Google)
- Only your Google account can access it
- The key is never exposed in logs or dialogs
- You can revoke it anytime from Firebase Console

## Troubleshooting

### "Firebase service account not configured"
- Run **Setup Firebase Upload** from the menu first
- Make sure you pasted the complete JSON

### "Failed to get Firebase access token"
- Check that the service account key is valid
- Make sure the key hasn't been revoked in Firebase Console
- Try regenerating the key and setting it up again

### "Firebase upload failed: 403"
- Check Firebase Storage rules allow writes
- Make sure the service account has Storage Admin role
- Go to Firebase Console → IAM & Admin → check service account permissions

### "Firebase upload failed: 401"
- Service account key might be invalid
- Regenerate the key and set it up again

## Firebase Storage Rules

Make sure your Storage rules allow the service account to write:

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /prepopulated_pois.json {
      allow read: if true;  // Public read
      allow write: if request.auth != null || 
                      request.resource.size < 10 * 1024 * 1024; // Allow service account writes
    }
  }
}
```

Or for service account access, you can use:

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /prepopulated_pois.json {
      allow read: if true;
      allow write: if true; // Service accounts bypass rules
    }
  }
}
```

## Automatic Uploads

Once set up, you can configure automatic uploads:

1. **Time-based trigger**: Convert every hour/day automatically
2. **Manual**: Click menu when ready

Both will upload to Firebase if `UPLOAD_TO_FIREBASE: true` is set!

## Workflow

**Before (Manual):**
1. Edit in Google Sheets
2. Convert to JSON
3. Download from Drive
4. Upload to Firebase manually

**After (Automatic):**
1. Edit in Google Sheets
2. Convert to JSON
3. ✅ **Automatically uploaded to Firebase!**
4. App downloads on next launch

Much easier! 🎉
