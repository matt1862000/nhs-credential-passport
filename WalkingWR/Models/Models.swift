//
//  Models.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import Foundation
import SwiftUI
import Combine
import CoreLocation

// MARK: - Clinician
struct Clinician: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let title: String
    let specialty: String
    let photoName: String?      // Local asset name (legacy)
    let photoURL: String?       // Remote URL from Google Sheets
    let bio: String
    let expertiseDescription: String
    let expertiseTags: [String]
    let achievements: String
    let publicationsIntro: String
    let publicationTitle: String?
    let publicationSubtitle: String?
    let publicationsOutro: String
    let interests: [ClinicianInterest]
    let interestsDescription: String
    var currentWaitMinutes: Int
    var queuePosition: Int
    var lastUpdated: Date
    
    struct ClinicianInterest: Codable, Hashable {
        let icon: String
        let text: String
    }
    
    init(id: UUID = UUID(), name: String, title: String, specialty: String, 
         photoName: String? = nil, photoURL: String? = nil, bio: String,
         expertiseDescription: String, expertiseTags: [String],
         achievements: String,
         publicationsIntro: String, publicationTitle: String? = nil, publicationSubtitle: String? = nil, publicationsOutro: String,
         interests: [ClinicianInterest], interestsDescription: String,
         currentWaitMinutes: Int = 20, queuePosition: Int = 3) {
        self.id = id
        self.name = name
        self.title = title
        self.specialty = specialty
        self.photoName = photoName
        self.photoURL = photoURL
        self.bio = bio
        self.expertiseDescription = expertiseDescription
        self.expertiseTags = expertiseTags
        self.achievements = achievements
        self.publicationsIntro = publicationsIntro
        self.publicationTitle = publicationTitle
        self.publicationSubtitle = publicationSubtitle
        self.publicationsOutro = publicationsOutro
        self.interests = interests
        self.interestsDescription = interestsDescription
        self.currentWaitMinutes = currentWaitMinutes
        self.queuePosition = queuePosition
        self.lastUpdated = Date()
    }
    
    var formattedWaitTime: String {
        if currentWaitMinutes == 0 {
            return "On Time"
        } else if currentWaitMinutes < 60 {
            return "\(currentWaitMinutes) min"
        } else {
            let hours = currentWaitMinutes / 60
            let mins = currentWaitMinutes % 60
            return "\(hours)h \(mins)m"
        }
    }
    
    var isOnTime: Bool {
        currentWaitMinutes == 0
    }
    
    var fullTitle: String {
        "\(title) \(name)"
    }
    
    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
    
    // Sample clinicians
    static let sampleClinicians: [Clinician] = [
        // Dr. Sarah Mitchell - Consultant Psychiatrist
        Clinician(
            name: "Sarah Mitchell",
            title: "Dr.",
            specialty: "Consultant Psychiatrist",
            photoName: "DrSarahMitchell",
            bio: "Dr. Sarah Mitchell is a highly respected consultant psychiatrist with over 15 years of experience in adult mental health. She completed her medical degree at King's College London and went on to specialize in psychiatry at the Maudsley Hospital, where she developed a passion for integrating evidence-based medicine with compassionate care.",
            expertiseDescription: "Her clinical expertise spans mood disorders, psychosis, and trauma-informed approaches. Dr. Mitchell is particularly known for her work in digital mental health, pioneering the use of technology to improve patient engagement and continuity of care.",
            expertiseTags: ["Mood Disorders", "Psychosis", "Trauma-Informed Care", "Digital Mental Health"],
            achievements: "She has led several national projects on virtual therapy platforms and AI-assisted risk assessment tools, earning recognition from the Royal College of Psychiatrists for innovation in clinical practice. In 2022, she received the NHS Innovation Award for her digital consultation framework.",
            publicationsIntro: "Beyond her clinical work, Dr. Mitchell is an advocate for mental health equity and has authored the book:",
            publicationTitle: "Beyond the Diagnosis",
            publicationSubtitle: "Humanizing Psychiatry in the Digital Age",
            publicationsOutro: "She regularly speaks at international conferences and contributes to policy development aimed at reducing stigma and improving access to mental health services.",
            interests: [
                ClinicianInterest(icon: "figure.hiking", text: "Hiking"),
                ClinicianInterest(icon: "camera.fill", text: "Photography"),
                ClinicianInterest(icon: "person.2.fill", text: "Mentoring")
            ],
            interestsDescription: "When not working, Sarah enjoys hiking in the Peak District, photography, and mentoring early-career clinicians.",
            currentWaitMinutes: 25,
            queuePosition: 3
        ),
        
        // Dr. James Thompson - Clinical Psychologist
        Clinician(
            name: "James Thompson",
            title: "Dr.",
            specialty: "Clinical Psychologist",
            photoName: "DrJamesThompson",
            bio: "Dr. James Thompson is a clinical psychologist with 12 years of experience in NHS mental health services. He trained at the University of Sheffield and completed his doctorate in Clinical Psychology at Leeds, specializing in evidence-based psychological therapies for adults experiencing anxiety and mood difficulties.",
            expertiseDescription: "James is an expert in cognitive behavioral therapy (CBT) and has additional training in acceptance and commitment therapy (ACT), compassion-focused therapy, and EMDR for trauma. He takes a collaborative approach, working alongside patients to understand their unique experiences.",
            expertiseTags: ["CBT", "ACT", "Anxiety Disorders", "OCD", "Depression"],
            achievements: "He was awarded the British Psychological Society's Early Career Award in 2018 for his research on improving CBT outcomes. James has trained over 50 junior psychologists and therapists in evidence-based interventions and regularly contributes to service development.",
            publicationsIntro: "James has contributed to several peer-reviewed journals and co-authored:",
            publicationTitle: "Living with Anxiety",
            publicationSubtitle: "A Practical Guide Using ACT Principles",
            publicationsOutro: "He is passionate about making psychological therapies accessible and has developed self-help resources used across South Yorkshire.",
            interests: [
                ClinicianInterest(icon: "figure.run", text: "Fell Running"),
                ClinicianInterest(icon: "mountain.2.fill", text: "Climbing"),
                ClinicianInterest(icon: "heart.fill", text: "Volunteering")
            ],
            interestsDescription: "Outside of work, James is an avid fell runner and rock climber. He volunteers with Sheffield Mind and helps run their anxiety support groups.",
            currentWaitMinutes: 15,
            queuePosition: 2
        ),
        
        // Dr. Priya Patel - Consultant Psychiatrist (EIP)
        Clinician(
            name: "Priya Patel",
            title: "Dr.",
            specialty: "Consultant Psychiatrist",
            photoName: "DrPriyaPatel",
            bio: "Dr. Priya Patel is a consultant psychiatrist who leads the Early Intervention in Psychosis (EIP) team. She qualified from the University of Birmingham Medical School and completed her psychiatry training in the West Midlands before joining Sheffield in 2016.",
            expertiseDescription: "Dr. Patel specializes in first-episode psychosis and has expertise in culturally sensitive mental health care. She is fluent in Gujarati, Hindi, and Urdu, allowing her to connect with patients from diverse backgrounds. Her approach emphasizes early intervention, family involvement, and holistic recovery.",
            expertiseTags: ["Early Psychosis", "Cultural Psychiatry", "Family Therapy", "Recovery-Focused Care"],
            achievements: "She has published influential research on improving access to mental health services for South Asian communities, presented at the Royal College of Psychiatrists International Congress, and was shortlisted for the BME Health Professional of the Year Award in 2021.",
            publicationsIntro: "Dr. Patel is committed to addressing health inequalities and has published research including:",
            publicationTitle: nil,
            publicationSubtitle: nil,
            publicationsOutro: "Her papers on cultural barriers to mental health care have informed NHS England guidance. She supervises trainee psychiatrists and teaches on the Sheffield medical school curriculum.",
            interests: [
                ClinicianInterest(icon: "book.fill", text: "Reading"),
                ClinicianInterest(icon: "fork.knife", text: "Cooking"),
                ClinicianInterest(icon: "graduationcap.fill", text: "Teaching")
            ],
            interestsDescription: "Priya enjoys reading contemporary fiction, cooking traditional Gujarati recipes learned from her grandmother, and spending time with her two children.",
            currentWaitMinutes: 35,
            queuePosition: 4
        ),
        
        // Mr. Michael O'Brien - Advanced Nurse Practitioner
        Clinician(
            name: "Michael O'Brien",
            title: "Mr.",
            specialty: "Advanced Nurse Practitioner",
            photoName: "MrMichaelOBrien",
            bio: "Michael O'Brien is an Advanced Mental Health Nurse Practitioner with over 22 years of experience in psychiatric nursing. He began his career at the Maudsley Hospital in London before moving to Sheffield in 2008. Michael holds a Master's degree in Advanced Clinical Practice from Sheffield Hallam University.",
            expertiseDescription: "As a qualified non-medical prescriber, Michael specializes in medication management, physical health monitoring, and recovery-focused care. He coordinates the depot clinic and leads the team's physical health initiative, ensuring patients receive holistic care that addresses both mental and physical wellbeing.",
            expertiseTags: ["Medication Management", "Physical Health", "Recovery Model", "Depot Clinic"],
            achievements: "Michael received the Chief Nursing Officer's Award for Excellence in 2019 for his work improving physical health outcomes in patients with serious mental illness. He has reduced cardiovascular risk factors by 30% in his caseload through proactive monitoring.",
            publicationsIntro: "Michael is a strong advocate for nursing-led care and has contributed to:",
            publicationTitle: nil,
            publicationSubtitle: nil,
            publicationsOutro: "He regularly presents at nursing conferences and mentors student nurses. Michael is known for his warm, approachable manner and his commitment to reducing stigma around mental health.",
            interests: [
                ClinicianInterest(icon: "figure.pool.swim", text: "Swimming"),
                ClinicianInterest(icon: "sportscourt.fill", text: "Football"),
                ClinicianInterest(icon: "pawprint.fill", text: "Dog Walking")
            ],
            interestsDescription: "Outside work, Michael enjoys swimming at Ponds Forge, supporting Sheffield Wednesday FC, and walking his border collie, Finn, in the Peak District.",
            currentWaitMinutes: 10,
            queuePosition: 1
        ),
        
        // Dr. Emma Wilson - Specialty Registrar
        Clinician(
            name: "Emma Wilson",
            title: "Dr.",
            specialty: "Specialty Registrar (ST6)",
            photoName: "DrEmmaWilson",
            bio: "Dr. Emma Wilson is a specialty registrar in her final year of psychiatry training. She studied medicine at Newcastle University and has worked across various mental health settings including inpatient wards, community teams, and liaison psychiatry at the Northern General Hospital.",
            expertiseDescription: "Emma has a keen interest in perinatal mental health and digital innovations in healthcare. She completed a special interest module in mother and baby psychiatry at the Bethlem Royal Hospital and is passionate about improving mental health support for new mothers.",
            expertiseTags: ["Perinatal Mental Health", "Digital Health", "Quality Improvement", "Liaison Psychiatry"],
            achievements: "Emma led the development of this Walking Waiting Room app as part of her quality improvement portfolio, winning the Trainee Innovation Prize at the Yorkshire regional conference. She has also published case reports in the BJPsych Bulletin.",
            publicationsIntro: "As a trainee passionate about innovation, Emma has contributed to:",
            publicationTitle: nil,
            publicationSubtitle: nil,
            publicationsOutro: "She is actively involved in teaching medical students and junior doctors, and hopes to pursue a career combining clinical work with digital health research after completing her training.",
            interests: [
                ClinicianInterest(icon: "camera.fill", text: "Photography"),
                ClinicianInterest(icon: "guitars.fill", text: "Guitar"),
                ClinicianInterest(icon: "figure.hiking", text: "Hiking")
            ],
            interestsDescription: "When not at work, Emma enjoys landscape photography, is learning to play guitar (slowly!), and loves hiking in the Yorkshire Dales.",
            currentWaitMinutes: 20,
            queuePosition: 2
        )
    ]
}

