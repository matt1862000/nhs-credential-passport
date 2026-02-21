//
//  POICacheService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 22/12/2025.
//

import Foundation
import CoreLocation

/// Caches POIs by location to reduce Places API calls
/// - No expiry (POIs are landmarks, they don't move)
/// - Multiple locations supported (up to 10)
/// - Uses 1km radius for cache matching
class POICacheService {
    static let shared = POICacheService()
    
    // v1.9.3: Bump cache key to force refresh (clear cache for API testing)
    private let cacheKey = "cachedPOILocations_v6"
    private let maxCachedLocations = 10
    private let matchRadiusMeters: Double = 1000 // 1km
    
    // Free tier limit - v1.6.28: Removed limit (was 3)
    // static let freeTierLocationLimit = 3  // DISABLED
    
    private init() {}
    
    /// Check if user has reached free tier location limit
    /// v1.6.28: Always returns false (no limit)
    var hasReachedFreeLimit: Bool {
        false  // No limit for now
    }
    
    /// Check if adding a new location at this coordinate would exceed free limit
    /// v1.6.28: Always returns true (no limit)
    func canAddLocation(at location: CLLocationCoordinate2D) -> Bool {
        true  // No limit for now
    }
    
    // MARK: - Cache Entry Structure
    
    struct CachedPOILocation: Codable {
        let latitude: Double
        let longitude: Double
        let pois: [CachedPOI]
        let fetchedAt: Date
        
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
    
    struct CachedPOI: Codable {
        let placeId: String
        let name: String
        let latitude: Double
        let longitude: Double
        let types: [String]
        let vicinity: String?
        let source: String?  // v2.1.0: Track source for ToS compliance (only cache osm/geograph/database)
        
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
    
    // MARK: - ToS-Safe Sources
    // Only these sources can be cached to comply with Google/Apple Terms of Service
    static let tosSafeSources: Set<String> = ["osm", "geograph", "database", "unknown", "apple", "ors"]
    
    // MARK: - Public Methods
    
    /// Check if we have cached POIs near the given location
    /// Returns cached POIs if within 1km, nil otherwise
    func getCachedPOIs(near location: CLLocationCoordinate2D) -> [PlaceResult]? {
        let cached = loadCache()
        
        for entry in cached {
            let distance = distanceBetween(entry.coordinate, location)
            if distance <= matchRadiusMeters {
                print("📦 POI Cache HIT! Found \(entry.pois.count) POIs cached \(Int(distance))m away")
                return entry.pois.map { $0.toPlaceResult() }
            }
        }
        
        print("📦 POI Cache MISS - no cached POIs within \(Int(matchRadiusMeters))m")
        return nil
    }
    
    /// Save POIs for a location
    /// v2.1.0: Only caches POIs from ToS-safe sources (osm, geograph, database)
    /// Google and Apple POIs are NOT cached to comply with their Terms of Service
    func cachePOIs(_ pois: [PlaceResult], for location: CLLocationCoordinate2D) {
        // v2.1.0: Filter to only cache ToS-safe sources (NOT Google or Apple)
        let safePOIs = pois.filter { poi in
            let sourceString = poi.source.rawValue
            let isSafe = Self.tosSafeSources.contains(sourceString)
            return isSafe
        }
        
        // Log what we're filtering out
        let googleCount = pois.filter { $0.source.rawValue == "google" }.count
        let appleCount = pois.filter { $0.source.rawValue == "apple" }.count
        if googleCount > 0 || appleCount > 0 {
            print("📦 POI Cache: Skipping \(googleCount) Google + \(appleCount) Apple POIs (ToS compliance)")
        }
        
        // Don't cache if no safe POIs
        guard !safePOIs.isEmpty else {
            print("📦 POI Cache: No ToS-safe POIs to cache")
            return
        }
        
        var cached = loadCache()
        
        // Remove any existing cache for nearby location (within matchRadiusMeters)
        // This prevents duplicates like "Kirkhamgate" appearing 3 times
        let removedCount = cached.count
        cached.removeAll { entry in
            distanceBetween(entry.coordinate, location) < matchRadiusMeters
        }
        let duplicatesRemoved = removedCount - cached.count
        if duplicatesRemoved > 0 {
            print("📦 POI Cache: Removed \(duplicatesRemoved) duplicate location(s) within \(Int(matchRadiusMeters))m")
        }
        
        // v1.6.28: Removed free tier limit check - now unlimited
        // Only limit is maxCachedLocations (10) to prevent unbounded growth
        if cached.count >= maxCachedLocations {
            print("📦 POI Cache: Max locations reached (\(maxCachedLocations)), removing oldest")
            cached.removeLast()
        }
        
        // Create new cache entry with only safe POIs
        let newEntry = CachedPOILocation(
            latitude: location.latitude,
            longitude: location.longitude,
            pois: safePOIs.map { CachedPOI(from: $0) },
            fetchedAt: Date()
        )
        
        // Add to front of list
        cached.insert(newEntry, at: 0)
        
        // Keep only the most recent locations (hard cap)
        if cached.count > maxCachedLocations {
            cached = Array(cached.prefix(maxCachedLocations))
        }
        
        saveCache(cached)
        print("📦 POI Cache SAVED: \(safePOIs.count) ToS-safe POIs for location (\(String(format: "%.4f", location.latitude)), \(String(format: "%.4f", location.longitude)))")
    }
    
