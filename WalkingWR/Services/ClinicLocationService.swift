//
//  ClinicLocationService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 08/01/2026.
//

import Foundation
import CoreLocation

/// Maps clinic/service location names to their physical addresses and coordinates
/// Based on Sheffield Partnership NHS Foundation Trust services
/// https://www.sheffieldpartnership.nhs.uk/services
class ClinicLocationService: ObservableObject {
    static let shared = ClinicLocationService()
    
    /// Known Sheffield NHS mental health service locations
    struct ClinicLocation {
        let name: String
        let alternativeNames: [String]  // Other names this might be called
        let address: String
        let postcode: String
        let coordinate: CLLocationCoordinate2D
    }
    
    /// All known clinic locations in Sheffield
    let knownLocations: [ClinicLocation] = [
        // Northlands - Community Mental Health Centre
        ClinicLocation(
            name: "Northlands",
            alternativeNames: ["Northlands Centre", "Northlands CMHT"],
            address: "Southey Hill, Sheffield",
            postcode: "S5 8BE",
            coordinate: CLLocationCoordinate2D(latitude: 53.4219, longitude: -1.4742)
        ),
        
        // Eastglade - Community Mental Health Centre
        ClinicLocation(
            name: "Eastglade",
            alternativeNames: ["Eastglade Centre", "Eastglade CMHT"],
            address: "Eastglade Road, Sheffield",
            postcode: "S12 4QN",
            coordinate: CLLocationCoordinate2D(latitude: 53.3503, longitude: -1.3984)
        ),
        
        // Longley Centre - Main mental health hub (Decisions Unit, Crisis Team, etc.)
        ClinicLocation(
            name: "Longley Centre",
            alternativeNames: ["Decisions Unit", "Crisis Resolution", "Health Based Place of Safety", "136 Suite", "ECT Suite"],
            address: "Norwood Grange Drive",
            postcode: "S5 7JT",
            coordinate: CLLocationCoordinate2D(latitude: 53.4097, longitude: -1.4647)
        ),
        
        // Michael Carlisle Centre - Nether Edge
        ClinicLocation(
            name: "Michael Carlisle Centre",
            alternativeNames: ["Stanage Ward", "Burbage Ward", "Maple Ward", "Dovedale Ward", "Endcliffe Ward", "PICU"],
            address: "Nether Edge Hospital, 75 Osborne Road",
            postcode: "S11 9BF",
            coordinate: CLLocationCoordinate2D(latitude: 53.3618, longitude: -1.4897)
        ),
        
        // Fulwood House - Community teams
        ClinicLocation(
            name: "Fulwood House",
            alternativeNames: ["Community Mental Health Team", "CMHT", "Recovery Service"],
            address: "Old Fulwood Road",
            postcode: "S10 3TH",
            coordinate: CLLocationCoordinate2D(latitude: 53.3782, longitude: -1.5183)
        ),
        
        // Centre Court - Trust HQ
        ClinicLocation(
            name: "Centre Court",
            alternativeNames: ["Trust Headquarters", "Atlas Way"],
            address: "Atlas Way",
            postcode: "S4 7QQ",
            coordinate: CLLocationCoordinate2D(latitude: 53.4021, longitude: -1.4298)
        ),
        
        // Forest Close/Lodge - Rehabilitation
        ClinicLocation(
            name: "Forest Close",
            alternativeNames: ["Forest Lodge", "Rehabilitation Unit"],
            address: "Middlewood Road",
            postcode: "S6 1TP",
            coordinate: CLLocationCoordinate2D(latitude: 53.4089, longitude: -1.5012)
        ),
        
        // Fitzwilliam Centre - Specialist services
        ClinicLocation(
            name: "Fitzwilliam Centre",
            alternativeNames: ["Psychosexual Therapy", "Specialist Services"],
            address: "143-145 Fitzwilliam Street",
            postcode: "S1 4JP",
            coordinate: CLLocationCoordinate2D(latitude: 53.3774, longitude: -1.4714)
        ),
        
        // Grenoside Grange - Dementia
        ClinicLocation(
            name: "Grenoside Grange",
            alternativeNames: ["G1 Ward", "Dementia Unit"],
            address: "Salt Box Lane, Grenoside",
            postcode: "S35 8QS",
            coordinate: CLLocationCoordinate2D(latitude: 53.4461, longitude: -1.5028)
        ),
        
        // Birch Avenue - Dementia nursing
        ClinicLocation(
            name: "Birch Avenue",
            alternativeNames: ["Dementia Nursing Home"],
            address: "Birch Avenue, Beighton",
            postcode: "S20 1BQ",
            coordinate: CLLocationCoordinate2D(latitude: 53.3455, longitude: -1.3565)
        ),
        
        // Woodland View - Dementia nursing
        ClinicLocation(
            name: "Woodland View",
            alternativeNames: ["Dementia Nursing"],
            address: "Batemoor Road",
            postcode: "S8 8EE",
            coordinate: CLLocationCoordinate2D(latitude: 53.3388, longitude: -1.5019)
        ),
        
        // Beech - Step-down provision
        ClinicLocation(
            name: "Beech",
            alternativeNames: ["Step-down", "Residential"],
            address: "Jordanthorpe",
            postcode: "S8 8DX",
            coordinate: CLLocationCoordinate2D(latitude: 53.3344, longitude: -1.4891)
        ),
        
        // Porterbrook Clinic - Gender Identity
        ClinicLocation(
            name: "Porterbrook Clinic",
            alternativeNames: ["Gender Identity Clinic", "GIC"],
            address: "75 Osborne Road, Nether Edge",
            postcode: "S11 9BF",
            coordinate: CLLocationCoordinate2D(latitude: 53.3618, longitude: -1.4897)
        ),
        
        // Northern General Hospital - Liaison Psychiatry
        ClinicLocation(
            name: "Northern General Hospital",
            alternativeNames: ["Liaison Psychiatry", "NGH"],
            address: "Herries Road",
            postcode: "S5 7AU",
            coordinate: CLLocationCoordinate2D(latitude: 53.4107, longitude: -1.4656)
        )
    ]
    