// MARK: - Wait Time (Legacy - keeping for compatibility)
struct WaitTimeInfo: Identifiable {
    let id = UUID()
    var estimatedMinutes: Int
    var lastUpdated: Date
    var clinicianName: String
    var queuePosition: Int
    
    var formattedTime: String {
        if estimatedMinutes == 0 {
            return "On Time"
        } else if estimatedMinutes < 60 {
            return "\(estimatedMinutes) min"
        } else {
            let hours = estimatedMinutes / 60
            let mins = estimatedMinutes % 60
            return "\(hours)h \(mins)m"
        }
    }
    
    var isOnTime: Bool {
        estimatedMinutes == 0
    }
    
    // Create from clinician
    init(from clinician: Clinician) {
        self.estimatedMinutes = clinician.currentWaitMinutes
        self.lastUpdated = clinician.lastUpdated
        self.clinicianName = clinician.fullTitle
        self.queuePosition = clinician.queuePosition
    }
    
    // Original init
    init(estimatedMinutes: Int, lastUpdated: Date, clinicianName: String, queuePosition: Int) {
        self.estimatedMinutes = estimatedMinutes
        self.lastUpdated = lastUpdated
        self.clinicianName = clinicianName
        self.queuePosition = queuePosition
    }
}

// MARK: - Walking Route
struct WalkingRoute: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let description: String
    let durationMinutes: Int
    let distanceMeters: Int
    let difficulty: RouteDifficulty
    let isIndoor: Bool
    let isAccessible: Bool
    let landmarks: [String]
    let icon: String
    let color: Color
    let qrMarkers: [QRMarker]
    
    var estimatedSteps: Int {
        // Average stride length ~0.76m
        return Int(Double(distanceMeters) / 0.76)
    }
    
    static func == (lhs: WalkingRoute, rhs: WalkingRoute) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum RouteDifficulty: String, CaseIterable {
    case easy = "Easy"
    case moderate = "Moderate"
    case challenging = "Challenging"
    
    var color: Color {
        switch self {
        case .easy: return .mintGreen
        case .moderate: return .softAmber
        case .challenging: return .coralPink
        }
    }
    
    var icon: String {
        switch self {
        case .easy: return "figure.walk"
        case .moderate: return "figure.walk.motion"
        case .challenging: return "figure.hiking"
        }
    }
}

