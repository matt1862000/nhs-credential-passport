//
//  ProfileView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import CoreMotion
import CoreLocation
#if os(iOS)
import UIKit
#endif

struct ProfileView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @ObservedObject var healthKitService: HealthKitService
    // Settings moved to WaitTimeView (Delay tab)
    @State private var showHelpSheet = false
    @State private var showIntroduction = false
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Stats summary card
                        StatsSummaryCard(progress: viewModel.userProgress)
                            .padding(.top, 20)
                        
                        // Activity History (scrollable)
                        ActivityHistorySection(
                            progress: viewModel.userProgress,
                            healthKitTotalSteps: healthKitService.totalDailySteps
                        )
                        
                        // Wellbeing sections (grouped with less spacing)
                        VStack(spacing: 12) {
                            // Swipeable Wellbeing History (Your Wellbeing)
                            WellbeingHistorySection(
                                progress: viewModel.userProgress,
                                title: "Your Wellbeing",
                                icon: "heart.fill",
                                useWalkScores: false
                            )
                            
                            // Swipeable Walking Wellbeing History
                            WellbeingHistorySection(
                                progress: viewModel.userProgress,
                                title: "Walking Wellbeing Impact",
                                icon: "figure.walk",
                                useWalkScores: true
                            )
                        }
                        
                        // Badges section
                        BadgesSection(progress: viewModel.userProgress)
                        
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Your Progress")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showHelpSheet = true }) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(.coralPink)
                    }
                }
            }
            .sheet(isPresented: $showHelpSheet) {
                HelpView()
            }
            .fullScreenCover(isPresented: $showIntroduction) {
                IntroductionReplayView(isPresented: $showIntroduction)
            }
            .onAppear {
                // Refresh HealthKit total daily steps when view appears
                healthKitService.refreshTotalDailySteps()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active {
                    // Refresh HealthKit steps when app becomes active
                    healthKitService.refreshTotalDailySteps()
                }
            }
        }
    }
}

// MARK: - Stats Summary Card
struct StatsSummaryCard: View {
    @ObservedObject var progress: UserProgress
    
    var body: some View {
        VStack(spacing: 20) {
            // Points display
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total Points")
                        .font(.caption)
                        .foregroundColor(.primary)
                        .textCase(.uppercase)
                    
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(progress.totalPoints)")
                            .font(.displayMedium)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Image(systemName: "star.fill")
                            .font(.title3)
                            .foregroundColor(.softAmber)
                    }
                }
                
                Spacer()
                
                // Level badge
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.tealAccent, .mintGreen],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 70, height: 70)
                    
                    VStack(spacing: 2) {
                        Text("Level")
                            .font(.micro)
                            .foregroundColor(.white)
                        
                        Text("\(currentLevel)")
                            .font(.titleLarge)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                }
            }
            
            // Progress to next level
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Progress to Level \(currentLevel + 1)")
                        .font(.caption)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text("\(pointsToNextLevel) points to go")
                        .font(.caption)
                        .foregroundColor(.tealAccent)
                }
                
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.tealAccent.opacity(0.2))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.tealAccent)
                            .frame(width: geometry.size.width * levelProgress, height: 8)
                    }
                }
                .frame(height: 8)
            }
        }
        .padding(24)
        .cardStyle()
    }
    
    var currentLevel: Int {
        progress.totalPoints / 100 + 1
    }
    
    var pointsToNextLevel: Int {
        let nextLevelPoints = currentLevel * 100
        return nextLevelPoints - progress.totalPoints
    }
    
    var levelProgress: Double {
        let pointsInCurrentLevel = progress.totalPoints % 100
        return Double(pointsInCurrentLevel) / 100.0
    }
}

// Detail type enum
enum ActivityDetailType {
    case steps
    case routes
    case spots
    case gratitude
    case all
}

// Combined selection for sheet
struct ActivityDetailSelection: Identifiable {
    let id = UUID()
    let activity: DailyActivity
    let detailType: ActivityDetailType
    var healthKitTotalSteps: Int? = nil  // Optional HealthKit total steps for today
}

// MARK: - Activity History Section
struct ActivityHistorySection: View {
    @ObservedObject var progress: UserProgress
    var healthKitTotalSteps: Int = 0  // Total daily steps from HealthKit
    @State private var currentIndex = 0
    @State private var cardHeight: CGFloat = 200 // Default, will be measured
    @State private var detailSelection: ActivityDetailSelection?
    
    // All activities with today first, then previous days sorted newest to oldest
    var allActivities: [DailyActivity] {
        var activities = [progress.todayActivity]
        let previousDays = progress.dailyHistory.filter { !$0.isToday }
        activities.append(contentsOf: previousDays)
        return activities
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with page indicator
            HStack {
                Text("Your Activity")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Page indicator
                if allActivities.count > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption2)
                            .foregroundColor(currentIndex > 0 ? .tealAccent : .secondary.opacity(0.3))
                        
                        Text("\(currentIndex + 1)/\(allActivities.count)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(currentIndex < allActivities.count - 1 ? .tealAccent : .secondary.opacity(0.3))
                    }
                }
            }
            
            // Swipeable activity cards
            if allActivities.count > 1 {
                TabView(selection: $currentIndex) {
                    ForEach(Array(allActivities.enumerated()), id: \.element.id) { index, activity in
                        DailyActivityCard(
                            activity: activity,
                            isExpanded: true,
                            healthKitTotalSteps: activity.isToday ? healthKitTotalSteps : nil
                        ) { detailType in
                            detailSelection = ActivityDetailSelection(
                                activity: activity,
                                detailType: detailType,
                                healthKitTotalSteps: activity.isToday ? healthKitTotalSteps : nil
                            )
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CardHeightPreferenceKey.self,
                                    value: geo.size.height
                                )
                            }
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: cardHeight)
                .onPreferenceChange(CardHeightPreferenceKey.self) { height in
                    if height > cardHeight {
                        cardHeight = height
                    }
                }
            } else {
                // Just show today if no history - naturally sizes itself
                DailyActivityCard(
                    activity: progress.todayActivity,
                    isExpanded: true,
                    healthKitTotalSteps: healthKitTotalSteps
                ) { detailType in
                    detailSelection = ActivityDetailSelection(
                        activity: progress.todayActivity,
                        detailType: detailType,
                        healthKitTotalSteps: healthKitTotalSteps
                    )
                }
            }
            
            }
        // Sheet uses combined selection - activity and detail type bundled together
        .sheet(item: $detailSelection) { selection in
            ActivityDetailSheet(
                activity: selection.activity,
                focusedDetail: selection.detailType,
                healthKitTotalSteps: selection.healthKitTotalSteps
            )
        }
    }
}

// Preference key to measure card height
struct CardHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 180
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Daily Activity Card
struct DailyActivityCard: View {
    let activity: DailyActivity
    var isExpanded: Bool = false
    var healthKitTotalSteps: Int? = nil  // Total daily steps from HealthKit (for today only)
    var onTapDetail: ((ActivityDetailType) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    
    // Use HealthKit total steps for today if available, otherwise use activity steps
    var displaySteps: Int {
        if activity.isToday, let hkSteps = healthKitTotalSteps, hkSteps > 0 {
            return hkSteps
        }
        return activity.steps
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.displayTitle)
                        .font(.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    if !activity.isToday {
                        Text(activity.formattedDate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if activity.isToday {
                    Text("Now")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.tealAccent)
                        .clipShape(Capsule())
                }
            }
            
            // Stats row - tappable
            HStack(spacing: 12) {
                TappableStatView(
                    icon: "figure.walk",
                    value: "\(displaySteps)",
                    label: "Steps",
                    color: .tealAccent
                ) {
                    onTapDetail?(.steps)
                }
                
                TappableStatView(
                    icon: "map.fill",
                    value: "\(activity.routesCompleted)",
                    label: "Routes",
                    color: .mintGreen
                ) {
                    onTapDetail?(.routes)
                }
                
                TappableStatView(
                    icon: "mappin",
                    value: "\(activity.qrScansCompleted)",
                    label: "Spots",
                    color: .softAmber
                ) {
                    onTapDetail?(.spots)
                }
            }
            
// Gratitude entries count - tappable
            if !activity.gratitudeEntries.isEmpty {
                Button(action: { onTapDetail?(.gratitude) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.text.square")
                            .font(.caption)
                            .foregroundColor(.coralPink)
                        
                        Text("\(activity.gratitudeEntries.count) gratitude entr\(activity.gratitudeEntries.count == 1 ? "y" : "ies")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.coralPink.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            }
            
        }
        .padding(16)
        .cardStyle()
    }
}

struct ActivityStatView: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 50, height: 50)
                
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
            }
            
            Text(value)
                .font(.titleMedium)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            Text(label)
                .font(.micro)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tappable Stat View
struct TappableStatView: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(color)
                }
                