    /// Clear all cached POIs
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        print("📦 POI Cache CLEARED")
    }
    
    /// Get cache statistics
    func getCacheStats() -> (locations: Int, totalPOIs: Int) {
        let cached = loadCache()
        let totalPOIs = cached.reduce(0) { $0 + $1.pois.count }
        return (cached.count, totalPOIs)
    }
    
    /// Get detailed info about each cached location for display in settings
    struct CachedLocationInfo: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let poiCount: Int
        let fetchedAt: Date
        var locationName: String = "Loading..." // Human-readable location name
    }
    
    func getCachedLocationsInfo() -> [CachedLocationInfo] {
        let cached = loadCache()
        return cached.map { entry in
            CachedLocationInfo(
                coordinate: entry.coordinate,
                poiCount: entry.pois.count,
                fetchedAt: entry.fetchedAt,
                locationName: "Loading..."
            )
        }
    }
    
    /// Get POIs for a specific cached location (for detail view)
    func getPOIsForLocation(at coordinate: CLLocationCoordinate2D) -> [CachedPOI] {
        let cached = loadCache()
        
        for entry in cached {
            let distance = distanceBetween(entry.coordinate, coordinate)
            if distance <= matchRadiusMeters {
                return entry.pois
            }
        }
        
        return []
    }
    
    /// Delete a cached location by its coordinate
    /// Used for swipe-to-delete in settings
    func deleteLocation(at coordinate: CLLocationCoordinate2D) {
        var cached = loadCache()
        
        // Remove entries within matchRadiusMeters of the given coordinate
        let beforeCount = cached.count
        cached.removeAll { entry in
            distanceBetween(entry.coordinate, coordinate) <= matchRadiusMeters
        }
        
        let removedCount = beforeCount - cached.count
        if removedCount > 0 {
            print("📦 POI Cache: Deleted \(removedCount) cached location(s)")
            saveCache(cached)
        }
    }
    
    /// Delete a cached location by index (for SwiftUI onDelete)
    func deleteLocation(at index: Int) {
        var cached = loadCache()
        guard index >= 0 && index < cached.count else { return }
        
        cached.remove(at: index)
        print("📦 POI Cache: Deleted location at index \(index)")
        saveCache(cached)
    }
    
