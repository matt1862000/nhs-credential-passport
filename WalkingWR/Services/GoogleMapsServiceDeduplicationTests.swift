//
//  GoogleMapsServiceDeduplicationTests.swift
//  WalkingWR
//
//  Tests for unified route deduplication system
//

import XCTest
import CoreLocation
@testable import WalkingWR

final class GoogleMapsServiceDeduplicationTests: XCTestCase {
    
    // Helper to create a PlaceResult for testing
    func createPlaceResult(name: String, lat: Double, lon: Double, placeId: String = "", source: POISource = .osm, category: String = "unknown") -> PlaceResult {
        return PlaceResult(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            placeId: placeId.isEmpty ? "test_\(name.replacingOccurrences(of: " ", with: "_"))" : placeId,
            source: source,
            types: category == "unknown" ? [] : [category]
        )
    }
    
    // Test: Deduplicates Lindale Methodist Church variants within 100m
    func testDeduplicatesLindaleMethodistChurchVariants() {
        let a = createPlaceResult(
            name: "SE2922 : Lindale Methodist Church, Kirkhamgate",
            lat: 53.724,
            lon: -1.593,
            category: "religious"
        )
        let b = createPlaceResult(
            name: "Lindale Methodist Church",
            lat: 53.72401,
            lon: -1.59299,
            category: "religious"
        )
        
        // Calculate distance (should be < 100m)
        let distance = distanceBetween(a.coordinate, b.coordinate)
        XCTAssertLessThan(distance, 100.0, "POIs should be within 100m")
        
        // Test cleaned names match
        let cleanedA = GoogleMapsService.cleanPOIDisplayName(a.name).lowercased()
        let cleanedB = GoogleMapsService.cleanPOIDisplayName(b.name).lowercased()
        XCTAssertEqual(cleanedA, cleanedB, "Cleaned names should match")
        XCTAssertEqual(cleanedA, "lindale methodist church", "Cleaned name should be 'lindale methodist church'")
        
        // Test unified duplicate comparator
        let service = GoogleMapsService.shared
        XCTAssertTrue(service.isRouteDuplicate(a, b), "POIs should be considered duplicates")
    }
    
    // Test: Deduplicates War Memorial variants within 100m
    func testDeduplicatesWarMemorialVariants() {
        let a = createPlaceResult(
            name: "War Memorial",
            lat: 53.7245,
            lon: -1.5932,
            category: "memorial"
        )
        let b = createPlaceResult(
            name: "SE2922 : War memorial, Kirkhamgate",
            lat: 53.72449,
            lon: -1.59319,
            category: "memorial"
        )
        
        // Calculate distance (should be < 100m)
        let distance = distanceBetween(a.coordinate, b.coordinate)
        XCTAssertLessThan(distance, 100.0, "POIs should be within 100m")
        
        // Test cleaned names match
        let cleanedA = GoogleMapsService.cleanPOIDisplayName(a.name).lowercased()
        let cleanedB = GoogleMapsService.cleanPOIDisplayName(b.name).lowercased()
        XCTAssertEqual(cleanedA, cleanedB, "Cleaned names should match")
        XCTAssertEqual(cleanedA, "war memorial", "Cleaned name should be 'war memorial'")
        
        // Test unified duplicate comparator
        let service = GoogleMapsService.shared
        XCTAssertTrue(service.isRouteDuplicate(a, b), "POIs should be considered duplicates")
    }
    
    // Test: Does NOT deduplicate POIs >100m apart even with same name
    func testDoesNotDeduplicateFarApartPOIs() {
        let a = createPlaceResult(
            name: "War Memorial",
            lat: 53.7245,
            lon: -1.5932,
            category: "memorial"
        )
        let b = createPlaceResult(
            name: "War Memorial",
            lat: 53.7255,  // ~110m away
            lon: -1.5932,
            category: "memorial"
        )
        
        // Calculate distance (should be > 100m)
        let distance = distanceBetween(a.coordinate, b.coordinate)
        XCTAssertGreaterThan(distance, 100.0, "POIs should be >100m apart")
        
        // Test cleaned names match
        let cleanedA = GoogleMapsService.cleanPOIDisplayName(a.name).lowercased()
        let cleanedB = GoogleMapsService.cleanPOIDisplayName(b.name).lowercased()
        XCTAssertEqual(cleanedA, cleanedB, "Cleaned names should match")
        
        // These should NOT be considered duplicates due to distance
        let service = GoogleMapsService.shared
        XCTAssertFalse(service.isRouteDuplicate(a, b), "POIs should NOT be considered duplicates (too far apart)")
    }
    
    // Test: Deduplicates by placeId
    func testDeduplicatesByPlaceId() {
        let a = createPlaceResult(
            name: "The Star Inn",
            lat: 53.724,
            lon: -1.593,
            placeId: "same_place_id",
            source: .google
        )
        let b = createPlaceResult(
            name: "Different Name",
            lat: 53.725,  // Far away
            lon: -1.594,
            placeId: "same_place_id",  // Same placeId
            source: .osm
        )
        
        // These should be considered duplicates due to same placeId
        XCTAssertEqual(a.placeId, b.placeId, "PlaceIds should match")
        
        // Test unified duplicate comparator
        let service = GoogleMapsService.shared
        XCTAssertTrue(service.isRouteDuplicate(a, b), "POIs should be considered duplicates (same placeId)")
    }
    
    // Test: Deduplicates by location (<20m)
    func testDeduplicatesByLocation() {
        let a = createPlaceResult(
            name: "POI A",
            lat: 53.724,
            lon: -1.593,
            placeId: "id_a"
        )
        let b = createPlaceResult(
            name: "POI B",
            lat: 53.724001,  // ~10m away
            lon: -1.593001,
            placeId: "id_b"
        )
        
        // Calculate distance (should be < 20m)
        let distance = distanceBetween(a.coordinate, b.coordinate)
        XCTAssertLessThan(distance, 20.0, "POIs should be within 20m")
        
        // These should be considered duplicates due to proximity
        let service = GoogleMapsService.shared
        XCTAssertTrue(service.isRouteDuplicate(a, b), "POIs should be considered duplicates (same location)")
    }
    
    // Helper function to calculate distance (same as in GoogleMapsService)
    private func distanceBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
        let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
        return loc1.distance(from: loc2)
    }
}
