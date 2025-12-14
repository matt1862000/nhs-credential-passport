//
//  ProfileView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ProfileView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var showSettings = false
    @State private var showHelpSheet = false
    @State private var showIntroduction = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Stats summary card
                        StatsSummaryCard(progress: viewModel.userProgress)
                        
                        // Activity History (scrollable)
                        ActivityHistorySection(progress: viewModel.userProgress)
                        
                        // Overall anxiety score (from any activity - walk or breathing)
                        if let before = viewModel.userProgress.anxietyLevelBefore {
                            AnxietyScoreCard(
                                before: before,
                                after: viewModel.userProgress.anxietyLevelAfter
                            )
                        }
                        
                        // Walking-specific wellbeing impact (always shows if there's a before score, but "after" only if walk done)
                        if let before = viewModel.userProgress.anxietyLevelBefore {
                            WalkingWellbeingCard(
                                before: before,
                                after: viewModel.userProgress.anxietyLevelAfterWalk
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
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.tealAccent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showHelpSheet = true }) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(.coralPink)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel, showIntroduction: $showIntroduction)
            }
            .sheet(isPresented: $showHelpSheet) {
                HelpView()
            }
            .fullScreenCover(isPresented: $showIntroduction) {
                IntroductionReplayView(isPresented: $showIntroduction)
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
}

// MARK: - Activity History Section
struct ActivityHistorySection: View {
    @ObservedObject var progress: UserProgress
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
                        DailyActivityCard(activity: activity, isExpanded: true) { detailType in
                            detailSelection = ActivityDetailSelection(activity: activity, detailType: detailType)
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
                DailyActivityCard(activity: progress.todayActivity, isExpanded: true) { detailType in
                    detailSelection = ActivityDetailSelection(activity: progress.todayActivity, detailType: detailType)
                }
            }
            
            // Swipe hint (only show if there's history)
            if allActivities.count > 1 {
                Text("Swipe to see previous days")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        // Sheet uses combined selection - activity and detail type bundled together
        .sheet(item: $detailSelection) { selection in
            ActivityDetailSheet(activity: selection.activity, focusedDetail: selection.detailType)
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
    var onTapDetail: ((ActivityDetailType) -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    
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
                    value: "\(activity.steps)",
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
    @Environment(\.dismiss) var dismiss
    
    var distanceKm: Double {
        Double(activity.steps) * 0.0008
    }
    
    var caloriesBurned: Int {
        activity.steps / 20
    }
    
    var activeMinutes: Int {
        max(1, activity.steps / 100)
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
                
                Text("\(activity.steps)")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text("steps")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
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
        if activity.steps >= 5000 { return "🎉 Amazing effort! You've hit a great milestone." }
        else if activity.steps >= 2000 { return "👍 Great progress! Every step counts." }
        else if activity.steps >= 500 { return "🚶 Good start! Keep moving when you can." }
        else if activity.steps > 0 { return "🌱 Every journey begins with a single step." }
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
                
                Text("Today's Wellbeing")
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
    @Binding var showIntroduction: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue
    @State private var showResetTodayAlert = false
    @State private var showResetAllAlert = false
    
    var selectedTheme: AppTheme {
        AppTheme(rawValue: appTheme) ?? .system
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: openAppSettings) {
                        HStack {
                            Label("Notifications", systemImage: "bell.fill")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .foregroundColor(.primary)
                    
                    Button(action: openHealthSettings) {
                        HStack {
                            Label("Health & Activity", systemImage: "heart.fill")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Manage permissions in iOS Settings")
                        .font(.caption)
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
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
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
                
                // Care Opinion Feedback Section
                Section {
                    Link(destination: URL(string: "https://www.careopinion.org.uk")!) {
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
            .preferredColorScheme(selectedTheme.colorScheme)
        }
    }
    
    private func openAppSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
    
    private func openHealthSettings() {
        #if os(iOS)
        if let url = URL(string: "x-apple-health://") {
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

#Preview {
    ProfileView(viewModel: WaitingRoomViewModel())
}


