//
//  FirebaseService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 10/12/2025.
//

import Foundation
import FirebaseFirestore
import Combine

/// Data structure for clinician info from Firebase/Google Sheets
struct FirebaseClinicianData: Identifiable {
    let id: String
    let name: String
    let location: String       // Clinic location (e.g., "Decisions Unit")
    let title: String
    let specialty: String
    let delay: Int
    let bio: String
    let photoURL: String?
    let expertise: String?
    let expertiseTags: [String]
    let achievements: String?
    let publications: String?
    let interests: String?
    var lastUpdated: Date
    
    /// Full display name with title
    var fullName: String {
        "\(title) \(name)".trimmingCharacters(in: .whitespaces)
    }
}

class FirebaseService: ObservableObject {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    /// Once we have received at least one snapshot with clinicians, we stop aggressive retries.
    private var hasReceivedClinicians = false
    private var retryWorkItem: DispatchWorkItem?
    /// Throttle duplicate snapshot logging: only log when count/delays change or every 60s.
    private var lastLoggedFingerprint: String?
    private var lastSnapshotLogTime: Date?
    private static let snapshotLogInterval: TimeInterval = 60
    
    @Published var clinicianDelays: [String: Int] = [:] // name -> delay in minutes (legacy support)
    @Published var availableClinicianNames: Set<String> = [] // names from Firebase
    @Published var clinicians: [FirebaseClinicianData] = [] // Full clinician data
    
    init() {
        startListening()
    }
    
    deinit {
        retryWorkItem?.cancel()
        listener?.remove()
    }
    
    /// Start real-time listener for clinician data. On connection error, retries until clinicians are received.
    func startListening() {
        retryWorkItem?.cancel()
        print("🚀 Starting Firebase listener for 'clinicians' collection...")
        
        listener = db.collection("clinicians").addSnapshotListener { [weak self] snapshot, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Firebase error: \(error.localizedDescription)")
                self.listener?.remove()
                self.listener = nil
                let delay: TimeInterval = self.hasReceivedClinicians ? 15 : 5
                print("🔄 Retrying clinicians fetch in \(Int(delay))s...")
                let work = DispatchWorkItem { [weak self] in
                    self?.startListening()
                }
                self.retryWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return
            }
            
            guard let documents = snapshot?.documents else {
                print("⚠️ No clinicians found in Firestore")
                return
            }
            
            if !documents.isEmpty {
                self.hasReceivedClinicians = true
            }
            
            var delays: [String: Int] = [:]
            var names: Set<String> = []
            var clinicianList: [FirebaseClinicianData] = []
            
            for document in documents {
                let data = document.data()
                
                // Required fields
                guard let name = data["name"] as? String else {
                    print("⚠️ Missing name in document: \(document.documentID)")
                    continue
                }
                
                let delay = data["delay"] as? Int ?? 0
                
                // Optional fields with defaults
                let location = data["location"] as? String ?? ""
                let title = data["title"] as? String ?? ""
                let specialty = data["specialty"] as? String ?? "Clinician"
                let bio = data["bio"] as? String ?? "Profile information coming soon."
                let photoURL = data["photo_url"] as? String
                let expertise = data["expertise"] as? String
                let achievements = data["achievements"] as? String
                let publications = data["publications"] as? String
                let interests = data["interests"] as? String
                
                // Parse expertise tags (comma-separated)
                let expertiseTags: [String]
                if let tagsString = data["expertise_tags"] as? String, !tagsString.isEmpty {
                    expertiseTags = tagsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    expertiseTags = []
                }
                
                let clinicianData = FirebaseClinicianData(
                    id: document.documentID,
                    name: name,
                    location: location,
                    title: title,
                    specialty: specialty,
                    delay: delay,
                    bio: bio,
                    photoURL: photoURL,
                    expertise: expertise,
                    expertiseTags: expertiseTags,
                    achievements: achievements,
                    publications: publications,
                    interests: interests,
                    lastUpdated: Date()
                )
                
                clinicianList.append(clinicianData)
                
                // Legacy support
                let fullName = clinicianData.fullName
                delays[fullName] = delay
                delays[name] = delay
                names.insert(fullName)
                names.insert(name)
            }
            
            // Only log when clinician list meaningfully changed or every 60s to avoid log storm
            let fingerprint = "\(documents.count):" + clinicianList.sorted(by: { $0.fullName < $1.fullName }).map { "\($0.fullName)|\($0.delay)" }.joined(separator: ",")
            let now = Date()
            let shouldLog = lastLoggedFingerprint != fingerprint || lastSnapshotLogTime.map { now.timeIntervalSince($0) >= Self.snapshotLogInterval } ?? true
            if shouldLog {
                lastLoggedFingerprint = fingerprint
                lastSnapshotLogTime = now
                #if DEBUG
                print("📦 Firebase clinicians: \(documents.count) — \(clinicianList.map { $0.fullName }.joined(separator: ", "))")
                #endif
            }
            
            DispatchQueue.main.async {
                self.clinicianDelays = delays
                self.availableClinicianNames = names
                self.clinicians = clinicianList
            }
        }
    }
    
    /// Get delay for a specific clinician by name
    func getDelay(for clinicianName: String) -> Int? {
        // Normalize the search name (remove special chars, lowercase)
        let normalizedSearch = normalizeForMatching(clinicianName)
        
        // Try exact match first
        if let delay = clinicianDelays[clinicianName] {
            return delay
        }
        
        // Try normalized match
        for (name, delay) in clinicianDelays {
            let normalizedName = normalizeForMatching(name)
            
            // Exact normalized match
            if normalizedName == normalizedSearch {
                return delay
            }
            
            // Partial match (contains)
            if normalizedName.contains(normalizedSearch) || normalizedSearch.contains(normalizedName) {
                return delay
            }
            
            // Match just the surname (last word)
            let nameSurname = normalizedName.split(separator: " ").last.map(String.init) ?? ""
            let searchSurname = normalizedSearch.split(separator: " ").last.map(String.init) ?? ""
            if !nameSurname.isEmpty && nameSurname == searchSurname {
                return delay
            }
        }
        
        return nil
    }
    
    /// Normalize name for flexible matching
    private func normalizeForMatching(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "'", with: "")  // Remove apostrophe
            .replacingOccurrences(of: "'", with: "")  // Remove curly apostrophe
            .replacingOccurrences(of: ".", with: "")  // Remove periods
            .replacingOccurrences(of: "dr ", with: "")
            .replacingOccurrences(of: "mr ", with: "")
            .replacingOccurrences(of: "ms ", with: "")
            .replacingOccurrences(of: "mrs ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    
    /// Check if a clinician exists in Firebase
    func isClinicianAvailable(_ clinicianName: String) -> Bool {
        return getDelay(for: clinicianName) != nil
    }
    
    /// Stop listening to updates
    func stopListening() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        listener?.remove()
        listener = nil
    }
}