                Text(value)
                    .font(.titleMedium)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text(label)
                    .font(.micro)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Activity Detail Sheet
struct ActivityDetailSheet: View {
    let activity: DailyActivity
    var focusedDetail: ActivityDetailType = .all
    var healthKitTotalSteps: Int? = nil  // Total HealthKit steps (for today)
    @Environment(\.dismiss) var dismiss
    
    // Use HealthKit total steps for today if available
    var displaySteps: Int {
        if activity.isToday, let hkSteps = healthKitTotalSteps, hkSteps > 0 {
            return hkSteps
        }
        return activity.steps
    }
    
    var distanceKm: Double {
        Double(displaySteps) * 0.0008
    }
    
    var caloriesBurned: Int {
        displaySteps / 20
    }
    
    var activeMinutes: Int {
        max(1, displaySteps / 100)
    }
    
    var sheetTitle: String {
        switch focusedDetail {
        case .steps: return "Steps"
        case .routes: return "Routes"
        case .spots: return "Discovery Spots"
        case .gratitude: return "Gratitude Journal"
        case .all: return activity.displayTitle
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Steps Section
                    if focusedDetail == .steps || focusedDetail == .all {
                        stepsSection
                    }
                    
                    // Routes Section
                    if focusedDetail == .routes || focusedDetail == .all {
                        routesSection
                    }
                    
                    // Spots Section
                    if focusedDetail == .spots || focusedDetail == .all {
                        spotsSection
                    }
                    
                    // Gratitude Section
                    if focusedDetail == .gratitude || focusedDetail == .all {
                        gratitudeSection
                    }
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .background(AnimatedGradientBackground())
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - Steps Section
    var stepsSection: some View {
        VStack(spacing: 16) {
            // Big number display
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.tealAccent.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "figure.walk")
                        .font(.system(size: 36))
                        .foregroundColor(.tealAccent)
                }
                
                Text("\(displaySteps)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text("steps")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Steps breakdown - show route steps vs total steps
            if activity.isToday, let hkSteps = healthKitTotalSteps, hkSteps > 0 {
                VStack(spacing: 12) {
                    Text("Steps Breakdown")
                        .font(.bodyMedium)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 20) {
                        // Route steps
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "map.fill")
                                    .font(.caption)
                                    .foregroundColor(.mintGreen)
                                Text("\(activity.steps)")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                            }
                            Text("During Routes")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.mintGreen.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        
                        // Total daily steps
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "figure.walk")
                                    .font(.caption)
                                    .foregroundColor(.tealAccent)
                                Text("\(hkSteps)")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                            }
                            Text("Total Today")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.tealAccent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    
                    // Percentage from routes
                    if hkSteps > 0 {
                        let percentage = min(100, (Double(activity.steps) / Double(hkSteps)) * 100)
                        Text("\(Int(percentage))% of your steps today were during WaitWell routes")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                Divider()
            }
            
            // Stats breakdown
            HStack(spacing: 16) {
                DetailMiniStat(icon: "ruler", value: String(format: "%.2f km", distanceKm), label: "Distance")
                DetailMiniStat(icon: "flame.fill", value: "\(caloriesBurned) kcal", label: "Calories")
                DetailMiniStat(icon: "clock.fill", value: "\(activeMinutes) min", label: "Active")
            }
            
            // Motivation message
            Text(stepsMotivation)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(20)
        .cardStyle()
    }
    
    var stepsMotivation: String {
        if displaySteps >= 5000 { return "🎉 Amazing effort! You've hit a great milestone." }
        else if displaySteps >= 2000 { return "👍 Great progress! Every step counts." }
        else if displaySteps >= 500 { return "🚶 Good start! Keep moving when you can." }
        else if displaySteps > 0 { return "🌱 Every journey begins with a single step." }
        else { return "Ready to start walking? Even a short walk can boost your mood." }
    }
    
    // MARK: - Routes Section
    var routesSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.mintGreen.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "map.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.mintGreen)
                }
                
                Text("\(activity.routesCompleted)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text(activity.routesCompleted == 1 ? "route completed" : "routes completed")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Benefits of Walking Routes")
                    .font(.bodyMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                BenefitItem(icon: "brain.head.profile", text: "Reduces anxiety while waiting")
                BenefitItem(icon: "heart.fill", text: "Improves cardiovascular health")
                BenefitItem(icon: "leaf.fill", text: "Connects you with nature")
            }
        }
        .padding(20)
        .cardStyle()
    }
    
    // MARK: - Spots Section
    var spotsSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.softAmber.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "mappin")
                        .font(.system(size: 36))
                        .foregroundColor(.softAmber)
                }
                
                Text("\(activity.qrScansCompleted)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text(activity.qrScansCompleted == 1 ? "spot discovered" : "spots discovered")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("What are discovery spots?")
                    .font(.bodyMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("Special locations along routes. Get within 20m and the app offers a wellbeing activity.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                BenefitItem(icon: "camera.fill", text: "Take photos for badges")
                BenefitItem(icon: "wind", text: "Try breathing exercises")
                BenefitItem(icon: "star.fill", text: "Earn bonus points")
            }
        }
        .padding(20)
        .cardStyle()
    }
    
    // MARK: - Gratitude Section
    @ViewBuilder
    var gratitudeSection: some View {
        if !activity.gratitudeEntries.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color.coralPink.opacity(0.15))
                            .frame(width: 50, height: 50)
                        Image(systemName: "heart.text.square.fill")
                            .font(.title2)
                            .foregroundColor(.coralPink)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Gratitude Journal")
                            .font(.titleMedium)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text("\(activity.gratitudeEntries.count) entr\(activity.gratitudeEntries.count == 1 ? "y" : "ies")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                ForEach(Array(activity.gratitudeEntries.enumerated()), id: \.offset) { index, entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.coralPink)
                            .clipShape(Circle())
                        
                        Text(entry)
                            .font(.bodyMedium)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color.coralPink.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                
                Text("Practicing gratitude reduces anxiety and improves wellbeing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding(20)
            .cardStyle()
        }
    }
}

struct BenefitItem: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.tealAccent)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct DetailMiniStat: View {
    let icon: String
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.bodyMedium)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}


// MARK: - Anxiety Comparison Card
// MARK: - General Anxiety Score Card (any activity)
struct AnxietyScoreCard: View {
    let before: Int
    let after: Int?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "heart.circle.fill")
                    .font(.title2)
                    .foregroundColor(.coralPink)
                
                Text("Your Wellbeing")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            HStack(spacing: 20) {
                // Before
                VStack(spacing: 8) {
                    Text("Before")
                        .font(.caption)
                        .foregroundColor(.primary)
                    
                    ZStack {
                        Circle()
                            .fill(anxietyColor(for: before).opacity(0.15))
                            .frame(width: 60, height: 60)
                        
                        Text("\(before)")
                            .font(.titleLarge)
                            .fontWeight(.bold)
                            .foregroundColor(anxietyColor(for: before))
                    }
                    
                    Text(anxietyLabel(for: before))
                        .font(.micro)
                        .foregroundColor(.primary)
                }
                
                // Arrow
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundColor(.primary)
                
                // After
                VStack(spacing: 8) {
                    Text("After")
                        .font(.caption)
                        .foregroundColor(.primary)
                    
                    if let afterValue = after {
                        ZStack {
                            Circle()
                                .fill(anxietyColor(for: afterValue).opacity(0.15))
                                .frame(width: 60, height: 60)
                            
                            Text("\(afterValue)")
                                .font(.titleLarge)
                                .fontWeight(.bold)
                                .foregroundColor(anxietyColor(for: afterValue))
                        }
                        
                        Text(anxietyLabel(for: afterValue))
                            .font(.micro)
                            .foregroundColor(.primary)
                    } else {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [5]))
                                .frame(width: 60, height: 60)
                            
                            Text("?")
                                .font(.titleLarge)
                                .foregroundColor(.primary)
                        }
                        
                        Text("Pending")
                            .font(.micro)
                            .foregroundColor(.primary)
                    }
                }
                
                Spacer()
                
                // Change indicator
                if let afterValue = after {
                    let change = before - afterValue
                    VStack(spacing: 4) {
                        Image(systemName: change > 0 ? "arrow.down.circle.fill" : (change < 0 ? "arrow.up.circle.fill" : "equal.circle.fill"))
                            .font(.title)
                            .foregroundColor(change > 0 ? .mintGreen : (change < 0 ? .coralPink : .secondary))
                        
                        Text(change > 0 ? "-\(change)" : (change < 0 ? "+\(abs(change))" : "No change"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(change > 0 ? .mintGreen : (change < 0 ? .coralPink : .secondary))
                    }
                }
            }
        }
        .padding(20)
        .cardStyle()
    }
    
    func anxietyColor(for level: Int) -> Color {
        switch level {
        case 1...3: return .mintGreen
        case 4...6: return .softAmber
        default: return .coralPink
        }
    }
    
    func anxietyLabel(for level: Int) -> String {
        switch level {
        case 1...3: return "Calm"
        case 4...6: return "Moderate"
        default: return "Anxious"
        }
    }
}

