//
//  PhotoStorageService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 09/12/2025.
//

import SwiftUI
import Foundation

class PhotoStorageService: ObservableObject {
    static let shared = PhotoStorageService()
    
    @Published var capturedPhotos: [CapturedPhoto] = []
    
    private let fileManager = FileManager.default
    private let photosDirectory: URL
    private let metadataKey = "WalkingWR_CapturedPhotos"
    
    private init() {
        // Create photos directory in documents
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        photosDirectory = documentsPath.appendingPathComponent("CapturedPhotos", isDirectory: true)
        
        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: photosDirectory.path) {
            try? fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        }
        
        loadPhotos()
    }
    
    func savePhoto(_ image: UIImage) {
        let photoId = UUID().uuidString
        let fileName = "\(photoId).jpg"
        let fileURL = photosDirectory.appendingPathComponent(fileName)
        
        // Compress and save image
        if let imageData = image.jpegData(compressionQuality: 0.7) {
            try? imageData.write(to: fileURL)
            
            let photo = CapturedPhoto(
                id: photoId,
                fileName: fileName,
                capturedDate: Date()
            )
            
            capturedPhotos.insert(photo, at: 0) // Add to front (newest first)
            saveMetadata()
        }
    }
    
    func loadImage(for photo: CapturedPhoto) -> UIImage? {
        let fileURL = photosDirectory.appendingPathComponent(photo.fileName)
        if let imageData = try? Data(contentsOf: fileURL) {
            return UIImage(data: imageData)
        }
        return nil
    }
    
    func deletePhoto(_ photo: CapturedPhoto) {
        let fileURL = photosDirectory.appendingPathComponent(photo.fileName)
        try? fileManager.removeItem(at: fileURL)
        capturedPhotos.removeAll { $0.id == photo.id }
        saveMetadata()
    }
    
    private func saveMetadata() {
        if let encoded = try? JSONEncoder().encode(capturedPhotos) {
            UserDefaults.standard.set(encoded, forKey: metadataKey)
        }
    }
    
    private func loadPhotos() {
        if let data = UserDefaults.standard.data(forKey: metadataKey),
           let decoded = try? JSONDecoder().decode([CapturedPhoto].self, from: data) {
            // Filter out photos where file no longer exists
            capturedPhotos = decoded.filter { photo in
                let fileURL = photosDirectory.appendingPathComponent(photo.fileName)
                return fileManager.fileExists(atPath: fileURL.path)
            }
        }
    }
}

struct CapturedPhoto: Identifiable, Codable {
    let id: String
    let fileName: String
    let capturedDate: Date
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: capturedDate)
    }
}

