# Version Information

## ⚠️ Current Status: EXPERIMENTAL

**Last Stable Release:** `1.9.15 (Build 186)`

**Current Version:** `2.1.5 (Build 292)`

The current codebase contains experimental changes and should **NOT** be used for production releases.

---

## Version History

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
- **292**: Current build (2.1.5) - Address-based road snapping
