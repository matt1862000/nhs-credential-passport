//
//  SpottedPhotoStore.swift
//  WalkingWR
//
//  Saves the user’s photo when they add a bird from “Identify from photo” so it can be shown on the “Also spotted” card.
//

import UIKit
import Foundation

enum SpottedPhotoStore {
    private static let subdir = "spotted_photos"
    private static let logTag = "[BIRD_SPOT]"

    private static var directoryURL: URL? {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = cache.appendingPathComponent(subdir, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func filename(for birdName: String) -> String {
        let sanitized = birdName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let safe = sanitized.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        let hash = birdName.utf8.reduce(0) { 31 &* $0 &+ Int($1) }
        return (safe.isEmpty ? "bird" : safe) + "_" + String(abs(hash)) + ".jpg"
    }

    /// Save the user’s photo for an “Also spotted” bird (e.g. from Identify from photo).
    static func save(name: String, image: UIImage) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let dir = directoryURL else {
            print("\(logTag) stage=photo_save_fail name=\(name) reason=no_directory")
            return
        }
        let fileURL = dir.appendingPathComponent(filename(for: name))
        let ok = image.jpegData(compressionQuality: 0.8).flatMap { try? $0.write(to: fileURL) } != nil
        print("\(logTag) stage=photo_save name=\(name) ok=\(ok) ms=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))")
    }

    /// Load the saved photo for a bird name, if any.
    static func image(for birdName: String) -> UIImage? {
        guard let dir = directoryURL else { return nil }
        let fileURL = dir.appendingPathComponent(filename(for: birdName))
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    /// Remove saved photo for one bird (e.g. when removed from Also spotted).
    static func remove(name: String) {
        guard let dir = directoryURL else { return }
        let fileURL = dir.appendingPathComponent(filename(for: name))
        try? FileManager.default.removeItem(at: fileURL)
        print("\(logTag) stage=photo_remove name=\(name)")
    }

    /// Remove all saved spotted photos (e.g. Reset All Sightings).
    static func removeAll() {
        guard let dir = directoryURL else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        contents.forEach { try? FileManager.default.removeItem(at: $0) }
        print("\(logTag) stage=photo_removeAll count=\(contents.count)")
    }
}