// MARK: - QR Marker
struct QRMarker: Identifiable {
    let id = UUID()
    let code: String
    let name: String
    let location: String
    let coordinate: CLLocationCoordinate2D
    let contentType: MarkerContentType
    let content: WellbeingContent
    let pointsValue: Int
}

enum MarkerContentType: String {
    case breathingExercise = "Breathing"
    case gratitudePrompt = "Gratitude"
    case natureFact = "Nature"
    case digitalTip = "Digital Skills"
    case miniChallenge = "Challenge"
}

// MARK: - Wellbeing Content
struct WellbeingContent: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let duration: Int? // in seconds, nil for instant content
    let steps: [String]?
}		

// MARK: - Badge/Achievement
struct Badge: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String
    let color: Color
    let requirement: BadgeRequirement
    var isUnlocked: Bool = false
    var unlockedDate: Date?
}

enum BadgeRequirement {
    case steps(Int)
    case routes(Int)
    case qrScans(Int)
    case breathingExercises(Int)
    case consecutiveDays(Int)
    case digitalSkills(Int)
    case photos(Int)
    case daysUsed(Int)
}

// MARK: - User Progress
class UserProgress: ObservableObject {
    // Cumulative totals (all-time)
    @Published var totalSteps: Int = 0 { didSet { save() } }
    @Published var sessionSteps: Int = 0 { didSet { save() } }
    @Published var routesCompleted: Int = 0 { didSet { save() } }
    @Published var qrScansCompleted: Int = 0 { didSet { save() } }
    @Published var breathingExercisesCompleted: Int = 0 { didSet { save() } }
    @Published var totalPoints: Int = 0 { didSet { save() } }
    
