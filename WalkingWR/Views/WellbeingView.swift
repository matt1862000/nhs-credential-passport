//
//  WellbeingView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI

// MARK: - Wellbeing Category (extracted for reuse)
enum WellbeingCategory: String, CaseIterable {
    case breathing = "Breathing"
    case gratitude = "Gratitude"
    case nature = "Nature"
    case digital = "Digital Skills"
    
    var icon: String {
        switch self {
        case .breathing: return "wind"
        case .gratitude: return "heart.fill"
        case .nature: return "leaf.fill"
        case .digital: return "iphone"
        }
    }
    
    var color: Color {
        switch self {
        case .breathing: return .lavenderMist
        case .gratitude: return .coralPink
        case .nature: return .mintGreen
        case .digital: return .tealAccent
        }
    }
}

struct WellbeingView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var selectedCategory: WellbeingCategory
    @Binding var selectedExercise: WellbeingContent?
    @State private var showHelpSheet = false
    @State private var showPreWellbeingCheck = false
    @State private var showPostWellbeingCheck = false
    @State private var pendingExercise: WellbeingContent? // Exercise to start after pre-check
    @State private var exerciseCompleted = false // Track if exercise was completed
    @State private var localSelectedExercise: WellbeingContent? // Internal state for exercise sheet
    @State private var hasHandledDeepLink = false // Track if we've already handled the initial deep link
    
    init(viewModel: WaitingRoomViewModel, selectedCategory: Binding<WellbeingCategory> = .constant(.breathing), selectedExercise: Binding<WellbeingContent?> = .constant(nil)) {
        self.viewModel = viewModel
        self._selectedCategory = selectedCategory
        self._selectedExercise = selectedExercise
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Category selector
                        CategorySelector(selectedCategory: $selectedCategory)
                        
                        // Content based on category
                        switch selectedCategory {
                        case .breathing:
                            BreathingSection { exercise in
                                startExerciseWithCheck(exercise)
                            }
                        case .gratitude:
                            GratitudeSection(savedEntries: $viewModel.userProgress.gratitudeEntries)
                        case .nature:
                            NatureSection(viewModel: viewModel)
                        case .digital:
                            DigitalSkillsSection(userProgress: viewModel.userProgress, viewModel: viewModel)
                        }
                        
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Wellbeing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
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
            .sheet(item: $localSelectedExercise) { exercise in
                BreathingExerciseSheet(
                    exercise: exercise,
                    onDismiss: {
                        // Check if we need to show post-wellbeing check when sheet closes
                        let shouldShowPostCheck = exerciseCompleted
                        exerciseCompleted = false
                        localSelectedExercise = nil
                        selectedExercise = nil // Also clear the binding
                        
                        if shouldShowPostCheck {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                showPostWellbeingCheck = true
                            }
                        }
                    },
                    onComplete: {
                        viewModel.userProgress.breathingExercisesCompleted += 1
                        viewModel.userProgress.todayBreathingExercises += 1
                        viewModel.userProgress.addPoints(15)
                        exerciseCompleted = true
                    }
                )
            }
            .sheet(isPresented: $showPreWellbeingCheck) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: $showPreWellbeingCheck, isPostWalk: false)
                    .onDisappear {
                        // Start the pending exercise after pre-check
                        if let exercise = pendingExercise {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                localSelectedExercise = exercise
                                pendingExercise = nil
                            }
                        }
                    }
            }
            .sheet(isPresented: $showPostWellbeingCheck) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: $showPostWellbeingCheck, isPostWalk: true)
            }
            .onAppear {
                // Handle deep link exercise (e.g., from empty clinic screen)
                // Only handle once per view appearance
                if let exercise = selectedExercise, !hasHandledDeepLink {
                    hasHandledDeepLink = true
                    selectedExercise = nil // Clear the binding immediately
                    
                    // Route through the check flow
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        startExerciseWithCheck(exercise)
                    }
                }
            }
            .onChange(of: selectedExercise) { oldValue, newValue in
                // Handle deep link exercise set after view appeared
                // Only handle if we haven't already handled a deep link
                if let exercise = newValue, !hasHandledDeepLink {
                    hasHandledDeepLink = true
                    selectedExercise = nil // Clear the binding immediately
                    
                    // Route through the check flow
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        startExerciseWithCheck(exercise)
                    }
                }
            }
            .onDisappear {
                // Reset deep link flag when view disappears
                hasHandledDeepLink = false
            }
            .onChange(of: selectedCategory) { _, _ in
                // Dismiss keyboard when switching categories
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }
    
    // Check if pre-wellbeing check is needed before starting an exercise
    func startExerciseWithCheck(_ exercise: WellbeingContent) {
        if viewModel.userProgress.anxietyLevelBefore == nil {
            // First activity of the day - show pre-check first
            pendingExercise = exercise
            showPreWellbeingCheck = true
        } else {
            // Pre-check already done - start exercise directly
            localSelectedExercise = exercise
        }
    }
    
}

