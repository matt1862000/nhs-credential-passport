#!/usr/bin/env python3
"""
Generate pre-populated POI and route database for WalkingWR app
This script can be run on any computer with Python 3.7+

Usage:
    python3 generate_database.py

Requirements:
    pip install requests polyline

The script will:
1. Fetch POIs from OSM Overpass API and Geograph API (only cacheable sources)
2. Generate routes using OSRM (free, open-source routing - uses OpenStreetMap data)
3. Output prepopulated_pois.json in the correct format

IMPORTANT: 
- Only caches OSM and Geograph POIs (Apple POIs not cached - Apple restriction)
- Routes generated with OSRM (not MapKit - Apple doesn't allow caching MapKit routes)
- All data is open-source and cacheable
"""

import json
import requests
import time
import math
from datetime import datetime
from typing import List, Dict, Optional, Tuple
import polyline  # pip install polyline

# Postcode areas with their center coordinates
POSTCODE_AREAS = [
    ("WF2 0GU", 53.7029, -1.5496),  # Wakefield area
    ("S5 7JT", 53.4109, -1.4603),   # Sheffield area (Northern General Hospital)
    ("S35 0JW", 53.4200, -1.4800),  # Sheffield area
    ("S1 4JP", 53.3800, -1.4700),   # Sheffield city centre
    ("S5 7AU", 53.4100, -1.4500),   # Sheffield area
    ("S8 8BG", 53.3500, -1.4800),   # Sheffield area
    ("S35 1RQ", 53.4300, -1.4900),  # Sheffield area
    ("S11 9BF", 53.3700, -1.5000)   # Sheffield area
]

RADIUS_METERS = 2500
DURATIONS_TO_GENERATE = [5, 10, 15, 20, 30, 45, 60]
WALKING_SPEED_M_PER_MIN = 80  # Average walking speed

# OSM Overpass API endpoints (try multiple mirrors for reliability)
OSM_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
    "https://z.overpass-api.de/api/interpreter",
    "https://overpass.openstreetmap.ru/api/interpreter",
]

# Geograph API (optional - requires API key)
GEOGRAPH_API_KEY = "df200a5f61"  # Get from https://www.geograph.org.uk/help/api
GEOGRAPH_BASE_URL = "https://api.geograph.org.uk/syndicator.php"

# OSRM routing service (free, open-source)
# Note: Public server uses "driving" profile, we convert to walking time
OSRM_BASE_URL = "http://router.project-osrm.org/route/v1/driving"


