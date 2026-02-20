//
//  ORSService.swift
//  WalkingWR
//
//  ORS Isochrones V2 + Matrix V2 for topology (POI filtering, band classification, pre-score).
//  API key from APIKeys.openRouteService (Info.plist via Secrets.xcconfig + UserDefaults fallback).
//

import Foundation
import CoreLocation

// MARK: - Types

/// Walk-time band from isochrones: inner (shortest range), mid, outer (longest range).
enum POIWalkBand: String, Codable {
    case inner
    case mid
    case outer
}

/// One isochrone band: range in seconds and polygon (outer ring only).
struct IsochroneBand {
    let rangeSeconds: Int
    /// Outer ring of the polygon (closed: first point == last, or we close it in point-in-polygon).
    let polygon: [CLLocationCoordinate2D]
}

/// Result of fetchIsochroneBands: ordered from innermost to outermost.
struct IsochroneBands {
    /// Bands ordered by range ascending (inner first).
    let bands: [IsochroneBand]
    var outerPolygon: [CLLocationCoordinate2D]? { bands.last?.polygon }
}

/// Matrix API result: durations[i][j] = travel time from location i to j in seconds.
struct MatrixResult {
    let durations: [[Double]]
}

// MARK: - GeoJSON parsing (ORS isochrones)

private struct ORSIsochroneResponse: Decodable {
    let features: [ORSFeature]?
    struct ORSFeature: Decodable {
        let geometry: ORSGeometry?
        let properties: ORSProperties?
    }
    struct ORSGeometry: Decodable {
        let coordinates: [[[Double]]]?  // Polygon: [ ring ], ring = [ [lon, lat], ... ]
    }
    struct ORSProperties: Decodable {
        let value: Int?
    }
}

// MARK: - Cache key (~15m rounding: 4 decimals ≈ 11m at equator)

private func cacheKey(origin: CLLocationCoordinate2D, durationBucketMinutes: Int) -> String {
    let lat = (origin.latitude * 10000).rounded() / 10000
    let lon = (origin.longitude * 10000).rounded() / 10000
    return "\(lat)_\(lon)_\(durationBucketMinutes)_foot-walking"
}

private final class IsochroneCacheEntry {
    let bands: IsochroneBands
    let createdAt: Date
    init(bands: IsochroneBands) {
        self.bands = bands
        self.createdAt = Date()
    }
}

// MARK: - ORSService

final class ORSService {
    static let shared = ORSService()
    
    /// Log each ORS API request so you can see volume and rate (grep "ors_usage" in console).
    static func logORSUsage(type: String) {
        orsUsageLock.lock()
        let count = (orsUsageCounts[type] ?? 0) + 1
        orsUsageCounts[type] = count
        orsUsageLock.unlock()
        print("[ROUTE_FLOW] stage=ors_usage type=\(type) #\(count)")
    }
    private static var orsUsageCounts: [String: Int] = [:]
    private static let orsUsageLock = NSLock()
    
    /// When ORS_BASE_URL is set (e.g. to your Vercel proxy), use it and do not send the API key. Otherwise use ORS directly with key.
    private var baseURL: String {
        let proxy = APIKeys.orsBaseURL
        if !proxy.isEmpty { return proxy }
        return "https://api.openrouteservice.org"
    }
    
