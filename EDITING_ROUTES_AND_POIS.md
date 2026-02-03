# Editing routes and POIs, then updating the database

**Recommended:** Keep using **Google Sheets** to edit. Then push only the postcode(s) you changed to Firebase.

---

## Best workflow: Edit in sheet → Update by postcode

### 1. (Optional) Load current data into the sheet

If you want to edit the same data that’s live in the app:

1. Open the WalkingWR Google Sheet.
2. Menu: **WalkingWR → Download POIs & routes from Database**.
3. The script loads the postcode JSON files from Firebase into the **Routes** and **pois_export** (or POI) sheets.

You can skip this if you’re only adding a few rows and the sheet already has the right structure.

---

### 2. Edit in the sheet

- **Routes:** Edit the **Routes** sheet (add/change/delete rows for the postcode you care about). Keep columns: Postcode, Duration (min), Name, Description, Waypoint 1–3, Distance, Duration (sec), Polyline.
- **POIs:** Edit the **pois_export** (or POI) sheet for that postcode (add/change/delete POIs). Keep columns: Postcode, Name, Latitude, Longitude, etc.

**Tips:**

- Avoid huge cells (e.g. pasting long text into Description or waypoints). Trim to a few hundred characters so “Update by postcode” doesn’t hit size limits.
- For one postcode, only change rows for that postcode so “Update by postcode” only rebuilds that district.

---

### 3. Push your edits to Firebase

1. Menu: **WalkingWR → Update Database by postcode...** (or **Update JSON for Specific Postcode**).
2. Enter the postcode(s) you edited, e.g. `S12` or `S12, S10, WF2`.
3. Click OK. The script builds JSON from the sheet for those districts (100% per-row accurate) and uploads `prepopulated_pois_S12.json` (etc.) to Firebase.
4. The app will use the new data next time it loads that postcode.

---

## When the sheet update might not finish (6‑min limit)

| Postcode size | What to do |
|---------------|------------|
| **Small/medium** (e.g. S10, S12, S36, WF2, &lt; ~2k routes) | Use **Update by postcode**; it usually finishes in one run. |
| **Large** (e.g. S3, S1 with 4k–28k routes) | Run **Update by postcode** once. If you see “Progress saved at chunk X/Y”, run it again for the same postcode; it resumes and then uploads. |
| **Very large and you edit often** | Consider editing the generator source (TSV) for that postcode, then: `build_postcode_json_from_tsv.py` for that district → `upload_all_postcodes_to_firebase.py` (or upload that one file). |

---

## Summary

| Step | Action |
|------|--------|
| 1 | (Optional) **Download POIs & routes from Database** so the sheet matches Firebase. |
| 2 | Edit **Routes** and/or **pois_export** for the postcode(s) you care about. |
| 3 | **Update Database by postcode...** → enter those postcode(s) → script uploads only those files to Firebase. |

So: **edit in Google Sheets as before; update the database by running “Update by postcode” for the districts you changed.** Use resume (run twice) for large postcodes, or the generator + upload path for very large ones if needed.
