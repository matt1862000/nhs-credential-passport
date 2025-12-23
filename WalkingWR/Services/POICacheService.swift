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
    
    private let cacheKey = "cachedPOILocations"
    private let maxCachedLocations = 10
    private let matchRadiusMeters: Double = 1000 // 1km
    
    // Free tier limit
    static let freeTierLocationLimit = 3
    
    private init() {}
    
    /// Check if user has reached free tier location limit
    var hasReachedFreeLimit: Bool {
        loadCache().count >= POICacheService.freeTierLocationLimit
    }
    
    /// Check if adding a new location at this coordinate would exceed free limit
    /// Returns true if OK to add, false if would exceed limit
    func canAddLocation(at location: CLLocationCoordinate2D) -> Bool {
        let cached = loadCache()
        
        // Check if already cached nearby (no new slot needed)
        for entry in cached {
            if distanceBetween(entry.coordinate, location) <= matchRadiusMeters {
                return true // Already cached, no new slot needed
            }
        }
        
        // Would need a new slot - check limit
        return cached.count < POICacheService.freeTierLocationLimit
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
        let rating: Double?
        
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }
    
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
    func cachePOIs(_ pois: [PlaceResult], for location: CLLocationCoordinate2D) {
        var cached = loadCache()
        
        // Remove any existing cache for nearby location (within 500m)
        cached.removeAll { entry in
            distanceBetween(entry.coordinate, location) < 500
        }
        
        // Create new cache entry
        let newEntry = CachedPOILocation(
            latitude: location.latitude,
            longitude: location.longitude,
            pois: pois.map { CachedPOI(from: $0) },
            fetchedAt: Date()
        )
        
        // Add to front of list
        cached.insert(newEntry, at: 0)
        
        // Keep only the most recent locations
        if cached.count > maxCachedLocations {
            cached = Array(cached.prefix(maxCachedLocations))
        }
        
        saveCache(cached)
        print("📦 POI Cache SAVED: \(pois.count) POIs for location (\(String(format: "%.4f", location.latitude)), \(String(format: "%.4f", location.longitude)))")
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
    
    /// Get POI names for a specific cached location (for detail view)
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
            return try JSONDecoder().decode([CachedPOILocation].self, from: data)
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
        self.rating = place.rating
    }
    
    func toPlaceResult() -> PlaceResult {
        PlaceResult(
            placeId: placeId,
            name: name,
            vicinity: vicinity,
            geometry: PlaceGeometry(
                location: PlaceLocation(lat: latitude, lng: longitude)
            ),
            rating: rating,
            types: types,
            businessStatus: nil
        )
    }
}

