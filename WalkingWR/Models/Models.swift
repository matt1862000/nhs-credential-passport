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

// MARK: - Polyline Decoder
/// Decodes Google Maps encoded polylines into coordinate arrays
struct PolylineDecoder {
    /// Decodes an encoded polyline string into an array of coordinates
    /// Based on Google's Polyline Algorithm: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
    /// Uses Int64 throughout to avoid overflow traps on malformed or extreme input; returns [] on error.
    static func decode(_ encodedPolyline: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        let bytes = Array(encodedPolyline.utf8)
        let count = bytes.count
        if count == 0 { return [] }
        var pos = 0
        var lat: Int64 = 0
        var lng: Int64 = 0
        
        /// Read one byte; returns nil if out of bounds or outside Google's encoding range (63–126).
        func readByte() -> Int? {
            if pos < 0 || pos >= count { return nil }
            let b = Int(bytes[pos])
            pos += 1
            if b < 63 || b > 126 { return nil } // Invalid for Google polyline
            return b - 63
        }
        
        /// Decode one signed value (lat or lng). Uses Int64 to avoid overflow; returns nil if malformed.
        func decodeValue() -> Int64? {
            var result: Int64 = 0
            var shift = 0
            var byte = 0
            repeat {
                guard shift < 35 else { return nil }
                guard let b = readByte() else { return nil }
                byte = b
                result |= Int64(byte & 0x1F) << shift
                shift += 5
            } while byte >= 0x20
            let signed = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1)
            return signed
        }
        
        /// Reasonable delta range (1e5 degrees ≈ 1000+ km per step) to avoid runaway accumulation.
        let maxDelta: Int64 = 10_000_000
        /// Valid microdegrees so accumulated lat/lng never overflow Int64 and stay within geo range.
        let latMin: Int64 = -90 * 100_000
        let latMax: Int64 =  90 * 100_000
        let lngMin: Int64 = -180 * 100_000
        let lngMax: Int64 =  180 * 100_000
        
        while pos >= 0 && pos < count {
            guard let deltaLat = decodeValue() else { break }
            if pos >= count { break }
            if abs(deltaLat) > maxDelta { break }
            lat = min(max(lat &+ deltaLat, latMin), latMax)
            
            guard let deltaLng = decodeValue() else { break }
            if abs(deltaLng) > maxDelta { break }
            lng = min(max(lng &+ deltaLng, lngMin), lngMax)
            
            let latDeg = Double(lat) / 1e5
            let lngDeg = Double(lng) / 1e5
            guard latDeg >= -90, latDeg <= 90, lngDeg >= -180, lngDeg <= 180 else { break }
            coordinates.append(CLLocationCoordinate2D(latitude: latDeg, longitude: lngDeg))
        }
        
        return coordinates
    }
}

// MARK: - Clinician
struct Clinician: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let location: String        // Clinic location (e.g., "Decisions Unit")
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
    
    init(id: UUID = UUID(), name: String, location: String = "", title: String, specialty: String, 
         photoName: String? = nil, photoURL: String? = nil, bio: String,
         expertiseDescription: String, expertiseTags: [String],
         achievements: String,
         publicationsIntro: String, publicationTitle: String? = nil, publicationSubtitle: String? = nil, publicationsOutro: String,
         interests: [ClinicianInterest], interestsDescription: String,
         currentWaitMinutes: Int = 20, queuePosition: Int = 3) {
        self.id = id
        self.name = name
        self.location = location
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
    
    // v1.9.56: Optional appointment time for estimated time-to-be-seen calculation
    var appointmentTime: Date?
    
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
    
    // v1.9.56: Computed estimated time to be seen (appointment time + delay)
    var estimatedTimeToBeSeen: Date? {
        guard let appointmentTime = appointmentTime else { return nil }
        return Calendar.current.date(byAdding: .minute, value: estimatedMinutes, to: appointmentTime)
    }
    
    // v1.9.56: Formatted appointment time string
    var formattedAppointmentTime: String? {
        guard let appointmentTime = appointmentTime else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: appointmentTime)
    }
    
    // v1.9.56: Formatted estimated time to be seen string
    var formattedEstimatedTimeToBeSeen: String? {
        guard let estimatedTime = estimatedTimeToBeSeen else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: estimatedTime)
    }
    
    // v1.9.56: Check if past appointment time
    var isPastAppointmentTime: Bool {
        guard let appointmentTime = appointmentTime else { return false }
        return Date() > appointmentTime
    }
    
    // Create from clinician
    init(from clinician: Clinician) {
        self.estimatedMinutes = clinician.currentWaitMinutes
        self.lastUpdated = clinician.lastUpdated
        self.clinicianName = clinician.fullTitle
        self.queuePosition = clinician.queuePosition
        self.appointmentTime = nil
    }
    
    // Original init
    init(estimatedMinutes: Int, lastUpdated: Date, clinicianName: String, queuePosition: Int, appointmentTime: Date? = nil) {
        self.estimatedMinutes = estimatedMinutes
        self.lastUpdated = lastUpdated
        self.clinicianName = clinicianName
        self.queuePosition = queuePosition
        self.appointmentTime = appointmentTime
    }
}

