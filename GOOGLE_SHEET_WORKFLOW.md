# Google Sheet workflow: Firebase ↔ Sheet

Three parts: **download** (one-way), **edit**, **upload**.

---

## 1. Download: Firebase → Sheet (one-way only)

**When you open the sheet**
- The script runs automatically.
- It **downloads** POIs and routes from Firebase Storage (no upload).
- It fills:
  - **POI sheet** (e.g. pois_export) with all POIs
  - **Routes sheet** with all routes (and “no routes yet” for postcodes with no routes)
- You see a toast: “Loaded POIs and Routes from Firebase”.

**Manual refresh**
- **WalkingWR → Sync from Firebase**
- Same one-way download: Firebase → sheet. Replaces POI sheet and Routes sheet with current Firebase data. No upload.

---

## 2. Edit: Change POIs and routes in the sheet

**Edit POIs**
- Go to the **POI sheet** (first tab or “pois_export”).
- Edit cells (name, lat/lon, types, etc.) as needed. No special menu.

**Edit routes**
- **WalkingWR → Export Routes for Manual Editing**
- This rebuilds the **Routes** tab with dropdowns so you can change waypoints per route.
- Edit waypoints in the dropdowns; optionally use **Generate Polyline for Selected Route** on a row to refresh the polyline after changing waypoints.

So: **POI sheet** = edit POIs directly; **Routes sheet** = edit routes (use “Export Routes for Manual Editing” first if you want the dropdown layout).

---

## 3. Upload: Sheet → Firebase

After editing, push changes **back to Firebase**:

**Option A – Upload one postcode (POIs + routes)**
- **WalkingWR → Upload postcode to Firebase...**
- Enter the postcode you changed (e.g. S1, S5, WF2).
- The script reads that postcode’s POIs and routes from the sheet, builds the JSON, and **uploads** it to Firebase as `prepopulated_pois_<postcode>.json`.

**Option B – You only edited routes**
- **WalkingWR → Import Routes from Sheet**
- Reads the **Routes** sheet, updates the in-memory database from your edits, then **uploads** to Firebase (per-postcode files if configured).

Use **Option A** when you changed POIs and/or routes for a postcode. Use **Option B** when you only changed routes in the Routes sheet and want those changes pushed to Firebase.

---

## Summary

| Step | What happens | Direction |
|------|----------------|-----------|
| **Open sheet** | Auto-download POIs + routes from Firebase into POI sheet and Routes sheet | Firebase → Sheet |
| **Sync from Firebase** | Same as open: refresh POI + Routes sheets from Firebase | Firebase → Sheet |
| **Edit POIs** | Edit cells in POI sheet | — |
| **Export Routes for Manual Editing** | Rebuild Routes sheet with dropdowns for editing waypoints | — |
| **Edit routes** | Change waypoints (and optionally regenerate polyline) | — |
| **Upload postcode to Firebase...** | Build JSON from sheet for one postcode and upload to Firebase | Sheet → Firebase |
| **Import Routes from Sheet** | Read Routes sheet, update database, upload to Firebase | Sheet → Firebase |

**One-way sync** = only “Open sheet” and “Sync from Firebase”. They never upload; they only download from Firebase into the sheet.
