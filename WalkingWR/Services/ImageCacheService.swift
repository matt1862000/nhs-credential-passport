//
//  ImageCacheService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 21/12/2025.
//

import SwiftUI
import UIKit

/// A service that caches images for 24 hours to avoid unnecessary network requests
class ImageCacheService {
    static let shared = ImageCacheService()
    
    private let cache = NSCache<NSString, CachedImage>()
    private let cacheDirectory: URL
    private let cacheDuration: TimeInterval = 24 * 60 * 60 // 24 hours
    
    private init() {
        // Set up file-based cache directory
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("ClinicianPhotos")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Configure memory cache
        cache.countLimit = 50
    }
    
    /// Get cached image or fetch from network
    func getImage(for urlString: String, completion: @escaping (UIImage?) -> Void) {
        let key = NSString(string: urlString)
        
        // 1. Check memory cache
        if let cached = cache.object(forKey: key), !cached.isExpired {
            print("📷 Memory cache hit for: \(urlString.suffix(30))")
            completion(cached.image)
            return
        }
        
        // 2. Check disk cache
        let fileURL = cacheFileURL(for: urlString)
        if let diskCached = loadFromDisk(fileURL: fileURL) {
            // Add to memory cache
            let cachedImage = CachedImage(image: diskCached, timestamp: diskCacheTimestamp(for: fileURL))
            if !cachedImage.isExpired {
                print("📷 Disk cache hit for: \(urlString.suffix(30))")
                cache.setObject(cachedImage, forKey: key)
                completion(diskCached)
                return
            }
        }
        
        // 3. Fetch from network
        guard let url = URL(string: urlString) else {
            print("📷 Invalid URL: \(urlString)")
            completion(nil)
            return
        }
        
        print("📷 Fetching from network: \(urlString.suffix(50))")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            if let error = error {
                print("📷 Network error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📷 HTTP status: \(httpResponse.statusCode)")
            }
            
            guard let data = data, let image = UIImage(data: data) else {
                print("📷 Failed to decode image data")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            print("📷 Successfully fetched image, size: \(data.count) bytes")
            
            // Cache in memory
            let cachedImage = CachedImage(image: image, timestamp: Date())
            self.cache.setObject(cachedImage, forKey: key)
            
            // Cache on disk
            self.saveToDisk(image: image, fileURL: fileURL)
            
            DispatchQueue.main.async {
                completion(image)
            }
        }.resume()
    }
    
    // MARK: - Disk Cache Helpers
    
    private func cacheFileURL(for urlString: String) -> URL {
        let filename = urlString.data(using: .utf8)?.base64EncodedString() ?? "unknown"
        let safeFilename = filename.prefix(100) // Limit filename length
        return cacheDirectory.appendingPathComponent(String(safeFilename) + ".jpg")
    }
    
    private func saveToDisk(image: UIImage, fileURL: URL) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: fileURL)
    }
    
    private func loadFromDisk(fileURL: URL) -> UIImage? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return UIImage(data: data)
    }
    
    private func diskCacheTimestamp(for fileURL: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attributes?[.modificationDate] as? Date ?? Date.distantPast
    }
    
    /// Clear expired cache entries
    func clearExpiredCache() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        
        let now = Date()
        for file in files {
            let timestamp = diskCacheTimestamp(for: file)
            if now.timeIntervalSince(timestamp) > cacheDuration {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

/// Wrapper class for cached images with timestamp
private class CachedImage {
    let image: UIImage
    let timestamp: Date
    private let cacheDuration: TimeInterval = 24 * 60 * 60 // 24 hours
    
    init(image: UIImage, timestamp: Date) {
        self.image = image
        self.timestamp = timestamp
    }
    
    var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > cacheDuration
    }
}