// MARK: - Walking Wellbeing Card (specifically from walks)
struct WalkingWellbeingCard: View {
    let before: Int
    let after: Int? // Only populated if a walk was completed
    
    var change: Int? {
        guard let after = after else { return nil }
        return before - after
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "figure.walk.circle.fill")
                    .font(.title2)
                    .foregroundColor(.lavenderMist)
                
                Text("Walking Wellbeing Impact")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            HStack(spacing: 20) {
                // Before
                VStack(spacing: 8) {
                    Text("Before Walk")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ZStack {
                        Circle()
                            .fill(anxietyColor(for: before).opacity(0.15))
                            .frame(width: 60, height: 60)
                        
                        Text("\(before)")
                            .font(.titleLarge)
                            .fontWeight(.bold)
                            .foregroundColor(anxietyColor(for: before))
                    }
                    
                    Text(anxietyLabel(for: before))
                        .font(.micro)
                        .foregroundColor(.secondary)
                }
                
                // Arrow
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundColor(.secondary)
                
                // After
                VStack(spacing: 8) {
                    Text("After Walk")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let afterValue = after {
                        ZStack {
                            Circle()
                                .fill(anxietyColor(for: afterValue).opacity(0.15))
                                .frame(width: 60, height: 60)
                            
                            Text("\(afterValue)")
                                .font(.titleLarge)
                                .fontWeight(.bold)
                                .foregroundColor(anxietyColor(for: afterValue))
                        }
                        
                        Text(anxietyLabel(for: afterValue))
                            .font(.micro)
                            .foregroundColor(.secondary)
                    } else {
                        // No walk completed yet
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [5]))
                                .frame(width: 60, height: 60)
                            
                            Text("?")
                                .font(.titleLarge)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("No walk yet")
                            .font(.micro)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Change indicator (only show if walk completed)
                if let changeValue = change {
                    VStack(spacing: 4) {
                        Image(systemName: changeValue > 0 ? "arrow.down.circle.fill" : (changeValue < 0 ? "arrow.up.circle.fill" : "equal.circle.fill"))
                            .font(.title)
                            .foregroundColor(changeValue > 0 ? .mintGreen : (changeValue < 0 ? .coralPink : .secondary))
                        
                        Text(changeValue > 0 ? "-\(changeValue)" : (changeValue < 0 ? "+\(abs(changeValue))" : "Same"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(changeValue > 0 ? .mintGreen : (changeValue < 0 ? .coralPink : .secondary))
                    }
                }
            }
        }
        .padding(20)
        .cardStyle()
    }
    
    func anxietyColor(for level: Int) -> Color {
        switch level {
        case 1...3: return .mintGreen
        case 4...6: return .softAmber
        default: return .coralPink
        }
    }
    
    func anxietyLabel(for level: Int) -> String {
        switch level {
        case 1...3: return "Calm"
        case 4...6: return "Moderate"
        default: return "Anxious"
        }
    }
}

// MARK: - Wellbeing History Section (Swipeable)
struct WellbeingHistorySection: View {
    @ObservedObject var progress: UserProgress
    let title: String
    let icon: String
    let useWalkScores: Bool // true = Walking Wellbeing, false = Your Wellbeing
    @Environment(\.colorScheme) var colorScheme
    @State private var currentIndex: Int = 0
    
    // Get activities that have wellbeing data
    var activitiesWithWellbeing: [DailyActivity] {
        progress.allActivities.filter { activity in
            if useWalkScores {
                // For walking wellbeing, show if they did a walk (routes > 0) AND have a before score
                // The "after" score can be nil (will show "?")
                return activity.routesCompleted > 0 && activity.anxietyBefore != nil
            } else {
                // For general wellbeing, need before score
                return activity.anxietyBefore != nil
            }
        }
    }
    
    var body: some View {
        // Only show if there's data
        if !activitiesWithWellbeing.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                // Header with navigation indicator (aligned with Your Activity style)
                HStack {
                    Text(title)
                        .font(.titleMedium)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    // Page indicator in header
                    if activitiesWithWellbeing.count > 1 {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.caption2)
                                .foregroundColor(currentIndex > 0 ? .tealAccent : .secondary.opacity(0.3))
                            
                            Text("\(currentIndex + 1)/\(activitiesWithWellbeing.count)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(currentIndex < activitiesWithWellbeing.count - 1 ? .tealAccent : .secondary.opacity(0.3))
                        }
                    }
                }
                .padding(.horizontal, 4)
                
                TabView(selection: $currentIndex) {
                    ForEach(Array(activitiesWithWellbeing.enumerated()), id: \.element.id) { index, activity in
                        WellbeingDayCard(
                            activity: activity,
                            useWalkScores: useWalkScores,
                            colorScheme: colorScheme
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 160)
            }
        }
    }
}

struct WellbeingDayCard: View {
    let activity: DailyActivity
    let useWalkScores: Bool
    let colorScheme: ColorScheme
    
    var before: Int? { activity.anxietyBefore }
    var after: Int? { useWalkScores ? activity.anxietyAfterWalk : activity.anxietyAfter }
    
    var change: Int? {
        guard let b = before, let a = after else { return nil }
        return b - a
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header - matching DailyActivityCard style
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.isToday ? "Today" : activity.displayTitle)
                        .font(.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    if !activity.isToday {
                        Text(activity.formattedDate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if activity.isToday {
                    Text("Now")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.tealAccent)
                        .clipShape(Capsule())
                }
            }
            
            // Stats row - matching DailyActivityCard alignment
            HStack(spacing: 12) {
                // Before/Start
                if let beforeValue = before {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(anxietyColor(for: beforeValue).opacity(0.15))
                                .frame(width: 50, height: 50)
                            
                            Text("\(beforeValue)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(anxietyColor(for: beforeValue))
                        }
                        
                        Text(useWalkScores ? "Before" : "Start")
                            .font(.micro)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                }
                
                // After/Now
                VStack(spacing: 8) {
                    if let afterValue = after {
                        ZStack {
                            Circle()
                                .fill(anxietyColor(for: afterValue).opacity(0.15))
                                .frame(width: 50, height: 50)
                            
                            Text("\(afterValue)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(anxietyColor(for: afterValue))
                        }
                        
                        Text(useWalkScores ? "After" : "Now")
                            .font(.micro)
                            .foregroundColor(.primary)
                    } else {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [4]))
                                .frame(width: 50, height: 50)
                            
                            Text("?")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Pending")
                            .font(.micro)
                            .foregroundColor(.primary)
                    }
                }
                .frame(maxWidth: .infinity)
                
                // Result indicator
                if let changeValue = change {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill((changeValue > 0 ? Color.mintGreen : (changeValue < 0 ? Color.coralPink : Color.secondary)).opacity(0.15))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: changeValue > 0 ? "arrow.down" : (changeValue < 0 ? "arrow.up" : "equal"))
                                .font(.title3)
                                .foregroundColor(changeValue > 0 ? .mintGreen : (changeValue < 0 ? .coralPink : .secondary))
                        }
                        
