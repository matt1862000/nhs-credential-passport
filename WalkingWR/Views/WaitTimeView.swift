//
//  WaitTimeView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI

// Sheet types for WaitTimeView
enum WaitTimeSheetType: Identifiable {
    case help
    case anxietyCheck
    case clinicianProfile
    case clinicianSelection
    
    var id: String {
        switch self {
        case .help: return "help"
        case .anxietyCheck: return "anxietyCheck"
        case .clinicianProfile: return "clinicianProfile"
        case .clinicianSelection: return "clinicianSelection"
        }
    }
}

struct WaitTimeView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var selectedTab: Int
    
    @State private var pulseAnimation = false
    @State private var activeSheet: WaitTimeSheetType?
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Main wait time display
                        WaitTimeCard(
                            viewModel: viewModel,
                            onShowClinicianSelection: { activeSheet = .clinicianSelection },
                            onShowClinicianProfile: { activeSheet = .clinicianProfile }
                        )
                            .padding(.top, 20)
                        
                        // Walking suggestion
                        if !viewModel.walkSession.isActive {
                            WalkingSuggestionCard(
                                viewModel: viewModel,
                                selectedTab: $selectedTab
                            )
                        } else {
                            ActiveWalkCard(viewModel: viewModel)
                        }
                        
                        // Wellbeing prompt - only show if no initial score recorded
                        if viewModel.userProgress.anxietyLevelBefore == nil {
                            AnxietyCheckCard(
                                onTap: { activeSheet = .anxietyCheck },
                                hasCompletedPre: false
                            )
                        }
                        
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Clinic Delay")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { activeSheet = .help }) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(.coralPink)
                    }
                }
            }
            .sheet(item: $activeSheet) { sheetType in
                switch sheetType {
                case .help:
                    HelpView()
                case .anxietyCheck:
                    AnxietyCheckSheet(viewModel: viewModel, isPresented: .init(
                        get: { activeSheet == .anxietyCheck },
                        set: { if !$0 { activeSheet = nil } }
                    ), isPostWalk: false)
                case .clinicianProfile:
                    if let clinician = viewModel.selectedClinician {
                        ClinicianProfileView(clinician: clinician)
                    }
                case .clinicianSelection:
                    ClinicianSelectionView(viewModel: viewModel, isPresented: .init(
                        get: { activeSheet == .clinicianSelection },
                        set: { if !$0 { activeSheet = nil } }
                    ))
                }
            }
            .alert("Clinician Ready!", isPresented: $viewModel.showClinicianReadyAlert) {
                Button("I'm on my way") {
                    viewModel.endWalk(completed: false)
                }
            } message: {
                Text("Your clinician is ready to see you. Please return to reception.")
            }
            .alert("Clinic Delay Updated", isPresented: $viewModel.showWaitTimeIncreasedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                if let info = viewModel.waitTimeChangeInfo {
                    let increase = info.newMinutes - info.oldMinutes
                    Text("The clinic delay has increased by \(increase) minutes (now \(info.newMinutes) min delay).\n\nWe apologise for any inconvenience. Feel free to explore our wellbeing activities while you wait.")
                } else {
                    Text("The clinic delay has been updated.")
                }
            }
            .alert("Good News! 🎉", isPresented: $viewModel.showWaitTimeDecreasedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                if let info = viewModel.waitTimeChangeInfo {
                    let decrease = info.oldMinutes - info.newMinutes
                    if info.newMinutes == 0 {
                        Text("The clinic is now running on time.\n\nPlease check in with reception when you're ready for your appointment.")
                    } else if info.newMinutes <= 5 {
                        Text("The clinic delay has reduced to just \(info.newMinutes) minutes.\n\nThe clinic is nearly back on schedule.")
                    } else {
                        Text("The clinic delay has reduced by \(decrease) minutes (now \(info.newMinutes) min delay).\n\nWe'll keep you updated.")
                    }
                } else {
                    Text("The clinic delay has been updated.")
                }
            }
        }
    }
}

// MARK: - Wait Time Card
struct WaitTimeCard: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    var onShowClinicianSelection: () -> Void
    var onShowClinicianProfile: () -> Void
    
    var waitInfo: WaitTimeInfo {
        viewModel.waitTimeInfo
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Last updated - top right
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Text("Updated")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(waitInfo.lastUpdated, style: .time)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
            }
            
            // Time display - large
            if waitInfo.isOnTime {
                Text("On Time")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(.mintGreen)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(waitInfo.estimatedMinutes)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("min")
                        .font(.titleMedium)
                        .foregroundColor(.primary)
                        .padding(.bottom, 8)
                }
            }
            
            // Clinician info with change option
            if let clinician = viewModel.selectedClinician {
                HStack(spacing: 20) {
                    // Clinician photo/initial - larger
                    ClinicianPhotoView(clinician: clinician, size: 80)
                    
                    // Name and specialty
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: onShowClinicianProfile) {
                            HStack(spacing: 6) {
                                Text(clinician.fullTitle)
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                Image(systemName: "info.circle")
                                    .font(.subheadline)
                                    .foregroundColor(.tealAccent)
                            }
                        }
                        
                        Text(clinician.specialty)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        // Change button - more prominent
                        Button(action: onShowClinicianSelection) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.subheadline)
                                Text("Change Clinician")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundColor(.tealAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.tealAccent.opacity(0.15))
                            .clipShape(Capsule())
                        }
                        .padding(.top, 6)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }
}

