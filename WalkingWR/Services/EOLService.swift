//
//  EOLService.swift
//  WalkingWR
//
//  Encyclopedia of Life API client for species description, habitat, and image URL.
//  Used to enrich bird spotting content (eBird provides list + names only).
//

import Foundation

// MARK: - Types

struct EOLSpeciesContent {
    let description: String?
    let habitat: String?
    let imageURL: String?
}

// MARK: - Response DTOs (defensive: all optional)

private struct EOLSearchResponse: Decodable {
    let results: [EOLSearchResult]?
    struct EOLSearchResult: Decodable {
        let id: Int?
        let title: String?
    }
}

private struct EOLPageResponse: Decodable {
    let dataObjects: [EOLDataObject]?
    let data_objects: [EOLDataObject]?
    let taxonConcepts: [EOLTaxonConcept]?

    var objects: [EOLDataObject]? {
        if let o = dataObjects ?? data_objects, !o.isEmpty { return o }
        return taxonConcepts?.first?.dataObjects ?? taxonConcepts?.first?.data_objects
    }

    struct EOLTaxonConcept: Decodable {
        let dataObjects: [EOLDataObject]?
        let data_objects: [EOLDataObject]?
    }

    struct EOLDataObject: Decodable {
        let eolMediaURL: String?
        let eol_media_url: String?
        let mimeType: String?
        let mime_type: String?
        let dataType: String?
        let data_type: String?
        let title: String?
        let description: String?
        let license: String?

        var mediaURL: String? { eolMediaURL ?? eol_media_url }
        var mime: String? { mimeType ?? mime_type }
        var type: String? { dataType ?? data_type }
    }
}

// MARK: - EOLService

final class EOLService {
    static let shared = EOLService()
    private static let logTag = "[BIRD_SPOT]"
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    private init() {}

    /// Fetches description, habitat, and image URL for a species. Tries scientific name first, then common name.
    func fetchSpeciesContent(commonName: String, scientificName: String) async -> EOLSpeciesContent {
        if let content = await fetchSpeciesContent(query: scientificName, label: commonName) {
            return content
        }
        if commonName != scientificName, let content = await fetchSpeciesContent(query: commonName, label: commonName) {
            return content
        }
        return EOLSpeciesContent(description: nil, habitat: nil, imageURL: nil)
    }

    private func fetchSpeciesContent(query: String, label: String) async -> EOLSpeciesContent? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let searchURL = URL(string: "https://eol.org/api/search/1.0.json?q=\(encoded)&exact=true") else {
            return nil
        }

        do {
            let (searchData, _) = try await session.data(from: searchURL)
            let searchDecoded = try? JSONDecoder().decode(EOLSearchResponse.self, from: searchData)
            let firstId = searchDecoded?.results?.first?.id
            guard let pageId = firstId else {
                return nil
            }

            guard let pageURL = URL(string: "https://eol.org/api/pages/1.0/\(pageId).json?images=5&text=10") else {
                return nil
            }
            let (pageData, _) = try await session.data(from: pageURL)
            let pageDecoded = try? JSONDecoder().decode(EOLPageResponse.self, from: pageData)
            let objectCount = pageDecoded?.objects?.count ?? 0

            var description: String?
            var habitat: String?
            var imageURL: String?

            if let objects = pageDecoded?.objects {
                for obj in objects {
                    if let desc = obj.description, !desc.isEmpty, description == nil {
                        let cleaned = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleaned.count > 20 { description = String(cleaned.prefix(400)) }
                    }
                    if let tit = obj.title?.lowercased(), (tit.contains("habitat") || tit.contains("distribution")), let desc = obj.description, !desc.isEmpty {
                        habitat = String(desc.prefix(200)).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let url = obj.mediaURL, (obj.mime?.hasPrefix("image/") == true || obj.type == "image"), imageURL == nil {
                        imageURL = url
                    }
                }
            }

            if objectCount == 0 {
                print("\(Self.logTag) EOL \(label): page \(pageId) has 0 dataObjects (check API shape)")
            }
            return EOLSpeciesContent(description: description, habitat: habitat, imageURL: imageURL)
        } catch {
            print("\(Self.logTag) EOL \(label): \(error.localizedDescription)")
            return nil
        }
    }
}