    /// Reverse geocode a coordinate to get a human-readable place name
    /// Prioritizes specific areas (neighborhood/street) over general city names
    func getLocationName(for coordinate: CLLocationCoordinate2D, completion: @escaping (String) -> Void) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            if let placemark = placemarks?.first {
                // Priority order for specificity (most specific first):
                // 1. Street name + subLocality (e.g., "Ecclesall Road, Sharrow")
                // 2. SubLocality + locality (e.g., "Sharrow, Sheffield")
                // 3. Name + locality (e.g., "Kelham Island, Sheffield")
                // 4. Locality only (e.g., "Sheffield")
                
                var result: String?
                
                // Try: Neighborhood/SubLocality + City
                if let subLocality = placemark.subLocality {
                    if let locality = placemark.locality, locality != subLocality {
                        result = "\(subLocality), \(locality)"
                    } else {
                        result = subLocality
                    }
                }
                // Try: Thoroughfare (street) + SubLocality or Locality
                else if let street = placemark.thoroughfare {
                    if let subLocality = placemark.subLocality {
                        result = "\(street), \(subLocality)"
                    } else if let locality = placemark.locality {
                        result = "\(street), \(locality)"
                    } else {
                        result = street
                    }
                }
                // Try: Name (landmark/POI name) + Locality
                else if let name = placemark.name, !name.contains(coordinate.latitude.description) {
                    if let locality = placemark.locality, name != locality {
                        result = "\(name), \(locality)"
                    } else {
                        result = name
                    }
                }
                // Fallback: Locality or administrative area
                else if let locality = placemark.locality {
                    result = locality
                } else if let admin = placemark.administrativeArea {
                    result = admin
                }
                
                completion(result ?? "Unknown Area")
            } else {
                // Fallback to coordinates if geocoding fails
                let latDir = coordinate.latitude >= 0 ? "N" : "S"
                let lonDir = coordinate.longitude >= 0 ? "E" : "W"
                completion(String(format: "%.2f°%@, %.2f°%@", 
                                  abs(coordinate.latitude), latDir,
                                  abs(coordinate.longitude), lonDir))
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func loadCache() -> [CachedPOILocation] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else {
            return []
        }
        
        do {
            let cached = try JSONDecoder().decode([CachedPOILocation].self, from: data)
            
            // Deduplicate on load: remove entries that are within matchRadiusMeters of each other
            // Keep the entry with the most POIs
            var deduplicated: [CachedPOILocation] = []
            for entry in cached {
                let isDuplicate = deduplicated.contains { existing in
                    distanceBetween(existing.coordinate, entry.coordinate) < matchRadiusMeters
                }
                
                if !isDuplicate {
                    deduplicated.append(entry)
                } else {
                    // It's a duplicate - check if this one has more POIs
                    if let existingIndex = deduplicated.firstIndex(where: { 
                        distanceBetween($0.coordinate, entry.coordinate) < matchRadiusMeters 
                    }) {
                        if entry.pois.count > deduplicated[existingIndex].pois.count {
                            // Replace with the one that has more POIs
                            print("📦 POI Cache: Dedup - keeping entry with \(entry.pois.count) POIs over \(deduplicated[existingIndex].pois.count)")
                            deduplicated[existingIndex] = entry
                        }
                    }
                }
            }
            
            // If we deduplicated anything, save the cleaned cache
            if deduplicated.count < cached.count {
                print("📦 POI Cache: Deduplicated \(cached.count) → \(deduplicated.count) entries")
                saveCache(deduplicated)
            }
            
            return deduplicated
        } catch {
            print("📦 Error loading POI cache: \(error)")
            return []
        }
    }
    
    private func saveCache(_ cache: [CachedPOILocation]) {
        do {
            let data = try JSONEncoder().encode(cache)
            UserDefaults.standard.set(data, forKey: cacheKey)
        } catch {
            print("📦 Error saving POI cache: \(error)")
        }
    }
    
    private func distanceBetween(_ coord1: CLLocationCoordinate2D, _ coord2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: coord1.latitude, longitude: coord1.longitude)
        let loc2 = CLLocation(latitude: coord2.latitude, longitude: coord2.longitude)
        return loc1.distance(from: loc2)
    }
}

// MARK: - Conversion Extensions

extension POICacheService.CachedPOI {
    init(from place: PlaceResult) {
        self.placeId = place.placeId
        self.name = place.name
        self.latitude = place.geometry.location.lat
        self.longitude = place.geometry.location.lng
        self.types = place.types ?? []
        self.vicinity = place.vicinity
        self.source = place.source.rawValue  // v2.1.0: Preserve source for ToS tracking
    }
    
    func toPlaceResult() -> PlaceResult {
        var result = PlaceResult(
            placeId: placeId,
            name: name,
            vicinity: vicinity,
            geometry: PlaceGeometry(
                location: PlaceLocation(lat: latitude, lng: longitude)
            ),
            types: types
        )
        // v2.1.0: Restore source from cache
        if let sourceString = source {
            result.source = POISource(rawValue: sourceString) ?? .unknown
        }
        return result
    }
}