// MARK: - Pulsing Status Dot
struct PulsingStatusDot: View {
    var body: some View {
        Circle()
            .fill(Color.mintGreen)
            .frame(width: 10, height: 10)
    }
}

// MARK: - Quick Actions Row
struct QuickActionsRow: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var selectedTab: Int
    
    var body: some View {
        HStack(spacing: 12) {
            QuickActionButton(
                icon: "figure.walk",
                title: "Start Walk",
                color: .tealAccent
            ) {
                selectedTab = 1
            }
            
            QuickActionButton(
                icon: "wind",
                title: "Breathe",
                color: .lavenderMist
            ) {
                selectedTab = 2
            }
            
            QuickActionButton(
                icon: "leaf.fill",
                title: "Nature",
                color: .mintGreen
            ) {
                selectedTab = 2 // Goes to Wellbeing where Nature tab is
            }
        }
    }
}

struct QuickActionButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .cardStyle()
        }
    }
}

// MARK: - Walking Suggestion Card
struct WalkingSuggestionCard: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var selectedTab: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "figure.walk.motion")
                    .font(.title2)
                    .foregroundColor(.tealAccent)
                
                Text("Time to walk?")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
            }
            
            let suggestedRoutes = viewModel.suggestedRoutes(for: viewModel.waitTimeInfo.estimatedMinutes)
            
            if let bestRoute = suggestedRoutes.first {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bestRoute.name)
                            .font(.bodyLarge)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("\(bestRoute.durationMinutes) min • \(bestRoute.estimatedSteps) steps")
                            .font(.bodyMedium)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Button("Go") {
                        viewModel.selectRoute(bestRoute)
                        selectedTab = 1
                    }
                    .font(.bodyLarge)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.tealAccent)
                    .clipShape(Capsule())
                }
                .padding()
                .background(Color.tealAccent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                
                Text("You have time for a \(bestRoute.durationMinutes)-minute route. We'll notify you when to head back.")
                    .font(.caption)
                    .foregroundColor(.primary)
            } else {
                Text("Wait time is short, stay close to reception.")
                    .font(.bodyMedium)
                    .foregroundColor(.primary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Active Walk Card
struct ActiveWalkCard: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var showMap = false
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "figure.walk")
                    .font(.title2)
                    .foregroundColor(.primary)
                    .symbolEffect(.pulse, options: .repeating)
                
                Text("Walk in Progress")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(viewModel.walkSession.stepsThisSession) steps")
                    .font(.bodyMedium)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: geometry.size.width * viewModel.walkSession.progress, height: 8)
                }
            }
            .frame(height: 8)
            
            if let route = viewModel.walkSession.currentRoute {
                HStack {
                    Text(route.name)
                        .font(.bodyMedium)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if viewModel.walkSession.halfwayAlertSent {
                        Label("Head back now", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }
                }
            }
            
            // Action buttons
            HStack(spacing: 12) {
                Button(action: { showMap = true }) {
                    HStack {
                        Image(systemName: "map.fill")
                        Text("View Map")
                    }
                    .font(.bodyMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.3))
                    .clipShape(Capsule())
                }
                
                Button("End Walk") {
                    viewModel.endWalk(completed: true)
                }
                .font(.bodyMedium)
                .fontWeight(.semibold)
                .foregroundColor(.tealAccent)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(Capsule())
            }
        }
        .sheet(isPresented: $showMap) {
            WalkingMapView(viewModel: viewModel)
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color.tealAccent, Color.forestGreen],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.tealAccent.opacity(0.3), radius: 10, y: 5)
    }
}

// MARK: - Anxiety Check Card
struct AnxietyCheckCard: View {
    var onTap: () -> Void
    var hasCompletedPre: Bool = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(hasCompletedPre ? Color.mintGreen.opacity(0.2) : Color.lavenderMist.opacity(0.2))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "heart.text.square")
                        .font(.title2)
                        .foregroundColor(.lavenderMist)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasCompletedPre ? "Update Your Wellbeing" : "How are you feeling?")
                        .font(.bodyLarge)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text(hasCompletedPre ? "Initial score recorded ✓" : "Quick check-in to track your wellbeing")
                        .font(.caption)
                        .foregroundColor(hasCompletedPre ? .mintGreen : .primary)
                }
                
                Spacer()
                
                if hasCompletedPre {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.mintGreen)
                }
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.primary)
            }
            .padding(16)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Digital Skills Challenge Tip Card
