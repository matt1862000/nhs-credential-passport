# Testing the Unified Deduplication System

## Step 1: Build and Run Unit Tests

1. **Open Xcode** and open the `WalkingWR.xcodeproj` project
2. **Run Unit Tests:**
   - Press `Cmd+U` to run all tests
   - Or: Product → Test (⌘U)
   - Or: Click the test diamond icon next to `GoogleMapsServiceDeduplicationTests` class

3. **Verify Tests Pass:**
   - ✅ `testDeduplicatesLindaleMethodistChurchVariants`
   - ✅ `testDeduplicatesWarMemorialVariants`
   - ✅ `testDoesNotDeduplicateFarApartPOIs`
   - ✅ `testDeduplicatesByPlaceId`
   - ✅ `testDeduplicatesByLocation`

## Step 2: Manual Testing - Generate Routes

### Test Case 1: 10-Minute Route
1. **Open the app** and select a clinician
2. **Generate a 10-minute route**
3. **Check the console output** for the route summary:
   ```
   10min - route 1: POI1 → POI2 → ...
   10min - route 2: POI3 → POI4 → ...
   ...
   ```
4. **Look for duplicates:**
   - ❌ Should NOT see "War Memorial" appearing twice in the same route
   - ❌ Should NOT see "Lindale Methodist Church" appearing twice in the same route
   - ❌ Should NOT see "The Star Inn" appearing twice in the same route
   - ❌ Should NOT see the same POI appearing in multiple routes (cross-route duplicates)

### Test Case 2: 15-Minute Route
1. **Generate a 15-minute route**
2. **Check console** for route summary
3. **Verify no duplicates** appear

### Test Case 3: Multiple Route Durations
1. **Generate routes for:**
   - 10 minutes
   - 15 minutes
   - 20 minutes
   - 30 minutes
2. **Check console** after each generation
3. **Copy and paste the console output** to verify no duplicates

## Step 3: Check Console Logs

### What to Look For:

**✅ Good Signs:**
- `🔍 DEDUPLICATION: Checking X POIs for duplicates...`
- `✅ Route dedup [N/X]: Kept 'POI Name'`
- `🚫 Route dedup [N/X]: Removed 'POI Name' (duplicate: same placeId)`
- `🚫 Route dedup [N/X]: Removed 'POI Name' (duplicate: same location, X.Xm apart)`
- `🚫 Route dedup [N/X]: Removed 'POI Name' (duplicate: same cleaned name, X.Xm apart)`
- `🔒 FINAL SAFETY WRAPPER: Deduplicating route before return`
- `✅ Final deduplication: No duplicates found` or `Removed X duplicate(s)`

**❌ Warning Signs:**
- `⚠️ Potential duplicate not removed: 'POI1' vs 'POI2' - XXXm apart (threshold: 100m)`
  - This means two POIs with the same name are >100m apart (might be legitimate different locations)
- Seeing the same POI name twice in the route summary

## Step 4: Verify Specific Scenarios

### Scenario A: "War Memorial" Duplicates
**Before Fix:** "War Memorial" appeared as both "4 of 10" and "5 of 10"  
**After Fix:** Should only appear once per route

**Test:**
1. Generate a 10-minute route
2. Check if "War Memorial" appears multiple times
3. Check console for deduplication logs

### Scenario B: "Lindale Methodist Church" Cross-Route Duplicates
**Before Fix:** Appeared in both route 2 and route 6  
**After Fix:** Should only appear in one route

**Test:**
1. Generate a 10-minute route (generates 10 routes)
2. Check console output for all 10 routes
3. Verify "Lindale Methodist Church" doesn't appear in multiple routes

### Scenario C: "The Star Inn" Duplicates
**Before Fix:** Appeared as both "9 of 10" and "10 of 10"  
**After Fix:** Should only appear once per route

**Test:**
1. Generate a 15-minute route
2. Check if "The Star Inn" appears multiple times
3. Check console for deduplication logs

## Step 5: Monitor Console Output

### Expected Console Output Format:
```
═══════════════════════════════════════════════════════════
10min - route 1: SE3023 : Elizabeth II postbox on Brandy Carr Road, Kirkhamgate
10min - route 2: SE2922 : Lindale Methodist Church, Kirkhamgate
10min - route 3: The Star Inn
10min - route 4: Oriental Chef
10min - route 5: Village Stores
10min - route 6: Kirkhamgate Village Hall
10min - route 7: War Memorial
10min - route 8: Country Kitchen
10min - route 9: SE2922 : War memorial, Kirkhamgate
10min - route 10: SE3023 : Elizabeth II postbox on Brandy Carr Road, Kirkhamgate
═══════════════════════════════════════════════════════════
```

**Note:** If you see the same POI name in different routes (e.g., "War Memorial" in route 7 and route 9), check if they're actually different locations (>100m apart). The system should prevent same-name POIs within 100m from appearing in different routes.

## Step 6: Report Issues

If you find duplicates:

1. **Copy the console output** showing the duplicate
2. **Note which route(s)** contain the duplicate
3. **Check the console logs** for:
   - Deduplication messages
   - Distance between duplicates
   - Why they weren't removed
4. **Share:**
   - The route duration (10min, 15min, etc.)
   - The POI name(s) that are duplicated
   - The console output

## Step 7: Verify Chain Safeguard

### Test Chain POIs (Tesco, Co-op, Costa, etc.)
1. **Generate routes** in areas with chain stores
2. **Verify** that different chain locations (e.g., two Tesco stores) are NOT incorrectly merged
3. **Check console** for chain safeguard messages

## Quick Checklist

- [ ] Unit tests pass (Cmd+U)
- [ ] 10-minute route generated without duplicates
- [ ] 15-minute route generated without duplicates
- [ ] Console shows deduplication logs
- [ ] No "War Memorial" duplicates
- [ ] No "Lindale Methodist Church" cross-route duplicates
- [ ] No "The Star Inn" duplicates
- [ ] Console output shows clean route summaries

## If Tests Fail

1. **Check Xcode console** for compilation errors
2. **Verify** the test file is included in the target:
   - Select `GoogleMapsServiceDeduplicationTests.swift` in Xcode
   - Check "Target Membership" in File Inspector
   - Ensure "WalkingWR" target is checked
3. **Check** that `@testable import WalkingWR` works
4. **Verify** `isRouteDuplicate` is accessible (might need to change from `private` to `internal`)