                        Text(changeValue > 0 ? "Better" : (changeValue < 0 ? "Higher" : "Same"))
                            .font(.micro)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    // Empty spacer to maintain alignment when no change
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 2, dash: [4]))
                                .frame(width: 50, height: 50)
                            
                            Text("-")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Change")
                            .font(.micro)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(Color.adaptiveCardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 4)
    }
    
    func anxietyColor(for level: Int) -> Color {
        switch level {
        case 1...3: return .mintGreen
        case 4...6: return .softAmber
        default: return .coralPink
        }
    }
    
    func anxietyLabel(for level: Int) -> String {
        switch level {
        case 1...3: return "Calm"
        case 4...6: return "Moderate"
        default: return "Anxious"
        }
    }
}

// MARK: - Badges Section
struct BadgesSection: View {
    @ObservedObject var progress: UserProgress
    @StateObject private var photoStorage = PhotoStorageService.shared
    @State private var selectedBadge: Badge? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Badges")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(unlockedCount)/\(Badge.allBadges.count)")
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            
            // Tap hint
            Text("Tap a badge to see how to earn it")
                .font(.caption)
                .foregroundColor(.secondary)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                ForEach(Badge.allBadges) { badge in
                    BadgeView(
                        badge: badge,
                        isUnlocked: isBadgeUnlocked(badge),
                        currentProgress: getProgress(for: badge),
                        requiredAmount: getRequired(for: badge)
                    )
                    .onTapGesture {
                        selectedBadge = badge
                    }
                }
            }
        }
        .padding(20)
        .cardStyle()
        .sheet(item: $selectedBadge) { badge in
            BadgeDetailSheet(
                badge: badge,
                isUnlocked: isBadgeUnlocked(badge),
                currentProgress: getProgress(for: badge),
                requiredAmount: getRequired(for: badge)
            )
            .presentationDetents([.medium])
        }
    }
    
    var unlockedCount: Int {
        Badge.allBadges.filter { isBadgeUnlocked($0) }.count
    }
    
    func isBadgeUnlocked(_ badge: Badge) -> Bool {
        switch badge.requirement {
        case .steps(let required):
            return progress.totalSteps >= required
        case .routes(let required):
            return progress.routesCompleted >= required
        case .qrScans(let required):
            return progress.qrScansCompleted >= required
        case .breathingExercises(let required):
            return progress.breathingExercisesCompleted >= required
        case .consecutiveDays:
            return false // Not implemented
        case .digitalSkills(let required):
            return progress.digitalSkillsCompletedCount >= required
        case .photos(let required):
            return photoStorage.capturedPhotos.count >= required
        case .daysUsed(let required):
            return progress.daysUsedCount >= required
        }
    }
    
    func getProgress(for badge: Badge) -> Int {
        switch badge.requirement {
        case .steps:
            return progress.totalSteps
        case .routes:
            return progress.routesCompleted
        case .qrScans:
            return progress.qrScansCompleted
        case .breathingExercises:
            return progress.breathingExercisesCompleted
        case .consecutiveDays:
            return 0
        case .digitalSkills:
            return progress.digitalSkillsCompletedCount
        case .photos:
            return photoStorage.capturedPhotos.count
        case .daysUsed:
            return progress.daysUsedCount
        }
    }
    
    func getRequired(for badge: Badge) -> Int {
        switch badge.requirement {
        case .steps(let required):
            return required
        case .routes(let required):
            return required
        case .qrScans(let required):
            return required
        case .breathingExercises(let required):
            return required
        case .consecutiveDays(let required):
            return required
        case .digitalSkills(let required):
            return required
        case .photos(let required):
            return required
        case .daysUsed(let required):
            return required
        }
    }
}

struct BadgeView: View {
    let badge: Badge
    let isUnlocked: Bool
    var currentProgress: Int = 0
    var requiredAmount: Int = 1
    
    var progressPercent: Double {
        min(Double(currentProgress) / Double(requiredAmount), 1.0)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Progress ring (only show if not unlocked)
                if !isUnlocked {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 3)
                        .frame(width: 60, height: 60)
                    
                    Circle()
                        .trim(from: 0, to: progressPercent)
                        .stroke(badge.color.opacity(0.5), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90))
                }
                
                Circle()
                    .fill(isUnlocked ? badge.color.opacity(0.15) : Color.gray.opacity(0.1))
                    .frame(width: 54, height: 54)
                
                Image(systemName: badge.icon)
                    .font(.title2)
                    .foregroundColor(isUnlocked ? badge.color : .secondary)
                
                if !isUnlocked {
                    Circle()
                        .fill(Color.black.opacity(0.3))
                        .frame(width: 54, height: 54)
                    
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            
            Text(badge.name)
                .font(.micro)
                .fontWeight(.medium)
                .foregroundColor(isUnlocked ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }
}

// MARK: - Badge Detail Sheet
struct BadgeDetailSheet: View {
    let badge: Badge
    let isUnlocked: Bool
    let currentProgress: Int
    let requiredAmount: Int
    @Environment(\.dismiss) private var dismiss
    
    var progressPercent: Double {
        min(Double(currentProgress) / Double(requiredAmount), 1.0)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Handle bar
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 40, height: 5)
                .padding(.top, 12)
            
            // Badge icon (larger)
            ZStack {
                Circle()
                    .fill(isUnlocked ? badge.color.opacity(0.15) : Color.gray.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: badge.icon)
                    .font(.system(size: 44))
                    .foregroundColor(isUnlocked ? badge.color : .secondary)
                
                if isUnlocked {
                    // Checkmark for unlocked
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.mintGreen)
                                .background(Circle().fill(.white).padding(-2))
                        }
                        Spacer()
                    }
                    .frame(width: 100, height: 100)
                }
            }
            
            // Badge name and status
            VStack(spacing: 8) {
                Text(badge.name)
                    .font(.titleLarge)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text(isUnlocked ? "Unlocked! 🎉" : "Locked")
                    .font(.bodyMedium)
                    .foregroundColor(isUnlocked ? .mintGreen : .secondary)
            }
            
            // Description
            Text(badge.description)
                .font(.bodyMedium)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            
            // Progress section
            if !isUnlocked {
                VStack(spacing: 12) {
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 12)
                            
                            RoundedRectangle(cornerRadius: 8)
                                .fill(badge.color)
                                .frame(width: geometry.size.width * progressPercent, height: 12)
                        }
                    }
                    .frame(height: 12)
                    .padding(.horizontal, 40)
                    
                    // Progress text
                    Text("\(currentProgress) / \(requiredAmount)")
                        .font(.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text(howToEarnText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }
            
            Spacer()
            
            // Close button
            Button("Close") {
                dismiss()
            }
            .font(.bodyMedium)
            .foregroundColor(.tealAccent)
            .padding(.bottom, 20)
        }
    }
    
    var howToEarnText: String {
        let remaining = requiredAmount - currentProgress
        switch badge.requirement {
        case .steps:
            return "Walk \(remaining) more steps to unlock"
        case .routes:
            return "Complete \(remaining) more route\(remaining == 1 ? "" : "s") to unlock"
        case .qrScans:
            return "Discover \(remaining) more marker\(remaining == 1 ? "" : "s") to unlock"
        case .breathingExercises:
            return "Complete \(remaining) more breathing exercise\(remaining == 1 ? "" : "s") to unlock"
        case .consecutiveDays:
            return "Use the app for \(remaining) more consecutive day\(remaining == 1 ? "" : "s")"
        case .digitalSkills:
            return "Complete \(remaining) more digital skill\(remaining == 1 ? "" : "s") to unlock"
        case .photos:
            return "Take \(remaining) more photo\(remaining == 1 ? "" : "s") to unlock"
        case .daysUsed:
            return "Use the app on \(remaining) more day\(remaining == 1 ? "" : "s") to unlock"
        }
    }
}

// MARK: - Digital Skills Challenge Progress Card
struct DigitalLiteracyProgressCard: View {
    let scans: Int
    let totalSkills = 5
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                    .foregroundColor(.tealAccent)
                
                Text("Digital Skills Challenge")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(min(scans, totalSkills))/\(totalSkills) skills")
                    .font(.caption)
                    .foregroundColor(.tealAccent)
            }
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.tealAccent.opacity(0.2))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.tealAccent)
                        .frame(width: geometry.size.width * progress, height: 8)
                }
            }
            .frame(height: 8)
            
            Text("Keep discovering markers on your walks and exploring wellbeing content to build your digital confidence!")
                .font(.caption)
                .foregroundColor(.primary)
        }
        .padding(20)
        .cardStyle()
    }
    
    var progress: Double {
        min(Double(scans) / Double(totalSkills), 1.0)
    }
}