    // Today's values only (reset daily)
    @Published var todaySteps: Int = 0 { didSet { save() } }
    @Published var todayRoutesCompleted: Int = 0 { didSet { save() } }
    @Published var todayQRScansCompleted: Int = 0 { didSet { save() } }
    @Published var todayBreathingExercises: Int = 0 { didSet { save() } }
    @Published var todayPoints: Int = 0 { didSet { save() } }
    @Published var lastActivityDate: String = "" { didSet { save() } }
    @Published var badges: [Badge] = [] { didSet { save() } }
    @Published var anxietyLevelBefore: Int? = nil { didSet { save() } }
    @Published var anxietyLevelAfter: Int? = nil { didSet { save() } }
    @Published var anxietyLevelAfterWalk: Int? = nil { didSet { save() } } // Specifically from walks
    @Published var gratitudeEntries: [String] = [] { didSet { save() } }
    @Published var lastWalkDate: Date? = nil { didSet { save() } }
    @Published var dailyHistory: [DailyActivity] = [] { didSet { save() } }
    @Published var completedDigitalSkills: Set<String> = [] { didSet { save() } }
    @Published var daysUsedDates: Set<String> = [] { didSet { save() } } // Tracks unique days app was used
    
    // Digital skill identifiers
    static let digitalSkillIds = ["nhs_number", "mytoolkit", "learnmyway", "take_photo", "nhs_app"]
    
    var digitalSkillsCompletedCount: Int {
        completedDigitalSkills.count
    }
    
    func markDigitalSkillComplete(_ skillId: String) {
        completedDigitalSkills.insert(skillId)
    }
    
    func isDigitalSkillComplete(_ skillId: String) -> Bool {
        completedDigitalSkills.contains(skillId)
    }
    
    private let userDefaultsKey = "WalkingWR_UserProgress"
    private var lastRecordedDate: String?
    
    private var todayDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
    
    init() {
        load()
        checkAndArchivePreviousDay()
    }
    
    func addPoints(_ points: Int) {
        totalPoints += points
        todayPoints += points
    }
    
    func recordSteps(_ steps: Int) {
        sessionSteps += steps
        totalSteps += steps
        todaySteps += steps
    }
    
