# Version Information

## ⚠️ Current Status: EXPERIMENTAL

**Last Stable Release:** `1.9.15 (Build 186)`

**Current Version:** `2.1.5 (Build 294)`

The current codebase contains experimental changes and should **NOT** be used for production releases.

---

## Version History

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
- **294**: Current build (2.1.5) - Comprehensive waypoint distance enforcement for all routes and cached routes
