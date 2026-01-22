# Pre-Populated POI Database System

## Overview

The app can use a pre-populated database of **POIs and routes** from common NHS clinic postcode areas to speed up fetching. This eliminates API calls for frequently-visited locations and provides instant route options.

## Target Postcode Areas

The system pre-populates POIs for these postcode areas:
- **WF2 0GU** - Wakefield area
- **S5 7JT** - Sheffield area  
- **S35 0JW** - Sheffield area
- **S1 4JP** - Sheffield city centre
- **S5 7AU** - Sheffield area
- **S8 8BG** - Sheffield area
- **S35 1RQ** - Sheffield area
- **S11 9BF** - Sheffield area

## Database Format

The pre-populated database is a JSON file with the following structure:

```json
{
  "version": 1,
  "lastUpdated": "2026-01-21T00:00:00Z",
  "postcodeAreas": [
    {
      "postcode": "WF2 0GU",
      "centerLatitude": 53.7029,
      "centerLongitude": -1.5496,
      "radiusMeters": 2500,
      "pois": [
        {
          "placeId": "osm_123456",
          "name": "Village Stores",
          "latitude": 53.7013,
          "longitude": -1.5522,
          "types": ["shop", "convenience"],
          "vicinity": "Kirkhamgate",
          "source": "osm"
        }
      ]
    }
  ]
}
```

## How to Generate the Database

### ✅ **Option 1: Use the Built-in Generator (RECOMMENDED)**

The app includes `PrePopulatedPOIGenerator` that automatically fetches POIs for all postcode areas.

**Steps:**

1. **Add a debug button** (temporary - you can remove it after generating):
   
   Add this to your ProfileView or a debug view:
   ```swift
   Button("Generate POI Database") {
       Task {
           let generator = PrePopulatedPOIGenerator()
           do {
               let fileURL = try await generator.generateAndSaveDatabase()
               print("✅ Database saved to: \(fileURL.path)")
               // The file will be in the app's Documents directory
               // You can access it via Xcode's Device window or Files app
           } catch {
               print("❌ Error: \(error)")
           }
       }
   }
   ```

2. **Run the app** and tap the button. This will:
   - Query OSM and Geograph APIs for each postcode area
   - Collect all POIs (skipping Google to save costs)
   - Generate the JSON database file
   - Save it to the Documents directory

3. **Copy the generated file**:
   - Connect your device to Mac
   - Open Xcode → Window → Devices and Simulators
   - Select your device → Your app → Download Container
   - Find `prepopulated_pois.json` in the Documents folder
   - Copy it to your Xcode project

4. **Add to Xcode project**:
   - Drag `prepopulated_pois.json` into your Xcode project
   - Make sure "Copy items if needed" is checked
   - Ensure it's included in the app target