    func recordAppUsage() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        daysUsedDates.insert(today)
    }
    
    var daysUsedCount: Int {
        daysUsedDates.count
    }
    
    // MARK: - Daily History Management
    
    /// Check if we need to archive yesterday's data
    func checkAndArchivePreviousDay() {
        // If we have data from a previous day, archive it
        if let lastDate = lastRecordedDate, lastDate != todayDateString {
            archiveCurrentDayToHistory(forDate: lastDate)
            // Reset session data for new day
            sessionSteps = 0
            anxietyLevelBefore = nil
            anxietyLevelAfter = nil
            anxietyLevelAfterWalk = nil
            gratitudeEntries = []
        }
        lastRecordedDate = todayDateString
        save()
    }
    
    /// Archive current session data to history
    private func archiveCurrentDayToHistory(forDate dateString: String) {
        // Only archive if there's meaningful data from today
        guard todaySteps > 0 || todayRoutesCompleted > 0 || anxietyLevelBefore != nil || !gratitudeEntries.isEmpty else {
            return
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: dateString) ?? Date()
        
        // Use today's values (daily), not cumulative totals
        let dailyRecord = DailyActivity(
            dateString: dateString,
            date: date,
            steps: todaySteps,
            routesCompleted: todayRoutesCompleted,
            qrScansCompleted: todayQRScansCompleted,
            breathingExercises: todayBreathingExercises,
            pointsEarned: todayPoints,
            anxietyBefore: anxietyLevelBefore,
            anxietyAfter: anxietyLevelAfter,
            gratitudeEntries: gratitudeEntries
        )
        
        // Remove existing entry for this date if any
        dailyHistory.removeAll { $0.dateString == dateString }
        
        // Add new record and sort by date (newest first)
        dailyHistory.append(dailyRecord)
        dailyHistory.sort { $0.date > $1.date }
        
        // Keep only last 30 days
        if dailyHistory.count > 30 {
            dailyHistory = Array(dailyHistory.prefix(30))
        }
    }
    
    /// Get today's activity (only today's values, not cumulative)
    var todayActivity: DailyActivity {
        // NOTE: Don't call checkAndResetDailyValues() here - it causes infinite re-renders
        // It's called on app launch in load() instead
        
        return DailyActivity(
            dateString: todayDateString,
            date: Date(),
            steps: todaySteps,
            routesCompleted: todayRoutesCompleted,
            qrScansCompleted: todayQRScansCompleted,
            breathingExercises: todayBreathingExercises,
            pointsEarned: todayPoints,
            anxietyBefore: anxietyLevelBefore,
            anxietyAfter: anxietyLevelAfter,
            gratitudeEntries: todayGratitudeEntries
        )
    }
    
    /// Today's gratitude entries only
    var todayGratitudeEntries: [String] {
        // Filter gratitude entries to only include today's
        // For now, we'll use the existing array since entries are added per session
        gratitudeEntries
    }
    
    /// Check if it's a new day and reset daily values
    func checkAndResetDailyValues() {
        let today = todayDateString
        if lastActivityDate != today && !lastActivityDate.isEmpty {
            // It's a new day - archive yesterday's data before resetting
            archiveCurrentDayToHistory(forDate: lastActivityDate)
            
            // Reset daily values
            todaySteps = 0
            todayRoutesCompleted = 0
            todayQRScansCompleted = 0
            todayBreathingExercises = 0
            todayPoints = 0
            anxietyLevelBefore = nil
            anxietyLevelAfter = nil
            gratitudeEntries = []
        }
        lastActivityDate = today
    }
    
    /// All activities including today
    var allActivities: [DailyActivity] {
        var activities = [todayActivity]
        activities.append(contentsOf: dailyHistory.filter { !$0.isToday })
        return activities
    }
    
    // MARK: - Persistence
    private func save() {
        let data = UserProgressData(
            totalSteps: totalSteps,
            sessionSteps: sessionSteps,
            routesCompleted: routesCompleted,
            qrScansCompleted: qrScansCompleted,
            breathingExercisesCompleted: breathingExercisesCompleted,
            totalPoints: totalPoints,
            anxietyLevelBefore: anxietyLevelBefore,
            anxietyLevelAfter: anxietyLevelAfter,
            anxietyLevelAfterWalk: anxietyLevelAfterWalk,
            gratitudeEntries: gratitudeEntries,
            lastWalkDate: lastWalkDate,
            dailyHistory: dailyHistory,
            lastRecordedDate: lastRecordedDate,
            completedDigitalSkills: Array(completedDigitalSkills),
            daysUsedDates: Array(daysUsedDates),
            todaySteps: todaySteps,
            todayRoutesCompleted: todayRoutesCompleted,
            todayQRScansCompleted: todayQRScansCompleted,
            todayBreathingExercises: todayBreathingExercises,
            todayPoints: todayPoints,
            lastActivityDate: lastActivityDate
        )
        
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
    
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(UserProgressData.self, from: data) else {
            return
        }
        
        totalSteps = decoded.totalSteps
        sessionSteps = decoded.sessionSteps
        routesCompleted = decoded.routesCompleted
        qrScansCompleted = decoded.qrScansCompleted
        breathingExercisesCompleted = decoded.breathingExercisesCompleted
        totalPoints = decoded.totalPoints
        anxietyLevelBefore = decoded.anxietyLevelBefore
        anxietyLevelAfter = decoded.anxietyLevelAfter
        anxietyLevelAfterWalk = decoded.anxietyLevelAfterWalk
        gratitudeEntries = decoded.gratitudeEntries
        lastWalkDate = decoded.lastWalkDate
        dailyHistory = decoded.dailyHistory
        lastRecordedDate = decoded.lastRecordedDate
        completedDigitalSkills = Set(decoded.completedDigitalSkills ?? [])
        daysUsedDates = Set(decoded.daysUsedDates ?? [])
        
        // Load daily values
        todaySteps = decoded.todaySteps ?? 0
        todayRoutesCompleted = decoded.todayRoutesCompleted ?? 0
        todayQRScansCompleted = decoded.todayQRScansCompleted ?? 0
        todayBreathingExercises = decoded.todayBreathingExercises ?? 0
        todayPoints = decoded.todayPoints ?? 0
        lastActivityDate = decoded.lastActivityDate ?? ""
        
        // Check if it's a new day and reset if needed
        checkAndResetDailyValues()
    }
    
    func resetForNewSession() {
        // Reset session-specific data but keep totals
        anxietyLevelBefore = nil
        anxietyLevelAfter = nil
        anxietyLevelAfterWalk = nil
    }
    
    func resetToday() {
        // Reset today's data only
        sessionSteps = 0
        todaySteps = 0
        todayRoutesCompleted = 0
        todayQRScansCompleted = 0
        todayBreathingExercises = 0
        todayPoints = 0
        anxietyLevelBefore = nil
        anxietyLevelAfter = nil
        anxietyLevelAfterWalk = nil
        gratitudeEntries = []
        lastWalkDate = nil
    }
    
    func resetAll() {
        // Reset everything
        totalSteps = 0
        sessionSteps = 0
        routesCompleted = 0
        qrScansCompleted = 0
        breathingExercisesCompleted = 0
        totalPoints = 0
        todaySteps = 0
        todayRoutesCompleted = 0
        todayQRScansCompleted = 0
        todayBreathingExercises = 0
        todayPoints = 0
        lastActivityDate = ""
        badges = []
        anxietyLevelBefore = nil
        anxietyLevelAfter = nil
        anxietyLevelAfterWalk = nil
        gratitudeEntries = []
        lastWalkDate = nil
        dailyHistory = []
        lastRecordedDate = nil
        completedDigitalSkills = []
        daysUsedDates = []
        
        // Clear from UserDefaults
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

// Codable struct for persistence
struct UserProgressData: Codable {
    let totalSteps: Int
    let sessionSteps: Int
    let routesCompleted: Int
    let qrScansCompleted: Int
    let breathingExercisesCompleted: Int
    let totalPoints: Int
    let anxietyLevelBefore: Int?
    let anxietyLevelAfter: Int?
    let anxietyLevelAfterWalk: Int? // Specifically from walks
    let gratitudeEntries: [String]
    let lastWalkDate: Date?
    let dailyHistory: [DailyActivity]
    let lastRecordedDate: String?
    let completedDigitalSkills: [String]?
    let daysUsedDates: [String]?
    
    // Daily values (reset each day)
    let todaySteps: Int?
    let todayRoutesCompleted: Int?
    let todayQRScansCompleted: Int?
    let todayBreathingExercises: Int?
    let todayPoints: Int?
    let lastActivityDate: String?
}

// MARK: - Daily Activity Record
struct DailyActivity: Codable, Identifiable {
    var id: String { dateString }
    let dateString: String // Format: "yyyy-MM-dd"
    let date: Date
    let steps: Int
    let routesCompleted: Int
    let qrScansCompleted: Int
    let breathingExercises: Int
    let pointsEarned: Int
    let anxietyBefore: Int?
    let anxietyAfter: Int?
    let gratitudeEntries: [String]
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
    
    var dayOfWeek: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
    
    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }
    
    var isYesterday: Bool {
        Calendar.current.isDateInYesterday(date)
    }
    
    var displayTitle: String {
        if isToday {
            return "Today"
        } else if isYesterday {
            return "Yesterday"
        } else {
            return dayOfWeek
        }
    }
}

