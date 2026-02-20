# POI Cleaning Pipeline

## Overview

Pre-populated POI JSON files (`prepopulated_pois_WFx.json`) are generated from OpenStreetMap (OSM) and Geograph, then cleaned using `scripts/clean_pois_v2.py` before uploading to Firebase.

## How to Run

```bash
# Clean a single file (outputs to _cleaned.json)
python3 scripts/clean_pois_v2.py prepopulated_pois_WF2.json -o prepopulated_pois_WF2_cleaned.json

# Clean all WF districts
for i in $(seq 1 17); do
  python3 scripts/clean_pois_v2.py "prepopulated_pois_WF${i}.json" -o "prepopulated_pois_WF${i}_cleaned.json"
done
```

## Cleaning Rules Applied

### 1. Strip `(ID: osm_xxx)` suffix
OSM POIs without a real name get assigned `Type (ID: osm_12345)` during generation. The `(ID: osm_xxx)` part is stripped, leaving just the type label (e.g. "Post Box").

### 2. Remove boring infrastructure POIs
POIs that aren't interesting walking destinations are removed entirely:

| Removed Type | Example |
|---|---|
| Post Box | Royal Mail letterboxes |
| Car Park (unnamed only) | Generic parking areas — named ones like "Hepworth Gallery Car Park" are kept |
| Parking Space / Entrance | Individual bays and barriers |
| Bicycle / Motorcycle Parking | Bike racks |
| Waste Bin | Street bins |
| Grit Bin | Salt/grit boxes |
| Trolley Bay | Supermarket trolley returns |
| Compressed Air / Vacuum | Petrol station amenities |
| Storage Rental / Boat Storage | Self-storage units |

### 3. Fix brand capitalisation
A lookup table corrects known brand names that were incorrectly title-cased:

| Bad | Corrected |
|---|---|
| Whsmith | WHSmith |
| Mcdonald's | McDonald's |
| Kfc | KFC |
| Ee | EE |
| Atm | ATM |
| Bbq | BBQ |
| B & Q | B&Q |
| Natwest | NatWest |
| Evbox | EVBox |
| Inpost | InPost |
| Vets4pets | Vets4Pets |

Word-level corrections also fix brands mid-name (e.g. "Raja's Desi Grill & Bbq" → "Raja's Desi Grill & BBQ").

### 4. Remove generic type-only names
After stripping the OSM ID, some POIs are left with just a bare type label and no real name. These are removed if they're low-value types:

- Pitch, Bench, Track, Shelter, Information
- Fitness Station, Bicycle Repair Station
- Mounting Block, Wreck, Slipway
- Park (unnamed), Garden (unnamed), EVBox
- Telephone Kiosk, Telephone Exchange
- Toilets, Grave Yard, Parcel Locker
- Charging Station, Taxi, ATM, Photo Booth
- Car Wash, Vending Machine, Outdoor Seating, Recycling Point

**Note:** Named variants are kept (e.g. "Thornes Park", "Clarence Park", "Imo Car Wash").

### 5. Deduplicate chain stores
Chain stores with identical names within the same sector are capped at **2 per sector**, keeping the closest to the sector centre. This reduces repetition like 15x "Costa" or 13x "Subway" across sectors.

### 6. Strip `(est.)` suffix
Geograph-sourced POIs sometimes have an `(est.)` suffix (e.g. "Charity Shop – Bishopgate Walk The Ridings Centre (est.)"). This is stripped. The em-dash format ("Type – Location") is kept as it provides useful context.

## Results (Feb 2026)

| District | Before | After | Removed % |
|----------|--------|-------|-----------|
| WF1 | 7,408 | 5,082 | 31% |
| WF2 | 5,558 | 3,768 | 32% |
| WF3 | 2,030 | 1,159 | 42% |
| WF4 | 2,168 | 1,441 | 33% |
| WF5 | 594 | 372 | 37% |
| WF6 | 485 | 353 | 27% |
| WF7 | 990 | 640 | 35% |
| WF8 | 3,057 | 1,680 | 45% |
| WF9 | 1,271 | 971 | 23% |
| WF10 | 3,339 | 1,925 | 42% |
| WF11 | 965 | 593 | 38% |
| WF12 | 721 | 426 | 40% |
| WF13 | 3,470 | 1,967 | 43% |
| WF14 | 1,614 | 999 | 38% |
| WF15 | 1,315 | 805 | 38% |
| WF16 | 767 | 454 | 40% |
| WF17 | 5,651 | 3,295 | 41% |
| **Total** | **41,403** | **25,930** | **37%** |

## File Workflow

1. **Generate** raw POIs: `scripts/generate_sector_pois.py` → `prepopulated_pois_WFx.json`
2. **Clean** with this script: `scripts/clean_pois_v2.py` → `prepopulated_pois_WFx_cleaned.json`
3. **Rename** cleaned files to production names: `prepopulated_pois_WFx.json`
4. **Upload** to Firebase Storage
