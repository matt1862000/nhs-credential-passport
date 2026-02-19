# Geograph POI Integration (Experimental)

## Overview

This branch adds Geograph.org.uk as a 4th POI source alongside Google, Apple Maps, and OpenStreetMap. Geograph provides 8+ million geotagged photos covering Great Britain and Ireland, which can serve as unique landmarks and points of interest.

## Implementation Details

### Changes Made

1. **Added `.geograph` to POISource enum** - New source type for tracking Geograph POIs
2. **Created `searchGeographForPOIs()` method** - Fetches POIs from Geograph Syndicator API
3. **Integrated into parallel fetch** - Geograph runs alongside Google/Apple/OSM in `findNearbyPlaces()`
4. **Added API key configuration** - `GEOGRAPH_API_KEY` in Info.plist
5. **Attribution handling** - Extracts photographer info and includes CC BY-SA 2.0 license notes

### API Details

- **Endpoint**: `https://api.geograph.org.uk/syndicator.php`
- **Format**: JSON
- **Parameters**: 
  - `key`: API key (required)
  - `location`: lat,lon coordinates
  - `distance`: radius in km
  - `perpage`: max 1000 results
  - `format=JSON&ll=1&thumb=1&desc=1`: Include lat/lon, thumbnails, descriptions

### License & Attribution

Geograph photos are licensed under **CC BY-SA 2.0**. When displaying Geograph data:
- Credit the photographer (stored in `vicinity` field if available)
- Credit Geograph.org.uk
- Include license information

## Setup Instructions

### 1. Request API Key

Visit https://www.geograph.org.uk/help/api and request an API key. You'll need to provide:
- Your project details
- Project URL
- Intended use case

### 2. Add API Key to Info.plist

Once you receive your API key, add it to `Info.plist`:

```xml
<key>GEOGRAPH_API_KEY</key>
<string>YOUR_API_KEY_HERE</string>
```

Currently, the key is set to an empty string as a placeholder.

### 3. Test the Integration

The Geograph source will automatically be included in POI searches when:
- API key is configured (non-empty)
- `findNearbyPlaces()` is called
- Parallel fetch runs (cache miss scenario)

## How It Works

1. **Cache Check**: First checks POI cache (same as other sources)
2. **Parallel Fetch**: If cache miss, fetches from all sources simultaneously:
   - Google Places (if enabled)
   - Apple Maps
   - OpenStreetMap
   - **Geograph** (if API key configured)
3. **Early Exit**: Stops when enough POIs found (6+) or timeout (3s)
4. **Deduplication**: Removes duplicate POIs across all sources
5. **Filtering**: Applies distance and restricted area filters

## Logging

Geograph results are logged with the 📸 emoji:
- `📸 Geograph: Found X POIs`
- `📸 Geograph: X POIs (+Y after dedup) @ Zs`
- Included in final summary: `Sources: Google=X, Apple=Y, OSM=Z, Geograph=W`

## Benefits

- **Free**: No cost (just requires API key)
- **Unique Landmarks**: Photos often capture landmarks not in other databases
- **Visual Reference**: Geotagged photos can help with navigation
- **Historical/Cultural**: Many photos document interesting local features

## Limitations

- **API Key Required**: Must request from Geograph
- **Not All Photos Are POIs**: Some photos are just landscapes (filtered by distance)
- **Response Time**: Can be slower than Apple Maps (10s timeout)
- **Coverage**: Primarily Great Britain and Ireland

## Testing

To test without an API key:
- Leave `GEOGRAPH_API_KEY` empty in Info.plist
- Geograph will be skipped gracefully (logged but no error)

To test with API key:
1. Add your API key to Info.plist
2. Trigger a POI search (cache miss scenario)
3. Check logs for Geograph results
4. Verify POIs include `.geograph` source

## Future Improvements

- Filter photos by "image class" to focus on actual POIs vs landscapes
- Store full attribution metadata separately
- Cache Geograph results separately (different expiry than other sources)
- Add UI indicator for Geograph-sourced POIs
