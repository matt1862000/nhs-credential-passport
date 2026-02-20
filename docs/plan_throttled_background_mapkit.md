# Throttled background MapKit (MapKit + OSRM + GraphHopper; no HeiGIT)

## Goal
When the main pre-generation loop stops (55s cap or 10-attempt cap) and we still have 0 or 1 in-band routes, continue with a **throttled** background phase that uses **MapKit, public OSRM, and GraphHopper** — but **no ORS (HeiGIT) API**. Attempts are spaced out and only run when well under the MapKit rate limit.

## Constraint: No HeiGIT only
- **Use**: MapKit (primary), public OSRM (OpenStreetMap, free, no key), and GraphHopper (when API key is set) as fallbacks when MapKit is rate-limited.
- **Do not use**: OpenRouteService / HeiGIT API. Google Directions can be skipped in this phase (optional).

## Current behaviour (reference)
- **Main pregen loop** ([RouteSelectionView.swift](WalkingWR/Views/RouteSelectionView.swift) ~7015–7388): up to 10 attempts, 55s cap; pauses when `shouldPauseBackgroundGeneration()` (MapKit count ≥ 25); delay 0.1–0.5s between attempts.
- **Rate limiting** ([GoogleMapsService.swift](WalkingWR/Services/GoogleMapsService.swift)): `mapKitRateLimit = 45`, 60s window; `shouldPauseBackgroundGeneration()` at `currentCount >= 25`.
- **Routing today**: In `generateLocalRoute` → directions logic, order is ORS (HeiGIT) → OSRM → GraphHopper → MapKit when `useOSRM`; and when MapKit would wait, ORS then GraphHopper are used. We need to skip only ORS (HeiGIT) in the throttled phase; OSRM and GraphHopper remain allowed.

## Implementation steps

### 1. Skip HeiGIT (ORS) only for throttled phase (GoogleMapsService)
- Add a flag on `GoogleMapsService`, e.g. **`skipHeiGITForBackground: Bool`** (default `false`). When `true`, the internal directions logic must (skip only HeiGIT/ORS; keep OSRM and GraphHopper):
  - **In the `useOSRM` branch** (~6364–6472): do **not** call ORS (`getOpenRouteServiceWalkingDirections`). Go straight to **public OSRM** (`getOSRMWalkingDirections`). Keep the existing **GraphHopper** fallback after OSRM failure.
  - **In the “MapKit would wait → use ORS/GraphHopper” branch** (~6474–6538): do **not** call ORS; skip the ORS block. Still allow **GraphHopper** when `!graphHopperApiKey.isEmpty` so we use MapKit, OSRM, and GraphHopper without HeiGIT.
- **Call site**: In RouteSelectionView, before each throttled-phase call to `generateLocalRoute`, set `mapsService.skipHeiGITForBackground = true`; after the call (defer or finally), set it back to `false`.

**File**: [WalkingWR/Services/GoogleMapsService.swift](WalkingWR/Services/GoogleMapsService.swift) — add property; in the directions function, gate only the ORS (HeiGIT) calls on `!skipHeiGITForBackground`. Leave OSRM and GraphHopper unchanged.

### 2. Stricter “throttled phase” rate-limit check (GoogleMapsService)
- Add **`canRunThrottledBackgroundMapKit() async -> Bool`**: return true only when current MapKit count **&lt; 20** (e.g. constant `mapKitThrottledPhaseMaxCount = 20`).
- **File**: [WalkingWR/Services/GoogleMapsService.swift](WalkingWR/Services/GoogleMapsService.swift) (near `shouldPauseBackgroundGeneration`, ~5652).

### 3. Throttled phase after main pregen loop (RouteSelectionView)
- **Placement**: After the main pregen `while` loop and **after** cross-bucket fill; before the “Only X routes found - calling Google API for more POIs” branch (~7467).
- **Condition**: Enter only when `inBandRouteCount() < targetInBandRoutes` (0 or 1 in-band) after cross-bucket.
- **Loop**: Cap 3 attempts or 90s from `preGenTaskStart`. Before each attempt: check `shouldCancelBackgroundWork`; if `isGeneratingAdditionalRoute`, wait; call **`canRunThrottledBackgroundMapKit()`** — if false, wait 10–15s and re-check, then skip or exit. **Spacing**: 15–20s between attempts.
- **Each attempt**: Set `mapsService.skipHeiGITForBackground = true`, call `mapsService.generateLocalRoute(...)` with same params as main pregen (excludePlaceIds, excludePOIs, prefetchedPOIs, preferMultiWaypoint), then set `skipHeiGITForBackground = false`. Use same append/in-band logic; exit when `inBandRouteCount() >= targetInBandRoutes` or cap/cancel.
- **File**: [WalkingWR/Views/RouteSelectionView.swift](WalkingWR/Views/RouteSelectionView.swift).

### 4. Optional: skip Google Directions in throttled phase
- To avoid Google Directions usage in this phase, gate any Google Directions re-measure/fallback inside `generateLocalRoute` on a flag (e.g. same `skipHeiGITForBackground` or a separate `skipGoogleDirectionsForBackground`). When set, skip Google Directions for that call. Can be a follow-up if the change is large.

### 5. Logging
- Log when throttled phase starts: “Throttled MapKit+OSRM+GraphHopper phase starting (inBand &lt; 2, no HeiGIT)”.
- Log each attempt: skipped (rate limit), cancelled, or route added.
- Log when phase ends (reason).

## Summary
- **Throttled phase** = MapKit + public OSRM + GraphHopper (no ORS/HeiGIT; optional no Google in this phase).
- **GoogleMapsService**: Add `skipHeiGITForBackground` and gate only ORS (HeiGIT) calls in the directions path; add `canRunThrottledBackgroundMapKit()` (e.g. count &lt; 20).
- **RouteSelectionView**: After main pregen and cross-bucket, if in-band &lt; 2, run throttled loop (3 attempts, 15–20s apart, 90s cap), set `skipHeiGITForBackground` around each `generateLocalRoute` call, gated by `canRunThrottledBackgroundMapKit()` and cancel/+1 checks.