// MARK: - Walk Session
class WalkSession: ObservableObject {
    @Published var isActive: Bool = false
    @Published var startTime: Date?
    @Published var currentRoute: WalkingRoute?
    @Published var estimatedReturnTime: Date?
    @Published var halfwayAlertSent: Bool = false
    @Published var stepsThisSession: Int = 0
    @Published var markersScanned: [QRMarker] = []
    @Published var elapsedSeconds: Int = 0
    
    var elapsedTime: TimeInterval {
        return TimeInterval(elapsedSeconds)
    }
    
    var progress: Double {
        guard let route = currentRoute else { return 0 }
        let totalSeconds = Double(route.durationMinutes * 60)
        return min(elapsedTime / totalSeconds, 1.0)
    }
    
    func updateElapsedTime() {
        guard let start = startTime else { return }
        elapsedSeconds = Int(Date().timeIntervalSince(start))
    }
}

// MARK: - Notification Types
enum WalkNotification {
    case halfwayPoint
    case returnNow
    case clinicianReady
    case delayUpdate(newMinutes: Int)
}

// MARK: - Sample Data
extension WalkingRoute {
    static let sampleRoutes: [WalkingRoute] = [
        WalkingRoute(
            name: "Corridor Circuit",
            description: "A gentle indoor loop through the main corridors. Perfect for staying close to the clinic.",
            durationMinutes: 5,
            distanceMeters: 300,
            difficulty: .easy,
            isIndoor: true,
            isAccessible: true,
            landmarks: ["Reception", "Café", "Garden View Window"],
            icon: "building.2",
            color: .tealAccent,
            qrMarkers: [
                QRMarker(
                    code: "CORRIDOR1",
                    name: "Reception Calm",
                    location: "Near Reception",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4150, longitude: -1.4683),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[0],
                    pointsValue: 10
                ),
                QRMarker(
                    code: "CORRIDOR2",
                    name: "Café Corner",
                    location: "Outside Café",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4148, longitude: -1.4685),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[0],
                    pointsValue: 10
                ),
                QRMarker(
                    code: "CORRIDOR3",
                    name: "Garden View",
                    location: "Window Alcove",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4149, longitude: -1.4681),
                    contentType: .natureFact,
                    content: WellbeingContent(title: "Window Views", description: "Looking at nature through a window can reduce stress by 40%.", icon: "window.vertical.open", duration: 30, steps: ["Pause by the window", "Look at something green", "Take 3 deep breaths"]),
                    pointsValue: 10
                )
            ]
        ),
        WalkingRoute(
            name: "Courtyard Calm",
            description: "A peaceful walk through the enclosed courtyard garden with seating areas.",
            durationMinutes: 10,
            distanceMeters: 500,
            difficulty: .easy,
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Courtyard Entrance", "Memorial Bench", "Water Feature"],
            icon: "leaf.fill",
            color: .mintGreen,
            qrMarkers: [
                QRMarker(
                    code: "COURT1",
                    name: "Courtyard Entrance",
                    location: "Garden Gate",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4147, longitude: -1.4693),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[0],
                    pointsValue: 15
                ),
                QRMarker(
                    code: "COURT2",
                    name: "Garden Bench",
                    location: "Memorial Bench",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4146, longitude: -1.4690),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[0],
                    pointsValue: 15
                ),
                QRMarker(
                    code: "COURT3",
                    name: "Water Feature",
                    location: "Fountain Area",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4144, longitude: -1.4687),
                    contentType: .natureFact,
                    content: WellbeingContent(title: "Water Sounds", description: "The sound of water can lower cortisol levels and promote relaxation.", icon: "drop.fill", duration: 30, steps: ["Close your eyes", "Listen to the water", "Let your shoulders relax"]),
                    pointsValue: 15
                )
            ]
        ),
        WalkingRoute(
            name: "Green Loop",
            description: "Explore the grounds with views of the community garden and wildflower meadow.",
            durationMinutes: 15,
            distanceMeters: 900,
            difficulty: .moderate,
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Main Entrance", "Community Garden", "Wildflower Area", "Bird Boxes"],
            icon: "tree.fill",
            color: .forestGreen,
            qrMarkers: [
                QRMarker(
                    code: "GREEN1",
                    name: "Garden Gate",
                    location: "Community Garden Entrance",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4154, longitude: -1.4695),
                    contentType: .natureFact,
                    content: WellbeingContent(title: "Garden Wildlife", description: "Community gardens support 30% more wildlife than traditional lawns.", icon: "bird", duration: 30, steps: ["Look for butterflies", "Listen for birdsong", "Notice the plants"]),
                    pointsValue: 20
                ),
                QRMarker(
                    code: "GREEN2",
                    name: "Herb Spiral",
                    location: "Herb Garden",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4156, longitude: -1.4697),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[1],
                    pointsValue: 20
                ),
                QRMarker(
                    code: "GREEN3",
                    name: "Wildflower Meadow",
                    location: "Meadow Viewpoint",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4159, longitude: -1.4700),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[1],
                    pointsValue: 20
                ),
                QRMarker(
                    code: "GREEN4",
                    name: "Bird Boxes",
                    location: "Woodland Edge",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4152, longitude: -1.4705),
                    contentType: .miniChallenge,
                    content: WellbeingContent(title: "Bird Spotting", description: "Can you spot any birds using the nest boxes?", icon: "bird.fill", duration: 60, steps: ["Stand quietly for 1 minute", "Look at the bird boxes", "Listen for chirping", "Count how many birds you see"]),
                    pointsValue: 25
                )
            ]
        ),
        WalkingRoute(
            name: "Longley Explorer",
            description: "The full grounds circuit with nature trail elements and quiet reflection spots.",
            durationMinutes: 20,
            distanceMeters: 1200,
            difficulty: .moderate,
            isIndoor: false,
            isAccessible: false,
            landmarks: ["Reception", "Sensory Garden", "Woodland Path", "Viewpoint", "Return Path"],
            icon: "map.fill",
            color: .softAmber,
            qrMarkers: [
                QRMarker(
                    code: "LONG1",
                    name: "Sensory Garden",
                    location: "Herb Garden",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4152, longitude: -1.4680),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[2],
                    pointsValue: 20
                ),
                QRMarker(
                    code: "LONG2",
                    name: "Lavender Walk",
                    location: "Scented Path",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4155, longitude: -1.4685),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[0],
                    pointsValue: 20
                ),
                QRMarker(
                    code: "LONG3",
                    name: "Woodland Entry",
                    location: "Path Start",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4164, longitude: -1.4690),
                    contentType: .natureFact,
                    content: WellbeingContent(title: "Forest Bathing", description: "Walking in woodland can reduce cortisol by 16% and blood pressure by 2%.", icon: "tree.fill", duration: 45, steps: ["Walk slowly and mindfully", "Touch the bark of a tree", "Breathe in the forest air", "Notice the light through leaves"]),
                    pointsValue: 25
                ),
                QRMarker(
                    code: "LONG4",
                    name: "Hilltop View",
                    location: "Viewpoint",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4169, longitude: -1.4693),
                    contentType: .miniChallenge,
                    content: WellbeingContent(title: "Horizon Gazing", description: "Looking at distant views relaxes your eye muscles and reduces mental fatigue.", icon: "binoculars.fill", duration: 60, steps: ["Find a comfortable stance", "Look at the furthest point you can see", "Notice the sky", "Take 5 slow breaths"]),
                    pointsValue: 25
                ),
                QRMarker(
                    code: "LONG5",
                    name: "Reflection Spot",
                    location: "Quiet Bench",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4159, longitude: -1.4675),
                    contentType: .digitalTip,
                    content: WellbeingContent(title: "Digital Detox Moment", description: "Take a moment away from screens.", icon: "iphone.slash", duration: 60, steps: ["Put your phone in your pocket", "Look at the horizon", "Take 5 deep breaths", "Notice how you feel"]),
                    pointsValue: 25
                )
            ]
        )
    ]
}

