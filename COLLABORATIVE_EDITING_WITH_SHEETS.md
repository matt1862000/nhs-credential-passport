# Collaborative editing with Google Sheets → Firebase

Keep **Google Sheets as the place everyone edits**; use a clear **publish** step to push changes to the database.

---

## Why keep Sheets

- **Multiple people** can edit the same Routes and POI sheet at once (real-time, comments, sharing).
- **No local files** – one source of truth in the cloud.
- **Version history** – Sheet keeps “See version history” so you can revert if needed.
- **Familiar** – no new tools for editors.

---

## Simple workflow for the team

### 1. Everyone edits in the sheet

- Share the WalkingWR Google Sheet with your editors (e.g. “Anyone with the link can edit” or specific people).
- People edit **Routes** and/or **pois_export** (add/change/delete routes and POIs).
- They can note in a cell or in chat which **postcode(s)** they changed (e.g. “Updated S12 and S10”).

### 2. One person (or a designated “publisher”) pushes to Firebase

When you’re ready to update the app:

1. Open the same WalkingWR Google Sheet.
2. Menu: **WalkingWR → Update Database by postcode...**
3. Enter the postcode(s) that were edited, e.g. `S12, S10, WF2`.
4. Click OK. The script builds JSON from the sheet for those districts and uploads to Firebase.
5. The app uses the new data the next time users load those postcodes.

**Who runs it:** Anyone who has **edit access to the Sheet** and can open the Apps Script menu. No Firebase credentials needed in the sheet – the script uses Script Properties (FIREBASE_SERVICE_ACCOUNT) that you set once.

---

## Tips so “Update by postcode” succeeds

- **One or a few postcodes per run** – e.g. `S12, S10` is fine; avoid “Update all” from the sheet for very large sets (use the generator + upload path for that).
- **Trim heavy cells** – Keep Description and waypoint text short (e.g. under a few hundred characters) so the script doesn’t hit size limits.
- **Large postcodes (e.g. S1, S3):** If you see “Progress saved at chunk X/Y”, run **Update by postcode** again for the same postcode; it resumes and then uploads.
- **Very large postcodes (e.g. S1):** If you only changed a small part, still run “Update by postcode” for S1 and use resume (run twice) if needed. For a full refresh of S1, use the generator TSV + `build_postcode_json_from_tsv.py` + upload instead.

---

## Optional: “Download from DB” before big edits

If you want the sheet to match what’s currently in the app before people edit:

1. **WalkingWR → Download POIs & routes from Database** (loads Firebase → sheet).
2. Then everyone edits as usual.
3. When ready, **Update Database by postcode...** for the changed districts.

Use this when you’ve previously updated Firebase from the generator or another source and want the sheet to match.

---

## Summary

| Step | Who | What |
|------|-----|------|
| Edit | Anyone with sheet access | Edit Routes / pois_export; note which postcodes changed. |
| Publish | One person (or whoever’s on duty) | **Update Database by postcode...** → enter those postcodes → script uploads to Firebase. |

Sheets stays the **collaborative editor**; **Update by postcode** is the **publish** step that updates the database. No alternative needed for collaboration – just a clear rule: “when we’re ready, run Update by postcode for the postcodes we changed.”