// MARK: - Wellbeing Header Card
struct WellbeingHeaderCard: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Take a moment")
                        .font(.titleMedium)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("Your wellbeing matters. Try a quick exercise while you wait.")
                        .font(.bodyMedium)
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                ZStack {
                    Circle()
                        .fill(Color.lavenderMist.opacity(0.2))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.lavenderMist, .coralPink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
        }
        .padding(20)
        .cardStyle()
    }
}

// MARK: - Category Selector
struct CategorySelector: View {
    @Binding var selectedCategory: WellbeingCategory
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(WellbeingCategory.allCases, id: \.self) { category in
                        CategoryTab(
                            category: category,
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                        .id(category)  // ID for ScrollViewReader
                    }
                }
                .padding(.horizontal, 4)  // Small padding so edge items can center
            }
            .onChange(of: selectedCategory) { _, newCategory in
                // Auto-scroll to center the selected category after state updates
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newCategory, anchor: .center)
                }
            }
        }
    }
}

struct CategoryTab: View {
    let category: WellbeingCategory
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.body)
                
                Text(category.rawValue)
                    .font(.bodyMedium)
                    .fontWeight(.medium)
            }
            .foregroundColor(isSelected ? .white : category.color)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? category.color : category.color.opacity(0.1))
            )
        }
    }
}

// MARK: - Breathing Section
struct BreathingSection: View {
    var onSelectExercise: (WellbeingContent) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Smoking Cessation Support Card
            SmokingCessationCard()
            
            // Wellbeing prompt card
            WellbeingHeaderCard()
            
            // Breathing Exercises
            VStack(alignment: .leading, spacing: 16) {
                Text("Breathing Exercises")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                ForEach(WellbeingContent.breathingExercises) { exercise in
                    BreathingExerciseCard(exercise: exercise) {
                        onSelectExercise(exercise)
                    }
                }
            }
        }
    }
}

// MARK: - Smoking Cessation Card
struct SmokingCessationCard: View {
    @Environment(\.openURL) var openURL
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.mintGreen, Color.tealAccent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "lungs.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quit Smoking Support")
                        .font(.titleMedium)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    
                    Text("Yorkshire Smokefree Sheffield")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.title2)
                    .foregroundColor(.tealAccent)
            }
            
            // Description
            Text("Ready to quit smoking? Get free NHS support from trained advisors. Choose from in-person clinics, phone support, video calls, or online plans.")
                .font(.bodyMedium)
                .foregroundColor(.primary)
                .lineSpacing(4)
            
            // Features
            HStack(spacing: 16) {
                SmokefreeFeature(icon: "person.2.fill", text: "1-to-1 Support")
                SmokefreeFeature(icon: "phone.fill", text: "Free Helpline")
                SmokefreeFeature(icon: "pills.fill", text: "Stop Aids")
            }
            
            // CTA Button
            Button(action: {
                openURL(URL(string: "https://sheffield.yorkshiresmokefree.nhs.uk")!)
            }) {
                HStack {
                    Image(systemName: "link")
                    Text("Visit Smokefree Sheffield")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.bodyMedium)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
                .background(
                    LinearGradient(
                        colors: [Color.mintGreen, Color.forestGreen],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            
            // Contact info
            HStack(spacing: 16) {
                Label("0114 5536296", systemImage: "phone.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Label("Text 'YSF' to 80800", systemImage: "message.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(colorScheme == .dark ? Color.darkCardBackground : Color.white)
                .shadow(color: Color.mintGreen.opacity(colorScheme == .dark ? 0.3 : 0.15), radius: 10, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.mintGreen.opacity(0.3), lineWidth: 1)
        )
    }
}

struct SmokefreeFeature: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.mintGreen)
            Text(text)
                .font(.caption)
                .foregroundColor(.primary)
        }
    }
}

struct BreathingExerciseCard: View {
    let exercise: WellbeingContent
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.lavenderMist.opacity(0.15))
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: exercise.icon)
                        .font(.title2)
                        .foregroundColor(.lavenderMist)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(exercise.title)
                        .font(.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text(exercise.description)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    
                    if let duration = exercise.duration {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.micro)
                            Text("\(duration / 60) min")
                                .font(.micro)
                        }
                        .foregroundColor(.lavenderMist)
                    }
                }
                
                Spacer()
                
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundColor(.lavenderMist)
            }
            .padding(16)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Breathing Exercise Sheet
struct BreathingExerciseSheet: View {
    let exercise: WellbeingContent
    let onDismiss: () -> Void
    var onComplete: (() -> Void)? = nil
    @Environment(\.dismiss) var dismiss
    
    @State private var currentStep = 0
    @State private var breathPhase: BreathPhase = .ready
    @State private var circleScale: CGFloat = 0.6
    @State private var timer: Timer?
    @State private var isActive = false
    @State private var cycleCount = 0
    @State private var hasRecordedCompletion = false
    @State private var hasStartedExercise = false // Track if user started at all
    
