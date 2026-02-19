//
//  APIKeys.swift
//  WalkingWR
//
//  Single source for API keys: Bundle (from Secrets.xcconfig → Info.plist) with optional UserDefaults fallback for dev.
//

import Foundation

enum APIKeys {
    private static let orsPlistKey = "OPEN_ROUTE_SERVICE_API_KEY"
    private static let orsUserDefaultsKey = "OPEN_ROUTE_SERVICE_API_KEY"
    private static let orsBaseURLPlistKey = "ORS_BASE_URL"
    private static let orsBaseURLUserDefaultsKey = "ORS_BASE_URL"
    private static let ebirdPlistKey = "EBIRD_API_KEY"
    private static let ebirdUserDefaultsKey = "EBIRD_API_KEY"
    
    /// Base URL for ORS requests. When set to your proxy (e.g. https://wait-well.vercel.app/api/ors), the app does not send the API key (key stays server-side). When unset, app uses api.openrouteservice.org and sends OPEN_ROUTE_SERVICE_API_KEY.
    static var orsBaseURL: String {
        let fromPlist = (Bundle.main.object(forInfoDictionaryKey: orsBaseURLPlistKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromPlist.isEmpty { return fromPlist }
        return (UserDefaults.standard.string(forKey: orsBaseURLUserDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// OpenRouteService API key. Read from Info.plist (injected by Secrets.xcconfig at build time), then UserDefaults fallback. Not sent when orsBaseURL points to your proxy.
    static var openRouteService: String {
        let fromPlist = (Bundle.main.object(forInfoDictionaryKey: orsPlistKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromPlist.isEmpty { return fromPlist }
        return (UserDefaults.standard.string(forKey: orsUserDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// eBird API key for bird spotting (recent observations by location). Get a free key at https://ebird.org/api/keygen
    static var ebird: String {
        let fromPlist = (Bundle.main.object(forInfoDictionaryKey: ebirdPlistKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromPlist.isEmpty { return fromPlist }
        return (UserDefaults.standard.string(forKey: ebirdUserDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