extension WellbeingContent {
    static let breathingExercises: [WellbeingContent] = [
        WellbeingContent(
            title: "Box Breathing",
            description: "A calming technique used by Navy SEALs to reduce stress.",
            icon: "square",
            duration: 60,
            steps: [
                "Breathe in slowly for 4 seconds",
                "Hold your breath for 4 seconds",
                "Breathe out slowly for 4 seconds",
                "Hold empty for 4 seconds",
                "Repeat 4 times"
            ]
        ),
        WellbeingContent(
            title: "4-7-8 Relaxation",
            description: "Dr. Andrew Weil's relaxation breath for anxiety relief.",
            icon: "wind",
            duration: 90,
            steps: [
                "Exhale completely through your mouth",
                "Inhale quietly through your nose for 4 seconds",
                "Hold your breath for 7 seconds",
                "Exhale completely through mouth for 8 seconds",
                "Repeat 3 more times"
            ]
        ),
        WellbeingContent(
            title: "Grounding Breath",
            description: "Connect with the present moment through mindful breathing.",
            icon: "leaf.fill",
            duration: 120,
            steps: [
                "Feel your feet firmly on the ground",
                "Take a slow, deep breath in",
                "Notice 3 things you can see",
                "Breathe out slowly",
                "Notice 2 things you can hear",
                "Take another deep breath",
                "Notice 1 thing you can feel"
            ]
        )
    ]
    
