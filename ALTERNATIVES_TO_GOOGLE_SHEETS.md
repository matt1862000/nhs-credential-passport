# Alternatives to Google Sheets for editing routes and POIs

Ways to edit data and update Firebase without using the sheet (no 6‑min limit, no Apps Script size limits).

---

## Option 1: Edit the TSV files locally (best fit with what you have)

You already have **pre_generated_routes_&lt;district&gt;.tsv** and **build_postcode_json_from_tsv.py**. Use them as the source of truth for routes.

**Workflow:**
1. **Edit the TSV** in any editor:
   - **Excel / Numbers / LibreOffice** – Open `route_csv_generator/pre_generated_routes_S12.tsv`, edit (add/change/delete rows), save as TSV (tab-separated, UTF-8).
   - **VS Code / Cursor** – Open the TSV, edit as text (tabs between columns).
2. **Rebuild JSON** for that postcode:
   ```bash
   python3 build_postcode_json_from_tsv.py --district S12 \
     --routes-tsv route_csv_generator/pre_generated_routes_S12.tsv \
     --poi-json prepopulated_pois_S12.json --output prepopulated_pois_S12.json
   ```
3. **Upload** (one file or all):
   ```bash
   python3 upload_all_postcodes_to_firebase.py
   ```

**POIs:** Right now POIs come from the existing `prepopulated_pois_<district>.json`. To edit POIs without the sheet you’d either:
- Edit the JSON by hand for small changes (see Option 2), or
- Add a POI TSV/CSV and a small script that builds/updates the JSON from routes TSV + POI TSV (we can add this if you want).

**Pros:** No Google, no 6‑min limit, same pipeline you use for mass upload.  
**Cons:** POI editing is either manual JSON or needs a small script.

---

## Option 2: Edit the JSON file directly (good for small edits)

For a few route or POI changes in one postcode, edit the JSON file and re-upload.

**Workflow:**
1. **Get the file** – Either download `prepopulated_pois_S12.json` from Firebase Storage (Console → Storage → file → download), or use the copy in your repo after a recent build/upload.
2. **Edit** in VS Code / Cursor (or any JSON editor):
   - **Routes:** In `postcodeAreas[0].routes` you have `durationMinutes` and `routes[]`; each route has `places`, `polyline`, `distanceMeters`, `durationSeconds`, `name`, `description`.
   - **POIs:** In `postcodeAreas[0].pois` you have `name`, `latitude`, `longitude`, `placeId`, `types`, etc.
3. **Save** (valid JSON: commas, quotes, no trailing commas).
4. **Upload** that one file:
   ```bash
   cd /Users/raihant/Documents/WalkingWR
   python3 -c "
   import firebase_admin
   from firebase_admin import credentials, storage
   cred = credentials.Certificate('serviceAccountKey.json')
   if not firebase_admin._apps:
       firebase_admin.initialize_app(cred, {'storageBucket': 'doctorwaittimes.firebasestorage.app'})
   bucket = storage.bucket()
   blob = bucket.blob('prepopulated_pois_S12.json')
   blob.upload_from_filename('prepopulated_pois_S12.json')
   print('Uploaded prepopulated_pois_S12.json')
   "
   ```
   Or add a small script `upload_one_postcode.py` that takes a filename and uploads it.

**Pros:** No spreadsheet, no TSV, works for any small change.  
**Cons:** Easy to break JSON; best for a few edits at a time.

---

## Option 3: Local spreadsheet (Excel, Numbers, LibreOffice) + CSV

Edit in a **local** spreadsheet, then convert CSV → your JSON and upload.

**Workflow:**
1. **Export** current data to CSV (one-off: download JSON from Firebase, run a small script that writes `routes_S12.csv` and `pois_S12.csv` with the columns you care about).
2. **Edit** in Excel/Numbers/LibreOffice (add/change/delete rows).
3. **Save as CSV** (UTF-8).
4. **Script** converts CSV → app JSON format and uploads (or overwrites `prepopulated_pois_S12.json` and you run `upload_all_postcodes_to_firebase.py`).

**What’s needed:** A small script that:
- Reads your routes CSV and POI CSV,
- Builds the same structure as `prepopulated_pois_<district>.json` (postcodeAreas, routes by duration, POIs, center),
- Writes JSON and optionally uploads.

If you want this, we can add `csv_to_postcode_json.py` that takes e.g. `routes_S12.csv`, `pois_S12.csv`, and district, and outputs `prepopulated_pois_S12.json`.

**Pros:** Familiar spreadsheet UI, no Google, no 6‑min limit.  
**Cons:** Requires the CSV export and CSV→JSON script.

---

## Option 4: Lightweight web or desktop editor (later)

A simple CRUD app (e.g. local React/Next.js or a small Electron app) that:
- Lists postcodes and loads one at a time from Firebase (or local JSON),
- Lets you edit routes and POIs in forms/tables,
- Saves back to JSON and uploads to Firebase.

**Pros:** Tailored to your schema, no spreadsheet limits.  
**Cons:** More work to build and maintain.

---

## Summary

| Approach              | Best for              | Effort        |
|-----------------------|------------------------|---------------|
| **Edit TSV locally**  | Routes, any postcode   | Low (you have TSV + script) |
| **Edit JSON directly**| Few routes/POIs, one district | Low (editor + upload) |
| **Local spreadsheet + CSV** | Familiar sheet UI, no Google | Medium (need CSV→JSON script) |
| **Custom web/desktop app** | Long-term, many edits | High |

**Practical recommendation:** Use **Option 1 (edit TSV)** for routes and **Option 2 (edit JSON)** for small POI/route fixes; add **Option 3 (CSV + script)** if you prefer editing in Excel/Numbers and want to avoid JSON by hand.