// MARK: - Route Type
enum RouteType: String, Codable {
    case curated = "Curated"      // Verified routes at specific locations
    case local = "Local"          // Generated from user's location
    case indoor = "Indoor"        // Indoor hospital routes
}

// MARK: - Walking Direction Step
struct WalkingDirection: Identifiable, Hashable {
    let id = UUID()
    let instruction: String       // Plain text instruction (HTML stripped)
    let distance: String          // e.g., "120 m"
    let distanceMeters: Int
    let duration: String          // e.g., "2 mins"
    let maneuver: String?         // e.g., "turn-left", "turn-right"
    
    /// Icon for the direction maneuver
    var icon: String {
        switch maneuver {
        case "turn-left": return "arrow.turn.up.left"
        case "turn-right": return "arrow.turn.up.right"
        case "turn-slight-left": return "arrow.up.left"
        case "turn-slight-right": return "arrow.up.right"
        case "turn-sharp-left": return "arrow.turn.left.down"
        case "turn-sharp-right": return "arrow.turn.right.down"
        case "uturn-left", "uturn-right": return "arrow.uturn.down"
        case "straight": return "arrow.up"
        case "roundabout-left", "roundabout-right": return "arrow.triangle.2.circlepath"
        case "arrive": return "flag.checkered"
        default: return "arrow.up"
        }
    }
    
