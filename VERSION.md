# Version Information

## ⚠️ Current Status: EXPERIMENTAL

**Last Stable Release:** `1.9.15 (Build 186)`

**Current Version:** `2.1.11 (Build 305)`

The current codebase contains experimental changes and should **NOT** be used for production releases.

---

## Version History

### 2.1.11 (Build 305) - Current
- Version/build bump
- Previous: 2.1.10 (Build 304)

### 2.1.10 (Build 304)
- Google primacy for "mins left": pill never reverts to OSM/cache after Google refresh (displayDurationMinutesForPill, hasReceivedGoogleRefreshForPill)
- startWalk() guard: if already walking, return immediately so duplicate calls don't overwrite Google route/pill
- Previous: 2.1.9 (Build 303)

### 2.1.9 (Build 303)
- Remove refresh button from route preview action bar
- Location: only re-request when missing or stale (>30s); stop clearing lock on RouteSelectionView appear
- Previous: 2.1.9 (Build 302)

### 2.1.8 (Build 301)
- New build for TestFlight/release
- Previous: 2.1.8 (Build 300)

### 2.1.8 (Build 300)
- Pre-populated routes: prefer 2+ waypoints for >10 min, fallback to 1-waypoint if none; prefer more direct (closer first POI)
- "xx mins left" pill updates when Google refresh completes (objectWillChange in updateCurrentRoute)
- Previous: 2.1.8 (Build 299)

### 2.1.8 (Build 299) - Ready for TestFlight
- Bump version/build for TestFlight submission
- Previous: 2.1.7 (Build 298)

### 2.1.7 (Build 298) - EXPERIMENTAL ⚠️
- **Fallbacks re-enabled**: `databaseOnlyMode = false` — DB miss/empty falls back to cache and live generation
- Pre-populated route telemetry: DB_CANDIDATES (hugeTravelCount), DB_RESULT, CACHE_RESULT
- Polyline invalid-char trim; WalkingRoute uses `trimmed`; in-app Gemini naming when DB has no name

### 2.1.7 (Build 297) - EXPERIMENTAL ⚠️
- **Google Apps Script: OSRM walking profile for accurate routes**:
  - Updated `generatePolylineForRoute` to use OSRM walking profile instead of driving
  - Now calculates actual walking distance and time (not driving distance converted to walking)
  - Routes use pedestrian-appropriate paths where available
- **iOS App: Accurate duration for pre-populated routes**:
  - Added travel time calculation from user's current location to postcode center
  - Pre-populated routes now show total duration: travel to center + route duration
  - Filters out routes where total duration exceeds requested duration (with tolerance)
  - Important for broad postcodes like S1 where center may be far from user's actual location
- **Not recommended for production use**

### 2.1.6 (Build 296) - EXPERIMENTAL ⚠️
- **Google Apps Script: Manual route editing and two-way sync**: 
  - "Convert to JSON" now prioritizes routes from Routes sheet over regeneration
  - Added dropdown validation to waypoint columns (G, H, I) filtered by postcode from column A
  - Waypoint dropdowns automatically show only POIs matching the route's postcode
  - Fixed generatePolylineForRoute to automatically find POI sheet (prioritizes "poi_export")
  - Fixed success message calculation to use database structure instead of poisByPostcode
  - Fixed validation clearing in exportRoutesToSheet to prevent errors
- **Not recommended for production use**

### 2.1.5 (Build 295) - EXPERIMENTAL ⚠️
- **Removed debug section from settings**: Removed all debug/test route functionality from the Settings view
- **Fixed Privacy section header**: Changed incorrect "Debug" header to "Privacy" in Settings
- **Not recommended for production use**

### 2.1.5 (Build 294) - EXPERIMENTAL ⚠️
- **Comprehensive waypoint distance enforcement**: Standardized all `removeCloseWaypoints` calls to 100m minimum distance across all route durations (10-60 min)
- **Cached route filtering**: Added synchronous distance filtering for cached/pre-populated routes to ensure waypoints are ≥100m apart even when loaded from cache
- **All code paths covered**: Added distance checks to route enhancement, micro-spur insertion, post-trim extension, and topology-safe route generation
- **Waypoint sorting protection**: Added distance check after waypoint sorting in `enhanceRouteWithWaypoints` to prevent sorting from bringing waypoints closer
- **Not recommended for production use**