    enum BreathPhase: String {
        case ready = "Tap to begin"
        case breatheIn = "Breathe in..."
        case hold = "Hold..."
        case breatheOut = "Breathe out..."
        case holdEmpty = "Hold empty..."
        case complete = "Well done!"
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Gradient background
                LinearGradient(
                    colors: [Color.lavenderMist.opacity(0.3), Color.calmGradientEnd],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 40) {
                    Spacer()
                    
                    // Breathing circle
                    ZStack {
                        // Outer ring
                        Circle()
                            .stroke(Color.lavenderMist.opacity(0.2), lineWidth: 4)
                            .frame(width: 250, height: 250)
                        
                        // Animated circle
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.lavenderMist.opacity(0.6), Color.lavenderMist.opacity(0.2)],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 120
                                )
                            )
                            .frame(width: 200, height: 200)
                            .scaleEffect(circleScale)
                        
                        // Phase text
                        VStack(spacing: 8) {
                            Text(breathPhase.rawValue)
                                .font(.titleMedium)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            if isActive && breathPhase != .complete {
                                Text("Cycle \(cycleCount + 1) of 4")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    .onTapGesture {
                        if !isActive {
                            startExercise()
                        }
                    }
                    
                    // Instructions
                    if let steps = exercise.steps, !isActive {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Instructions")
                                .font(.bodyMedium)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                        .frame(width: 22, height: 22)
                                        .background(Color.lavenderMist)
                                        .clipShape(Circle())
                                    
                                    Text(step)
                                        .font(.bodyMedium)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                        .padding(20)
                        .cardStyle()
                        .padding(.horizontal, 20)
                    }
                    
                    Spacer()
                    
                    // Start/Stop button
                    Button(action: {
                        if isActive {
                            stopExercise()
                        } else {
                            startExercise()
                        }
                    }) {
                        HStack {
                            Image(systemName: isActive ? "stop.fill" : "play.fill")
                            Text(isActive ? "Stop" : "Begin Exercise")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(color: isActive ? .coralPink : .lavenderMist))
                    .padding(.horizontal, 40)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle(exercise.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        stopExercise()
                        // If user started the exercise but hasn't recorded completion, count it
                        if hasStartedExercise && !hasRecordedCompletion {
                            hasRecordedCompletion = true
                            onComplete?()
                        }
                        // Call onDismiss to trigger post-check logic, then dismiss
                        onDismiss()
                    }
                }
            }
        }
    }
    
    func startExercise() {
        isActive = true
        hasStartedExercise = true
        cycleCount = 0
        runBreathingCycle()
    }
    
    func runBreathingCycle() {
        guard isActive else { return }
        
        // Breathe in
        breathPhase = .breatheIn
        withAnimation(.easeInOut(duration: 4)) {
            circleScale = 1.0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard self.isActive else { return }
            
            // Hold
            self.breathPhase = .hold
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard self.isActive else { return }
                
                // Breathe out
                self.breathPhase = .breatheOut
                withAnimation(.easeInOut(duration: 4)) {
                    self.circleScale = 0.6
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    guard self.isActive else { return }
                    
                    // Hold empty
                    self.breathPhase = .holdEmpty
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        guard self.isActive else { return }
                        
                        self.cycleCount += 1
                        
                        if self.cycleCount >= 4 {
                            self.breathPhase = .complete
                            self.isActive = false
                            // Record completion only once
                            if !self.hasRecordedCompletion {
                                self.hasRecordedCompletion = true
                                self.onComplete?()
                            }
                        } else {
                            self.runBreathingCycle()
                        }
                    }
                }
            }
        }
    }
    
    func stopExercise() {
        isActive = false
        breathPhase = .ready
        withAnimation {
            circleScale = 0.6
        }
    }
}

// MARK: - Gratitude Section
struct GratitudeSection: View {
    @State private var gratitudeText = ""
    @Binding var savedEntries: [String]
    @State private var currentPrompt: String = WellbeingContent.gratitudePrompts.randomElement()?.description ?? "What made you smile today?"
    @FocusState private var isTextEditorFocused: Bool  // Focus management for reliable keyboard
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gratitude Journal")
                .font(.titleMedium)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            // Prompt card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.coralPink)
                    