5. **Remove the debug button** (optional, after you've generated the file)

### Option 2: Export from Existing POI Cache

1. Run the app and visit each postcode area
2. Let the app fetch and cache POIs
3. Export the cached POIs using a debug/export function
4. Format them into the database JSON structure

### Option 3: Manual Collection from OSM/Geograph

1. For each postcode area:
   - Use Overpass API to query OSM POIs within radius
   - Use Geograph API to get photos/POIs
   - Combine and deduplicate
   - Format into database structure

### Option 4: Server-Side Generation Script

Create a script that:
1. Queries OSM Overpass API for each postcode area
2. Queries Geograph API for each postcode area
3. Deduplicates and merges results
4. Exports to JSON format
5. Hosts on server for download

## Implementation Details

### Storage

- **Downloaded database**: Stored in UserDefaults under key `prepopulatedPOIs_v1`
- **Bundled database**: File named `prepopulated_pois.json` in app bundle
- **Download flag**: `prepopulatedPOIsDownloaded` in UserDefaults

### Priority Order

**For POIs:**
1. **Pre-populated database** (fastest, no API calls)
2. **Regular cache** (UserDefaults, previously fetched POIs)
3. **API fetch** (OSM, Geograph, Apple Maps, Google)

**For Routes:**
1. **Pre-populated database** (fastest, no API calls)
2. **Regular cache** (UserDefaults, previously generated routes)
3. **API generation** (generate new routes from POIs)

### Integration

The pre-populated database is checked in `GoogleMapsService.findNearbyPlaces()` before checking the regular cache or making API calls.

## Usage

### Option 1: GitHub Hosting (Recommended) ⭐

1. Generate the JSON database file
2. Add it to your GitHub repository
3. Get the raw URL (click "Raw" button on GitHub)
4. Set `databaseURL` in `PrePopulatedPOIService.swift` to the GitHub raw URL
5. The app will download on first launch

**Example:**
```swift
return URL(string: "https://raw.githubusercontent.com/yourusername/WalkingWR/main/prepopulated_pois.json")
```

See `GITHUB_DATABASE_SETUP.md` for detailed instructions.

### Option 2: Bundling with App

1. Generate the JSON database file
2. Add `prepopulated_pois.json` to your Xcode project
3. Ensure it's included in the app bundle
4. Set `databaseURL` to `nil` in `PrePopulatedPOIService.swift`

### Option 3: Your Own Server

1. Host the JSON file on your server
2. Set `databaseURL` in `PrePopulatedPOIService.swift` to your server URL
3. The app will download on first launch

### Updating the Database

- **Bundled**: Update the JSON file and rebuild the app
- **Server**: Update the file on the server, increment the `version` field, and the app will re-download

## Example Database Generation Script (Python)

```python
import json
import requests
from datetime import datetime

# Postcode areas with their center coordinates
postcode_areas = [
    {"postcode": "WF2 0GU", "lat": 53.7029, "lon": -1.5496, "radius": 2500},
    {"postcode": "S5 7JT", "lat": 53.4109, "lon": -1.4603, "radius": 2500},
    # ... add other postcodes
]

def fetch_osm_pois(lat, lon, radius):
    """Query Overpass API for POIs"""
    query = f"""
    [out:json][timeout:30];
    (
      node["amenity"](around:{radius},{lat},{lon});
      node["shop"](around:{radius},{lat},{lon});
      node["tourism"](around:{radius},{lat},{lon});
      way["amenity"](around:{radius},{lat},{lon});
      way["shop"](around:{radius},{lat},{lon});
      way["tourism"](around:{radius},{lat},{lon});
    );
    out center;
    """
    # Make request to Overpass API
    # Parse and return POIs
    pass

def fetch_geograph_pois(lat, lon, radius):
    """Query Geograph API for POIs"""
    # Make request to Geograph API
    # Parse and return POIs
    pass

def generate_database():
    database = {
        "version": 1,
        "lastUpdated": datetime.utcnow().isoformat() + "Z",
        "postcodeAreas": []
    }
    
    for area in postcode_areas:
        osm_pois = fetch_osm_pois(area["lat"], area["lon"], area["radius"])
        geograph_pois = fetch_geograph_pois(area["lat"], area["lon"], area["radius"])
        
        # Combine and deduplicate
        all_pois = osm_pois + geograph_pois
        # Apply deduplication logic here
        
        database["postcodeAreas"].append({
            "postcode": area["postcode"],
            "centerLatitude": area["lat"],
            "centerLongitude": area["lon"],
            "radiusMeters": area["radius"],
            "pois": all_pois
        })
    
    # Save to JSON file
    with open("prepopulated_pois.json", "w") as f:
        json.dump(database, f, indent=2)

if __name__ == "__main__":
    generate_database()
```

## Benefits

1. **Faster POI fetching** - No API calls needed for common areas
2. **Reduced API costs** - Fewer Google Places API calls
3. **Better offline support** - POIs available even without internet
4. **Consistent data** - Same POIs for all users in these areas

## Next Steps

1. Generate the initial database JSON file for the 8 postcode areas
2. Either bundle it with the app or host it on a server
3. Test that POI fetching uses the pre-populated database
4. Monitor cache hit rates to verify it's working