def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calculate distance between two coordinates in meters"""
    R = 6371000  # Earth radius in meters
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    
    a = math.sin(delta_phi / 2) ** 2 + \
        math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    
    return R * c


def fetch_osm_pois(lat: float, lon: float, radius: int) -> List[Dict]:
    """Fetch POIs from OpenStreetMap Overpass API"""
    print(f"   🗺️ Fetching OSM POIs...")
    
    # Overpass QL query for POIs within radius
    query = f"""
    [out:json][timeout:30];
    (
      node["amenity"](around:{radius},{lat},{lon});
      node["shop"](around:{radius},{lat},{lon});
      node["tourism"](around:{radius},{lat},{lon});
      node["historic"](around:{radius},{lat},{lon});
      node["leisure"](around:{radius},{lat},{lon});
      way["amenity"](around:{radius},{lat},{lon});
      way["shop"](around:{radius},{lat},{lon});
      way["tourism"](around:{radius},{lat},{lon});
      way["historic"](around:{radius},{lat},{lon});
      way["leisure"](around:{radius},{lat},{lon});
    );
    out center;
    """
    
    for mirror in OSM_MIRRORS:
        try:
            response = requests.post(mirror, data=query, timeout=30)
            if response.status_code == 200:
                data = response.json()
                pois = []
                
                for element in data.get("elements", []):
                    if element.get("type") == "node":
                        lat_elem = element.get("lat")
                        lon_elem = element.get("lon")
                    elif element.get("type") == "way" and "center" in element:
                        lat_elem = element["center"].get("lat")
                        lon_elem = element["center"].get("lon")
                    else:
                        continue
                    
                    if lat_elem is None or lon_elem is None:
                        continue
                    
                    # Get name
                    tags = element.get("tags", {})
                    name = tags.get("name") or tags.get("addr:housename") or "Unnamed"
                    
                    # Get types
                    types = []
                    for key in ["amenity", "shop", "tourism", "historic", "leisure"]:
                        if key in tags:
                            types.append(tags[key])
                    
                    # Get vicinity (address)
                    vicinity = tags.get("addr:street") or tags.get("addr:city") or None
                    
                    pois.append({
                        "placeId": f"osm_{element.get('id')}",
                        "name": name,
                        "latitude": lat_elem,
                        "longitude": lon_elem,
                        "types": types,
                        "vicinity": vicinity,
                        "source": "osm",
                        "rating": None  # Optional rating field (can be edited in spreadsheet)
                    })
                
                print(f"   ✅ Found {len(pois)} OSM POIs")
                return pois
                
        except Exception as e:
            print(f"   ⚠️ OSM mirror {mirror} failed: {e}")
            continue
    
    print(f"   ❌ All OSM mirrors failed")
    return []


def fetch_geograph_pois(lat: float, lon: float, radius: int) -> List[Dict]:
    """Fetch POIs from Geograph API"""
    if not GEOGRAPH_API_KEY:
        print(f"   ⏭️ Skipping Geograph (no API key)")
        return []
    
    print(f"   📸 Fetching Geograph POIs...")
    
    try:
        # Geograph API uses distance in km
        distance_km = radius / 1000.0
        
        url = f"{GEOGRAPH_BASE_URL}"
        params = {
            "key": GEOGRAPH_API_KEY,
            "location": f"{lat},{lon}",
            "distance": distance_km,
            "perpage": 100,
            "format": "JSON",
            "ll": 1,
            "thumb": 1,
            "desc": 1
        }
        
        response = requests.get(url, params=params, timeout=30)
        if response.status_code == 200:
            data = response.json()
            items = data.get("items", [])
            
            pois = []
            for item in items:
                lat_elem = float(item.get("lat", 0))
                lon_elem = float(item.get("long", 0))
                
                if lat_elem == 0 and lon_elem == 0:
                    continue
                
                name = item.get("title", "Unnamed")
                # Extract grid reference from name if present (e.g., "SE2922 : The Star Inn")
                if " : " in name:
                    name = name.split(" : ", 1)[1]
                
                pois.append({
                    "placeId": f"geograph_{item.get('guid', '')}",
                    "name": name,
                    "latitude": lat_elem,
                    "longitude": lon_elem,
                    "types": ["geograph"],
                    "vicinity": None,
                    "source": "geograph",
                    "rating": None  # Optional rating field (can be edited in spreadsheet)
                })
            
            print(f"   ✅ Found {len(pois)} Geograph POIs")
            return pois
            
    except Exception as e:
        print(f"   ❌ Geograph API failed: {e}")
        return []
    
    return []


def deduplicate_pois(pois: List[Dict], origin_lat: float, origin_lon: float) -> List[Dict]:
    """Remove duplicate POIs (same name within 200m)"""
    seen = set()
    deduplicated = []
    
    for poi in pois:
        # Create a key based on name and location (rounded to ~20m)
        name_key = poi["name"].lower().strip()
        lat_rounded = round(poi["latitude"], 4)  # ~10m precision
        lon_rounded = round(poi["longitude"], 4)
        key = (name_key, lat_rounded, lon_rounded)
        
        if key not in seen:
            # Check if too close to another POI with same name
            is_duplicate = False
            for existing in deduplicated:
                if existing["name"].lower().strip() == name_key:
                    distance = haversine_distance(
                        poi["latitude"], poi["longitude"],
                        existing["latitude"], existing["longitude"]
                    )
                    if distance < 200:  # Same name within 200m = duplicate
                        is_duplicate = True
                        break
            
            if not is_duplicate:
                seen.add(key)
                deduplicated.append(poi)
    
    return deduplicated


def is_restricted_poi(poi: Dict) -> bool:
    """
    Check if a POI is restricted (childcare, playground, etc.)
    These should not be included in walking routes.
    Matches the logic in GoogleMapsService.swift isRestrictedPOI()
    """
    name = poi.get("name", "").lower()
    types = poi.get("types", [])
    
    # Normalize name: remove apostrophes and spaces for matching
    name_normalized = name.replace("'", "").replace("'", "").replace(" ", "")
    
    # Restricted name patterns (childcare facilities, playgrounds)
    restricted_name_patterns = [
        "playcare", "daycare", "preschool", "nursery", "kindergarten",
        "childcare", "playground", "playarea", "playgroup", "creche",
        "cjsplaycare"  # Specific case that was missed
    ]
    
    # Check normalized name
    for pattern in restricted_name_patterns:
        if pattern in name_normalized:
            print(f"   🏫 ❌ Restricted POI: '{poi.get('name')}' (matched: '{pattern}')")
            return True
    
    # Also check original name
    for pattern in ["playcare", "daycare", "preschool", "nursery", "kindergarten", 
                    "childcare", "playground", "play area", "playgroup", "creche"]:
        if pattern in name:
            print(f"   🏫 ❌ Restricted POI: '{poi.get('name')}' (matched: '{pattern}')")
            return True
    
    # Restricted types
    restricted_types = {
        "kindergarten", "nursery", "playground", "preschool", "daycare", "childcare"
    }
    
    for t in types:
        if t.lower() in restricted_types:
            print(f"   🏫 ❌ Restricted POI: '{poi.get('name')}' (type: '{t}')")
            return True
    
    return False


def filter_restricted_pois(pois: List[Dict]) -> List[Dict]:
    """Filter out restricted POIs (childcare, playgrounds, etc.)"""
    filtered = [poi for poi in pois if not is_restricted_poi(poi)]
    removed_count = len(pois) - len(filtered)
    if removed_count > 0:
        print(f"   🏫 Filtered {removed_count} restricted POIs (playcare/nursery/playground)")
    return filtered


def generate_route_osrm(origin_lat: float, origin_lon: float, 
                       waypoints: List[Tuple[float, float]], 
                       target_duration_min: int) -> Optional[Dict]:
    """Generate a route using OSRM routing service"""
    try:
        # Build coordinates string: origin;waypoint1;waypoint2;...;origin (loop back)
        coords = [f"{origin_lon},{origin_lat}"]
        for wp_lat, wp_lon in waypoints:
            coords.append(f"{wp_lon},{wp_lat}")
        coords.append(f"{origin_lon},{origin_lat}")  # Return to origin
        
        coords_str = ";".join(coords)
        
        url = f"{OSRM_BASE_URL}/{coords_str}"
        params = {
            "overview": "full",
            "geometries": "polyline",
            "steps": "true"
        }
        
        response = requests.get(url, params=params, timeout=30)
        if response.status_code == 200:
            data = response.json()
            
            if data.get("code") == "Ok" and data.get("routes"):
                route = data["routes"][0]
                duration_sec = route.get("duration", 0)
                distance_m = route.get("distance", 0)
                geometry = route.get("geometry", "")
                
                # IMPORTANT: OSRM public server returns DRIVING times
                # Convert to walking time (walking speed ~80m/min)
                walking_speed_m_per_min = 80.0
                walking_minutes = distance_m / walking_speed_m_per_min
                walking_duration_sec = int(walking_minutes * 60)
                
                # Check if duration is within acceptable range (70-130% of target)
                target_sec = target_duration_min * 60
                min_acceptable = target_sec * 0.70
                max_acceptable = target_sec * 1.30
                
                if min_acceptable <= walking_duration_sec <= max_acceptable:
                    return {
                        "polyline": geometry,
                        "distanceMeters": int(distance_m),
                        "durationSeconds": walking_duration_sec  # Use walking time, not driving time
                    }
        
    except Exception as e:
        print(f"      ⚠️ OSRM route generation failed: {e}")
    
    return None


def select_waypoints_for_route(pois: List[Dict], origin_lat: float, origin_lon: float, 
                                target_duration_min: int) -> List[Tuple[float, float]]:
    """Select waypoints for a route based on target duration"""
    if not pois:
        return []
    
    # Calculate ideal distance for target duration
    # Walking speed ~80m/min, but routes are 2-3x longer than straight-line
    ideal_distance = target_duration_min * WALKING_SPEED_M_PER_MIN * 0.65  # Conservative estimate
    
    # Sort POIs by distance from origin
    pois_with_distance = []
    for poi in pois:
        distance = haversine_distance(origin_lat, origin_lon, poi["latitude"], poi["longitude"])
        pois_with_distance.append((poi, distance))
    
    pois_with_distance.sort(key=lambda x: x[1])
    
    # Select waypoints that create a route close to target duration
    selected = []
    cumulative_distance = 0
    
    for poi, distance in pois_with_distance:
        if cumulative_distance + distance * 2 <= ideal_distance:  # *2 for return journey
            selected.append((poi["latitude"], poi["longitude"]))
            cumulative_distance += distance * 2
            if len(selected) >= 3:  # Limit to 3 waypoints max
                break
    
    return selected


def generate_routes_for_area(pois: List[Dict], origin_lat: float, origin_lon: float) -> List[Dict]:
    """Generate routes for all target durations using OSRM (OSM data, cacheable)"""
    routes_by_duration = {}
    
    for duration in DURATIONS_TO_GENERATE:
        print(f"      🗺️ Generating {duration}min route (OSRM)...")
        
        # Try up to 5 different waypoint combinations
        for attempt in range(5):
            waypoints = select_waypoints_for_route(pois, origin_lat, origin_lon, duration)
            
            if not waypoints:
                break
            
            route_data = generate_route_osrm(origin_lat, origin_lon, waypoints, duration)
            
            if route_data:
                if duration not in routes_by_duration:
                    routes_by_duration[duration] = []
                
                if len(routes_by_duration[duration]) < 3:  # Max 3 routes per duration
                    # Get POI details for waypoints
                    route_pois = []
                    for wp_lat, wp_lon in waypoints:
                        # Find matching POI
                        for poi in pois:
                            if abs(poi["latitude"] - wp_lat) < 0.0001 and abs(poi["longitude"] - wp_lon) < 0.0001:
                                route_pois.append({
                                    "placeId": poi["placeId"],
                                    "name": poi["name"],
                                    "latitude": poi["latitude"],
                                    "longitude": poi["longitude"],
                                    "types": poi["types"],
                                    "vicinity": poi.get("vicinity"),
                                    "source": poi["source"],
                                    "rating": poi.get("rating")  # Preserve rating if present
                                })
                                break
                    
                    # Create route data with proper structure
                    route_entry = {
                        "places": route_pois,
                        "polyline": route_data["polyline"],
                        "distanceMeters": route_data["distanceMeters"],
                        "durationSeconds": route_data["durationSeconds"],
                        "name": None,  # Can be generated later with Gemini
                        "description": None,  # Can be generated later with Gemini
                        "directions": None  # Can be generated later
                    }
                    routes_by_duration[duration].append(route_entry)
                    print(f"      ✅ Generated {duration}min route ({len(routes_by_duration[duration])}/3) - {route_data['distanceMeters']}m, {route_data['durationSeconds']//60}min")
                    break
        
        time.sleep(0.5)  # Be respectful to OSRM API
    
    if not routes_by_duration:
        print(f"      ⚠️ No routes generated for any duration")
    
    # Convert to required format (matches PrePopulatedRoute structure)
    route_groups = []
    for duration, routes in routes_by_duration.items():
        if routes:
            route_groups.append({
                "durationMinutes": duration,
                "routes": routes  # Each route already has: places, polyline, distanceMeters, durationSeconds, name, description, directions
            })
    
    return route_groups


def main():
    import sys
    sys.stdout.flush()
    print("📦 Starting database generation for WalkingWR")
    sys.stdout.flush()
    print(f"   Postcode areas: {len(POSTCODE_AREAS)}")
    sys.stdout.flush()
    print(f"   Radius: {RADIUS_METERS}m")
    sys.stdout.flush()
    print(f"   Route durations: {DURATIONS_TO_GENERATE}\n")
    sys.stdout.flush()
    
    postcode_areas = []
    
    for index, (postcode, lat, lon) in enumerate(POSTCODE_AREAS, 1):
        print(f"\n📦 Processing postcode area {index}/{len(POSTCODE_AREAS)}: {postcode}")
        print(f"   Location: ({lat}, {lon})")
        
        # Fetch POIs from OSM
        osm_pois = fetch_osm_pois(lat, lon, RADIUS_METERS)
        time.sleep(1)  # Be respectful to APIs
        
        # Fetch POIs from Geograph
        geograph_pois = fetch_geograph_pois(lat, lon, RADIUS_METERS)
        time.sleep(1)
        
        # Combine and deduplicate
        all_pois = osm_pois + geograph_pois
        deduplicated_pois = deduplicate_pois(all_pois, lat, lon)
        
        # Filter out restricted POIs (playcare, nursery, kindergarten, playground, etc.)
        filtered_pois = filter_restricted_pois(deduplicated_pois)
        
        print(f"   ✅ Total POIs after deduplication: {len(deduplicated_pois)}")
        print(f"   ✅ Total POIs after filtering: {len(filtered_pois)}")
        print(f"   📊 POI sources: OSM={len(osm_pois)}, Geograph={len(geograph_pois)}")
        print(f"   ⚠️ Note: Only OSM and Geograph POIs cached (Apple POIs not allowed)")
        
        # Generate routes using OSRM (OSM data, cacheable)
        print(f"   🗺️ Generating routes using OSRM (OSM data, cacheable)...")
        routes = generate_routes_for_area(filtered_pois, lat, lon)
        
        if routes:
            total_routes = sum(len(r["routes"]) for r in routes)
            print(f"   ✅ Generated {total_routes} routes across {len(routes)} duration groups")
        else:
            print(f"   ⚠️ No routes generated for this area")
        
        # Create postcode area entry
        area_entry = {
            "postcode": postcode,
            "centerLatitude": lat,
            "centerLongitude": lon,
            "radiusMeters": RADIUS_METERS,
            "pois": filtered_pois,  # Only non-restricted POIs
            "routes": routes  # OSRM-generated routes (OSM data, cacheable)
        }
        
        postcode_areas.append(area_entry)
        
        # Delay between postcode areas
        time.sleep(2)
    
    # Create database structure
    database = {
        "version": 1,
        "lastUpdated": datetime.utcnow().isoformat() + "Z",
        "postcodeAreas": postcode_areas
    }
    
    # Save to JSON file
    output_file = "prepopulated_pois.json"
    with open(output_file, "w") as f:
        json.dump(database, f, indent=2, ensure_ascii=False)
    
    total_pois = sum(len(area["pois"]) for area in postcode_areas)
    total_routes = sum(
        len(r["routes"]) if area.get("routes") else 0
        for area in postcode_areas
        for r in (area.get("routes") or [])
    )
    
    print(f"\n📦 ✅ Database generation complete!")
    print(f"   Total postcode areas: {len(postcode_areas)}")
    print(f"   Total POIs: {total_pois} (OSM + Geograph, filtered)")
    print(f"   Total routes: {total_routes} (OSRM-generated, OSM data)")
    print(f"   Output file: {output_file}")
    print(f"\n✅ Database ready! All data is open-source and cacheable.")
    print(f"   - POIs: OSM + Geograph (Apple POIs excluded)")
    print(f"   - Restricted POIs filtered: playcare, nursery, kindergarten, playground, etc.")
    print(f"   - Routes: OSRM (OSM data, not MapKit)")


if __name__ == "__main__":
    main()