struct DigitalLiteracyTipCard: View {
    @Environment(\.openURL) var openURL
    
    let tips: [(icon: String, title: String, description: String, url: String?)] = [
        ("iphone.badge.checkmark", "NHS App", "Book GP appointments, view records, and order prescriptions.", "https://apps.apple.com/gb/app/nhs-app/id1388411277"),
        ("mappin.circle.fill", "Route Markers", "Walk to discover markers - the app automatically detects when you arrive!", nil),
        ("map.fill", "Sheffield Health Walks", "Free group walks led by trained volunteers across Sheffield.", "https://www.stepoutsheffield.co.uk")
    ]
    
    @State private var currentTip = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.softAmber)
                
                Text("Digital Tip")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .textCase(.uppercase)
                
                Spacer()
                
                // Swipe hint
                Text("Swipe →")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 12) {
                Image(systemName: tips[currentTip].icon)
                    .font(.title3)
                    .foregroundColor(.tealAccent)
                    .frame(width: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tips[currentTip].title)
                        .font(.bodyMedium)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text(tips[currentTip].description)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                
                Spacer()
            }
            
            // Learn More button (only if URL exists)
            if let urlString = tips[currentTip].url, let url = URL(string: urlString) {
                Button(action: {
                    openURL(url)
                }) {
                    HStack(spacing: 4) {
                        Text("Learn More")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                    .foregroundColor(.tealAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.tealAccent.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            
            // Page dots
            HStack(spacing: 6) {
                ForEach(0..<tips.count, id: \.self) { index in
                    Circle()
                        .fill(currentTip == index ? Color.tealAccent : Color.tealAccent.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .cardStyle()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if value.translation.width < 0 {
                            // Swipe left - next tip
                            currentTip = (currentTip + 1) % tips.count
                        } else if value.translation.width > 0 {
                            // Swipe right - previous tip
                            currentTip = (currentTip - 1 + tips.count) % tips.count
                        }
                    }
                }
        )
    }
}

// MARK: - Anxiety Check Sheet
struct AnxietyCheckSheet: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var isPresented: Bool
    var isPostWalk: Bool = false
    var isWalkActivity: Bool = false // true if this is specifically for a walking activity
    @State private var selectedLevel: Int = 5
    
    var title: String {
        isPostWalk ? "Post-Activity Check" : "Pre-Activity Check"
    }
    
    var subtitle: String {
        isPostWalk ? "How do you feel now?" : "How anxious do you feel right now?"
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                VStack(spacing: 16) {
                    Image(systemName: isPostWalk ? "figure.walk.circle.fill" : "heart.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(anxietyColor)
                    
                    Text(subtitle)
                        .font(.titleMedium)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                    
                    Text("1 = Very calm, 10 = Very anxious")
                        .font(.caption)
                        .foregroundColor(.primary)
                    
                    if isPostWalk, let before = viewModel.userProgress.anxietyLevelBefore {
                        Text("Your starting score: \(before)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.tealAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.tealAccent.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
                
                // Scale
                VStack(spacing: 20) {
                    Text("\(selectedLevel)")
                        .font(.displayLarge)
                        .fontWeight(.bold)
                        .foregroundColor(anxietyColor)
                    
                    Slider(value: Binding(
                        get: { Double(selectedLevel) },
                        set: { selectedLevel = Int($0) }
                    ), in: 1...10, step: 1)
                    .tint(anxietyColor)
                    .padding(.horizontal, 30)
                    
                    HStack {
                        Text("Calm")
                            .font(.caption)
                            .foregroundColor(.mintGreen)
                        
                        Spacer()
                        
                        Text("Anxious")
                            .font(.caption)
                            .foregroundColor(.coralPink)
                    }
                    .padding(.horizontal, 30)
                }
                
                Spacer()
                
                Button("Save") {
                    if isPostWalk {
                        if isWalkActivity {
                            viewModel.recordAnxietyAfterWalk(selectedLevel)
                        } else {
                            viewModel.recordAnxietyAfter(selectedLevel)
                        }
                    } else {
                        viewModel.recordAnxietyBefore(selectedLevel)
                    }
                    isPresented = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Skip") {
                        isPresented = false
                    }
                }
            }
        }
    }
    
    var anxietyColor: Color {
        switch selectedLevel {
        case 1...3: return .mintGreen
        case 4...6: return .softAmber
        default: return .coralPink
        }
    }
}

#Preview {
    WaitTimeView(viewModel: WaitingRoomViewModel(), selectedTab: .constant(0))
}


