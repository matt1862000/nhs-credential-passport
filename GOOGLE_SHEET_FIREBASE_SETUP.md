# Google Sheet ↔ Firebase: Step-by-step setup

Do these once. After that, opening the sheet loads from Firebase; you can upload a postcode back from the menu.

---

## Part 1: Allow the sheet (and app) to **download** from Firebase

Without this, you get **403 Permission denied** when syncing.

1. Open **Google Cloud Console**: https://console.cloud.google.com  
2. At the top, select the project **doctorwaittimes** (or your Firebase project).  
3. Open the menu (≡) → **Cloud Storage** → **Buckets**.  
4. Click your **bucket name**: **doctorwaittimes.firebasestorage.app** (where your `prepopulated_pois_*.json` files are).  
5. Open the **Permissions** tab.  
6. Click **Grant access**.  
7. In **New principals**, type: `allUsers`  
8. In **Role**, choose: **Storage Object Viewer**  
9. Click **Save**. If you see “Allow public access”, confirm.  
10. Done. The Google Sheet “Sync from Firebase” and the app can now download `prepopulated_pois_*.json`.

---

## Part 2: Allow the sheet to **upload** to Firebase (optional, for “Upload postcode to Firebase”)

Only needed if you want to upload from the sheet back to Firebase.

1. In **Google Cloud Console** (same project: doctorwaittimes):  
   Menu (≡) → **APIs & Services** → **Credentials**.  
2. Click **Create credentials** → **Service account**.  
3. **Service account name**: e.g. `sheets-upload`.  
4. Click **Create and continue** → **Done**.  
5. Click the new service account → **Keys** tab → **Add key** → **Create new key** → **JSON** → **Create**.  
   A JSON file downloads; keep it private.  
6. Open the JSON file. Copy the **whole** contents (one object with `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, etc.).  
7. In your **Google Sheet**: menu **Extensions** → **Apps Script**.  
8. In the script editor: run **WalkingWR** → **Setup Firebase Upload** (or the equivalent menu you added).  
9. When asked, paste the **entire** JSON and confirm.  
10. Done. You can use **WalkingWR** → **Upload postcode to Firebase...** and enter a postcode (e.g. S1, S5, WF2) to upload that postcode’s data from the sheet to Firebase.

---

## Part 3: Using the sheet

1. **Open the sheet**  
   - The script runs automatically and loads POIs from Firebase into the POI sheet.  
   - You may see a short toast: “Loaded POIs from Firebase”.

2. **Refresh from Firebase manually**  
   - Menu **WalkingWR** → **Sync from Firebase**  
   - Confirm when asked; the POI sheet is replaced with data from Firebase.

3. **Upload a postcode back to Firebase**  
   - Edit the POI (and Routes) data for that postcode in the sheet.  
   - Menu **WalkingWR** → **Upload postcode to Firebase...**  
   - Enter the postcode (e.g. `S1`, `S5`, `WF2`) and confirm.  
   - That postcode’s JSON is uploaded to Firebase Storage.

---

## Quick checklist

| Step | Where | What |
|------|--------|------|
| 1 | Google Cloud Console → Storage → Buckets → your bucket → Permissions | Grant access: principal `allUsers`, role **Storage Object Viewer** |
| 2 (optional) | Google Cloud Console → Credentials | Create service account, download JSON key |
| 2 (optional) | Google Sheet → Extensions → Apps Script → WalkingWR menu | Run **Setup Firebase Upload** and paste the JSON |
| 3 | Google Sheet | Open sheet = auto load; use **Sync from Firebase** and **Upload postcode to Firebase...** as needed |

If you still get **403** on sync, the bucket in step 1 is wrong or the IAM change wasn’t saved. Your bucket is **doctorwaittimes.firebasestorage.app** — in Cloud Console go to **Cloud Storage → Buckets**, click that bucket, then **Permissions** and ensure `allUsers` has **Storage Object Viewer**.
