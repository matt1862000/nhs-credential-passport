//
//  BirdSpottingCache.swift
//  WalkingWR
//
//  In-memory cache for location- and month-based bird lists (eBird + EOL results).
//

import Foundation
import CoreLocation

/// In-memory cache keyed by rounded region + month. No TTL; cleared on app restart.
final class BirdSpottingCache {
    static let shared = BirdSpottingCache()

    private var store: [String: [BirdInfo]] = [:]
    private let queue = DispatchQueue(label: "BirdSpottingCache", attributes: .concurrent)

    private init() {}

    func cacheKey(coordinate: CLLocationCoordinate2D, month: Int) -> String {
        let lat = Int(coordinate.latitude * 100)
        let lng = Int(coordinate.longitude * 100)
        return "bird_\(lat)_\(lng)_\(month)"
    }

    func get(key: String) -> [BirdInfo]? {
        queue.sync { store[key] }
    }

    func set(key: String, birds: [BirdInfo]) {
        queue.async(flags: .barrier) { [weak self] in
            self?.store[key] = birds
        }
    }
}
