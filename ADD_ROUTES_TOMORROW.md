# Adding Routes Tomorrow

The POI database has been generated with **12,083 POIs** across 8 postcode areas. Routes will be added tomorrow using MapKit on your phone.

## Current Status

✅ **POIs**: Complete (12,083 POIs from OSM + Geograph)  
⏳ **Routes**: Will be added tomorrow

## Tomorrow: Add Routes with MapKit

### Option 1: Use iOS Generator (Recommended)

1. **Run the app** on your phone (DEBUG mode)
2. **Go to Profile → Settings → Debug Tests**
3. **Tap "Generate POI Database"**
4. The generator will:
   - Load the existing POIs from the database
   - Generate routes using **MapKit** for each postcode area
   - Add routes for: 5, 10, 15, 20, 30, 45, 60 minutes
   - Save the updated database

### Option 2: Modify Generator to Add Routes Only

The `PrePopulatedPOIGenerator` can be modified to:
- Load existing `prepopulated_pois.json`
- Generate routes for each area (using existing POIs)
- Update the database with routes
- Save back to file

## File Location

- **Project root**: `/Users/raihant/Documents/WalkingWR/prepopulated_pois.json` (3.3MB)
- **Bundled**: `/Users/raihant/Documents/WalkingWR/WalkingWR/prepopulated_pois.json`

Both files are ready. After adding routes tomorrow, commit to GitHub!