                    Text("Today's prompt")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .textCase(.uppercase)
                }
                
                Text(currentPrompt)
                    .font(.bodyLarge)
                    .foregroundColor(.primary)
                
                TextEditor(text: $gratitudeText)
                    .focused($isTextEditorFocused)
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .foregroundColor(.primary)
                    .padding(12)
                    .background(Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.coralPink.opacity(0.5), lineWidth: 1.5)
                    )
                    .cornerRadius(12)
                    .tint(.coralPink)
                
                Button("Save Entry") {
                    if !gratitudeText.isEmpty {
                        // Dismiss keyboard first
                        isTextEditorFocused = false
                        
                        savedEntries.append(gratitudeText)
                        gratitudeText = ""
                        // Only change prompt after saving
                        currentPrompt = WellbeingContent.gratitudePrompts.randomElement()?.description ?? "What made you smile today?"
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: .coralPink))
                .disabled(gratitudeText.isEmpty)
            }
            .padding(20)
            .cardStyle()
            
            // Previous entries
            if !savedEntries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Your entries")
                            .font(.caption)
                            .foregroundColor(.primary)
                            .textCase(.uppercase)
                        
                        Spacer()
                        
                        Text("\(savedEntries.count) entries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    ForEach(savedEntries.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "heart.fill")
                                .font(.caption)
                                .foregroundColor(.coralPink)
                            
                            Text(savedEntries[index])
                                .font(.bodyMedium)
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            Button(action: {
                                withAnimation {
                                    _ = savedEntries.remove(at: index)
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.body)
                                    .foregroundColor(Color.coralPink.opacity(0.5))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.coralPink.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }
}

// MARK: - Nature Section
struct NatureSection: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @StateObject private var photoStorage = PhotoStorageService.shared
    @State private var selectedPhoto: CapturedPhoto?
    @State private var showCamera = false
    @State private var showBirdChecklist = false
    @State private var currentNatureFact: String = NatureSection.natureFacts.randomElement() ?? "Trees release chemicals called phytoncides that boost our immune system."
    
    // Nature facts related to mental health and wellbeing
    static let natureFacts = [
        "Spending just 20 minutes in nature can significantly lower cortisol (stress hormone) levels.",
        "Walking in green spaces has been shown to reduce symptoms of depression by up to 71%.",
        "Bird songs activate the brain's attention restoration system, reducing mental fatigue.",
        "The colour green is processed by the brain without strain, creating a calming effect.",
        "Nature exposure increases activity in the prefrontal cortex, improving focus and decision-making.",
        "Being near water (rivers, ponds, fountains) has been proven to reduce anxiety and boost mood.",
        "Sunlight triggers serotonin production, the 'feel-good' hormone that regulates mood.",
        "Walking among trees lowers blood pressure within 15 minutes of starting.",
        "Natural environments help reduce rumination - the repetitive negative thoughts linked to depression.",
        "Spending time outdoors improves sleep quality by helping reset your circadian rhythm.",
        "Looking at fractal patterns in nature (trees, clouds, waves) naturally calms the nervous system.",
        "Green exercise (physical activity in nature) is twice as effective at improving mood as indoor exercise.",
        "Nature sounds can reduce the body's fight-or-flight response by up to 60%.",
        "Regular nature exposure has been linked to increased creativity and problem-solving ability.",
        "Walking in nature for 90 minutes reduces activity in the brain region linked to mental illness.",
        "Touching natural materials like wood and leaves activates the parasympathetic nervous system."
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nature Connection")
                .font(.titleMedium)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            // 1. Take a Nature Photo - opens camera directly
            Button {
                showCamera = true
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.mintGreen.opacity(0.15))
                            .frame(width: 50, height: 50)
                        Image(systemName: "camera.fill")
                            .font(.title3)
                            .foregroundColor(.mintGreen)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Take a Nature Photo")
                            .font(.bodyMedium)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text("Capture something beautiful around you")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .cardStyle()
            }
            
            // 2. Bird Spotting Checklist
            Button {
                showBirdChecklist = true
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 50, height: 50)
                        Image(systemName: "bird.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bird Spotting")
                            .font(.bodyMedium)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text("Track the birds you see on your walk")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .cardStyle()
            }
            
            // 3. Discover Nature Fact - tappable to get a new fact
            Button {
                withAnimation {
                    currentNatureFact = NatureSection.natureFacts.randomElement() ?? currentNatureFact
                }
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.tealAccent.opacity(0.15))
                            .frame(width: 50, height: 50)
                        Image(systemName: "leaf.circle.fill")
                            .font(.title3)
                            .foregroundColor(.tealAccent)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Nature Fact")
                                .font(.bodyMedium)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            Text("Tap for another")
                                .font(.caption2)
                                .foregroundColor(.tealAccent)
                        }
                        Text(currentNatureFact)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(16)
                .cardStyle()
            }
            
            // Photo Gallery (if photos exist)
            if !photoStorage.capturedPhotos.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "photo.stack.fill")
                            .foregroundColor(.mintGreen)
                        Text("Your Nature Photos")
                            .font(.bodyLarge)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Text("\(photoStorage.capturedPhotos.count)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.mintGreen)
                            .clipShape(Capsule())
                    }
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(photoStorage.capturedPhotos) { photo in
                                PhotoThumbnail(photo: photo, photoStorage: photoStorage)
                                    .onTapGesture {
                                        selectedPhoto = photo
                                    }
                            }
                        }
                    }
                }
                .padding(16)
                .cardStyle()
            }
            
            // Sheffield Health Walks
            SheffieldHealthWalksCard()
        }
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(photo: photo, photoStorage: photoStorage)
        }
        .sheet(isPresented: $showCamera) {
            NatureCameraView(photoStorage: photoStorage)
        }
        .sheet(isPresented: $showBirdChecklist) {
            BirdSpottingView()
        }
    }
}

// MARK: - Nature Camera View
struct NatureCameraView: View {
    @ObservedObject var photoStorage: PhotoStorageService
    @Environment(\.dismiss) var dismiss
    @State private var showImagePicker = false
    @State private var capturedImage: UIImage?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let image = capturedImage {
                    // Show captured image
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 400)
                        .cornerRadius(16)
                    
