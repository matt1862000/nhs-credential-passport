# Firebase Storage Upload Instructions

## Quick Upload Steps

1. **Open Firebase Console Storage:**
   - Go to: https://console.firebase.google.com/project/doctorwaittimes/storage
   - Or click the link that should have opened in your browser

2. **Set up Storage (if first time):**
   - Click "Get started"
   - Choose "Start in test mode" (we'll set rules after)
   - Select a location (choose closest to your users)
   - Click "Done"

3. **Upload the file:**
   - Click "Upload file" button
   - Navigate to: `/Users/raihant/Documents/WalkingWR/WalkingWR/prepopulated_pois.json`
   - **Important:** In the "File path in Cloud Storage" field, enter: `prepopulated_pois.json`
   - Click "Upload"

4. **Set Storage Rules (make it publicly readable):**
   - Click the "Rules" tab at the top
   - Replace the rules with:
   ```
   rules_version = '2';
   service firebase.storage {
     match /b/{bucket}/o {
       match /prepopulated_pois.json {
         allow read: if true;  // Public read access
         allow write: if false; // Only you can write via console
       }
     }
   }
   ```
   - Click "Publish"

5. **Verify:**
   - Go back to "Files" tab
   - Click on `prepopulated_pois.json`
   - Copy the "Download URL" - it should look like:
     `https://firebasestorage.googleapis.com/v0/b/doctorwaittimes.firebasestorage.app/o/prepopulated_pois.json?alt=media&token=...`

## File Details
- **File:** `WalkingWR/prepopulated_pois.json`
- **Size:** 3.3 MB
- **Destination path:** `prepopulated_pois.json` (root of bucket)

## After Upload

The app will automatically:
1. Check Firebase Storage on every app start
2. Download if version is newer than cached
3. Fall back to bundled database if Firebase is unavailable

No code changes needed - the app is already configured!
