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
    
    /// Generate an engaging, personalized route description using AI
    func generateRouteDescription(
        places: [String],
        durationMinutes: Int,
        distanceMeters: Int,
        difficulty: RouteDifficulty?
    ) async -> String? {
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
        
        let placesText = places.joined(separator: ", ")
        
        let prompt = """
        Write a brief, warm, and calming 2-sentence description for a walking route. 
        This is for a healthcare app helping people pass time while waiting for medical appointments.
        
        Route details:
        - Duration: \(durationMinutes) minutes
        - Distance: \(distanceMeters) meters
        - Places passed: \(placesText)
        - Pace: \(difficultyText)
        
        Guidelines:
        - Be encouraging and positive
        - Mention one or two of the places naturally
        - Include a subtle mindfulness or wellness angle
        - Keep it under 40 words
        - Don't mention the exact duration or distance numbers
        - Don't use phrases like "this route" - be more natural
        
        Just provide the description, no quotes or labels.
        """
        
        do {
            let description = try await callGemini(prompt: prompt)
            print("🤖 Gemini generated: \(description ?? "nil")")
            return description
        } catch {
            print("🤖 Gemini error: \(error.localizedDescription)")
            return nil
        }
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