### 2.1.5 (Build 293) - EXPERIMENTAL ⚠️
- **Waypoint distance enforcement**: Added `removeCloseWaypoints` calls after route extension and before final return to ensure minimum 100m spacing
- **Waypoint activation safeguard**: Added 30-second cooldown between waypoint activations to prevent accidental double-activation
- **Dynamic text sizing**: Banner and directions list text now scales down to fit without truncation (no ellipsis)
- **Color improvements**: Black backgrounds in dark mode, vibrant teal in light mode for better contrast and less washed-out appearance
- **Route Point filtering**: Filter out placeholder "Route Point" POIs from waypoint display
- **Not recommended for production use**

### 2.1.5 (Build 292) - EXPERIMENTAL ⚠️
- **Address-based road snapping**: Waypoints now snap to the road from their address, not just the nearest road
- Added `extractRoadName()` to parse road names from address strings
- Added `findRoadByName()` to query OSM for specific roads by name
- POIs like "Lindale Methodist Church" at "5A Brandy Carr Rd" now snap to "Brandy Carr Rd" instead of nearest road
- Falls back to nearest road if address road not found
- **Not recommended for production use**

### 2.1.4 (Build 291) - EXPERIMENTAL ⚠️
- **Road snapping fix**: Exclude service roads (driveways) from road snapping queries
- Two-stage Overpass query: prioritize main roads before footways/cycleways
- Additional tag filtering to skip `service=driveway` and `service=parking_aisle`
- MapKit fallback for Google Directions API quota/network errors
- Routes now stay on main roads instead of going into school driveways
- **Not recommended for production use**

### 2.0.20 (Build 290) - EXPERIMENTAL ⚠️
- Enhanced batch telemetry with roll-up assertions and dedup improvements

### 1.9.95 (Build 278) - EXPERIMENTAL ⚠️
- Fixed restricted POI filtering in route extension path
- Added `isRestrictedPOI()` check in `tryExtendRoute()` to prevent playcare/nursery/playground POIs from being added during route extension
- Added `isRestrictedPOI()` check in fallback mechanism to ensure restricted POIs are excluded even when falling back
- **Not recommended for production use**

### 1.9.15 (Build 186) - **LAST STABLE RELEASE** ✅
- Stable production release
- This is the version that should be used for production deployments

### 1.9.16+ (Build 187+) - EXPERIMENTAL ⚠️
- Experimental camera update optimizations
- Map lag and waypoint stall fixes (experimental)
- **Not recommended for production use**

---

## For Production Releases

Always use: **Version 1.9.15 (Build 186)**

To revert to the stable version:
```bash
git checkout 062eb41  # v1.9.16 commit (check if 1.9.15 tag exists)
# OR find the commit tagged as 1.9.15
```

---

## Build Numbers

- **186**: Last stable build (1.9.15)
- **187-289**: Experimental builds (do not use for production)
- **290**: Previous build (2.0.20) - Enhanced batch telemetry
- **291**: Previous build (2.1.4) - Road snapping fix, MapKit fallback
- **292**: Previous build (2.1.5) - Address-based road snapping
- **293**: Previous build (2.1.5) - Waypoint distance fixes, dynamic text sizing, color improvements
- **294**: Previous build (2.1.5) - Comprehensive waypoint distance enforcement for all routes and cached routes
- **295**: Previous build (2.1.5) - Removed debug section from settings
- **296**: Previous build (2.1.6) - Google Apps Script: Manual route editing and two-way sync
- **297**: Previous build (2.1.7) - OSRM walking profile + accurate pre-populated route durations
- **298**: Previous build (2.1.7) - Fallbacks re-enabled, telemetry, polyline trim, DB-only toggle off
- **299**: Previous build (2.1.8) - TestFlight
- **300**: Previous build (2.1.8) - Pre-populated routes, pill updates
- **301**: Previous build (2.1.8) - New build for release
- **302**: Previous build (2.1.9) - Pre-populated DB in-radius and center fix (WF2)
- **303**: Previous build (2.1.9) - Refresh button removed, location re-request only when stale
- **304**: Previous build (2.1.10) - Google primacy for mins left, startWalk guard
- **305**: Current build (2.1.11) - Version/build bump
