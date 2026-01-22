# Version Information

## ⚠️ Current Status: EXPERIMENTAL

**Last Stable Release:** `1.9.15 (Build 186)`

**Current Version:** `1.9.95 (Build 278)`

The current codebase contains experimental changes and should **NOT** be used for production releases.

---

## Version History

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
- **187-277**: Experimental builds (do not use for production)
- **278**: Current build (1.9.95) - Restricted POI filtering fix