    /// Create from HTML instructions (strips HTML tags)
    static func fromHTML(_ html: String, distance: String, distanceMeters: Int, duration: String, maneuver: String?) -> WalkingDirection {
        // Strip HTML tags from instruction
        let plainText = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        
        return WalkingDirection(
            instruction: plainText,
            distance: distance,
            distanceMeters: distanceMeters,
            duration: duration,
            maneuver: maneuver
        )
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
    let routeType: RouteType
    let encodedPolyline: String?  // Google Maps encoded polyline for accurate route display
    let walkingDirections: [WalkingDirection]  // Turn-by-turn directions
    let usedOSRMRouting: Bool  // v1.6.46: Track if polyline came from OSRM (driving profile)
    /// True when route came from pre-populated database; used for duration-adjust (add/drop waypoints) after Let's Go.
    let isFromPrePopulatedDatabase: Bool
    /// When set (pre-pop), walk time to first waypoint. Preview shows durationMinutes (route only); pill uses durationMinutes + this.
    let travelToStartMinutes: Int?
    
    /// Alias for encodedPolyline (used by route creation and map display)
    var trimmed: String? { encodedPolyline }
    
    // Default initializer with backwards compatibility (trimmed is alias for encodedPolyline)
    init(name: String, description: String, durationMinutes: Int, distanceMeters: Int,
         difficulty: RouteDifficulty, isIndoor: Bool, isAccessible: Bool,
         landmarks: [String], icon: String, color: Color, qrMarkers: [QRMarker],
         routeType: RouteType = .curated, encodedPolyline: String? = nil, trimmed trimVal: String? = nil,
         walkingDirections: [WalkingDirection] = [],
         usedOSRMRouting: Bool = false,
         isFromPrePopulatedDatabase: Bool = false,
         travelToStartMinutes: Int? = nil) {
        self.name = name
        self.description = description
        self.durationMinutes = durationMinutes
        self.distanceMeters = distanceMeters
        self.difficulty = difficulty
        self.isIndoor = isIndoor
        self.isAccessible = isAccessible
        self.landmarks = landmarks
        self.icon = icon
        self.color = color
        self.qrMarkers = qrMarkers
        self.routeType = routeType
        self.encodedPolyline = encodedPolyline ?? trimVal
        self.walkingDirections = walkingDirections
        self.usedOSRMRouting = usedOSRMRouting
        self.isFromPrePopulatedDatabase = isFromPrePopulatedDatabase
        self.travelToStartMinutes = travelToStartMinutes
    }
    
    /// Decoded route path coordinates for map display
    /// Uses Google's encoded polyline if available, otherwise falls back to marker coordinates
    var routePath: [CLLocationCoordinate2D] {
        if let polyline = encodedPolyline, !polyline.isEmpty {
            let decoded = PolylineDecoder.decode(polyline)
            // Only log anomalies (low point count) to avoid main-thread spam during walks
            if decoded.count < 5 {
                print("⚠️ [POLYLINE DEBUG] '\(name)': Low point count (\(decoded.count) points) - may show incorrect path")
            }
            return decoded
        }
        // Fallback to marker coordinates if no polyline - log once per route, not every read
        #if DEBUG
        print("🚨 [POLYLINE DEBUG] '\(name)': NO POLYLINE - falling back to straight lines between \(qrMarkers.count) markers!")
        #endif
        return qrMarkers.map { $0.coordinate }
    }
    
    /// Simple waypoints for basic display (start, markers, end)
    var waypoints: [CLLocationCoordinate2D] {
        var points: [CLLocationCoordinate2D] = []
        if let first = routePath.first {
            points.append(first)
        }
        points.append(contentsOf: qrMarkers.map { $0.coordinate })
        if let last = routePath.last {
            points.append(last)
        }
        return points
    }
    
    var estimatedSteps: Int {
        // Average stride length ~0.76m
        return Int(Double(distanceMeters) / 0.76)
    }
    
    /// Approximate minutes added by breathing-exercise (and similar) triggers at waypoints (~1 min per trigger). Used for total time display.
    var triggerStopsMinutes: Int {
        qrMarkers.filter { $0.contentType == .breathingExercise }.count
    }
    
    /// Total display duration in minutes (walking + trigger stops). Use when showing "total time" to the user.
    var totalDisplayMinutes: Int {
        durationMinutes + triggerStopsMinutes
    }
    
    var isCurated: Bool {
        routeType == .curated
    }
    
    static func == (lhs: WalkingRoute, rhs: WalkingRoute) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    /// Cap displayed duration when unreasonably high for distance (e.g. 25 min for 1 km).
    /// v2.1.8: Removed target-based cap (was `min(distanceCap, target*1.25)`) because it hid
    /// genuinely long routes — e.g. a 53 min route was displayed as 25 min.
    /// Now only uses distance-based plausibility: maxPlausible = distance / 80 m/min * 1.15.
    func withDurationSanityCap(targetDurationMinutes: Int? = nil) -> WalkingRoute {
        guard distanceMeters > 200 else { return self }
        let maxPlausible = max(1, Int(Double(distanceMeters) / 80.0 * 1.15))
        guard durationMinutes > maxPlausible else { return self }
        return WalkingRoute(
            name: name,
            description: description,
            durationMinutes: min(durationMinutes, maxPlausible),
            distanceMeters: distanceMeters,
            difficulty: difficulty,
            isIndoor: isIndoor,
            isAccessible: isAccessible,
            landmarks: landmarks,
            icon: icon,
            color: color,
            qrMarkers: qrMarkers,
            routeType: routeType,
            trimmed: trimmed,
            walkingDirections: walkingDirections,
            usedOSRMRouting: usedOSRMRouting,
            isFromPrePopulatedDatabase: isFromPrePopulatedDatabase,
            travelToStartMinutes: travelToStartMinutes
        )
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
struct WellbeingContent: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let duration: Int? // in seconds, nil for instant content
    let steps: [String]?
    
    static func == (lhs: WellbeingContent, rhs: WellbeingContent) -> Bool {
        lhs.title == rhs.title && lhs.description == rhs.description
    }
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
            anxietyAfterWalk: anxietyLevelAfterWalk,
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
            anxietyAfterWalk: anxietyLevelAfterWalk,
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
    let anxietyAfterWalk: Int? // Specifically from walks (for Walking Wellbeing Impact)
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
    @Published var returnNowAlertSent: Bool = false
    @Published var walkCompleteAlertSent: Bool = false
    @Published var stepsThisSession: Int = 0
    @Published var markersScanned: [QRMarker] = []
    @Published var elapsedSeconds: Int = 0
    @Published var startLocation: CLLocationCoordinate2D?  // v1.6.48: User's actual GPS position when walk started
    
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
    // The Longley Centre coordinates (start/end point)
    static let longleyCentre = CLLocationCoordinate2D(latitude: 53.4108891, longitude: -1.4603237)
    
    // MARK: - Curated Routes for Northern General Hospital (Longley Centre)
    // These routes have been verified using Google Directions API with walking mode
    // Polylines are encoded using Google's Polyline Algorithm for accurate path display
    static let curatedRoutes: [WalkingRoute] = [
        // Route 1: Courtyard Stroll (5 min / 385m) - VERIFIED
        WalkingRoute(
            name: "Courtyard Stroll",
            description: "A gentle 5-minute loop around the immediate hospital grounds. Perfect for a quick refresh without going far.",
            durationMinutes: 5,
            distanceMeters: 385,
            difficulty: .easy,
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Longley Centre", "Rivermead Drive", "Norwood Grange Way", "Return"],
            icon: "figure.walk",
            color: .tealAccent,
            qrMarkers: [
                QRMarker(
                    code: "COURT1",
                    name: "Rivermead View",
                    location: "Rivermead Drive",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4110, longitude: -1.4592),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[0],
                    pointsValue: 10
                ),
                QRMarker(
                    code: "COURT2",
                    name: "Grange Corner",
                    location: "Norwood Grange Way",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4113, longitude: -1.4603),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[0],
                    pointsValue: 10
                )
            ],
            routeType: .curated,
            encodedPolyline: "ay~dI~e|GAiDCKCCSCCm@OASDOD?x@?xC?F?G?yC?y@NEREN@Bl@J@HBBD@h@@fC"
        ),
        
        // Route 2: Hospital Circuit (10 min / 736m) - VERIFIED
        WalkingRoute(
            name: "Hospital Circuit",
            description: "A 10-minute triangular loop through the hospital campus, passing the Hand Unit and Firth Wing.",
            durationMinutes: 10,
            distanceMeters: 736,
            difficulty: .easy,
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Longley Centre", "Hand Unit", "Firth Wing", "Central Lane", "Return"],
            icon: "arrow.triangle.2.circlepath",
            color: .mintGreen,
            qrMarkers: [
                QRMarker(
                    code: "HOSP1",
                    name: "Hand Unit Garden",
                    location: "Near Hand Unit",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4102, longitude: -1.4580),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[1],
                    pointsValue: 15
                ),
                QRMarker(
                    code: "HOSP2",
                    name: "Central Lane",
                    location: "Firth Wing Area",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4110, longitude: -1.4565),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[1],
                    pointsValue: 15
                ),
                QRMarker(
                    code: "HOSP3",
                    name: "Quiet Corner",
                    location: "Herries Road Drive",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4105, longitude: -1.4575),
                    contentType: .natureFact,
                    content: WellbeingContent(title: "Walking Benefits", description: "Just 10 minutes of walking can improve mood and reduce anxiety.", icon: "heart.fill", duration: 30, steps: ["Take a deep breath", "Notice how your body feels", "Appreciate this moment"]),
                    pointsValue: 15
                )
            ],
            routeType: .curated,
            encodedPolyline: "ay~dI~e|GAiDCKCCSCCm@LAd@Ar@CLANI`@kA[}@ESCIFGPIPAQ@QHGFEKIKKEwAEOEA{@EyDT?U?DxDBhAUBDtBB`@Ax@L@Bl@J@HBBD@h@@fC"
        ),
        
        // Route 3: Brennan Way Loop (15 min / 1.2km) - VERIFIED
        WalkingRoute(
            name: "Brennan Way Loop",
            description: "A 15-minute walk through the residential area west of the hospital, via Brennan Way and Longley Lane.",
            durationMinutes: 15,
            distanceMeters: 1200,
            difficulty: .moderate,
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Longley Centre", "Brennan Way", "Norwood Grange Drive", "Longley Lane", "Return"],
            icon: "leaf.fill",
            color: .forestGreen,
            qrMarkers: [
                QRMarker(
                    code: "BREN1",
                    name: "Brennan Way",
                    location: "Residential Area",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4115, longitude: -1.4615),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[2],
                    pointsValue: 20
                ),
                QRMarker(
                    code: "BREN2",
                    name: "Longley Lane South",
                    location: "11 Longley Lane",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4120, longitude: -1.4642),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[2],
                    pointsValue: 20
                ),
                QRMarker(
                    code: "BREN3",
                    name: "Longley Lane North",
                    location: "10 Longley Lane",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4128, longitude: -1.4632),
                    contentType: .natureFact,
                    content: WellbeingContent(title: "Community Walking", description: "Walking in your local area helps you feel more connected to your community.", icon: "person.2.fill", duration: 30, steps: ["Look around at the buildings", "Notice any gardens or plants", "Wave if you see a neighbour"]),
                    pointsValue: 20
                ),
                QRMarker(
                    code: "BREN4",
                    name: "Norwood Return",
                    location: "Norwood Grange Drive",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4118, longitude: -1.4620),
                    contentType: .miniChallenge,
                    content: WellbeingContent(title: "Mindful Walking", description: "Focus on the sensation of walking.", icon: "figure.walk.motion", duration: 60, steps: ["Slow your pace slightly", "Feel each footstep", "Notice the ground beneath you", "Take 10 mindful steps"]),
                    pointsValue: 25
                )
            ],
            routeType: .curated,
            encodedPolyline: "ay~dI~e|GAiDCKCCSCCm@I?O?YH?~EAhBBn@APETGJSNIBFVADIt@e@pEQ|BC`@GPQVS^PXQYq@m@Do@Fi@GCYMs@_@MILHf@Vd@TFBGh@En@p@l@R_@PWFQT_Dn@gG@EGWHCROFKDU@QCo@@iB?_Fh@IH?Bl@RBBBBJ@hD"
        ),
        
        // Route 4: Longley Explorer (20 min / 1.5km) - VERIFIED
        WalkingRoute(
            name: "Longley Explorer",
            description: "A 20-minute exploration of the wider Longley area, including Longley Close and Herries Road. Great for a proper break.",
            durationMinutes: 20,
            distanceMeters: 1500,
            difficulty: .moderate,
            isIndoor: false,
            isAccessible: true,
            landmarks: ["Longley Centre", "Brennan Way", "Longley Close", "Herries Road", "Longley Lane", "Return"],
            icon: "map.fill",
            color: .softAmber,
            qrMarkers: [
                QRMarker(
                    code: "LONG1",
                    name: "Brennan Way Start",
                    location: "Leaving the Hospital",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4115, longitude: -1.4614),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[0],
                    pointsValue: 20
                ),
                QRMarker(
                    code: "LONG2",
                    name: "Longley Close",
                    location: "2 Longley Close",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4132, longitude: -1.4637),
                    contentType: .natureFact,
                    content: WellbeingContent(title: "Green Spaces", description: "Living near green spaces is linked to lower stress and better mental health.", icon: "leaf.fill", duration: 30, steps: ["Look for any trees nearby", "Notice any gardens", "Take 3 deep breaths of fresh air"]),
                    pointsValue: 20
                ),
                QRMarker(
                    code: "LONG3",
                    name: "Herries Road",
                    location: "306 Herries Road",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4122, longitude: -1.4658),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[0],
                    pointsValue: 25
                ),
                QRMarker(
                    code: "LONG4",
                    name: "Longley Lane View",
                    location: "Junction Area",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4117, longitude: -1.4647),
                    contentType: .miniChallenge,
                    content: WellbeingContent(title: "Horizon Gazing", description: "Looking at distant views relaxes your eyes and mind.", icon: "binoculars.fill", duration: 60, steps: ["Find the furthest point you can see", "Focus on it for 30 seconds", "Notice the sky", "Take 5 slow breaths"]),
                    pointsValue: 25
                ),
                QRMarker(
                    code: "LONG5",
                    name: "Return Path",
                    location: "Heading Back",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4115, longitude: -1.4625),
                    contentType: .digitalTip,
                    content: WellbeingContent(title: "Digital Detox Moment", description: "Take a moment away from screens.", icon: "iphone.slash", duration: 60, steps: ["Keep your phone in your pocket", "Look around you", "Notice 3 things you can see", "Feel present in this moment"]),
                    pointsValue: 25
                )
            ],
            routeType: .curated,
            encodedPolyline: "ay~dI~e|GAiDCKCCSCCm@I?O?YH?~EAhBBn@APETGJSNIBFVADIt@e@pEQ|BC`@GPQVS^q@m@yCa@MELDxC`@p@l@Xb@t@tAgAxBa@hAAHBZC[@I`@iAfAyBu@uAYc@R_@PWFQBa@P}Bn@gG@EGWHCROFKDU@QCo@@iB?_Fh@IH?Bl@RBBBBJ@hD"
        )
    ]
    
    // Indoor routes for Northern General Hospital
    // Based on NGH site map - hospital is over different levels with link corridors
    // Reference: https://sheffieldhospitalscharity.org.uk/storage/documents/NGH_site_map_-_Wycliffe_House_edit.pdf
    static let indoorRoutes: [WalkingRoute] = [
        // Indoor Route 1: Longley Centre Loop (5 min)
        WalkingRoute(
            name: "Longley Centre Loop",
            description: "A gentle 5-minute indoor circuit within The Longley Centre. Perfect for staying close to your appointment or during bad weather.",
            durationMinutes: 5,
            distanceMeters: 300,
            difficulty: .easy,
            isIndoor: true,
            isAccessible: true,
            landmarks: ["Main Reception", "Waiting Area", "Garden View Windows", "Return Corridor"],
            icon: "building.2",
            color: .lavenderMist,
            qrMarkers: [
                QRMarker(
                    code: "LC_IN1",
                    name: "Reception Calm",
                    location: "Longley Centre Reception",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4109, longitude: -1.4602),
                    contentType: .breathingExercise,
                    content: WellbeingContent.breathingExercises[0],
                    pointsValue: 10
                ),
                QRMarker(
                    code: "LC_IN2",
                    name: "Garden View",
                    location: "Window Alcove",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4108, longitude: -1.4600),
                    contentType: .natureFact,
                    content: WellbeingContent(title: "Window Gazing", description: "Looking at nature through a window can reduce stress by up to 40%. Even a brief glimpse of greenery helps.", icon: "window.vertical.open", duration: 30, steps: ["Find a window with a view", "Look at something green outside", "Take 3 slow, deep breaths", "Notice how you feel"]),
                    pointsValue: 10
                ),
                QRMarker(
                    code: "LC_IN3",
                    name: "Quiet Corner",
                    location: "End of Corridor",
                    coordinate: CLLocationCoordinate2D(latitude: 53.4110, longitude: -1.4604),
                    contentType: .gratitudePrompt,
                    content: WellbeingContent.gratitudePrompts[0],
                    pointsValue: 10
                )
            ],
            routeType: .indoor,
            encodedPolyline: nil
        )
    ]
    
    // Combined sample routes (for backwards compatibility)
    static let sampleRoutes: [WalkingRoute] = curatedRoutes + indoorRoutes
}

extension WellbeingContent {
    static let breathingExercises: [WellbeingContent] = [
        WellbeingContent(
            title: "Box Breathing",
            description: "A Navy SEAL technique for calm.",
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
            description: "Relaxation breath for anxiety relief.",
            icon: "wind",
            duration: 90,
            steps: [
                "Exhale completely",
                "Inhale slowly for 4 seconds",
                "Hold for 7 seconds",
                "Exhale slowly for 8 seconds",
                "Repeat 3 more times"
            ]
        ),
        WellbeingContent(
            title: "Grounding Breath",
            description: "Mindful breathing for presence.",
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

