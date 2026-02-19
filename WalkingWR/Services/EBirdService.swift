//
//  EBirdService.swift
//  WalkingWR
//
//  eBird API client for recent observations by location. Species list + names for bird spotting.
//  API key from APIKeys.ebird (https://ebird.org/api/keygen). Non-commercial use.
//

import Foundation
import CoreLocation

// MARK: - Types

struct EBirdSpecies: Equatable {
    let speciesCode: String
    let commonName: String
    let scientificName: String
}

// MARK: - Response DTOs

private struct EBirdObservation: Decodable {
    let speciesCode: String?
    let comName: String?
    let sciName: String?
}

// MARK: - EBirdService

final class EBirdService {
    static let shared = EBirdService()
    private let baseURL = "https://api.ebird.org"
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    private init() {}

    /// Fetches species recently reported near the coordinate (last N days). Dedupes by species code.
    /// Returns empty array if key missing, or on network/parse failure (caller can fallback to static list).
    private static let logTag = "[BIRD_SPOT]"

    func fetchRecentSpecies(
        coordinate: CLLocationCoordinate2D,
        daysBack: Int = 30,
        radiusKm: Int = 25
    ) async -> [EBirdSpecies] {
        let key = APIKeys.ebird
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("\(Self.logTag) eBird: no API key, skipping")
            return []
        }

        var components = URLComponents(string: "\(baseURL)/v2/data/obs/geo/recent")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.6f", coordinate.latitude)),
            URLQueryItem(name: "lng", value: String(format: "%.6f", coordinate.longitude)),
            URLQueryItem(name: "back", value: String(min(30, max(1, daysBack)))),
            URLQueryItem(name: "dist", value: String(min(50, max(0, radiusKm))))
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "X-eBirdApiToken")
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("\(Self.logTag) eBird: non-HTTP response")
                return []
            }
            guard http.statusCode == 200 else {
                print("\(Self.logTag) eBird: HTTP \(http.statusCode) at \(coordinate.latitude),\(coordinate.longitude)")
                return []
            }
            let observations = try JSONDecoder().decode([EBirdObservation].self, from: data)
            var seen = Set<String>()
            var result: [EBirdSpecies] = []
            for obs in observations {
                guard let code = obs.speciesCode, !code.isEmpty, !seen.contains(code),
                      let common = obs.comName, let scientific = obs.sciName else { continue }
                seen.insert(code)
                result.append(EBirdSpecies(
                    speciesCode: code,
                    commonName: common.trimmingCharacters(in: .whitespacesAndNewlines),
                    scientificName: scientific.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            print("\(Self.logTag) eBird: got \(result.count) species near \(String(format: "%.4f", coordinate.latitude)),\(String(format: "%.4f", coordinate.longitude))")
            return result
        } catch {
            print("\(Self.logTag) eBird: error \(error.localizedDescription)")
            return []
        }
    }
}
