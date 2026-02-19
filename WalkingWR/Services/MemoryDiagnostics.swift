//
//  MemoryDiagnostics.swift
//  WalkingWR
//
//  Logs process memory usage and OS memory warnings to help diagnose jetsam/OOM crashes.
//  Uses NSLog (flushes immediately) and appends to a file so logs survive if the process is killed before console flush.
//  Grep console or memory_log.txt for [MEMORY] to see resident size at checkpoints.
//

import Foundation
import Darwin

enum MemoryDiagnostics {

    private static let logPrefix = "[MEMORY]"
    private static var logFileHandle: FileHandle?
    private static let queue = DispatchQueue(label: "MemoryDiagnostics.file")

    /// Write a line to NSLog (immediate flush) and append to Caches/memory_log.txt (sync + flush so it survives kill).
    private static func emit(_ line: String) {
        NSLog("%@", "\(logPrefix) \(line)")
        queue.sync {
            guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("memory_log.txt") else { return }
            if logFileHandle == nil {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                logFileHandle = try? FileHandle(forWritingTo: url)
            }
            guard let f = logFileHandle else { return }
            let data = (line + "\n").data(using: .utf8) ?? Data()
            f.seekToEndOfFile()
            try? f.write(contentsOf: data)
            try? f.synchronize()
        }
    }

    /// Log current process resident memory (MB) with a tag. Call at key checkpoints (launch, POI fetch, route sheet, routes loaded).
    static func logMemory(tag: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                withUnsafeMutablePointer(to: &count) { countPtr in
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, countPtr)
                }
            }
        }
        let line: String
        if result != KERN_SUCCESS {
            line = "\(tag) resident=??? (task_info failed \(result))"
        } else {
            let mb = Double(info.resident_size) / 1_048_576.0
            // Sanity cap: values >1000 MB are often bogus (e.g. wrong struct on some OS) and confuse analysis
            let mbStr = mb > 1000 ? "??? (suspicious \(String(format: "%.0f", mb)) MB)" : "\(String(format: "%.1f", mb)) MB"
            line = "\(tag) resident=\(mbStr)"
        }
        emit(line)
    }

    /// Return current process resident memory in MB (or nil if task_info fails).
    /// Use for programmatic memory-pressure checks (e.g. pregen threshold).
    static func currentResidentMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                withUnsafeMutablePointer(to: &count) { countPtr in
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, countPtr)
                }
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1_048_576.0
    }

    /// Call when the OS sends a memory warning (often shortly before jetsam if pressure continues).
    static func logMemoryWarning() {
        emit("⚠️ didReceiveMemoryWarning - OS under pressure")
    }
}
