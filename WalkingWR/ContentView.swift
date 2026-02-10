//
//  ContentView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI

struct ContentView: View {
    private static var runRouteQualityTestPostcodes: [String]? = {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-RunRouteQualityTest"), idx + 1 < args.count else { return nil }
        let arg = args[idx + 1]
        if arg.uppercased() == "ALL" {
            // Representative mix: urban, suburban, small town, rural
            return ["WF1", "M1", "B1", "M20", "HX1", "DL8"]
        }
        return arg.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }()
    
    var body: some View {
        if let postcodes = Self.runRouteQualityTestPostcodes {
            RouteQualityMultiTestRunnerView(postcodes: postcodes)
        } else {
            SplashScreenView()
        }
    }
}

/// Shown when app is launched with -RunRouteQualityTest <postcodes>. Runs test for each location and combines results.
private struct RouteQualityMultiTestRunnerView: View {
    let postcodes: [String]
    @State private var progressMessage: String = "Starting..."
    @State private var outputPath: String = ""
    @State private var done = false
    @State private var currentLocation: String = ""
    @State private var completedCount: Int = 0
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Route quality test")
                .font(.headline)
            Text(postcodes.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !done {
                Text("Location \(completedCount + 1)/\(postcodes.count): \(currentLocation)")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Text(progressMessage)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if !done {
                ProgressView()
                    .progressViewStyle(.circular)
            }
            if !outputPath.isEmpty {
                Text("Output file:")
                    .font(.caption)
                Text(outputPath)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(5)
                    .padding()
            }
            if done {
                Text("Copy the path above into Finder (Go > Go to Folder) or get the file from the app container. Paste the file contents into Cursor.")
                    .font(.caption2)
                    .padding()
            }
        }
        .padding()
        .task {
            var allResults: [URL] = []
            let totalLocations = postcodes.count
            
            for (idx, postcode) in postcodes.enumerated() {
                await MainActor.run {
                    currentLocation = postcode
                    completedCount = idx
                    progressMessage = "[\(idx+1)/\(totalLocations)] Testing \(postcode)..."
                }
                
                let url = await GoogleMapsService.shared.testRouteQualitySingleLocation(
                    postcodeLabel: postcode,
                    includeGoogleRefresh: false,
                    progress: { msg in
                        progressMessage = "[\(idx+1)/\(totalLocations)] \(postcode): \(msg)"
                    }
                )
                if let url = url { allResults.append(url) }
            }
            
            // Combine all result files into one
            var combinedOutput = "PASTE THIS ENTIRE FILE INTO CURSOR FOR ANALYSIS\n"
            combinedOutput += "--- Multi-location route quality test ---\n"
            combinedOutput += "locations=\(postcodes.joined(separator: ","))\n\n"
            
            for url in allResults {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    combinedOutput += content + "\n\n"
                }
            }
            
            // Write combined file
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let combinedURL = docs.appendingPathComponent("route_quality_multi_\(ts).csv")
            try? combinedOutput.write(to: combinedURL, atomically: true, encoding: .utf8)
            let combinedPath = combinedURL.path
            print("📊 Combined results at: \(combinedPath)")
            
            await MainActor.run {
                done = true
                completedCount = totalLocations
                progressMessage = "Done. \(allResults.count)/\(totalLocations) locations completed."
                outputPath = combinedPath
            }
        }
    }
}

#Preview {
    ContentView()
}
