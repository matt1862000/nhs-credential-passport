//
//  BirdSpottingCache.swift
//  WalkingWR
//
//  In-memory cache for location- and month-based bird lists (eBird + EOL results).
//  Also persists the last downloaded list so the Bird Spotting screen can show it on next open.
//

import Foundation
import CoreLocation

private let lastKeyUD = "bird_spotting_last_key"
private let lastBirdsUD = "bird_spotting_last_birds"
private let lastPlaceNameUD = "bird_spotting_last_place"

/// In-memory cache keyed by rounded region + month. Also persists last list for restore on next open.
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

    /// Save the last downloaded list so we can show it when the user opens Bird Spotting again.
    func saveLast(key: String, birds: [BirdInfo], placeName: String?) {
        guard !birds.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(birds)
            UserDefaults.standard.set(key, forKey: lastKeyUD)
            UserDefaults.standard.set(data, forKey: lastBirdsUD)
            UserDefaults.standard.set(placeName, forKey: lastPlaceNameUD)
        } catch {
            print("[BIRD_SPOT] Failed to persist bird list: \(error.localizedDescription)")
        }
    }

    /// Restore last list if the stored key matches current location+month. Returns (birds, placeName) or nil.
    func getLast(currentKey: String) -> ([BirdInfo], String?)? {
        guard let storedKey = UserDefaults.standard.string(forKey: lastKeyUD),
              storedKey == currentKey,
              let data = UserDefaults.standard.data(forKey: lastBirdsUD) else {
            return nil
        }
        do {
            let birds = try JSONDecoder().decode([BirdInfo].self, from: data)
            guard !birds.isEmpty else { return nil }
            let placeName = UserDefaults.standard.string(forKey: lastPlaceNameUD)
            return (birds, placeName)
        } catch {
            print("[BIRD_SPOT] Failed to decode persisted bird list: \(error.localizedDescription)")
            return nil
        }
    }
}
