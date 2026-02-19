# Generate Database on Computer

You can generate the pre-populated database on your computer instead of running it in the iOS app!

## Quick Start

1. **Install Python dependencies:**
   ```bash
   pip3 install requests polyline
   ```

2. **Optional: Add Geograph API key** (for more POIs):
   - Get free API key from: https://www.geograph.org.uk/help/api
   - Edit `generate_database.py` and set `GEOGRAPH_API_KEY = "your_key_here"`

3. **Run the script:**
   ```bash
   cd /Users/raihant/Documents/WalkingWR
   python3 generate_database.py
   ```

4. **Wait for completion** (takes 10-20 minutes):
   - Fetches POIs from OSM and Geograph
   - Generates routes using OSRM (free routing service)
   - Outputs `prepopulated_pois.json`

5. **Commit to GitHub:**
   ```bash
   git add prepopulated_pois.json
   git commit -m "Add pre-populated POI and route database"
   git push
   ```

## What It Does

- **Fetches POIs** from:
  - OpenStreetMap (Overpass API) - free, no key needed
  - Geograph API - optional, requires free API key

- **Generates routes** using:
  - OSRM (Open Source Routing Machine) - free, no key needed
  - Creates routes for: 5, 10, 15, 20, 30, 45, 60 minutes
  - Up to 3 routes per duration per postcode area

- **Outputs** the same JSON format as the iOS generator

## Advantages Over iOS Generator

✅ **Faster** - No need to run in app  
✅ **Easier** - Just run a Python script  
✅ **No device needed** - Works on any computer  
✅ **Can run in background** - Takes 10-20 minutes  
✅ **Same result** - Identical JSON format  

## Troubleshooting

**"ModuleNotFoundError: No module named 'requests'"**
- Run: `pip3 install requests polyline`

**"OSRM route generation failed"**
- OSRM is a free public service, might be temporarily unavailable
- Script will continue with other routes
- Try again later if many routes fail

**"All OSM mirrors failed"**
- Check internet connection
- OSM servers might be temporarily down
- Script will continue with other postcodes

## Next Steps

After generating:
1. Review `prepopulated_pois.json` to verify it looks correct
2. Commit to GitHub
3. Update `PrePopulatedPOIService.swift` with GitHub URL
4. Test in app!
