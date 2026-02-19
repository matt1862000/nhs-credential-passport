//
//  WikipediaService.swift
//  WalkingWR
//
//  Fallback for bird description and image when EOL returns nothing. Uses REST API.
//

import Foundation

struct WikipediaSummary {
    let description: String?
    let imageURL: String?
}

private struct WikipediaSummaryResponse: Decodable {
    let extract: String?
    let thumbnail: Thumbnail?
    struct Thumbnail: Decodable {
        let source: String?
    }
}

final class WikipediaService {
    static let shared = WikipediaService()
    private static let logTag = "[BIRD_SPOT]"
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 6
        return URLSession(configuration: c)
    }()

    private init() {}

    /// Fetches short description and thumbnail for a page title (e.g. "European_robin").
    /// Use for bird common names; returns nil if page missing or request fails.
    func fetchSummary(commonName: String) async -> WikipediaSummary? {
        let title = commonName
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? commonName
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(title)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(WikipediaSummaryResponse.self, from: data)
            let desc = decoded.extract?.trimmingCharacters(in: .whitespacesAndNewlines)
            let img = decoded.thumbnail?.source
            if desc != nil || img != nil {
                return WikipediaSummary(description: desc, imageURL: img)
            }
            return nil
        } catch {
            return nil
        }
    }
}
