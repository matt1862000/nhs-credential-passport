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
    @Binding var showLocalRoutePicker: Bool
    @Binding var wellbeingCategory: WellbeingCategory
    @Binding var wellbeingExercise: WellbeingContent?
    
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
                Group {
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
                        ClinicianSelectionView(
                            viewModel: viewModel,
                            isPresented: .init(
                                get: { activeSheet == .clinicianSelection },
                                set: { if !$0 { activeSheet = nil } }
                            ),
                            onNavigateToWalk: {
                                activeSheet = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    selectedTab = 1
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        showLocalRoutePicker = true
                                    }
                                }
                            },
                            onNavigateToBreathing: {
                                activeSheet = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    selectedTab = 2
                                    wellbeingCategory = .breathing
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        wellbeingExercise = WellbeingContent.breathingExercises.randomElement()
                                    }
                                }
                            },
                            onNavigateToDigitalSkills: {
                                activeSheet = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    selectedTab = 2
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        wellbeingCategory = .digital
                                    }
                                }
                            }
                        )
                    }
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
                Button("Stop Alerts", role: .destructive) {
                    viewModel.disableNotifications()
                }
            } message: {
                if let info = viewModel.waitTimeChangeInfo {
                    let increase = info.newMinutes - info.oldMinutes
                    Text("The clinic delay has increased by \(increase) minutes (now \(info.newMinutes) min delay).")
                } else {
                    Text("The clinic delay has been updated.")
                }
            }
            .alert("Delay Reduction", isPresented: $viewModel.showWaitTimeDecreasedAlert) {
                Button("OK", role: .cancel) { }
                Button("Stop Alerts", role: .destructive) {
                    viewModel.disableNotifications()
                }
            } message: {
                if let info = viewModel.waitTimeChangeInfo {
                    let decrease = info.oldMinutes - info.newMinutes
                    if info.newMinutes == 0 {
                        Text("The clinic is now running on time.")
                    } else if info.newMinutes <= 5 {
                        Text("The clinic delay has reduced to \(info.newMinutes) minutes.")
                    } else {
                        Text("The clinic delay has reduced by \(decrease) minutes (now \(info.newMinutes) min delay).")
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
            // Notification reminder when alerts are off - only show if clinician is selected
            if !viewModel.notificationsEnabled && viewModel.selectedClinician != nil {
                Button(action: {
                    viewModel.enableNotifications()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill")
                            .font(.subheadline)
                        Text("Alerts off. Tap to re-enable.")
                            .font(.caption)
                            .fontWeight(.medium)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            
            // Last updated - top right (only show if clinician is selected)
            if viewModel.selectedClinician != nil {
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
            }
            
            // Time display - large
            if viewModel.selectedClinician == nil && !viewModel.hasNoClinicsAvailable {
                // User skipped selection but clinics are available
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 50))
                        .foregroundColor(.tealAccent.opacity(0.7))
                    
                    Text("Select a Clinician")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("Choose your clinician to see their delay time")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button(action: onShowClinicianSelection) {
                        HStack(spacing: 8) {
                            Image(systemName: "person.2.fill")
                                .font(.callout)
                            Text("View Available Clinicians")
                                .font(.callout)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.tealAccent)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 8)
                }
                .padding(.vertical, 16)
            } else if viewModel.hasNoClinicsAvailable {
                // No clinics running at all
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Active Clinics")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    Text("Check back during clinic hours")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .padding(.vertical, 8)
            } else if viewModel.isClinicEnded {
                // User had a clinician selected, but clinic has ended
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.tealAccent)
                    Text("Clinic Ended")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("Thank you for waiting with us")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if waitInfo.isOnTime {
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
            if viewModel.hasNoClinicsAvailable {
                // No clinics running - show button to check available clinicians
                Button(action: onShowClinicianSelection) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .font(.callout)
                        Text("View Clinicians")
                            .font(.callout)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.tealAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.tealAccent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .padding(.top, 8)
            } else if let clinician = viewModel.selectedClinician {
                HStack(spacing: 20) {
                    // Clinician photo/initial - larger (greyed out if clinic ended)
                    ClinicianPhotoView(clinician: clinician, size: 80)
                        .opacity(viewModel.isClinicEnded ? 0.6 : 1.0)
                    
                    // Name and specialty
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: onShowClinicianProfile) {
                            HStack(spacing: 6) {
                                Text(clinician.fullTitle)
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(viewModel.isClinicEnded ? .secondary : .primary)
                                
                                if !viewModel.isClinicEnded {
                                    Image(systemName: "info.circle")
                                        .font(.subheadline)
                                        .foregroundColor(.tealAccent)
                                }
                            }
                        }
                        .disabled(viewModel.isClinicEnded)
                        
                        Text(clinician.specialty)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        // Change clinician button - fixed size to prevent truncation
                        Button(action: onShowClinicianSelection) {
                            HStack(spacing: 8) {
                                Image(systemName: viewModel.isClinicEnded ? "person.2.fill" : "arrow.triangle.2.circlepath")
                                    .font(.callout)
                                Text(viewModel.isClinicEnded ? "Select New Clinician" : "Change Clinician")
                                    .font(.callout)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundColor(.tealAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.tealAccent.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.top, 8)
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
    
    // Suggested duration based on wait time (leave 5 min buffer)
    private var suggestedDuration: Int {
        let waitTime = viewModel.waitTimeInfo.estimatedMinutes
        if waitTime >= 25 { return 20 }
        if waitTime >= 20 { return 15 }
        if waitTime >= 15 { return 10 }
        if waitTime >= 10 { return 5 }
        return 0 // Too short to walk
    }
    
    // Estimated steps for the duration
    private var estimatedSteps: Int {
        suggestedDuration * 100 // ~100 steps per minute
    }
    
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
            
            if suggestedDuration > 0 {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Create your route")
                            .font(.bodyLarge)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("\(suggestedDuration) min • \(estimatedSteps) steps")
                            .font(.bodyMedium)
                            .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    Button("Go") {
                        selectedTab = 1 // Navigate to Walk tab to create local route
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
                
                Text("You have time for a \(suggestedDuration)-minute route. We'll notify you when to head back.")
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
                        .frame(width: max(0, geometry.size.width * min(1, max(0, viewModel.walkSession.progress))), height: 8)
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
    WaitTimeView(
        viewModel: WaitingRoomViewModel(),
        selectedTab: .constant(0),
        showLocalRoutePicker: .constant(false),
        wellbeingCategory: .constant(.breathing),
        wellbeingExercise: .constant(nil)
    )
}


