//
//  GeminiService.swift
//  WalkingWR
//
//  AI-powered content generation using Google Gemini
//

import Foundation

class GeminiService {
    static let shared = GeminiService()
    
    // Use Google Cloud Maps API key (with Generative Language API enabled)
    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "GOOGLE_MAPS_API_KEY") as? String ?? ""
    }
    
    private let session = URLSession.shared
    
    // v1.9.3: Comprehensive API call tracking
    private struct APICallRecord {
        var success: Bool
        var httpStatus: Int?
        var responseTime: TimeInterval?
        var errorMessage: String?
        var bundleIdSent: Bool
        var timestamp: Date
        var details: String?  // Additional context (e.g., "route name generation")
    }
    private var apiCallRecords: [APICallRecord] = []
    
    private func recordAPICall(
        success: Bool,
        httpStatus: Int? = nil,
        responseTime: TimeInterval? = nil,
        errorMessage: String? = nil,
        bundleIdSent: Bool = false,
        details: String? = nil
    ) {
        apiCallRecords.append(APICallRecord(
            success: success,
            httpStatus: httpStatus,
            responseTime: responseTime,
            errorMessage: errorMessage,
            bundleIdSent: bundleIdSent,
            timestamp: Date(),
            details: details
        ))
    }
    
    func printAPICallSummary() {
        guard !apiCallRecords.isEmpty else { return }
        
        let successCount = apiCallRecords.filter { $0.success }.count
        let failCount = apiCallRecords.filter { !$0.success }.count
        let totalCount = apiCallRecords.count
        
        let status = failCount == 0 ? "✅" : (successCount == 0 ? "❌" : "⚠️")
        print("")
        print("\(status) Generative Language API (Gemini)")
        print("   Calls: \(totalCount) total (\(successCount) success, \(failCount) failed)")
        
        // Show bundle ID status
        let bundleIdSentCount = apiCallRecords.filter { $0.bundleIdSent }.count
        if bundleIdSentCount > 0 {
            print("   📱 Bundle ID: Sent in \(bundleIdSentCount)/\(totalCount) calls")
        } else {
            print("   ⚠️  Bundle ID: NOT sent (may cause restrictions)")
        }
        
        // Show response times
        let successfulCalls = apiCallRecords.filter { $0.success && $0.responseTime != nil }
        if !successfulCalls.isEmpty {
            let avgTime = successfulCalls.compactMap { $0.responseTime }.reduce(0, +) / Double(successfulCalls.count)
            let minTime = successfulCalls.compactMap { $0.responseTime }.min() ?? 0
            let maxTime = successfulCalls.compactMap { $0.responseTime }.max() ?? 0
            print("   ⏱️  Response time: avg \(String(format: "%.2f", avgTime))s (min: \(String(format: "%.2f", minTime))s, max: \(String(format: "%.2f", maxTime))s)")
        }
        
        // Show recent failures
        let recentFailures = apiCallRecords.filter { !$0.success }.suffix(3)
        if !recentFailures.isEmpty {
            print("   ❌ Recent failures:")
            for failure in recentFailures {
                if let status = failure.httpStatus {
                    print("      • HTTP \(status)", terminator: "")
                }
                if let error = failure.errorMessage {
                    let shortError = error.count > 60 ? String(error.prefix(60)) + "..." : error
                    print(": \(shortError)")
                } else {
                    print("")
                }
            }
        }
        
        // Don't clear results - keep them for later summary
    }
    
    /// Waypoint info for AI description generation
    struct WaypointInfo {
        let name: String
        let types: [String]
        let vicinity: String?
    }
    
    /// AI-generated route content
    struct RouteContent {
        let name: String
        let description: String
    }
    
    /// Generate both a creative route name and personalized description using AI
    /// Falls back to privacy-safe templates if API fails, quota exceeded, or takes >1 second
    func generateRouteContent(
        waypoints: [WaypointInfo],
        durationMinutes: Int,
        distanceMeters: Int,
        difficulty: RouteDifficulty?,
        originCoordinate: (lat: Double, lon: Double)? = nil  // For privacy filtering
    ) async -> RouteContent {
        // Try Gemini first if API key available, with 3 second timeout
        // Gemini typically takes 1-3 seconds, so 3s gives enough time without blocking too long
        if !apiKey.isEmpty {
            let startTime = Date()
            
            // Create a task with timeout
            let geminiTask = Task {
                await tryGeminiGeneration(
                waypoints: waypoints,
                durationMinutes: durationMinutes,
                distanceMeters: distanceMeters,
                difficulty: difficulty
                )
            }
            
            // Wait up to 3 seconds for Gemini response
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                geminiTask.cancel()
            }
            
            // Check if task was cancelled or completed
            if let geminiContent = await geminiTask.value {
                timeoutTask.cancel()
                let elapsed = Date().timeIntervalSince(startTime)
                print("🤖 ✅ Gemini generated: \(geminiContent.name) (in \(String(format: "%.2f", elapsed))s)")
                return geminiContent
            }
            
            // If we get here, Gemini didn't return content (timeout or error)
            let elapsed = Date().timeIntervalSince(startTime)
            if geminiTask.isCancelled {
                print("🤖 ⏱️  Gemini request cancelled after \(String(format: "%.2f", elapsed))s (timeout), using local template")
            } else if elapsed >= 3.0 {
                print("🤖 ⏱️  Gemini timed out after \(String(format: "%.2f", elapsed))s, using local template")
            } else {
                print("🤖 ⚠️  Gemini failed (no response), falling back to template")
            }
        } else {
            print("🤖 No Gemini API key, using template")
        }
        
        // Fallback to privacy-safe templates (ALWAYS succeeds)
        let templateContent = generateTemplateContent(
            waypoints: waypoints,
            durationMinutes: durationMinutes,
            distanceMeters: distanceMeters,
            originCoordinate: originCoordinate
        )
        print("🏷️ Template generated: \(templateContent.name)")
        return templateContent
    }
    
    /// Privacy-safe template-based name and description generation
    /// Only references POIs far from start location to protect user's home area
    func generateTemplateContent(
        waypoints: [WaypointInfo],
        durationMinutes: Int,
        distanceMeters: Int,
        originCoordinate: (lat: Double, lon: Double)? = nil
    ) -> RouteContent {
        // Filter to POIs that are safe to mention (not near home)
        // For privacy, we prefer POIs in the middle/far end of the route
        // Since waypoints are ordered along the route, prefer middle/later ones
        let safeWaypoints: [WaypointInfo]
        if waypoints.count >= 3 {
            // Skip first waypoint (too close to start), use middle/far ones
            safeWaypoints = Array(waypoints.dropFirst())
        } else if waypoints.count == 2 {
            // Use the second (farther) waypoint
            safeWaypoints = [waypoints[1]]
        } else {
            safeWaypoints = waypoints
        }
        
        // Get the best POI to feature (prefer named landmarks over generic places)
        let featurePOI = selectBestPOI(from: safeWaypoints)
        
        // Generate name
        let name = generateTemplateName(
            featurePOI: featurePOI,
            durationMinutes: durationMinutes,
            waypointCount: waypoints.count
        )
        
        // Generate description
        let description = generateTemplateDescription(
            featurePOI: featurePOI,
            safeWaypoints: safeWaypoints,
            durationMinutes: durationMinutes,
            distanceMeters: distanceMeters,
            totalWaypoints: waypoints.count
        )
        
        print("🏷️ Template name: \(name)")
        print("🏷️ Template description: \(description)")
        
        return RouteContent(name: name, description: description)
    }
    
    /// Select the best POI to feature in the route name
    private func selectBestPOI(from waypoints: [WaypointInfo]) -> WaypointInfo? {
        guard !waypoints.isEmpty else { return nil }
        
        // Prefer POIs with interesting types (pubs, churches, parks, etc.)
        let interestingTypes = Set(["bar", "pub", "restaurant", "cafe", "church", "park", 
                                     "museum", "library", "school", "bakery", "post_office"])
        
        // Score each POI
        let scored = waypoints.map { poi -> (poi: WaypointInfo, score: Int) in
            var score = 0
            
            // Bonus for interesting types
            if poi.types.contains(where: { interestingTypes.contains($0) }) {
                score += 10
            }
            
            // Bonus for having a proper name (not just "Point of Interest")
            if !poi.name.lowercased().contains("point of interest") && 
               !poi.name.lowercased().contains("unnamed") {
                score += 5
            }
            
            // Bonus for shorter names (easier to display)
            if poi.name.count <= 20 {
                score += 3
            }
            
            return (poi, score)
        }
        
        return scored.max(by: { $0.score < $1.score })?.poi
    }
    
    /// Generate a template-based route name
    private func generateTemplateName(
        featurePOI: WaypointInfo?,
        durationMinutes: Int,
        waypointCount: Int
    ) -> String {
        // If we have a good POI, use it
        if let poi = featurePOI {
            let shortName = shortenPOIName(poi.name)
            
            // Different templates based on POI type
            let poiType = poi.types.first ?? ""
            
            switch poiType {
            case "bar", "pub", "restaurant":
                return "Loop via \(shortName)"
            case "church", "place_of_worship":
                return "\(shortName) Walk"
            case "park", "natural_feature":
                return "\(shortName) Stroll"
            case "school", "university":
                return "Walk past \(shortName)"
            default:
                return "Via \(shortName)"
            }
        }
        
        // Fallback to duration-based names
        switch durationMinutes {
        case 1...10:
            return "Quick Loop"
        case 11...20:
            return "Discovery Walk"
        case 21...35:
            return "Local Circular"
        case 36...50:
            return "Extended Stroll"
        default:
            return "Long Walk"
        }
    }
    
    /// Shorten a POI name to fit in route title
    private func shortenPOIName(_ name: String) -> String {
        // Remove common prefixes
        var shortened = name
        let prefixesToRemove = ["The ", "St ", "St. "]
        for prefix in prefixesToRemove {
            if shortened.hasPrefix(prefix) && shortened.count > 15 {
                shortened = String(shortened.dropFirst(prefix.count))
                break
            }
        }
        
        // Truncate if still too long
        if shortened.count > 18 {
            let words = shortened.components(separatedBy: " ")
            if words.count > 2 {
                // Use first two words
                shortened = words.prefix(2).joined(separator: " ")
            } else {
                shortened = String(shortened.prefix(18))
            }
        }
        
        return shortened
    }
    
    /// Generate a template-based description
    private func generateTemplateDescription(
        featurePOI: WaypointInfo?,
        safeWaypoints: [WaypointInfo],
        durationMinutes: Int,
        distanceMeters: Int,
        totalWaypoints: Int
    ) -> String {
        let distanceKm = String(format: "%.1f", Double(distanceMeters) / 1000.0)
        
        if let poi = featurePOI {
            let poiType = formatPlaceTypes(poi.types)
            
            // Get a second POI if available
            let secondPOI = safeWaypoints.first(where: { $0.name != poi.name })
            
            if let second = secondPOI {
                return "A \(durationMinutes) minute circular walk passing \(poi.name) and \(second.name). Distance: \(distanceKm)km."
            } else {
                return "A \(durationMinutes) minute loop featuring \(poi.name) (\(poiType)). Approximately \(distanceKm)km with \(totalWaypoints) points of interest."
            }
        }
        
        // Generic fallback
        return "A \(durationMinutes) minute circular walk covering \(distanceKm)km with \(totalWaypoints) discovery spots along the way."
    }
    
    /// Try to generate content using Gemini API
    private func tryGeminiGeneration(
        waypoints: [WaypointInfo],
        durationMinutes: Int,
        distanceMeters: Int,
        difficulty: RouteDifficulty?
    ) async -> RouteContent? {
        guard !apiKey.isEmpty else {
            print("🤖 Gemini: No API key")
            return nil
        }
        
        let difficultyText: String
        switch difficulty {
        case .easy: difficultyText = "easy, gentle"
        case .moderate: difficultyText = "moderate"
        case .challenging: difficultyText = "challenging, brisk"
        case .none: difficultyText = "comfortable"
        }
        
        // Build detailed waypoint descriptions
        let waypointDescriptions = waypoints.map { wp in
            let typeDescription = formatPlaceTypes(wp.types)
            if let vicinity = wp.vicinity, !vicinity.isEmpty {
                return "\(wp.name) (\(typeDescription)) near \(vicinity)"
            } else {
                return "\(wp.name) (\(typeDescription))"
            }
        }.joined(separator: "; ")
        
        // Extract unique place categories for context
        let allTypes = waypoints.flatMap { $0.types }
        let meaningfulTypes = Set(allTypes.compactMap { formatSingleType($0) })
        let categoryContext = meaningfulTypes.prefix(4).joined(separator: ", ")
        
        let prompt = """
        Create a fun, creative name AND a warm description for a walking route that a patient can take while waiting for their medical appointment.
        
        WAYPOINTS YOU'LL PASS:
        \(waypointDescriptions)
        
        ROUTE CONTEXT:
        - Total walk time: \(durationMinutes) minutes
        - Distance: approximately \(distanceMeters) meters
        - Walking pace: \(difficultyText)
        - Categories of places: \(categoryContext)
        - Number of discovery spots: \(waypoints.count)
        
        RESPOND IN EXACTLY THIS FORMAT (two lines only):
        NAME: [Your creative route name here]
        DESCRIPTION: [Your 2-sentence description here]
        
        NAME GUIDELINES:
        - Make it fun, memorable, and specific to THIS route
        - MAXIMUM 20 CHARACTERS (this is critical - will be truncated otherwise)
        - 2-4 words maximum
        - Can be playful, alliterative, or reference a key landmark
        - Examples of good styles: "Pub & Spire Stroll", "Bakery Loop", "Garden Gateway", "High Street Wander", "Cosy Circuit"
        - Don't use generic names like "Local Discovery" or "Neighbourhood Walk"
        - Don't start with "The" to save characters
        
        DESCRIPTION GUIDELINES:
        - YOU MUST mention at least 2 specific place names from the waypoints list
        - Describe something CONCRETE about each place (e.g. "grab a coffee at Costa", "see the historic church spire", "pass the colourful nursery gardens")
        - NO generic phrases like "enjoy fresh air", "take a breath", "clear your mind", "stretch your legs"
        - Instead, be SPECIFIC: what will they actually SEE, SMELL, HEAR at these places?
        - If it's a pub/restaurant: mention you could peek at the menu or smell the food
        - If it's a church: mention the architecture or peaceful grounds
        - If it's a shop: mention window shopping or the products
        - If it's a park/nursery: mention specific things like flowers, trees, benches
        - Keep it under 40 words
        - Don't mention exact times or distances
        - Make it sound like a friend giving directions, not a travel brochure
        
        BAD EXAMPLE: "Enjoy some fresh air as you stroll past local landmarks and take a moment to relax."
        GOOD EXAMPLE: "Pop past The Star Inn with its hanging flower baskets, then swing by Lindale Church - the old stone tower is worth a look."
        
        Remember: Respond ONLY with the two lines starting with NAME: and DESCRIPTION:
        """
        
        do {
            guard let response = try await callGemini(prompt: prompt) else {
                return nil
            }
            
            // Parse the response
            let lines = response.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var name: String?
            var description: String?
            
            for line in lines {
                if line.uppercased().hasPrefix("NAME:") {
                    name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                } else if line.uppercased().hasPrefix("DESCRIPTION:") {
                    description = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                }
            }
            
            if let name = name, let description = description, !name.isEmpty, !description.isEmpty {
                // Truncate name if too long (max 22 characters)
                let truncatedName: String
                if name.count > 22 {
                    // Try to truncate at a word boundary
                    let words = name.components(separatedBy: " ")
                    var result = ""
                    for word in words {
                        if result.isEmpty {
                            result = word
                        } else if (result + " " + word).count <= 22 {
                            result += " " + word
                        } else {
                            break
                        }
                    }
                    truncatedName = result.isEmpty ? String(name.prefix(22)) : result
                } else {
                    truncatedName = name
                }
                
                print("🤖 Gemini generated name: \(truncatedName)")
                print("🤖 Gemini generated description: \(description)")
                return RouteContent(name: truncatedName, description: description)
            } else {
                print("🤖 Gemini: Failed to parse response: \(response)")
                return nil
            }
        } catch {
            print("🤖 Gemini error: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Format place types into readable text
    private func formatPlaceTypes(_ types: [String]) -> String {
        let formatted = types.prefix(2).compactMap { formatSingleType($0) }
        return formatted.isEmpty ? "local spot" : formatted.joined(separator: ", ")
    }
    
    /// Format a single Google place type into readable text
    private func formatSingleType(_ type: String) -> String? {
        // Types that are too generic and should be ignored
        let ignoredTypes = Set(["point_of_interest", "establishment", "premise", "route", "street_address", "geocode", "locality", "political", "sublocality"])
        
        if ignoredTypes.contains(type) {
            return nil
        }
        
        let typeMap: [String: String] = [
            "park": "park",
            "cafe": "café",
            "restaurant": "restaurant",
            "bar": "bar",
            "church": "church",
            "museum": "museum",
            "library": "library",
            "school": "school",
            "university": "university",
            "hospital": "hospital",
            "pharmacy": "pharmacy",
            "supermarket": "supermarket",
            "store": "shop",
            "shopping_mall": "shopping centre",
            "gym": "gym",
            "spa": "spa",
            "beauty_salon": "salon",
            "hair_care": "hair salon",
            "bakery": "bakery",
            "bank": "bank",
            "post_office": "post office",
            "gas_station": "petrol station",
            "parking": "car park",
            "lodging": "hotel",
            "tourist_attraction": "attraction",
            "place_of_worship": "place of worship",
            "natural_feature": "nature spot"
        ]
        
        // Return mapped type or format the original type if not in map
        if let mapped = typeMap[type] {
            return mapped
        }
        
        // Convert snake_case to readable format for unmapped types
        return type.replacingOccurrences(of: "_", with: " ")
    }
    
    private func callGemini(prompt: String) async throws -> String? {
        // Gemini API endpoint - using gemini-2.0-flash model
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
        
        print("🤖 ═══════════════════════════════════════════════════════")
        print("🤖 GEMINI API: Starting request...")
        print("🤖   🔗 Endpoint: generativelanguage.googleapis.com")
        print("🤖   🔑 API Key present: \(!apiKey.isEmpty), prefix: \(String(apiKey.prefix(10)))...")
        print("🤖   📝 Prompt length: \(prompt.count) characters")
        
        guard let url = URL(string: urlString) else {
            print("🤖   ❌ ERROR: Invalid URL")
            print("🤖 ═══════════════════════════════════════════════════════")
            throw GeminiError.invalidURL
        }
        
        // Build request body
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // v1.9.13: Set explicit timeout for slow networks
        request.timeoutInterval = 30.0 // 30 second timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-goog-api-key")
        // Add iOS bundle ID for API key restrictions
        let bundleIdSent: Bool
        if let bundleId = Bundle.main.bundleIdentifier {
            request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
            bundleIdSent = true
            print("🤖   📱 Bundle ID: \(bundleId)")
        } else {
            bundleIdSent = false
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Use custom session with timeout configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let timeoutSession = URLSession(configuration: config)
        
        let startTime = Date()
        print("🤖   ⏱️  Making HTTP request...")
        let (data, response) = try await timeoutSession.data(for: request)
        let elapsed = Date().timeIntervalSince(startTime)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("🤖   ❌ ERROR: No HTTP response")
            print("🤖 ═══════════════════════════════════════════════════════")
            recordAPICall(
                success: false,
                responseTime: elapsed,
                errorMessage: "No HTTP response",
                bundleIdSent: bundleIdSent,
                details: "route name generation"
            )
            throw GeminiError.serverError
        }
        
        print("🤖   📡 HTTP Status: \(httpResponse.statusCode)")
        print("🤖   📦 Response size: \(data.count) bytes")
        print("🤖   ⏱️  Response time: \(String(format: "%.2f", elapsed))s")
        
        if httpResponse.statusCode != 200 {
            var errorMessage: String?
            if let errorString = String(data: data, encoding: .utf8) {
                print("🤖   ❌ ERROR: \(errorString)")
                print("🤖   📄 Full error response (first 500 chars): \(String(errorString.prefix(500)))")
                
                // Check if it's a bundle ID restriction error
                if httpResponse.statusCode == 403,
                   let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = errorJson["error"] as? [String: Any] {
                    errorMessage = error["message"] as? String ?? "iOS app blocked"
                } else {
                    errorMessage = "HTTP \(httpResponse.statusCode)"
                }
            } else {
                errorMessage = "HTTP \(httpResponse.statusCode) - Unknown error"
            }
            
            recordAPICall(
                success: false,
                httpStatus: httpResponse.statusCode,
                responseTime: elapsed,
                errorMessage: errorMessage,
                bundleIdSent: bundleIdSent,
                details: "route name generation"
            )
            
            print("🤖 ═══════════════════════════════════════════════════════")
            throw GeminiError.apiError("Status \(httpResponse.statusCode)")
        }
        
        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            print("🤖   ❌ ERROR: Failed to parse response")
            if let rawResponse = String(data: data, encoding: .utf8) {
                print("🤖   📄 Raw response (first 500 chars): \(String(rawResponse.prefix(500)))")
            }
            print("🤖 ═══════════════════════════════════════════════════════")
            recordAPICall(
                success: false,
                httpStatus: httpResponse.statusCode,
                responseTime: elapsed,
                errorMessage: "Failed to parse response",
                bundleIdSent: bundleIdSent,
                details: "route name generation"
            )
            throw GeminiError.parseError
        }
        
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("🤖   ✅ SUCCESS: Generated \(result.count) characters")
        print("🤖   📄 Response preview: \(String(result.prefix(100)))...")
        print("🤖 ═══════════════════════════════════════════════════════")
        
        // Record success
        recordAPICall(
            success: true,
            httpStatus: httpResponse.statusCode,
            responseTime: elapsed,
            bundleIdSent: bundleIdSent,
            details: "route name generation, \(result.count) chars"
        )
        
        return result
    }
}

enum GeminiError: LocalizedError {
    case invalidURL
    case serverError
    case apiError(String)
    case parseError
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .serverError: return "Server error"
        case .apiError(let msg): return "API error: \(msg)"
        case .parseError: return "Failed to parse response"
        }
    }
}

