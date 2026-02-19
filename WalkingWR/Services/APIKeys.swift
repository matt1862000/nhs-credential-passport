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
    private static let ebirdPlistKey = "EBIRD_API_KEY"
    private static let ebirdUserDefaultsKey = "EBIRD_API_KEY"
    
    /// OpenRouteService API key. Read from Info.plist (injected by Secrets.xcconfig at build time), then UserDefaults fallback.
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
