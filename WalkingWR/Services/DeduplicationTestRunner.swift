//
//  DeduplicationTestRunner.swift
//  WalkingWR
//
//  In-app test runner for deduplication system
//  Call this from your app to verify deduplication works
//

import Foundation
import CoreLocation

/// In-app test runner for deduplication system
/// Call runAllTests() to execute all tests and print results to console
class DeduplicationTestRunner {
    
    static let shared = DeduplicationTestRunner()
    
    private init() {}
    
    /// Run all deduplication tests and print results
    func runAllTests() {
        // Force immediate console output using both print and NSLog
        NSLog("🔵🔵🔵 DEDUPLICATION TEST RUNNER CALLED 🔵🔵🔵")
        print("🔵🔵🔵 DEDUPLICATION TEST RUNNER CALLED 🔵🔵🔵")
        fflush(stdout)
        
        print("═══════════════════════════════════════════════════════════")
        print("🧪 DEDUPLICATION TEST SUITE - Starting Tests")
        print("═══════════════════════════════════════════════════════════")
        print("")
        NSLog("🧪 DEDUPLICATION TEST SUITE - Starting Tests")
        fflush(stdout)
        
        var passed = 0
        var failed = 0
        
        // Test 1: Lindale Methodist Church variants
        print("🔵 [TEST] Running Test 1: Lindale Methodist Church variants...")
        if testLindaleMethodistChurchVariants() {
            passed += 1
            print("✅ Test 1: PASSED - Lindale Methodist Church variants")
            NSLog("✅ Test 1: PASSED - Lindale Methodist Church variants")
        } else {
            failed += 1
            print("❌ Test 1: FAILED - Lindale Methodist Church variants")
            NSLog("❌ Test 1: FAILED - Lindale Methodist Church variants")
        }
        print("")
        fflush(stdout)
        
        // Test 2: War Memorial variants
        if testWarMemorialVariants() {
            passed += 1
            print("✅ Test 2: PASSED - War Memorial variants")
        } else {
            failed += 1
            print("❌ Test 2: FAILED - War Memorial variants")
        }
        print("")
        
        // Test 3: Far apart POIs should NOT be duplicates
        if testFarApartPOIs() {
            passed += 1
            print("✅ Test 3: PASSED - Far apart POIs not duplicates")
        } else {
            failed += 1
            print("❌ Test 3: FAILED - Far apart POIs not duplicates")
        }
        print("")
        
        // Test 4: PlaceId matching
        if testPlaceIdMatching() {
            passed += 1
            print("✅ Test 4: PASSED - PlaceId matching")
        } else {
            failed += 1
            print("❌ Test 4: FAILED - PlaceId matching")
        }
        print("")
        
        // Test 5: Location matching (<20m)
        if testLocationMatching() {
            passed += 1
            print("✅ Test 5: PASSED - Location matching")
        } else {
            failed += 1
            print("❌ Test 5: FAILED - Location matching")
        }
        print("")
        
        // Summary
        print("═══════════════════════════════════════════════════════════")
        print("📊 TEST SUMMARY")
        print("═══════════════════════════════════════════════════════════")
        print("✅ Passed: \(passed)")
        print("❌ Failed: \(failed)")
        print("📋 Total: \(passed + failed)")
        print("")
        
        if failed == 0 {
            print("🎉 All tests passed!")
            NSLog("🎉 All tests passed!")
        } else {
            print("⚠️ Some tests failed. Review the output above.")
            NSLog("⚠️ Some tests failed. Review the output above.")
        }
        print("═══════════════════════════════════════════════════════════")
        NSLog("═══════════════════════════════════════════════════════════")
        fflush(stdout)  // Force console output
        NSLog("🔵 [TEST] All tests completed. Passed: \(passed), Failed: \(failed)")
    }
    
    // MARK: - Individual Tests
    
    private func testLindaleMethodistChurchVariants() -> Bool {
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
        
        let distance = distanceBetween(a.coordinate, b.coordinate)
        guard distance < 100.0 else {
            print("  ⚠️ POIs are \(String(format: "%.1f", distance))m apart (expected <100m)")
            return false
        }
        
        let cleanedA = GoogleMapsService.cleanPOIDisplayName(a.name).lowercased()
        let cleanedB = GoogleMapsService.cleanPOIDisplayName(b.name).lowercased()
        guard cleanedA == cleanedB else {
            print("  ⚠️ Cleaned names don't match: '\(cleanedA)' vs '\(cleanedB)'")
            return false
        }
        
        let service = GoogleMapsService.shared
        let isDuplicate = service.isRouteDuplicate(a, b)
        
        if !isDuplicate {
            print("  ⚠️ Expected duplicates but isRouteDuplicate returned false")
            return false
        }
        
        return true
    }
    