    private var useProxy: Bool { !APIKeys.orsBaseURL.isEmpty }
    
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10  // Fail fast so route gen can fall back to radius-based
        return URLSession(configuration: c)
    }()
    
    private var isochroneCache: [String: IsochroneCacheEntry] = [:]
    private let cacheLock = NSLock()
    private let cacheMaxEntries = 50
    private let cacheTTL: TimeInterval = 300  // 5 minutes
    
    private init() {}
    
    /// API key from shared source (Secrets → Info.plist or UserDefaults fallback).
    private var apiKey: String { APIKeys.openRouteService }
    
    private static var hasLoggedMissingKey = false
    var hasAPIKey: Bool {
        if useProxy { return true }
        let ok = !apiKey.isEmpty
        if !ok && !Self.hasLoggedMissingKey {
            Self.hasLoggedMissingKey = true
            print("[ROUTE_FLOW] stage=ors_key key=missing (check Secrets.xcconfig → Info.plist or set UserDefaults OPEN_ROUTE_SERVICE_API_KEY)")
        }
        return ok
    }
    
    // MARK: - Duration bucket → range (seconds)
    
    /// Map duration bucket (10, 20, 30, 45, 60) to isochrone ranges in seconds.
    static func rangeSeconds(forBucketMinutes bucket: Int) -> [Int] {
        switch bucket {
        case 10: return [600]
        case 20: return [600, 1200]
        case 30: return [600, 1200, 1800]
        case 45: return [600, 1200, 1800, 2700]
        case 60: return [600, 1200, 1800, 2700, 3600]
        default:
            if bucket <= 15 { return [600] }
            if bucket <= 25 { return [600, 1200] }
            if bucket <= 35 { return [600, 1200, 1800] }
            if bucket <= 50 { return [600, 1200, 1800, 2700] }
            return [600, 1200, 1800, 2700, 3600]
        }
    }
    
    /// Map target duration to bucket (10, 20, 30, 45, 60).
    static func durationBucket(minutes: Int) -> Int {
        if minutes <= 15 { return 10 }
        if minutes <= 25 { return 20 }
        if minutes <= 35 { return 30 }
        if minutes <= 52 { return 45 }
        return 60
    }
    
    // MARK: - Isochrones
    
    func fetchIsochroneBands(origin: CLLocationCoordinate2D, durationBucketMinutes: Int) async throws -> IsochroneBands {
        let key = cacheKey(origin: origin, durationBucketMinutes: durationBucketMinutes)
        cacheLock.lock()
        if let entry = isochroneCache[key], Date().timeIntervalSince(entry.createdAt) < cacheTTL {
            let bands = entry.bands
            cacheLock.unlock()
            return bands
        }
        cacheLock.unlock()

        guard hasAPIKey else { throw ORSServiceError.noAPIKey }
        Self.logORSUsage(type: "isochrones")

        let range = Self.rangeSeconds(forBucketMinutes: durationBucketMinutes)
        let url = URL(string: "\(baseURL)/v2/isochrones/foot-walking")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !useProxy { request.setValue(apiKey, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "locations": [[origin.longitude, origin.latitude]],
            "range": range
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        cacheLock.lock()
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                let cached = isochroneCache[key]?.bands
                cacheLock.unlock()
                if let cached = cached { return cached }
                throw ORSServiceError.rateLimited
            }
            if http.statusCode != 200 {
                cacheLock.unlock()
                throw ORSServiceError.httpStatus(http.statusCode, String(data: data.prefix(200), encoding: .utf8))
            }
        }
        cacheLock.unlock()

        let decoded = try JSONDecoder().decode(ORSIsochroneResponse.self, from: data)
        guard let features = decoded.features, !features.isEmpty else {
            throw ORSServiceError.invalidResponse("no features")
        }

        var bands: [IsochroneBand] = []
        for f in features {
            guard let geom = f.geometry, let coords = geom.coordinates, let ring = coords.first, ring.count >= 3 else { continue }
            let rangeSec = f.properties?.value ?? 0
            let polygon: [CLLocationCoordinate2D] = ring.map { arr in
                CLLocationCoordinate2D(latitude: arr[1], longitude: arr[0])
            }
            bands.append(IsochroneBand(rangeSeconds: rangeSec, polygon: polygon))
        }
        bands.sort { $0.rangeSeconds < $1.rangeSeconds }
        let result = IsochroneBands(bands: bands)

        cacheLock.lock()
        if isochroneCache.count >= cacheMaxEntries {
            let keysToRemove = Array(isochroneCache.keys.prefix(cacheMaxEntries / 2))
            for k in keysToRemove { isochroneCache.removeValue(forKey: k) }
        }
        isochroneCache[key] = IsochroneCacheEntry(bands: result)
        cacheLock.unlock()
        return result
    }
    
    /// Point-in-polygon (ray-casting). Polygon can be open or closed.
    func isPointInsidePolygon(_ point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        let n = polygon.count
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            if ((yi > point.latitude) != (yj > point.latitude)),
               (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
    
    /// Which band (inner/mid/outer) contains the point; bands ordered inner first. Returns nil if none.
    func band(for point: CLLocationCoordinate2D, bands: IsochroneBands) -> POIWalkBand? {
        let b = bands.bands
        if b.isEmpty { return nil }
        for (idx, band) in b.enumerated() {
            if isPointInsidePolygon(point, polygon: band.polygon) {
                if b.count == 1 { return .outer }
                if b.count == 2 { return idx == 0 ? .inner : .outer }
                if idx == 0 { return .inner }
                if idx == b.count - 1 { return .outer }
                return .mid
            }
        }
        return nil
    }
    
    // MARK: - Matrix
    
    /// Matrix with raw coordinates (for connectivity check). Each element is [lon, lat].
    private func fetchMatrix(locations: [[Double]]) async throws -> MatrixResult {
        guard hasAPIKey else { throw ORSServiceError.noAPIKey }
        guard locations.count >= 2 else { throw ORSServiceError.invalidResponse("need at least 2 locations") }
        Self.logORSUsage(type: "matrix")
        
        let url = URL(string: "\(baseURL)/v2/matrix/foot-walking")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !useProxy { request.setValue(apiKey, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "locations": locations,
            "metrics": ["duration"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw ORSServiceError.rateLimited }
            if http.statusCode != 200 {
                throw ORSServiceError.httpStatus(http.statusCode, String(data: data.prefix(200), encoding: .utf8))
            }
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let durations = json["durations"] as? [[Double]] else {
            throw ORSServiceError.invalidResponse("no durations")
        }
        return MatrixResult(durations: durations)
    }
    
    func fetchMatrix(origin: CLLocationCoordinate2D, waypoints: [PlaceResult]) async throws -> MatrixResult {
        var locations: [[Double]] = [[origin.longitude, origin.latitude]]
        for wp in waypoints {
            let c = wp.coordinate
            locations.append([c.longitude, c.latitude])
        }
        return try await fetchMatrix(locations: locations)
    }
    
    /// Sum origin→wp1, wp1→wp2, … , last→origin from matrix. Index 0 = origin, 1..<count = waypoints.
    func estimateLoopDuration(matrixResult: MatrixResult) -> TimeInterval {
        let d = matrixResult.durations
        guard d.count >= 2, let row0 = d.first, row0.count >= 2 else { return 0 }
        var total: Double = 0
        total += d[0][1]  // origin → first waypoint
        for i in 1..<(d.count - 1) {
            total += d[i][i + 1]  // waypoint i → waypoint i+1
        }
        total += d[d.count - 1][0]  // last waypoint → origin
        return total
    }
    
    // MARK: - Snap V2 (collaborative plan: 10000/day, 150/min)
    /// Snaps points to the walking network. Returns snapped coordinates in same order; for any point that could not be snapped (null from API), returns the original coordinate so result.count == coordinates.count.
    /// Requires API key; collaborative plan recommended for higher limits.
    func fetchSnapV2(coordinates: [CLLocationCoordinate2D], radiusMeters: Int = 100) async -> [CLLocationCoordinate2D]? {
        guard hasAPIKey, coordinates.count >= 1, coordinates.count <= 100 else { return nil }
        Self.logORSUsage(type: "snap")
        let locations = coordinates.map { [ $0.longitude, $0.latitude ] }
        guard let url = URL(string: "\(baseURL)/v2/snap/foot-walking") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !useProxy { request.setValue(apiKey, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "locations": locations,
            "radius": radiusMeters
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if let http = response as? HTTPURLResponse {
                    print("[ROUTE_FLOW] stage=ors_snap_v2 status=\(http.statusCode)")
                }
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultLocations = json["locations"] as? [Any],
                  resultLocations.count == coordinates.count else {
                print("[ROUTE_FLOW] stage=ors_snap_v2 invalid_response")
                return nil
            }
            var snapped: [CLLocationCoordinate2D] = []
            for (i, item) in resultLocations.enumerated() {
                if let obj = item as? [String: Any],
                   let loc = obj["location"] as? [Double],
                   loc.count >= 2 {
                    snapped.append(CLLocationCoordinate2D(latitude: loc[1], longitude: loc[0]))
                } else {
                    snapped.append(coordinates[i])
                }
            }
            print("[WALK_REFRESH] [ROUTE_FLOW] stage=ors_snap_v2 ok points=\(coordinates.count)")
            return snapped
        } catch {
            print("[ROUTE_FLOW] stage=ors_snap_v2 error=\(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Connectivity check (same as scripts/test_free_routing_apis.py)
    
    private static var hasVerifiedConnectivity = false
    
    /// One-time check that ORS isochrones and matrix are reachable with the current key.
    /// Logs [ROUTE_FLOW] stage=ors_connectivity isochrones=OK|FAIL matrix=OK|FAIL. Call when you have an origin (e.g. first route gen).
    func runConnectivityCheckIfNeeded(origin: CLLocationCoordinate2D) {
        guard !Self.hasVerifiedConnectivity else { return }
        Self.hasVerifiedConnectivity = true
        Task {
            let isochronesOk: Bool
            let matrixOk: Bool
            if !hasAPIKey {
                isochronesOk = false
                matrixOk = false
            } else {
                isochronesOk = (try? await fetchIsochroneBands(origin: origin, durationBucketMinutes: 20)) != nil
                let delta: Double = 0.008
                let locs: [[Double]] = [
                    [origin.longitude, origin.latitude],
                    [origin.longitude + delta, origin.latitude],
                    [origin.longitude, origin.latitude + delta]
                ]
                matrixOk = (try? await fetchMatrix(locations: locs)) != nil
            }
            print("[ROUTE_FLOW] stage=ors_connectivity isochrones=\(isochronesOk ? "OK" : "FAIL") matrix=\(matrixOk ? "OK" : "FAIL") (same check as scripts/test_free_routing_apis.py)")
        }
    }
}

enum ORSServiceError: Error {
    case noAPIKey
    case rateLimited
    case httpStatus(Int, String?)
    case invalidResponse(String)
}