    private init() {}
    
    /// Find the coordinate for a given location name
    /// Performs fuzzy matching against known locations and their alternatives
    func findCoordinate(for locationName: String) -> CLLocationCoordinate2D? {
        let searchName = locationName.lowercased().trimmingCharacters(in: .whitespaces)
        
        // First try exact match
        for location in knownLocations {
            if location.name.lowercased() == searchName {
                return location.coordinate
            }
            
            // Check alternative names
            for altName in location.alternativeNames {
                if altName.lowercased() == searchName {
                    return location.coordinate
                }
            }
        }
        
        // Try partial/fuzzy match
        for location in knownLocations {
            if location.name.lowercased().contains(searchName) || searchName.contains(location.name.lowercased()) {
                return location.coordinate
            }
            
            for altName in location.alternativeNames {
                if altName.lowercased().contains(searchName) || searchName.contains(altName.lowercased()) {
                    return location.coordinate
                }
            }
        }
        
        return nil
    }
    
    /// Get the full location info for a given name
    func findLocation(for locationName: String) -> ClinicLocation? {
        let searchName = locationName.lowercased().trimmingCharacters(in: .whitespaces)
        
        for location in knownLocations {
            if location.name.lowercased() == searchName {
                return location
            }
            
            for altName in location.alternativeNames {
                if altName.lowercased() == searchName {
                    return location
                }
            }
            
            // Partial match
            if location.name.lowercased().contains(searchName) || searchName.contains(location.name.lowercased()) {
                return location
            }
            
            for altName in location.alternativeNames {
                if altName.lowercased().contains(searchName) || searchName.contains(altName.lowercased()) {
                    return location
                }
            }
        }
        
        return nil
    }
    
    /// Calculate distance from user to a clinic location in meters
    func distance(from userLocation: CLLocation, to locationName: String) -> Double? {
        guard let coordinate = findCoordinate(for: locationName) else {
            return nil
        }
        
        let clinicLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return userLocation.distance(from: clinicLocation)
    }
    
    /// Sort clinicians by their distance from the user
    /// Clinicians with unknown locations go to the end
    func sortByProximity(clinicians: [Clinician], userLocation: CLLocation) -> [Clinician] {
        #if DEBUG
        // Log only in debug to avoid log spam when Firebase/location updates trigger frequent re-sorts
        print("📍 Sorting \(clinicians.count) clinicians by proximity to \(userLocation.coordinate)")
        #endif
        
        let sorted = clinicians.sorted { c1, c2 in
            let dist1 = distance(from: userLocation, to: c1.location)
            let dist2 = distance(from: userLocation, to: c2.location)
            
            // If both have known locations, sort by distance
            if let d1 = dist1, let d2 = dist2 {
                return d1 < d2
            }
            
            // Known location comes before unknown
            if dist1 != nil && dist2 == nil {
                return true
            }
            if dist1 == nil && dist2 != nil {
                return false
            }
            
            // Both unknown - sort by name
            return c1.name < c2.name
        }
        
        #if DEBUG
        // Debug log the result (omit in release to avoid log spam from frequent re-sorts)
        for (index, clinician) in sorted.enumerated() {
            let dist = distance(from: userLocation, to: clinician.location)
            let distStr = dist.map { String(format: "%.0fm", $0) } ?? "unknown"
            print("📍 [\(index + 1)] \(clinician.name) @ \(clinician.location) → \(distStr)")
        }
        #endif
        
        return sorted
    }
    
    /// Format distance for display (e.g., "1.2 km away")
    func formattedDistance(from userLocation: CLLocation, to locationName: String) -> String? {
        guard let meters = distance(from: userLocation, to: locationName) else {
            return nil
        }
        
        if meters < 1000 {
            return "\(Int(meters))m away"
        } else {
            let km = meters / 1000
            return String(format: "%.1f km away", km)
        }
    }
}

