# How it practically works: 100% accurate data

Two ways to get postcode data into Firebase. When to use which, and exact steps.

---

## Quick reference

| Goal | What you do |
|------|-------------|
| **Change one postcode** (e.g. edited S12 in the sheet) | Sheet → **WalkingWR → Update JSON for Specific Postcode** → enter `S12`. |
| **Refresh all postcodes from generator** | 1) Generate TSV: `route_csv_generator/` → `pre_generated_routes_*.tsv`. 2) For each district: `python3 build_postcode_json_from_tsv.py --district S12 --routes-tsv route_csv_generator/pre_generated_routes_S12.tsv --poi-json prepopulated_pois_S12.json --output prepopulated_pois_S12.json`. 3) Upload: `python3 upload_all_postcodes_to_firebase.py`. |

**First-time mass upload:** You need existing `prepopulated_pois_<district>.json` for each district (for POIs + center). Get them by running "Update by postcode" once per district from the sheet, or by downloading from Firebase Storage. Then use those files as `--poi-json` when building from TSV.

---

## When to use which

| Situation | Use | Why |
|-----------|-----|-----|
| You changed one postcode in the sheet (e.g. added a route for S12) | **Sheet: Update by postcode** | One click, 100% accurate from sheet, no local scripts. |
| You want to refresh all postcodes or a very large one (e.g. S1) | **Generator → JSON → Upload** | No 6‑min limit; data comes straight from your TSV. |
| You regenerated routes (e.g. new `pre_generated_routes_*.tsv`) | **Generator → JSON → Upload** | Reuse POIs from existing JSON, replace routes from TSV. |

---

## Option 1: Single postcode update (Google Sheet)

**Use for:** One or a few postcodes after editing the Routes or POI sheet.

**Steps:**

1. Open the WalkingWR Google Sheet (with POI + Routes tabs).
2. Edit data for the postcode(s) you care about (e.g. add/change routes or POIs for S12).
3. Menu: **WalkingWR → Update JSON for Specific Postcode** (or **Update by postcode**).
4. Enter postcode(s), e.g. `S12` or `S12, S10`.
5. Script builds JSON from the sheet (per-row accurate), uploads `prepopulated_pois_S12.json` (etc.) to Firebase.
6. The app loads those files when the user picks that postcode.

**Limits:** 6‑minute execution. Very large postcodes (e.g. S1 with ~28k routes) may timeout; use Option 2 for those.

---

## Option 2: Mass upload / full refresh (generator → Firebase)

**Use for:** Refreshing many or all postcodes, or a postcode that’s too big for the sheet to finish in time.

**Idea:** Build JSON from your generator TSV (and existing POI JSON), then upload those JSON files to Firebase. No Google Sheet in the loop.

**Steps:**

### 2a. Get routes TSV per postcode

- In `route_csv_generator/`, run your usual route generation so you have:
  - `pre_generated_routes_S1.tsv`, `pre_generated_routes_S12.tsv`, … (one per postcode).

### 2b. Get POIs per postcode (for waypoint lookup)

- Reuse the POIs you already have in Firebase:
  - Download existing `prepopulated_pois_S12.json` (etc.) from Firebase Storage, **or**
  - Use a copy you have locally (e.g. from a previous sheet run).
- Each file has `postcodeAreas[0].pois`; we use that list to resolve waypoint names (e.g. "Stonecroft Medical centre (S12)") to POI objects.

### 2c. Build app-format JSON from TSV

- From the repo root, for each postcode you want to refresh:

```bash
# Build prepopulated_pois_S12.json from TSV + existing POI JSON
python3 build_postcode_json_from_tsv.py \
  --district S12 \
  --routes-tsv route_csv_generator/pre_generated_routes_S12.tsv \
  --poi-json prepopulated_pois_S12.json \
  --output prepopulated_pois_S12.json
```

- `--poi-json`: existing JSON for that postcode (we keep its POIs and center; we replace routes from the TSV).
- Repeat for S1, S3, S10, etc., or use a loop in a shell script.

### 2d. Upload to Firebase

- **Option A – Firebase Console (manual):**  
  Firebase Console → Storage → upload each `prepopulated_pois_XX.json` to the path the app expects (e.g. `prepopulated_pois_S12.json`).

- **Option B – Bulk upload (script):**  
  From the repo root, after building JSON files:

```bash
# Upload all prepopulated_pois_*.json in current directory to Firebase Storage
python3 upload_all_postcodes_to_firebase.py
```

  Uses the same credentials as `upload_to_firebase_storage.py` (Firebase Admin; see that script for setup). Each file is uploaded with the same filename (e.g. `prepopulated_pois_S12.json`).

- **Option C – One file at a time:**  
  Use `upload_to_firebase_storage.py` once per file (edit `FILE_PATH` / `STORAGE_PATH` in the script, or extend it to accept a path argument).

After upload, the app will load the new data when users select those postcodes.

---

## Summary

- **Single postcode / small edits:** Sheet → **Update by postcode** → 100% accurate from sheet, one or a few postcodes at a time.
- **Mass or very large postcodes:** Generator TSV + existing POI JSON → **build_postcode_json_from_tsv.py** → **upload** → 100% accurate from your generator, no 6‑min limit.

The script `build_postcode_json_from_tsv.py` (below) does TSV + existing JSON → app-format JSON so Option 2 is repeatable and consistent with what the sheet would produce.