                    HStack(spacing: 20) {
                        Button("Retake") {
                            capturedImage = nil
                            showImagePicker = true
                        }
                        .foregroundColor(.secondary)
                        
                        Button {
                            // Save the photo
                            photoStorage.savePhoto(image)
                            dismiss()
                        } label: {
                            Text("Save Photo")
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(Color.mintGreen)
                                .cornerRadius(12)
                        }
                    }
                } else {
                    // Prompt to take photo
                    VStack(spacing: 16) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.mintGreen)
                        
                        Text("Capture Nature")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Take a photo of something beautiful in nature")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("🌳 Trees • 🌸 Flowers • 🐦 Birds • ☁️ Sky")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    .padding()
                    
                    Button {
                        showImagePicker = true
                    } label: {
                        Text("Open Camera")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.mintGreen)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 40)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Nature Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $capturedImage)
        }
    }
}

// MARK: - Bird Data
struct BirdInfo: Identifiable {
    let id = UUID()
    let name: String
    let scientificName: String
    let description: String
    let habitat: String
    let imageURL: String // Wikipedia image URL (fallback)
    let localAsset: String? // Bundled asset name (preferred)
    let seasonalNote: String // When they're commonly seen
    let isYearRound: Bool
    let summerOnly: Bool
    let winterOnly: Bool
}