    private func testWarMemorialVariants() -> Bool {
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
        
        let distance = distanceBetween(a.coordinate, b.coordinate)
        guard distance < 100.0 else {
            print("  ⚠️ POIs are \(String(format: "%.1f", distance))m apart (expected <100m)")
            return false
        }
        
        let cleanedA = GoogleMapsService.cleanPOIDisplayName(a.name).lowercased()
        let cleanedB = GoogleMapsService.cleanPOIDisplayName(b.name).lowercased()
        guard cleanedA == cleanedB else {
            print("  ⚠️ Cleaned names don't match: '\(cleanedA)' vs '\(cleanedB)'")
            return false
        }
        
        let service = GoogleMapsService.shared
        let isDuplicate = service.isRouteDuplicate(a, b)
        
        if !isDuplicate {
            print("  ⚠️ Expected duplicates but isRouteDuplicate returned false")
            return false
        }
        
        return true
    }
    
    private func testFarApartPOIs() -> Bool {
        let a = createPlaceResult(
            name: "War Memorial",
            lat: 53.7245,
            lon: -1.5932,
            placeId: "war_memorial_location_a",  // Different placeId
            category: "memorial"
        )
        let b = createPlaceResult(
            name: "War Memorial",
            lat: 53.7255,  // ~111m away (0.001 degrees latitude ≈ 111m)
            lon: -1.5932,
            placeId: "war_memorial_location_b",  // Different placeId
            category: "memorial"
        )
        
        let distance = distanceBetween(a.coordinate, b.coordinate)
        print("  📏 Actual distance between POIs: \(String(format: "%.2f", distance))m")
        print("  📍 POI A: lat=\(a.coordinate.latitude), lon=\(a.coordinate.longitude)")
        print("  📍 POI B: lat=\(b.coordinate.latitude), lon=\(b.coordinate.longitude)")
        
        guard distance > 100.0 else {
            print("  ⚠️ POIs are \(String(format: "%.1f", distance))m apart (expected >100m)")
            print("  ⚠️ Test setup issue: POIs are too close together")
            return false
        }
        
        let service = GoogleMapsService.shared
        let isDuplicate = service.isRouteDuplicate(a, b)
        
        // Debug: Check each condition in isRouteDuplicate
        let nameA = GoogleMapsService.cleanPOIDisplayName(a.name).lowercased()
        let nameB = GoogleMapsService.cleanPOIDisplayName(b.name).lowercased()
        let namesMatch = nameA == nameB
        let distanceCheck = distance < 100.0
        
        print("  🔍 Debug: placeId A='\(a.placeId)', placeId B='\(b.placeId)'")
        print("  🔍 Debug: names match=\(namesMatch), distance < 100m=\(distanceCheck)")
        print("  🔍 Debug: nameA='\(nameA)', nameB='\(nameB)'")
        
        if isDuplicate {
            print("  ⚠️ Expected NOT duplicates but isRouteDuplicate returned true")
            print("  📏 Distance: \(String(format: "%.2f", distance))m (should be >100m to not be duplicate)")
            print("  📝 Name A: '\(a.name)' -> cleaned: '\(nameA)'")
            print("  📝 Name B: '\(b.name)' -> cleaned: '\(nameB)'")
            return false
        }
        
        return true
    }
    
    private func testPlaceIdMatching() -> Bool {
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
        
        guard a.placeId == b.placeId else {
            print("  ⚠️ PlaceIds don't match")
            return false
        }
        
        let service = GoogleMapsService.shared
        let isDuplicate = service.isRouteDuplicate(a, b)
        
        if !isDuplicate {
            print("  ⚠️ Expected duplicates (same placeId) but isRouteDuplicate returned false")
            return false
        }
        
        return true
    }
    
    private func testLocationMatching() -> Bool {
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
        
        let distance = distanceBetween(a.coordinate, b.coordinate)
        guard distance < 20.0 else {
            print("  ⚠️ POIs are \(String(format: "%.1f", distance))m apart (expected <20m)")
            return false
        }
        
        let service = GoogleMapsService.shared
        let isDuplicate = service.isRouteDuplicate(a, b)
        
        if !isDuplicate {
            print("  ⚠️ Expected duplicates (same location) but isRouteDuplicate returned false")
            return false
        }
        
        return true
    }
    
    // MARK: - Helpers
    
    private func createPlaceResult(name: String, lat: Double, lon: Double, placeId: String = "", source: POISource = .osm, category: String = "unknown") -> PlaceResult {
        return PlaceResult(
            placeId: placeId.isEmpty ? "test_\(name.replacingOccurrences(of: " ", with: "_"))" : placeId,
            name: name,
            vicinity: nil,
            geometry: PlaceGeometry(
                location: PlaceLocation(lat: lat, lng: lon)
            ),
            types: category == "unknown" ? nil : [category],
            source: source
        )
    }
    
    private func distanceBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        let loc1 = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
        let loc2 = CLLocation(latitude: c2.latitude, longitude: c2.longitude)
        return loc1.distance(from: loc2)
    }
}
