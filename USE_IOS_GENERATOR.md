# Using iOS Generator (MapKit Routes) - RECOMMENDED

Since you want **MapKit routes** (more accurate than OSRM), use the iOS app generator instead of the Python script.

## Steps

1. **Build and run the app** in Xcode (DEBUG mode)

2. **Go to Profile → Settings** (gear icon in top right)

3. **Scroll to "Debug Tests" section**

4. **Tap "Generate POI Database"**

5. **Wait for completion** (10-20 minutes):
   - The app will fetch POIs from OSM and Geograph
   - Generate routes using **MapKit** (more accurate than OSRM)
   - Save to Documents directory and Desktop

6. **Copy the generated file**:
   - The file will be on your Desktop: `prepopulated_pois.json`
   - Or check the console for the exact path

7. **Commit to GitHub**:
   ```bash
   cd /Users/raihant/Documents/WalkingWR
   cp ~/Desktop/prepopulated_pois.json .
   git add prepopulated_pois.json
   git commit -m "Add pre-populated POI and route database (MapKit routes)"
   git push
   ```

## Advantages of iOS Generator

✅ **Uses MapKit** - More accurate routes for iOS  
✅ **Same POI sources** - OSM + Geograph (with your API key)  
✅ **Better route quality** - MapKit knows iOS walking paths better  
✅ **Already integrated** - Uses the same code as the app  

## Note

The Python script is stopped. If you want to use it instead (OSRM routes), you can restart it, but iOS generator is recommended for better accuracy.