// MARK: - Bird Spotting View
struct BirdSpottingView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("spottedBirds") private var spottedBirdsData: Data = Data()
    @State private var expandedBird: String? = nil
    
    // Get current month to show appropriate birds
    var currentMonth: Int {
        Calendar.current.component(.month, from: Date())
    }
    
    // Common UK birds with seasonal availability
    let allBirds: [BirdInfo] = [
        // Year-round residents (always show)
        BirdInfo(name: "Robin", scientificName: "Erithacus rubecula", 
                 description: "Britain's favourite bird with its distinctive red breast. Very territorial and often seen in gardens.",
                 habitat: "Gardens, parks, woodlands",
                 imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/f/f3/Erithacus_rubecula_with_cocked_head.jpg/220px-Erithacus_rubecula_with_cocked_head.jpg",
                 localAsset: "Robin",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "Blackbird", scientificName: "Turdus merula",
                 description: "Males are jet black with orange-yellow beak. Females are brown. Often seen hopping on lawns.",
                 habitat: "Gardens, parks, hedgerows",
                 imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Common_Blackbird.jpg/220px-Common_Blackbird.jpg",
                 localAsset: "Blackbird",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "Blue Tit", scientificName: "Cyanistes caeruleus",
                 description: "Small, colourful bird with blue cap, yellow belly. Very acrobatic on feeders.",
                 habitat: "Gardens, woodlands, hedgerows",
                 imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/8/86/Eurasian_blue_tit_Lancashire.jpg/220px-Eurasian_blue_tit_Lancashire.jpg",
                 localAsset: "BlueTit",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "Great Tit", scientificName: "Parus major",
                 description: "Largest UK tit with yellow belly and distinctive black stripe. Bold and curious.",
                 habitat: "Gardens, woodlands, parks",
                 imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/4/49/Kohlmeise.jpg/220px-Kohlmeise.jpg",
                 localAsset: "GreatTit",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "House Sparrow", scientificName: "Passer domesticus",
                 description: "Chunky brown and grey bird. Males have grey cap and black bib. Very social.",
                 habitat: "Towns, villages, near buildings",
                 imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d9/House_Sparrow_mar08.jpg/220px-House_Sparrow_mar08.jpg",
                 localAsset: "HouseSparrow",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "Magpie", scientificName: "Pica pica",
                 description: "Striking black and white bird with long tail. Iridescent blue-green on wings.",
                 habitat: "Gardens, parks, farmland",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/magpie",
                 localAsset: "Magpie",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "Wood Pigeon", scientificName: "Columba palumbus",
                 description: "Large grey pigeon with white neck patch and pink breast. Distinctive cooing call.",
                 habitat: "Gardens, parks, woodlands",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/woodpigeon",
                 localAsset: "WoodPigeon",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "Carrion Crow", scientificName: "Corvus corone",
                 description: "All-black, intelligent bird. Often seen in pairs or small groups.",
                 habitat: "Almost anywhere - very adaptable",
                 imageURL: "https://upload.wikimedia.org/wikipedia/commons/thumb/8/84/Corvus_corone_-_Hailsham%2C_Sussex%2C_England-8.jpg/220px-Corvus_corone_-_Hailsham%2C_Sussex%2C_England-8.jpg",
                 localAsset: "CarrionCrow",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "Wren", scientificName: "Troglodytes troglodytes",
                 description: "Tiny brown bird with upturned tail. Incredibly loud song for its size. UK's most common breeding bird!",
                 habitat: "Gardens, hedgerows, undergrowth",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/wren",
                 localAsset: "Wren",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        BirdInfo(name: "Goldfinch", scientificName: "Carduelis carduelis",
                 description: "Colourful finch with red face and gold wing bars. Loves thistle seeds.",
                 habitat: "Gardens, orchards, woodland edges",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/goldfinch",
                 localAsset: "Goldfinch",
                 seasonalNote: "Year-round resident", isYearRound: true, summerOnly: false, winterOnly: false),
        // Summer visitors (April-September)
        BirdInfo(name: "Swallow", scientificName: "Hirundo rustica",
                 description: "Elegant bird with long forked tail. Catches insects on the wing.",
                 habitat: "Open countryside, near water, farms",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/swallow",
                 localAsset: "Swallow",
                 seasonalNote: "Summer visitor (Apr-Oct)", isYearRound: false, summerOnly: true, winterOnly: false),
        BirdInfo(name: "House Martin", scientificName: "Delichon urbicum",
                 description: "Blue-black above, white below with distinctive white rump. Builds mud nests under eaves.",
                 habitat: "Towns, villages, near buildings",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/house-martin",
                 localAsset: "HouseMartin",
                 seasonalNote: "Summer visitor (Apr-Oct)", isYearRound: false, summerOnly: true, winterOnly: false),
        BirdInfo(name: "Swift", scientificName: "Apus apus",
                 description: "Dark, scythe-winged bird that screams through the sky. Rarely lands except to nest.",
                 habitat: "Towns, villages - high in the sky",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/swift",
                 localAsset: "Swift",
                 seasonalNote: "Summer visitor (May-Aug)", isYearRound: false, summerOnly: true, winterOnly: false),
        // Winter visitors (October-March)
        BirdInfo(name: "Fieldfare", scientificName: "Turdus pilaris",
                 description: "Large thrush with grey head, chestnut back. Arrives from Scandinavia in flocks.",
                 habitat: "Fields, hedgerows, orchards",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/fieldfare",
                 localAsset: "Fieldfare",
                 seasonalNote: "Winter visitor (Oct-Mar)", isYearRound: false, summerOnly: false, winterOnly: true),
        BirdInfo(name: "Redwing", scientificName: "Turdus iliacus",
                 description: "Small thrush with cream eyestripe and red underwing. Often heard migrating at night.",
                 habitat: "Fields, hedgerows, gardens in cold snaps",
                 imageURL: "https://www.rspb.org.uk/birds-and-wildlife/redwing",
                 localAsset: "Redwing",
                 seasonalNote: "Winter visitor (Oct-Mar)", isYearRound: false, summerOnly: false, winterOnly: true)
    ]
    
    // Season names for display
    var currentSeasonName: String {
        switch currentMonth {
        case 3...5: return "Spring"
        case 6...8: return "Summer"
        case 9...11: return "Autumn"
        default: return "Winter"
        }
    }
    
    // Season color for badge
    var seasonColor: Color {
        switch currentMonth {
        case 3...5: return .green      // Spring
        case 6...8: return .orange     // Summer
        case 9...11: return .brown     // Autumn
        default: return .blue          // Winter
        }
    }
    
    // Seasonal message
    var seasonalMessage: String {
        switch currentMonth {
        case 4: return "🌸 Spring arrivals! Look out for Swallows and House Martins returning from Africa."
        case 5: return "🐦 Peak breeding season! Swifts have arrived - listen for their screaming calls."
        case 6...7: return "☀️ Summer chorus! Best time to spot fledglings learning to fly."
        case 8: return "🍂 Late summer. Swifts are heading south - catch them while you can!"
        case 9: return "🍁 Autumn migration. Summer visitors departing, watch for passing migrants."
        case 10: return "❄️ Winter thrushes arriving! Look for Fieldfares and Redwings from Scandinavia."
        case 11...12: return "🌨️ Winter flocks. Fieldfares and Redwings raid berry bushes."
        case 1...2: return "❄️ Coldest months. Garden birds more visible at feeders."
        case 3: return "🌱 Spring is coming! Early migrants may appear on warm days."
        default: return "🐦 Great time for birdwatching!"
        }
    }
    
    // Special seasonal birds to highlight
    var seasonalHighlights: [BirdInfo] {
        let month = currentMonth
        return allBirds.filter { bird in
            // Highlight arriving summer visitors in spring
            if bird.summerOnly && (month == 4 || month == 5) { return true }
            // Highlight arriving winter visitors in autumn
            if bird.winterOnly && (month == 10 || month == 11) { return true }
            return false
        }
    }
    
    // Filter birds based on current season
    var seasonalBirds: [BirdInfo] {
        let isSummer = currentMonth >= 4 && currentMonth <= 9  // April to September
        let isWinter = currentMonth <= 3 || currentMonth >= 10 // October to March
        
        return allBirds.filter { bird in
            if bird.isYearRound { return true }
            if bird.summerOnly && isSummer { return true }
            if bird.winterOnly && isWinter { return true }
            return false
        }
    }
    
    var spottedBirds: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: spottedBirdsData)) ?? []
        }
        set {
            spottedBirdsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Seasonal header card
                    VStack(spacing: 12) {
                        // Season indicator
                        HStack {
                            Text(currentSeasonName)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(seasonColor)
                                .clipShape(Capsule())
                            
                            Spacer()
                            
                            // RSPB credit
                            Text("Data: RSPB")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        // Seasonal message
                        Text(seasonalMessage)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Divider()
                        
                        // Stats
                        HStack {
                            Image(systemName: "bird.fill")
                                .font(.title)
                                .foregroundColor(.orange)
                            Text("Birds Spotted")
                                .font(.title2)
                                .fontWeight(.bold)
                            Spacer()
                            Text("\(spottedBirds.count)/\(seasonalBirds.count)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                        }
                        
                        if spottedBirds.count == seasonalBirds.count && !seasonalBirds.isEmpty {
                            Text("🎉 Amazing! You've spotted all the birds!")
                                .font(.callout)
                                .foregroundColor(.green)
                        }
                        
                        Text("Tap a bird to learn more, then mark it as spotted")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    
                    // Seasonal highlights (if any)
                    if !seasonalHighlights.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("✨ Seasonal Specials")
                                .font(.headline)
                                .foregroundColor(.orange)
                            
                            Text("These birds are special to spot right now!")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            ForEach(seasonalHighlights) { bird in
                                HStack(spacing: 8) {
                                    Image(systemName: spottedBirds.contains(bird.name) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(spottedBirds.contains(bird.name) ? .green : .orange)
                                    Text(bird.name)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(bird.seasonalNote)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(16)
                    }
                    
                    // Bird cards
                    ForEach(seasonalBirds) { bird in
                        BirdCard(
                            bird: bird,
                            isExpanded: expandedBird == bird.name,
                            isSpotted: spottedBirds.contains(bird.name),
                            onTap: {
                                withAnimation(.spring(response: 0.3)) {
                                    if expandedBird == bird.name {
                                        expandedBird = nil
                                    } else {
                                        expandedBird = bird.name
                                    }
                                }
                            },
                            onSpotted: {
                                var spotted = spottedBirds
                                if spotted.contains(bird.name) {
                                    spotted.remove(bird.name)
                                } else {
                                    spotted.insert(bird.name)
                                }
                                spottedBirdsData = (try? JSONEncoder().encode(spotted)) ?? Data()
                            }
                        )
                    }
                    
                    // Reset button
                    if !spottedBirds.isEmpty {
                        Button {
                            spottedBirdsData = Data()
                        } label: {
                            Text("Reset All Sightings")
                                .font(.callout)
                                .foregroundColor(.red)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
            .navigationTitle("Bird Spotting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Bird Card
struct BirdCard: View {
    let bird: BirdInfo
    let isExpanded: Bool
    let isSpotted: Bool
    let onTap: () -> Void
    let onSpotted: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible)
            Button(action: onTap) {
                HStack(spacing: 12) {
                    // Bird emoji/icon
                    ZStack {
                        Circle()
                            .fill(isSpotted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "bird.fill")
                            .font(.title3)
                            .foregroundColor(isSpotted ? .green : .orange)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bird.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(bird.seasonalNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if isSpotted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .padding()
            
            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    
                    // Image - prefer local asset, fall back to URL
                    if let assetName = bird.localAsset, UIImage(named: assetName) != nil {
                        // Use bundled image
                        Image(assetName)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 150)
                            .clipped()
                            .cornerRadius(12)
                    } else {
                        // Fall back to URL
                        AsyncImage(url: URL(string: bird.imageURL)) { phase in
                            switch phase {
                            case .empty:
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                                .frame(height: 150)
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(height: 150)
                                    .clipped()
                                    .cornerRadius(12)
                            case .failure:
                                HStack {
                                    Spacer()
                                    VStack {
                                        Image(systemName: "bird.fill")
                                            .font(.system(size: 40))
                                            .foregroundColor(.orange)
                                        Text(bird.name)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .frame(height: 150)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(12)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                    
                    // Scientific name
                    Text(bird.scientificName)
                        .font(.caption)
                        .italic()
                        .foregroundColor(.secondary)
                    
                    // Description
                    Text(bird.description)
                        .font(.body)
                        .foregroundColor(.primary)
                    
                    // Habitat
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(.tealAccent)
                        Text(bird.habitat)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Spotted button
                    Button(action: onSpotted) {
                        HStack {
                            Image(systemName: isSpotted ? "checkmark.circle.fill" : "circle")
                            Text(isSpotted ? "Spotted! ✓" : "Mark as Spotted")
                        }
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(isSpotted ? Color.green : Color.orange)
                        .cornerRadius(10)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
}

// MARK: - Sheffield Health Walks Card
struct SheffieldHealthWalksCard: View {
    var body: some View {
        Link(destination: URL(string: "https://www.stepoutsheffield.co.uk")!) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: "figure.walk.diamond.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sheffield Health Walks")
                            .font(.bodyLarge)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        Text("Free group walks led by trained volunteers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.green)
                }
                
                Text("Discover walks across Sheffield, from gentle strolls to more active routes. All free, friendly and welcoming.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .cardStyle()
        }
    }
}

// MARK: - Photo Thumbnail
struct PhotoThumbnail: View {
    let photo: CapturedPhoto
    @ObservedObject var photoStorage: PhotoStorageService
    
    var body: some View {
        if let image = photoStorage.loadImage(for: photo) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 100, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    VStack {
                        Spacer()
                        Text(photo.formattedDate)
                            .font(.system(size: 8))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                )
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 100, height: 100)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                )
        }
    }
}

// MARK: - Photo Detail View
struct PhotoDetailView: View {
    let photo: CapturedPhoto
    @ObservedObject var photoStorage: PhotoStorageService
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationStack {
            VStack {
                if let image = photoStorage.loadImage(for: photo) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding()
                } else {
                    Text("Unable to load photo")
                        .foregroundColor(.secondary)
                }
                
                Text("Captured: \(photo.formattedDate)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .navigationTitle("Nature Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .confirmationDialog("Delete Photo?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    photoStorage.deletePhoto(photo)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This photo will be permanently deleted.")
            }
        }
    }
}

// MARK: - Digital Skills Section
enum DigitalSkillAction {
    case url(String)
    case camera
    case none
}

struct DigitalSkillsSection: View {
    @ObservedObject var userProgress: UserProgress
    @ObservedObject var viewModel: WaitingRoomViewModel
    @StateObject private var photoStorage = PhotoStorageService.shared
    @State private var showImagePicker = false
    @State private var showPhotoOptions = false
    @State private var capturedImage: UIImage?
    @State private var useCamera = false
    @State private var showPhotoSavedAlert = false
    
    let skills: [(id: String, icon: String, title: String, description: String, action: DigitalSkillAction)] = [
        ("nhs_number", "number.circle.fill", "Find Your NHS Number", "Get your 10-digit NHS number online.", .url("https://www.nhs.uk/nhs-services/online-services/find-nhs-number/")),
        ("mytoolkit", "brain.head.profile", "Visit MyToolkit", "Helpful resources including your safety plan.", .url("https://toolkit.sheffieldmentalhealth.co.uk")),
        ("learnmyway", "graduationcap.fill", "Visit Learn My Way", "Free courses to build digital confidence.", .url("https://www.learnmyway.com")),
        ("take_photo", "camera.fill", "Take a Photo", "Capture nature - photos appear in Nature tab.", .camera),
        ("nhs_app", "app.badge", "Download the NHS App", "Book appointments and view health records.", .url("https://apps.apple.com/gb/app/nhs-app/id1388411277"))
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Digital Skills Challenge")
                    .font(.titleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(userProgress.digitalSkillsCompletedCount)/5")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.tealAccent)
            }
            
            Text("Complete all 5 to earn the Digital Pioneer badge!")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ForEach(skills, id: \.id) { skill in
                DigitalSkillCard(
                    icon: skill.icon,
                    title: skill.title,
                    description: skill.description,
                    isCompleted: userProgress.isDigitalSkillComplete(skill.id),
                    action: skill.action,
                    onCameraTap: { showPhotoOptions = true },
                    onComplete: {
                        userProgress.markDigitalSkillComplete(skill.id)
                    }
                )
            }
        }
        .confirmationDialog("Take a Photo", isPresented: $showPhotoOptions) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") {
                    useCamera = true
                    showImagePicker = true
                }
            }
            Button("Choose from Library") {
                useCamera = false
                showImagePicker = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Capture nature around you during your walk")
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(image: $capturedImage, useCamera: useCamera)
        }
        .onChange(of: capturedImage) { oldValue, newValue in
            if let image = newValue {
                photoStorage.savePhoto(image)
                userProgress.markDigitalSkillComplete("take_photo")
                showPhotoSavedAlert = true
                capturedImage = nil
            }
        }
        .alert("Photo Saved! 📸", isPresented: $showPhotoSavedAlert) {
            Button("OK") { }
        } message: {
            Text("Your photo has been saved. View it in the Nature tab!")
        }
    }
}

struct DigitalSkillCard: View {
    @Environment(\.openURL) var openURL
    
    let icon: String
    let title: String
    let description: String
    let isCompleted: Bool
    var action: DigitalSkillAction = .none
    var onCameraTap: (() -> Void)? = nil
    var onComplete: (() -> Void)? = nil
    
    var body: some View {
        Button(action: {
            switch action {
            case .url(let urlString):
                if let link = URL(string: urlString) {
                    openURL(link)
                    onComplete?() // Mark as complete when URL is opened
                }
            case .camera:
                onCameraTap?()
                // Camera completion is handled separately when photo is saved
            case .none:
                break
            }
        }) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isCompleted ? Color.mintGreen.opacity(0.15) : Color.tealAccent.opacity(0.15))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : icon)
                        .font(.title3)
                        .foregroundColor(isCompleted ? .mintGreen : .tealAccent)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.bodyMedium)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        if isCompleted {
                            Text("Done")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.mintGreen)
                                .clipShape(Capsule())
                        }
                    }
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                if !isCompleted {
                    switch action {
                    case .url:
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.tealAccent)
                    case .camera:
                        Image(systemName: "camera.fill")
                            .font(.caption)
                            .foregroundColor(.tealAccent)
                    case .none:
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(16)
            .cardStyle()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Image Picker for Camera
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    var useCamera: Bool = false
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = useCamera ? .camera : .photoLibrary
        picker.allowsEditing = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
                // Only save to photo library if taken with camera
                if picker.sourceType == .camera {
                    UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
                }
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

#Preview {
    WellbeingView(viewModel: WaitingRoomViewModel())
}



