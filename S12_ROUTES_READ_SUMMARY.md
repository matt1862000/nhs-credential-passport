# S12 / large-block routes read – summary (so we don’t go in circles)

## Root cause

The **Routes** sheet has some cells (duration, name, description, waypoint 1–3) whose content is so large that:

- `getValues(25 rows, 1 col)` throws **“Requested data exceeds the maximum allowed size”**.
- Even `getDisplayValues(1 row, 1 col)` can throw for those cells.

So any batch that includes those cells can fail. The only way to read them is **per-cell** `getDisplayValue()`, which is very slow (many round-trips per chunk).

## What we’ve tried (in order)

| Approach | Result |
|----------|--------|
| **First row for chunk** (use first row’s duration/name/desc/waypoints for all 25 rows) | Fast, fits in 6 min, but **wrong data** for most rows. |
| **Full chunk** `getDisplayValues(start, 2, end, 9)` (25×8) | Fails: 25×8 still exceeds size. |
| **Two-part read** (cols 2–5, then 7–9, 25 rows each) | Fails: 25×4 or 25×3 still exceeds. |
| **10-row sub-chunks** (same two parts, 10 rows at a time) | Fails: 10×4 or 10×3 still exceeds (or first sub-chunk throws, so we never build `chunkLeftMatrix`). |
| **Single-column reads** (25 rows × 1 col per call, with halve + per-cell fallback) | If 25×1 works → fast and accurate. If it doesn’t, we fall back to per-cell **inside** `readOneCol` → chunk still builds but takes ~2.5+ min per chunk → timeout over 68 chunks. |

When the “batch” path fails, we fall back to the **column-by-column loop** (getValues → halve → getDisplayValues → halve → getDisplayValue per cell). That path is **accurate** but does hundreds of per-cell calls per chunk → timeout.

## The real fix (no circles)

We are not wrong in circles; the logic is consistent. The bottleneck is **data size in the sheet**:

1. **Clean the sheet**  
   Make sure duration, name, description, and waypoint 1–3 columns do **not** contain pasted polylines or huge text. Then:
   - `getDisplayValues(start, 2, end, 9)` or single-column 25×1 reads should succeed.
   - Script stays under 6 min and data is accurate.

2. **If you can’t clean the sheet**  
   You have two choices:
   - **Accurate but slow:** keep current behaviour (batch → fallback to per-cell); it will timeout on S12 until the sheet is cleaned.
   - **Fast but approximate:** re-enable “first row for chunk” for large blocks only; data will be wrong for most rows but run will finish in 6 min.

## Current code paths (large block, one chunk)

1. **Build `chunkLeftMatrix`**  
   For each of columns 2, 4, 5, 7, 8, 9 we call `readOneCol(col)`:
   - Try `getDisplayValues(start, col, end, col)` (25×1).
   - On size error, halve batch (12, 6, 3, 1) and retry same range.
   - If even 1 row fails, use `getDisplayValue()` per cell for the rest of the column.
   - If all six columns return 25 values, we build `chunkLeftMatrix` and use it for left cols (accurate).

2. **If `chunkLeftMatrix` is null**  
   (One of `readOneCol(2/4/5/7/8/9)` returned null – should be rare; usually we build it but slowly.)  
   We fall back to the **column loop** (getValues → halve → getDisplayValues → per-cell), which is accurate but can timeout.

3. **Polyline**  
   Read in 20-row (or 15-row fallback) batches; unchanged.

## How to confirm which path ran

- If you see **“Col … (c=…): large block → full chunk (accurate)”** for duration, name, description, waypoints → the batch path worked and we used `chunkLeftMatrix`.
- If you see **“10 rows exceeded …”** and **“getDisplayValues(1) failed → getDisplayValue() per cell”** → the batch path failed (or `chunkLeftMatrix` was null) and we used the column loop; expect possible timeout.

A single log line when `chunkLeftMatrix` is null is added in the script so we know we fell through to the column loop.
