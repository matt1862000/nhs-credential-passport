# Step-by-step: Upload to Firebase using a service account key (Option A)

Use this when you want to run `upload_all_postcodes_to_firebase.py` (or `upload_to_firebase_storage.py`) on your machine without using `gcloud auth`.

---

## Step 1: Open Firebase Console

1. Go to **https://console.firebase.google.com**
2. Sign in with the Google account that owns the **doctorwaittimes** project
3. Click the **doctorwaittimes** project (or create/select it)

---

## Step 2: Open Project settings

1. Click the **gear icon** next to “Project Overview” (top left)
2. Click **Project settings**

---

## Step 3: Go to Service accounts

1. In the left sidebar, click **Service accounts**
2. You’ll see “Firebase Admin SDK” and a list of service accounts

---

## Step 4: Generate a new private key

1. Scroll down to **“Firebase Admin SDK”**
2. Click **“Generate new private key”** (or “Manage service account permissions” → then in Google Cloud Console you can create a key there; the steps below assume you use the “Generate new private key” button in Firebase)
3. In the dialog, click **“Generate key”**
4. A JSON file will download (e.g. `doctorwaittimes-firebase-adminsdk-xxxxx-xxxxxxxxxx.json`)

---

## Step 5: Rename and move the key file

1. Rename the downloaded file to exactly: **`serviceAccountKey.json`**
2. Move it into your WalkingWR project folder (the same folder that contains `upload_all_postcodes_to_firebase.py`)

   Example on Mac:
   - If the file downloaded to `~/Downloads/doctorwaittimes-firebase-adminsdk-xxxxx.json`
   - In Terminal:
     ```bash
     mv ~/Downloads/doctorwaittimes-firebase-adminsdk-*.json /Users/raihant/Documents/WalkingWR/serviceAccountKey.json
     ```
   - Or drag the file into the WalkingWR folder in Finder, then rename it to `serviceAccountKey.json`

3. Confirm the file is there:
   ```bash
   ls /Users/raihant/Documents/WalkingWR/serviceAccountKey.json
   ```
   You should see: `serviceAccountKey.json`

---

## Step 6: Run the upload script

1. Open Terminal
2. Go to the WalkingWR folder:
   ```bash
   cd /Users/raihant/Documents/WalkingWR
   ```
3. Run:
   ```bash
   python3 upload_all_postcodes_to_firebase.py
   ```
4. You should see:
   - `✅ Firebase initialized (serviceAccountKey.json)` (or the path to the file)
   - Then one line per file: `✅ prepopulated_pois_S1.json`, `✅ prepopulated_pois_S2.json`, etc.
   - At the end: `Uploaded 22/22 files to doctorwaittimes.firebasestorage.app`

---

## Step 7: Check in Firebase (optional)

1. In Firebase Console, go to **Build** → **Storage**
2. Open your bucket (e.g. **doctorwaittimes.firebasestorage.app**)
3. You should see `prepopulated_pois_S1.json`, `prepopulated_pois_S12.json`, etc.

---

## Security reminder

- **Do not commit `serviceAccountKey.json` to Git.** It’s already in `.gitignore`.
- Do not share the file or upload it anywhere public.
- If the key is ever exposed, go to Firebase Console → Project settings → Service accounts, delete the key and generate a new one.

---

## If something goes wrong

| Problem | What to do |
|--------|-------------|
| “File not found: serviceAccountKey.json” | Make sure the file is named exactly `serviceAccountKey.json` and is in `/Users/raihant/Documents/WalkingWR/` (same folder as the upload script). |
| “Permission denied” or 403 | In Firebase Console → Storage → Rules, ensure your rules allow uploads (or use the Firebase Console UI to upload one file and confirm the bucket works). |
| “firebase-admin not installed” | Run: `pip3 install firebase-admin` |
| Python 3.9 warning | You can ignore it for now, or upgrade to Python 3.10+ later. |