// MARK: - Help & Resources Card (Simplified - main help is via floating button)
struct HelpResourcesCard: View {
    @State private var showHelpSheet = false
    
    var body: some View {
        Button(action: {
            showHelpSheet = true
        }) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.coralPink.opacity(0.15))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "hand.raised.fill")
                        .font(.title3)
                        .foregroundColor(.coralPink)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Need Help?")
                        .font(.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("Crisis support & helplines available 24/7")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.coralPink)
            }
            .padding(20)
            .cardStyle()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showHelpSheet) {
            HelpView()
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @ObservedObject var healthKitService: HealthKitService
    let locationService: LocationService  // v1.6.46: NOT observed - prevents sheet dismissal on location updates
    @Binding var showIntroduction: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue
    @State private var showResetTodayAlert = false
    @State private var showResetAllAlert = false
    @State private var systemNotificationsEnabled = false
    @State private var notificationsNeverAsked = true  // True if user was never prompted
    @State private var showHealthKitUnavailable = false
    @State private var showMotionUnavailable = false
    @State private var showHealthKitManageAlert = false
    @State private var showTestResultsAlert = false
    @State private var googleQuota: (today: Int, cap: Int) = (0, 10)  // v1.9.50: Track Google quota
    
    // Only show permissions that have been interacted with (not .notDetermined)
    var shouldShowNotifications: Bool {
        !notificationsNeverAsked
    }
    
    var shouldShowLocation: Bool {
        locationService.authorizationStatus != .notDetermined
    }
    
    var shouldShowMotion: Bool {
        !healthKitService.isMotionNotDetermined
    }
    
    var shouldShowHealthKit: Bool {
        UserDefaults.standard.bool(forKey: "healthKitRequested")
    }
    
    var hasAnyPermissions: Bool {
        shouldShowNotifications || shouldShowLocation || shouldShowMotion || shouldShowHealthKit
    }
    
    var selectedTheme: AppTheme {
        AppTheme(rawValue: appTheme) ?? .system
    }
    
    // MARK: - Debug Test Actions
    #if DEBUG
    private func runDeduplicationTests() {
        print("🔵 [DEBUG] Test button tapped!")
        print("🔵 [DEBUG] Calling runAllTests()...")
        DeduplicationTestRunner.shared.runAllTests()
        print("🔵 [DEBUG] runAllTests() completed, showing alert")
        showTestResultsAlert = true
    }
    #endif
    
    // MARK: - List Sections (extracted to reduce compiler complexity)
    
    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion)
                    .foregroundColor(.primary)
            }
            
            Link(destination: URL(string: "https://www.sheffieldpartnership.nhs.uk")!) {
                HStack {
                    Text("Sheffield Health Partnership NHS Foundation Trust")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                }
            }
        }
    }
    
    #if DEBUG
    // NOTE: Database generation is now done on computer using generate_database.py
    // Removed database generation UI - database is generated on computer and bundled with app
    /*
    @State private var isGeneratingDatabase = false
    @State private var databaseGenerationStatus = ""
    @State private var showDatabaseSuccessAlert = false
    @State private var showDatabaseProgress = false
    @StateObject private var databaseGenerator = PrePopulatedPOIGenerator()
    
    // Optional: Use this if you need to add routes from the app
    private func addRoutesToDatabase() {
        isGeneratingDatabase = true
        showDatabaseProgress = true
        databaseGenerationStatus = "Loading database and generating routes..."
        
        Task {
            do {
                // Check if database exists with POIs
                guard let existingDB = PrePopulatedPOIService.shared.loadBundledDatabase(),
                      !existingDB.postcodeAreas.isEmpty,
                      existingDB.postcodeAreas.first?.pois.isEmpty == false else {
                    await MainActor.run {
                        isGeneratingDatabase = false
                        showDatabaseProgress = false
                        databaseGenerationStatus = "❌ No database found. Generate database using:\npython3 generate_database.py"
                        showDatabaseSuccessAlert = true
                    }
                    return
                }
                
                // Database exists - add routes using OSRM
                print("📦 Existing database found - adding routes with OSRM...")
                databaseGenerationStatus = "Found existing POIs. Generating routes with OSRM..."
                
                let fileURL = try await databaseGenerator.addRoutesToExistingDatabase()
                
                await MainActor.run {
                    isGeneratingDatabase = false
                    showDatabaseProgress = false
                    databaseGenerationStatus = "✅ Routes added!\n\(fileURL.path)\n\nReplace WalkingWR/prepopulated_pois.json with this file."
                    showDatabaseSuccessAlert = true
                    
                    // Also copy to Desktop for easy access
                    if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                        let desktopFile = desktopURL.appendingPathComponent("prepopulated_pois.json")
                        try? FileManager.default.copyItem(at: fileURL, to: desktopFile)
                        print("📦 Also copied to Desktop: \(desktopFile.path)")
                    }
                }
            } catch {
                await MainActor.run {
                    isGeneratingDatabase = false
                    showDatabaseProgress = false
                    databaseGenerationStatus = "❌ Error: \(error.localizedDescription)"
                    showDatabaseSuccessAlert = true
                }
            }
        }
    }
    
    private var databaseProgressView: some View {
        VStack(spacing: 24) {
            // Large progress indicator
            ProgressView()
                .scaleEffect(2.0)
                .tint(.tealAccent)
            
            // Main status text
            Text(databaseGenerator.currentStatus)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            // Detailed progress info
            if databaseGenerator.isGenerating {
                VStack(spacing: 12) {
                    // Progress bar for postcode areas
                    if databaseGenerator.totalPostcodes > 0 {
                        VStack(spacing: 4) {
                            HStack {
                                Text("Postcode Areas")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(databaseGenerator.currentPostcodeIndex)/\(databaseGenerator.totalPostcodes)")
                                    .font(.subheadline)
                                    .foregroundColor(.tealAccent)
                            }
                            
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(height: 8)
                                        .cornerRadius(4)
                                    
                                    Rectangle()
                                        .fill(Color.tealAccent)
                                        .frame(
                                            width: geometry.size.width * Double(databaseGenerator.currentPostcodeIndex) / Double(databaseGenerator.totalPostcodes),
                                            height: 8
                                        )
                                        .cornerRadius(4)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                    
                    // Current postcode
                    if !databaseGenerator.currentPostcode.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(.tealAccent)
                                Text("Current Area")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(databaseGenerator.currentPostcode)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .bold()
                        }
                    }
                    
                    // Current duration being generated
                    if databaseGenerator.currentDuration > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "clock.fill")
                                    .foregroundColor(.orange)
                                Text("Current Route")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(databaseGenerator.currentDuration)min route")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                    }
                    
                    // Routes generated count
                    if databaseGenerator.routesGenerated > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.mintGreen)
                                Text("Progress")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(databaseGenerator.routesGenerated) routes generated")
                                .font(.subheadline)
                                .foregroundColor(.mintGreen)
                                .bold()
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
            }
        }
        .padding(24)
        .frame(maxWidth: 400)
    }
    */
    
    private var debugTestsSection: some View {
        Section("Debug Tests") {
            Button(action: runDeduplicationTests) {
                HStack {
                    Label("Run Deduplication Tests", systemImage: "checkmark.seal")
                    Spacer()
                }
                .foregroundColor(.blue)
            }
            
            // Clear pre-populated database to test Firebase Storage download
            Button(action: {
                PrePopulatedPOIService.shared.clearDatabase()
                print("📦 Pre-populated DB: Cleared - will download from Firebase Storage on next app start")
            }) {
                HStack {
                    Label("Clear Pre-populated DB (Test Firebase)", systemImage: "arrow.down.circle")
                    Spacer()
                }
                .foregroundColor(.orange)
            }
            
            // Clear POI cache (may be showing old POI names)
            Button(action: {
                POICacheService.shared.clearCache()
                print("📦 POI Cache: Cleared - will fetch fresh POIs on next search")
            }) {
                HStack {
                    Label("Clear POI Cache", systemImage: "trash.circle")
                    Spacer()
                }
                .foregroundColor(.red)
            }
            
            // NOTE: Database generation is now done on computer using generate_database.py
            // Removed debug button - database is generated on computer and bundled with app
        }
    }
    #endif
    
    // Get app version from bundle (e.g., "1.0.1 (2)")
    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
    
    // Get the actual device color scheme (not the view's current scheme)
    var deviceColorScheme: ColorScheme {
        #if os(iOS)
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #else
        return .light
        #endif
    }
    
    // Effective color scheme - uses actual device scheme when "System" is selected
    var effectiveColorScheme: ColorScheme {
        switch selectedTheme {
        case .system: return deviceColorScheme // Use the actual device color scheme
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    @ViewBuilder
    private var listContent: some View {
        // Only show Permissions section if user has interacted with any permission
        if hasAnyPermissions {
                    Section {
                        if shouldShowNotifications {
                            Button(action: {
                                if !systemNotificationsEnabled {
                                    // System notifications disabled - open settings
                                    requestNotificationPermission()
                                } else if !viewModel.notificationsEnabled {
                                    // App alerts off - re-enable them
                                    viewModel.enableNotifications()
                                } else {
                                    // Everything enabled - open settings to manage
                                    requestNotificationPermission()
                                }
                            }) {
                                HStack {
                                    Label("Notifications", systemImage: "bell.fill")
                                    Spacer()
                                    if !systemNotificationsEnabled {
                                        Text("Denied")
                                            .font(.caption)
                                            .foregroundColor(.softAmber)
                                    } else if !viewModel.notificationsEnabled {
                                        Text("Alerts Off. Tap to re-enable")
                                            .font(.caption)
                                            .foregroundColor(.softAmber)
                                    } else {
                                        Text("Enabled")
                                            .font(.caption)
                                            .foregroundColor(.mintGreen)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                        
                        if shouldShowLocation {
                            Button(action: requestLocationPermission) {
                                HStack {
                                    Label("Location", systemImage: "location.fill")
                                    Spacer()
                                    if locationService.isAuthorized {
                                        Text("Enabled")
                                            .font(.caption)
                                            .foregroundColor(.mintGreen)
                                    } else {
                                        Text("Denied")
                                            .font(.caption)
                                            .foregroundColor(.softAmber)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                        
                        if shouldShowMotion {
                            Button(action: {
                                print("🔴 BUTTON TAPPED - Steps & Motion")
                                requestMotionPermission()
                            }) {
                                HStack {
                                    Label("Steps & Motion", systemImage: "figure.walk")
                                    Spacer()
                                    if healthKitService.isMotionAuthorized {
                                        Text("Enabled")
                                            .font(.caption)
                                            .foregroundColor(.mintGreen)
                                    } else {
                                        Text("Denied")
                                            .font(.caption)
                                            .foregroundColor(.softAmber)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                        
                        if shouldShowHealthKit {
                            Button(action: requestHealthKitPermission) {
                                HStack {
                                    Label("HealthKit Steps", systemImage: "heart.fill")
                                    Spacer()
                                    if healthKitService.isAuthorized {
                                        Text("Enabled")
                                            .font(.caption)
                                            .foregroundColor(.mintGreen)
                                    } else {
                                        Text("Denied")
                                            .font(.caption)
                                            .foregroundColor(.softAmber)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    } header: {
                        Text("Permissions")
                    } footer: {
                        Text("Permissions are requested when needed. Tap to manage in Settings.")
                            .font(.caption)
                    }
                }
                
                Section("Appearance") {
                    Picker(selection: $appTheme) {
                        ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                            Label(theme.rawValue, systemImage: theme.icon)
                                .tag(theme.rawValue)
                        }
                    } label: {
                        Label("Theme", systemImage: "paintbrush.fill")
                    }
                }
                
                Section("Reset Progress") {
                    Button(action: { showResetTodayAlert = true }) {
                        HStack {
                            Label("Reset Today's Progress", systemImage: "arrow.counterclockwise")
                            Spacer()
                        }
                        .foregroundColor(.softAmber)
                    }
                    
                    Button(action: { showResetAllAlert = true }) {
                        HStack {
                            Label("Reset All Progress", systemImage: "trash")
                            Spacer()
                        }
                        .foregroundColor(.coralPink)
                    }
                }
                
                aboutSection
                
                // Debug: Deduplication Tests (only in debug builds)
                #if DEBUG
                debugTestsSection
                #endif
                
                // v1.9.50: Cache Management for Testing
                CacheManagementSection(googleQuota: $googleQuota, onClear: clearAllCaches)
                
                // Cached Locations Section
                CachedLocationsSection()
                
                // Privacy Section
                Section {
                    NavigationLink {
                        PrivacyInfoView()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.mintGreen.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "shield.lefthalf.filled")
                                    .foregroundColor(.mintGreen)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your Privacy & Data")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                Text("How we protect your information")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // Care Opinion Feedback Section
                Section {
                    Link(destination: URL(string: "https://www.careopinion.org.uk/opinions?nacs=TAH")!) {
                        VStack(spacing: 12) {
                            HStack {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.mintGreen, Color.tealAccent],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 44, height: 44)
                                    
                                    Image(systemName: "heart.text.square.fill")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Share Your Story")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    Text("Help us improve on Care Opinion")
                                        .font(.caption)
                                        .foregroundColor(.tealAccent)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.tealAccent)
                            }
                            
                            Text("Your feedback makes a real difference. Care Opinion is a safe, independent platform where you can share what went well, suggest improvements, or thank staff who made a difference.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.leading)
                            
                            HStack(spacing: 16) {
                                FeedbackFeature(icon: "lock.shield.fill", text: "Anonymous")
                                FeedbackFeature(icon: "checkmark.seal.fill", text: "Independent")
                                FeedbackFeature(icon: "sparkles", text: "Makes Change")
                            }
                            .padding(.top, 4)
                        }
                        .padding(.vertical, 8)
                    }
                } header: {
                    HStack {
                        Image(systemName: "quote.bubble.fill")
                            .foregroundColor(.mintGreen)
                        Text("Your Voice Matters")
                            .foregroundColor(.mintGreen)
                    }
                }
    }
    
    var body: some View {
        NavigationStack {
            List {
                listContent
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Reset Today's Progress?", isPresented: $showResetTodayAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset Today", role: .destructive) {
                    viewModel.userProgress.resetToday()
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showIntroduction = true
                    }
                }
            } message: {
                Text("This will reset today's steps, wellbeing scores, and session data. Your total progress and gratitude entries will be kept.")
            }
            .alert("Reset All Progress?", isPresented: $showResetAllAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset Everything", role: .destructive) {
                    viewModel.userProgress.resetAll()
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showIntroduction = true
                    }
                }
            } message: {
                Text("This will permanently delete ALL your progress including total steps, routes completed, points, badges, and gratitude entries. This cannot be undone.")
            }
            .alert("Enable HealthKit Steps", isPresented: $showHealthKitUnavailable) {
                Button("Open Health App") {
                    openHealthApp()
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text("To enable step syncing:\n\n1. Open the Health app\n2. Tap your profile icon (top right)\n3. Look for Apps or Apps & Services\n4. Find WaitWell\n5. Enable Steps")
            }
            .alert("Motion Not Available", isPresented: $showMotionUnavailable) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Motion & Fitness tracking is not available on the iOS Simulator.\n\nPlease test on a real device to enable step counting during walks.")
            }
            .alert("Tests Executed", isPresented: $showTestResultsAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Deduplication tests have been executed.\n\nCheck the Xcode console (Cmd+Shift+Y) to see detailed test results with ✅/❌ indicators.")
            }
            // Removed database generation sheet and alert - no longer needed
            .alert("Manage HealthKit Access", isPresented: $showHealthKitManageAlert) {
                Button("Open Health App") {
                    openHealthApp()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("To manage HealthKit access:\n\n1. Tap 'Open Health App' below\n2. Tap your profile icon (top right)\n3. Look for Apps or Apps & Services\n4. Find WaitWell\n5. Toggle Steps on or off")
            }
            .preferredColorScheme(effectiveColorScheme)
            .id(appTheme) // Force view refresh when theme changes
            .onAppear {
                refreshPermissionStatuses()
                updateGoogleQuota()  // v1.9.50: Update quota on appear
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active {
                    // Refresh permission statuses when returning from Settings
                    refreshPermissionStatuses()
                }
            }
        }
    }
    
    // v1.9.50: Update Google quota
    private func updateGoogleQuota() {
        googleQuota = GoogleMapsService.shared.getGooglePlacesCallCount()
    }
    
    private func refreshPermissionStatuses() {
        // Check notification status
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                systemNotificationsEnabled = settings.authorizationStatus == .authorized
                notificationsNeverAsked = settings.authorizationStatus == .notDetermined
            }
        }
        // HealthKit and Location are already reactive via their services
        healthKitService.checkAuthorization()
    }
    
    // v1.9.50: Clear all caches for testing
    private func clearAllCaches() {
        // Get stats before clearing
        let poiStats = POICacheService.shared.getCacheStats()
        let routeStats = RouteCacheService.shared.getCacheStats()
        let quota = GoogleMapsService.shared.getGooglePlacesCallCount()
        
        // Clear both caches
        POICacheService.shared.clearCache()
        RouteCacheService.shared.clearCache()
        
        // Update quota display
        updateGoogleQuota()
        
        print("═══════════════════════════════════════════════════════════")
        print("🧹 CACHE CLEARED FOR TESTING")
        print("═══════════════════════════════════════════════════════════")
        print("📦 POI Cache: Removed \(poiStats.locations) locations, \(poiStats.totalPOIs) POIs")
        print("📦 Route Cache: Removed \(routeStats.routeSets) route sets, \(routeStats.totalRoutes) routes")
        print("🌐 Google Quota: \(quota.today)/\(quota.cap) calls remaining")
        print("═══════════════════════════════════════════════════════════")
        print("✅ Ready to test free-sources-first strategy!")
        print("   Next route generation will:")
        print("   1. Try free sources first (Apple/OSM/Geograph)")
        print("   2. Fallback to Google if <15 POIs found (optimal threshold)")
        print("═══════════════════════════════════════════════════════════")
    }
    
    private func requestNotificationPermission() {
        if systemNotificationsEnabled {
            // Already authorized, open settings to manage
            openAppSettings()
        } else {
            // Check if we need to go to settings (denied) or can request directly
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    if settings.authorizationStatus == .denied {
                        // Must go to settings to enable
                        openAppSettings()
                    } else {
                        // Request permission
                        Task {
                            let granted = await self.viewModel.notificationService.requestAuthorization()
                            await MainActor.run {
                                self.systemNotificationsEnabled = granted
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func requestLocationPermission() {
        if locationService.isAuthorized {
            // Already authorized, open settings to manage
            openAppSettings()
        } else {
            // Request permission or open settings if denied
            if locationService.authorizationStatus == .denied {
                openAppSettings()
            } else {
                locationService.requestPermission()
            }
        }
    }
    
    private func requestMotionPermission() {
        print("📱 requestMotionPermission called!")
        
        if healthKitService.isMotionAuthorized {
            // Already enabled - open Settings so user can disable
            openAppSettings()
        } else if healthKitService.isMotionDenied {
            // Denied - open Settings to re-enable
            openAppSettings()
        } else {
            // Not determined - trigger the permission request
            healthKitService.requestMotionAuthorization { granted in
                print("📱 Permission callback - granted: \(granted)")
                if granted {
                    self.healthKitService.objectWillChange.send()
                }
            }
        }
    }
    
    private func requestHealthKitPermission() {
        if healthKitService.isAuthorized {
            // Already authorized - show instructions before opening Health app
            showHealthKitManageAlert = true
        } else {
            // Request HealthKit authorization
            Task {
                let granted = await healthKitService.requestAuthorization()
                // No need to force UI refresh - @ObservedObject handles it
                if !granted {
                    await MainActor.run {
                        showHealthKitUnavailable = true
                    }
                }
            }
        }
    }
    
    private func openHealthApp() {
        #if os(iOS)
        // Open Health app - user can manage permissions there
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
        #endif
    }
    
    private func openAppSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

// MARK: - Feedback Feature Badge
struct FeedbackFeature: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.mintGreen)
            
            Text(text)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Introduction Replay View
struct IntroductionReplayView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0
    
    let pages: [(icon: String, title: String, description: String, color: Color)] = [
        ("clock.badge.checkmark.fill", "Real-Time Updates", "See your clinic delay, updated live from the clinic system.", .tealAccent),
        ("figure.walk.motion", "Walk While You Wait", "Choose a walking route matched to your wait time. Stay active, reduce anxiety.", .mintGreen),
        ("bell.badge.fill", "Smart Notifications", "We'll alert you when it's time to head back. No need to worry about missing your slot.", .softAmber),
        ("heart.circle.fill", "Wellbeing Support", "Discover breathing exercises, gratitude prompts, and digital health tips along the way.", .lavenderMist)
    ]
    
    var body: some View {
        ZStack {
            AnimatedGradientBackground()
            
            VStack(spacing: 0) {
                // Close button
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                // Page content
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        VStack(spacing: 30) {
                            Spacer()
                            
                            // Icon
                            ZStack {
                                Circle()
                                    .fill(pages[index].color.opacity(0.2))
                                    .frame(width: 140, height: 140)
                                
                                Image(systemName: pages[index].icon)
                                    .font(.system(size: 60))
                                    .foregroundColor(pages[index].color)
                            }
                            
                            // Text
                            VStack(spacing: 16) {
                                Text(pages[index].title)
                                    .font(.titleLarge)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                
                                Text(pages[index].description)
                                    .font(.bodyLarge)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 40)
                            }
                            
                            Spacer()
                            Spacer()
                        }
                        .tag(index)
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                
                // Page indicator and button
                VStack(spacing: 20) {
                    // Page dots
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Circle()
                                .fill(currentPage == index ? pages[index].color : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                    
                    // Close button
                    Button(action: {
                        if currentPage < pages.count - 1 {
                            withAnimation {
                                currentPage += 1
                            }
                        } else {
                            isPresented = false
                        }
                    }) {
                        Text(currentPage == pages.count - 1 ? "Done" : "Next")
                            .font(.bodyLarge)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(pages[currentPage].color)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 50)
            }
        }
    }
}

// MARK: - Privacy Info View

struct PrivacyInfoView: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.mintGreen.opacity(0.15))
                            .frame(width: 80, height: 80)
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 36))
                            .foregroundColor(.mintGreen)
                    }
                    
                    Text("Your Privacy & Data")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Text("We want you to feel safe using this app")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                
                // What stays on your phone
                PrivacySectionCard(
                    icon: "iphone",
                    iconColor: .tealAccent,
                    title: "What stays on YOUR phone",
                    items: [
                        "Your wellbeing scores",
                        "Gratitude journal entries",
                        "Walking progress and badges",
                        "Any photos you take"
                    ],
                    isPositive: true,
                    colorScheme: colorScheme
                )
                
                // What we do NOT do
                PrivacySectionCard(
                    icon: "xmark.shield",
                    iconColor: .mintGreen,
                    title: "We do NOT",
                    items: [
                        "Send your data to anyone",
                        "Track your location when you're not using the app",
                        "Share information with your clinician through this app",
                        "Tell the clinic that you're using this app",
                        "Access any health data other than steps",
                        "Store your HealthKit data – it stays in Apple Health"
                    ],
                    isPositive: false,
                    colorScheme: colorScheme
                )
                
                // How clinic delays work
                PrivacySectionCard(
                    icon: "arrow.down.circle",
                    iconColor: .softAmber,
                    title: "How clinic delays work",
                    items: [
                        "The app receives delay times from the clinic system",
                        "This is one-way – the clinic sends information TO the app",
                        "The clinic cannot see if you're using this app",
                        "Your clinician does not know your location or activity"
                    ],
                    isPositive: true,
                    colorScheme: colorScheme
                )
                
                // Permissions explained
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .foregroundColor(.lavenderMist)
                        Text("What we need permission for")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    
                    PermissionExplainer(
                        icon: "bell.fill",
                        title: "Notifications",
                        explanation: "To let you know if clinic times change or when it's time to head back."
                    )
                    
                    PermissionExplainer(
                        icon: "location.fill",
                        title: "Location",
                        explanation: "Only used during walks to show you the map and nearby discovery spots. We don't track you otherwise."
                    )
                    
                    PermissionExplainer(
                        icon: "figure.walk",
                        title: "Steps & Motion",
                        explanation: "Counts your steps in real-time during walks. This uses your phone's motion sensors and works even without internet."
                    )
                    
                    PermissionExplainer(
                        icon: "heart.fill",
                        title: "HealthKit Steps",
                        explanation: "Syncs your total daily step count from Apple Health. This lets you see all your steps, not just from walks in this app."
                    )
                }
                .padding(20)
                .background(Color.adaptiveCardBackground(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                
                // You're in control
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(.tealAccent)
                        Text("You're in control")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        ControlPoint(text: "You can delete all your data at any time in Settings")
                        ControlPoint(text: "Manage permissions in Settings → Privacy & Security, or search for WaitWell in Settings")
                        ControlPoint(text: "Closing the app stops all tracking")
                    }
                }
                .padding(20)
                .background(Color.adaptiveCardBackground(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                
                // Questions
                VStack(spacing: 12) {
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.title)
                        .foregroundColor(.tealAccent)
                    
                    Text("Questions?")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("Speak to a member of staff – they're happy to help.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color.tealAccent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
        }
        .background(Color.adaptiveBackground(colorScheme).ignoresSafeArea())
        .navigationTitle("Privacy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct PrivacySectionCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let items: [String]
    let isPositive: Bool
    let colorScheme: ColorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isPositive ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(isPositive ? .mintGreen : .coralPink.opacity(0.7))
                            .font(.subheadline)
                        Text(item)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.adaptiveCardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PermissionExplainer: View {
    let icon: String
    let title: String
    let explanation: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.tealAccent)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(explanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ControlPoint: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark")
                .foregroundColor(.mintGreen)
                .font(.caption)
                .fontWeight(.bold)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Cached Locations Section
struct CachedLocationsSection: View {
    @State private var cachedLocations: [POICacheService.CachedLocationInfo] = []
    @State private var locationNames: [UUID: String] = [:] // Store resolved names by location ID
    
    var body: some View {
        Section {
            // Header with count
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved Locations")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    // v1.6.28: No limit - just show count
                    Text("\(cachedLocations.count) location\(cachedLocations.count == 1 ? "" : "s") cached")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Count badge
                Text("\(cachedLocations.count)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.tealAccent)
                    .clipShape(Capsule())
            }
            .padding(.vertical, 4)
            
            // List of cached locations
            if cachedLocations.isEmpty {
                HStack {
                    Image(systemName: "mappin.slash")
                        .foregroundColor(.secondary)
                    Text("No locations saved yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(Array(cachedLocations.enumerated()), id: \.element.id) { index, location in
                    NavigationLink {
                        CachedPOIsDetailView(
                            locationName: locationNames[location.id] ?? "Cached Location",
                            coordinate: location.coordinate,
                            fetchedAt: location.fetchedAt
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(.tealAccent)
                                .font(.title3)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(locationNames[location.id] ?? "Loading...")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text("\(location.poiCount) places • Saved \(location.fetchedAt, style: .relative) ago")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear {
                        // Reverse geocode this location if not already done
                        if locationNames[location.id] == nil {
                            POICacheService.shared.getLocationName(for: location.coordinate) { name in
                                DispatchQueue.main.async {
                                    locationNames[location.id] = name
                                }
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            // Delete this cached location
                            POICacheService.shared.deleteLocation(at: index)
                            refreshCachedLocations()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Image(systemName: "map.fill")
                Text("Walking Routes Cache")
            }
        } footer: {
            // v1.6.28: No limit on cached locations
            Text("Routes are cached to speed up generation. Swipe to delete locations you no longer need.")
        }
        .onAppear {
            refreshCachedLocations()
        }
    }
    
    private func refreshCachedLocations() {
        cachedLocations = POICacheService.shared.getCachedLocationsInfo()
        locationNames = [:] // Reset names to trigger re-geocoding
    }
}

// MARK: - Cache Management Section (v1.9.50)
struct CacheManagementSection: View {
    @Binding var googleQuota: (today: Int, cap: Int)
    let onClear: () -> Void
    
    var body: some View {
        Group {
            Section {
                // Google Quota Status
                HStack {
                    Label("Google Places Quota", systemImage: "chart.bar.fill")
                    Spacer()
                    Text("\(googleQuota.today)/\(googleQuota.cap)")
                        .foregroundColor(googleQuota.today >= googleQuota.cap ? .red : .primary)
                        .fontWeight(.semibold)
                }
                
                // Clear All Caches Button
                Button(action: onClear) {
                    HStack {
                        Label("Clear All Caches", systemImage: "trash.fill")
                        Spacer()
                    }
                    .foregroundColor(.coralPink)
                }
            } header: {
                Text("Cache Management (Testing)")
            } footer: {
                Text("Clearing cache is safe and doesn't use API calls. Use this to test the free-sources-first strategy.")
            }
        }
    }
}

// MARK: - Cached POIs Detail View
struct CachedPOIsDetailView: View {
    let locationName: String
    let coordinate: CLLocationCoordinate2D
    let fetchedAt: Date
    
    @State private var pois: [POICacheService.CachedPOI] = []
    @State private var searchText: String = ""
    
    var filteredPOIs: [POICacheService.CachedPOI] {
        if searchText.isEmpty {
            return pois
        }
        return pois.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    // Group POIs by category
    var groupedPOIs: [(category: String, pois: [POICacheService.CachedPOI])] {
        var groups: [String: [POICacheService.CachedPOI]] = [:]
        
        for poi in filteredPOIs {
            let category = categorize(poi: poi)
            groups[category, default: []].append(poi)
        }
        
        // Sort categories and POIs
        return groups.map { (category: $0.key, pois: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category < $1.category }
    }
    
    var body: some View {
        List {
            // Header info
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .foregroundColor(.tealAccent)
                        
                        VStack(alignment: .leading) {
                            Text(locationName)
                                .font(.headline)
                            Text("\(pois.count) places discovered")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Saved \(fetchedAt, style: .relative) ago")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            // POI List by category
            ForEach(groupedPOIs, id: \.category) { group in
                Section(header: Text(group.category)) {
                    ForEach(group.pois, id: \.placeId) { poi in
                        HStack(spacing: 12) {
                            Image(systemName: iconFor(poi: poi))
                                .font(.title3)
                                .foregroundColor(.tealAccent)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(poi.toPlaceResult().displayName)
                                    .font(.subheadline)
                                
                                if let vicinity = poi.vicinity {
                                    Text(vicinity)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search places")
        .navigationTitle("Cached Places")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            pois = POICacheService.shared.getPOIsForLocation(at: coordinate)
        }
    }
    
    private func categorize(poi: POICacheService.CachedPOI) -> String {
        let types = poi.types
        
        if types.contains("restaurant") || types.contains("food") || types.contains("cafe") || types.contains("bakery") {
            return "🍽️ Food & Drink"
        } else if types.contains("lodging") || types.contains("hotel") {
            return "🏨 Hotels"
        } else if types.contains("store") || types.contains("shopping_mall") || types.contains("clothing_store") {
            return "🛍️ Shopping"
        } else if types.contains("park") || types.contains("natural_feature") {
            return "🌳 Parks & Nature"
        } else if types.contains("museum") || types.contains("art_gallery") || types.contains("tourist_attraction") {
            return "🎨 Arts & Culture"
        } else if types.contains("health") || types.contains("hospital") || types.contains("pharmacy") {
            return "🏥 Health"
        } else if types.contains("gym") || types.contains("spa") {
            return "💪 Fitness & Wellness"
        } else if types.contains("bank") || types.contains("atm") {
            return "🏦 Finance"
        } else {
            return "📍 Other Places"
        }
    }
    
    private func iconFor(poi: POICacheService.CachedPOI) -> String {
        let types = poi.types
        
        if types.contains("restaurant") { return "fork.knife" }
        if types.contains("cafe") { return "cup.and.saucer.fill" }
        if types.contains("bar") { return "wineglass.fill" }
        if types.contains("bakery") { return "birthday.cake.fill" }
        if types.contains("hotel") || types.contains("lodging") { return "bed.double.fill" }
        if types.contains("store") || types.contains("shopping") { return "bag.fill" }
        if types.contains("park") { return "leaf.fill" }
        if types.contains("museum") { return "building.columns.fill" }
        if types.contains("pharmacy") { return "cross.case.fill" }
        if types.contains("hospital") { return "cross.circle.fill" }
        if types.contains("gym") { return "dumbbell.fill" }
        if types.contains("spa") { return "sparkles" }
        if types.contains("bank") { return "banknote.fill" }
        if types.contains("church") { return "cross.fill" }
        
        return "mappin"
    }
}

#Preview {
    let viewModel = WaitingRoomViewModel()
    ProfileView(viewModel: viewModel, healthKitService: viewModel.healthKitService)
}


