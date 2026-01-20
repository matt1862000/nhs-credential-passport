//
//  DebugLogger.swift
//  WalkingWR
//
//  Created for debugging location and direction issues
//

import Foundation

class DebugLogger {
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
        
        // Log initialization
        log("🚀 DebugLogger initialized - Log file: \(logFileURL.lastPathComponent)")
    }
    
    deinit {
        logFileHandle?.closeFile()
    }
    
    /// Log a message to both console and file
    func log(_ message: String, category: String = "DEBUG") {
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = formatter.string(from: timestamp)
        
        let logMessage = "[\(timeString)] [\(category)] \(message)\n"
        
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
