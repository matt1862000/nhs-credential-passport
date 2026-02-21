# POI threshold recommendation

## Objectives

1. **Route quality** – Enough POIs so we can build routes in the duration band (e.g. 90–110%) with at least the minimum waypoints (1 for 10 min, 2 for 11–20 min, 3 for 21–30 min, etc.).
2. **Cost** – Minimise Google Places calls; use free sources (Apple, OSM, Geograph, ORS) when sufficient.
3. **Speed** – Don’t block the first route; early exit when we have “enough” POIs.
4. **Resilience** – Downstream needs at least **10 candidates** after pre-filter (`minimumCandidates = 10`).

## Pipeline attrition

- **Canonical dedup** – Often removes 10–25% (duplicates across sources).
- **Restricted filter** – Removes nursery/playground/playcare (variable).
- **Coordinate validation** – Removes bad coords (more with ORS “POI” before our fix).
- **Pre-filter** – Keeps POIs in duration band (e.g. 40–95% for 10 min); can reject 30–50% in sparse areas.

So **raw POIs → usable candidates** is often **~60–80%** in good cases and **~50–65%** in marginal cases.  
To **reliably get ≥10 candidates**: 10 ÷ 0.6 ≈ **17** raw; 10 ÷ 0.75 ≈ **14** raw. So **15 raw** is the bare minimum; **20 raw** gives a safety margin.

## Implemented (Feb 2026)

- **Skip ORS** (`minimumPOIsRequired`): **20**
- **Skip Google** (`minimumPOIsForGoogle`): **40**
- First-run sufficient / hard-stop / pre-gen / prefetch break: **20**
- **Google fallback trigger**: **20** (call Google when &lt;20 from free+ORS; was 10)
- **Early exit** (parallel fetch + blending): **20** (return when ≥20 POIs; was 10)

## Current vs recommended (reference)

| Threshold | Previous | Implemented | Rationale |
|-----------|---------|-------------|-----------|
| **Skip ORS** (`minimumPOIsRequired`) | 15 (30 temp for testing) | **20** | 15 is on the edge: after dedup/restricted/coords we often get 8–12. 20 gives buffer (typically 12–16 usable), so 10–30 min routes with 1–3 waypoints are well covered. |
| **Skip Google** (`minimumPOIsForGoogle`) | 50 | **40** | With 40+ POIs from free + ORS we’re in a dense area; skipping Google here saves cost with little quality loss. Keeping 50 is also fine if you prefer fewer Google skips. |
| **First-route “sufficient POIs”** (message + hard-stop) | 15 | **20** (if you adopt 20 for skip-ORS) | Keeps messaging and behaviour aligned with the main fetch. |
| **Trigger Google fallback** (first-run) | 10 | **10** (no change) | Matches `minimumCandidates`; we need at least 10 to attempt a route. |
| **Early exit** (prefetch / first response) | 10 | **10** (no change) | Good balance for “return as soon as we have enough to try”. |

## Summary

- **20** for “enough to skip ORS” and “sufficient from free sources” improves robustness and keeps a clear margin above the 10-candidate need.
- **40** for “enough to skip Google” (optional) saves some Google calls in dense areas.
- Revert the **temporary 30** to the chosen production value (15 or 20).

If you prefer to minimise ORS/Google calls and accept a bit more risk in marginal areas, keep **15** and **50**. If you prefer route quality and resilience over a few extra ORS calls, use **20** and **40**.