    static let gratitudePrompts: [WellbeingContent] = [
        WellbeingContent(
            title: "Three Good Things",
            description: "Reflect on three positive things from today or this week.",
            icon: "heart.fill",
            duration: nil,
            steps: nil
        ),
        WellbeingContent(
            title: "Kindness Received",
            description: "Think of someone who showed you kindness recently. How did it make you feel?",
            icon: "hand.wave.fill",
            duration: nil,
            steps: nil
        ),
        WellbeingContent(
            title: "Moment of Beauty",
            description: "Look around you right now. What's the most beautiful thing you can see? Take a moment to appreciate it.",
            icon: "sparkles",
            duration: nil,
            steps: nil
        )
    ]
    
    static let natureFacts: [WellbeingContent] = [
        WellbeingContent(
            title: "Did You Know?",
            description: "Spending just 20 minutes in nature can significantly lower stress hormones.",
            icon: "leaf.circle.fill",
            duration: nil,
            steps: nil
        ),
        WellbeingContent(
            title: "Bird Spotting",
            description: "The UK has over 600 bird species. Can you spot any robins or blackbirds today?",
            icon: "bird.fill",
            duration: nil,
            steps: nil
        )
    ]
}

extension Badge {
    static let allBadges: [Badge] = [
        Badge(name: "First Steps", description: "Complete your first walking route", icon: "figure.walk", color: .tealAccent, requirement: .routes(1)),
        Badge(name: "Explorer", description: "Complete 5 different routes", icon: "map.fill", color: .mintGreen, requirement: .routes(5)),
        Badge(name: "Nature Photographer", description: "Take 5 nature photos", icon: "camera.fill", color: .softAmber, requirement: .photos(5)),
        Badge(name: "Mindful Walker", description: "Complete 3 breathing exercises", icon: "wind", color: .lavenderMist, requirement: .breathingExercises(3)),
        Badge(name: "Streak Starter", description: "Use the app on 3 different days", icon: "flame.fill", color: .coralPink, requirement: .daysUsed(3)),
        Badge(name: "Digital Pioneer", description: "Complete all 5 digital skills", icon: "iphone", color: .tealAccent, requirement: .digitalSkills(5))
    ]
}
