//
//  DebugLogger.swift
//  WalkingWR
//
//  Created for debugging location and direction issues
//

import Foundation
import UIKit

/// On-device debug logger. All lines are prefixed with [WW] so you can search/copy easily.
/// Logs go to Documents/DebugLogs/ — use "Copy debug log" (tap Version in Profile) to paste for debugging.
class DebugLogger {
    /// Tag for every log line — search for "[WW]" to find WalkingWR debug lines.
    static let tag = "WW"
    
    static let shared = DebugLogger()
    
    private let fileManager = FileManager.default
    private let logFileURL: URL
    private let logQueue = DispatchQueue(label: "DebugLogger", qos: .utility)
    private var logFileHandle: FileHandle?
    
    private init() {
        // Create logs directory in Documents
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logsDirectory = documentsPath.appendingPathComponent("DebugLogs", isDirectory: true)
        
        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        }
        
        // Create log file with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        logFileURL = logsDirectory.appendingPathComponent("walk_debug_\(timestamp).log")
        
        // Create log file if it doesn't exist
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        // Open file handle for appending
        logFileHandle = try? FileHandle(forWritingTo: logFileURL)
        logFileHandle?.seekToEndOfFile()
        
        // Log initialization (use tag so it's findable)
        log("DebugLogger initialized - Log file: \(logFileURL.lastPathComponent)", category: "INIT")
    }
    
    deinit {
        logFileHandle?.closeFile()
    }
    
    /// Log a message to both console and file. Every line is prefixed with [WW] for easy search.
    func log(_ message: String, category: String = "DEBUG") {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        let logMessage = "[\(Self.tag)] [\(timeString)] [\(category)] \(message)\n"
        
        // Print to console
        print(logMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        
        // Write to file asynchronously
        logQueue.async { [weak self] in
            guard let self = self, let handle = self.logFileHandle else { return }
            
            if let data = logMessage.data(using: .utf8) {
                handle.write(data)
                handle.synchronizeFile() // Ensure data is written immediately
            }
        }
    }
    
    /// Read current session log file content (for copy/paste debugging).
    func getLogContent() -> String {
        logQueue.sync { }
        guard let data = try? Data(contentsOf: logFileURL),
              let text = String(data: data, encoding: .utf8) else {
            return "[WW] No log file or empty."
        }
        return text
    }
    
    /// Copy current log file content to the pasteboard. Returns true if something was copied.
    /// Includes return-leg debug lines (search for [AGENT_RETURN_LEG] for DISPLAY_SYNC_ADVANCING_TO_RETURN, LAST_MARKER_VISITED, SWITCHED_TO_RETURN_DIRECTIONS).
    @discardableResult
    func copyLogToPasteboard() -> Bool {
        let content = getLogContent()
        guard !content.isEmpty else { return false }
        let footer = "\n[WW] --- Search for [AGENT_RETURN_LEG] for return-leg / waypoint debug (DISPLAY_SYNC_ADVANCING_TO_RETURN, LAST_MARKER_VISITED, SWITCHED_TO_RETURN_DIRECTIONS) ---\n"
        UIPasteboard.general.string = content + footer
        return true
    }
    
    /// Get the most recent log file in DebugLogs (may be current or previous session).
    func getMostRecentLogURL() -> URL? {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logsDirectory = documentsPath.appendingPathComponent("DebugLogs", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.creationDateKey]),
              !files.isEmpty else { return nil }
        let sorted = files.sorted { url1, url2 in
            let d1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let d2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return d1 > d2
        }
        return sorted.first
    }
    
    /// Get the path to the log file (for sharing/debugging)
    var logFilePath: String {
        return logFileURL.path
    }
    
    /// Get the log file URL (for sharing)
    var logFile: URL {
        return logFileURL
    }
    
    /// Clear old log files (keep last 5)
    func cleanupOldLogs() {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            
            let documentsPath = self.fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let logsDirectory = documentsPath.appendingPathComponent("DebugLogs", isDirectory: true)
            
            guard let files = try? self.fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.creationDateKey]) else {
                return
            }
            
            // Sort by creation date (newest first)
            let sortedFiles = files.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return date1 > date2
            }
            
            // Delete files beyond the 5 most recent
            for file in sortedFiles.dropFirst(5) {
                try? self.fileManager.removeItem(at: file)
            }
        }
    }
}
