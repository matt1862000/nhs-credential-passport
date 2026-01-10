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
    
    @Published var clinicianDelays: [String: Int] = [:] // name -> delay in minutes (legacy support)
    @Published var availableClinicianNames: Set<String> = [] // names from Firebase
    @Published var clinicians: [FirebaseClinicianData] = [] // Full clinician data
    
    init() {
        startListening()
    }
    
    deinit {
        listener?.remove()
    }
    
    /// Start real-time listener for clinician data
    func startListening() {
        print("🚀 Starting Firebase listener for 'clinicians' collection...")
        
        listener = db.collection("clinicians").addSnapshotListener { [weak self] snapshot, error in
            guard let self = self else { return }
            
            print("📡 Firebase snapshot received!")
            
            if let error = error {
                print("❌ Firebase error: \(error.localizedDescription)")
                return
            }
            
            guard let documents = snapshot?.documents else {
                print("⚠️ No clinicians found in Firestore")
                return
            }
            
            print("📦 Found \(documents.count) documents in Firebase")
            
            var delays: [String: Int] = [:]
            var names: Set<String> = []
            var clinicianList: [FirebaseClinicianData] = []
            
            for document in documents {
                let data = document.data()
                print("📄 Firebase doc: \(data)")
                
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
                
                print("✅ Loaded: '\(fullName)' - \(delay) min delay")
            }
            
            print("📊 All loaded delays: \(delays)")
            print("👥 Available clinicians from Firebase: \(clinicianList.map { $0.fullName })")
            
            let dispatchStart = Date()
            print("⏱️ Firebase: Dispatching to main thread...")
            DispatchQueue.main.async {
                print("⏱️ Firebase: Main thread dispatch started after \(String(format: "%.2f", Date().timeIntervalSince(dispatchStart)))s")
                let updateStart = Date()
                self.clinicianDelays = delays
                print("⏱️ Firebase: clinicianDelays updated in \(String(format: "%.3f", Date().timeIntervalSince(updateStart)))s")
                self.availableClinicianNames = names
                print("⏱️ Firebase: availableClinicianNames updated")
                self.clinicians = clinicianList
                print("⏱️ Firebase: clinicians updated - triggering Combine pipeline")
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
        listener?.remove()
        listener = nil
    }
}

