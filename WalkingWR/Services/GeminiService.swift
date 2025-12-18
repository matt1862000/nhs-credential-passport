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
    func generateRouteContent(
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
        
        guard let url = URL(string: urlString) else {
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.serverError
        }
        
        if httpResponse.statusCode != 200 {
            if let errorString = String(data: data, encoding: .utf8) {
                print("🤖 Gemini API error (\(httpResponse.statusCode)): \(errorString)")
            }
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
            throw GeminiError.parseError
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

