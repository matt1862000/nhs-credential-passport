# Quick Start: Generate Pre-Populated POI Database

## The Easy Way (5 minutes)

### Step 1: Add a Temporary Debug Button

Add this code to your `ProfileView.swift` (or any view) temporarily:

```swift
// Add this inside your ProfileView body, maybe in a debug section
#if DEBUG
Button("🔧 Generate POI Database") {
    Task {
        let generator = PrePopulatedPOIGenerator()
        do {
            let fileURL = try await generator.generateAndSaveDatabase()
            print("✅ Database generated!")
            print("📁 File location: \(fileURL.path)")
            // Show alert or notification here if you want
        } catch {
            print("❌ Error: \(error)")
        }
    }
}
.padding()
.background(Color.blue)
.foregroundColor(.white)
.cornerRadius(8)
#endif
```

### Step 2: Run the App

1. Build and run the app on a device or simulator
2. Navigate to where you added the button
3. Tap "Generate POI Database"
4. Wait 10-20 minutes (it queries 8 postcode areas for POIs, then generates routes for 7 durations each)
   - POI fetching: ~1-2 minutes (8 areas × 1 second delay)
   - Route generation: ~8-18 minutes (8 areas × 7 durations × ~0.5-2 seconds each)

### Step 3: Get the Generated File

**For Simulator:**
- The file is saved in the simulator's Documents directory
- Path will be printed in console: `~/Library/Developer/CoreSimulator/Devices/[DEVICE_ID]/data/Containers/Data/Application/[APP_ID]/Documents/prepopulated_pois.json`
- Or use Finder: Go to `~/Library/Developer/CoreSimulator/Devices/` and search for `prepopulated_pois.json`

**For Physical Device:**
- Connect device to Mac
- Open Xcode → Window → Devices and Simulators
- Select your device → Your app → "Download Container..."
- Open the downloaded container
- Navigate to `AppData/Documents/prepopulated_pois.json`

### Step 4: Add to Xcode Project

1. Copy `prepopulated_pois.json` to your project folder
2. Drag it into Xcode (into the `WalkingWR` folder)
3. Make sure:
   - ✅ "Copy items if needed" is checked
   - ✅ Your app target is selected
   - ✅ File is visible in Project Navigator

### Step 5: Remove Debug Button (Optional)

Remove the debug button code you added in Step 1.

### Step 6: Test It

1. Run the app
2. Navigate to a location near one of the postcode areas
3. Check console logs - you should see: `📦 PRE-POPULATED DB HIT! Found X POIs`

## What the Generator Does

The `PrePopulatedPOIGenerator`:
1. Loops through all 8 postcode areas
2. For each area:
   - Calls `GoogleMapsService.findNearbyPlaces()` with `skipGoogle: true` to fetch POIs
   - Generates routes for common durations (5, 10, 15, 20, 30, 45, 60 minutes)
3. POIs are fetched from:
   - ✅ OSM (Overpass API) - FREE
   - ✅ Geograph API - FREE  
   - ✅ Apple Maps - FREE
   - ❌ Google Places - SKIPPED (to save costs)
4. Routes are generated using the existing route generation logic
5. Converts all POIs and routes to the database format
6. Saves everything to a JSON file

## Expected Results

- **Total POIs**: Typically 200-500 POIs across all 8 areas
- **Total Routes**: ~24-56 routes (3 routes × 7-8 durations × 8 areas, but some may fail)
- **Generation time**: 10-20 minutes (depends on API response times - route generation takes longer)
- **File size**: Usually 200-800 KB (JSON, depends on number of routes)

## Troubleshooting

**"No POIs found for area X"**
- That postcode area might not have many POIs in OSM/Geograph
- This is normal - the database will still work, just with fewer POIs for that area

**"API rate limit"**
- The generator includes 1-second delays between requests
- If you still hit limits, increase the delay in `PrePopulatedPOIGenerator.swift`

**"File not found"**
- Check the console for the exact file path
- Make sure you're looking in the right Documents directory
- For simulator, the path changes each time you delete/reinstall the app

## Next Steps

Once you have the database file:
1. ✅ It's already in the correct format
2. ✅ The app will automatically load it from the bundle
3. ✅ POI fetching will be much faster for those postcode areas
4. ✅ You can update it anytime by re-running the generator

## Updating the Database

To refresh the database with new POIs:
1. Run the generator again (same steps as above)
2. Replace the old `prepopulated_pois.json` file in your project
3. Rebuild the app

The app will automatically use the new database on next launch.
