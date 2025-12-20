//
//  WellbeingView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI

struct WellbeingView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @State private var selectedCategory: WellbeingCategory = .breathing
    @State private var selectedExercise: WellbeingContent?
    @State private var showHelpSheet = false
    @State private var showPreWellbeingCheck = false
    @State private var showPostWellbeingCheck = false
    @State private var pendingExercise: WellbeingContent? // Exercise to start after pre-check
    @State private var exerciseCompleted = false // Track if exercise was completed
    
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
            .sheet(item: $selectedExercise) { exercise in
                BreathingExerciseSheet(
                    exercise: exercise,
                    onDismiss: {
                        // Check if we need to show post-wellbeing check when sheet closes
                        let shouldShowPostCheck = exerciseCompleted
                        exerciseCompleted = false
                        selectedExercise = nil
                        
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
                                selectedExercise = exercise
                                pendingExercise = nil
                            }
                        }
                    }
            }
            .sheet(isPresented: $showPostWellbeingCheck) {
                AnxietyCheckSheet(viewModel: viewModel, isPresented: $showPostWellbeingCheck, isPostWalk: true)
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
            selectedExercise = exercise
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
    @Binding var selectedCategory: WellbeingView.WellbeingCategory
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(WellbeingView.WellbeingCategory.allCases, id: \.self) { category in
                    CategoryTab(
                        category: category,
                        isSelected: selectedCategory == category
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            selectedCategory = category
                        }
                    }
                }
            }
        }
    }
}

struct CategoryTab: View {
    let category: WellbeingView.WellbeingCategory
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
                    .frame(height: 100)
                    .padding(12)
                    .background(Color.softGray)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                Button("Save Entry") {
                    if !gratitudeText.isEmpty {
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nature Connection")
                .font(.titleMedium)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            ForEach(WellbeingContent.natureFacts) { fact in
                NatureFactCard(fact: fact)
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
                        
                        Text("\(photoStorage.capturedPhotos.count) photo\(photoStorage.capturedPhotos.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
            } else {
                // Photo prompt card - only show if no photos
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(Color.mintGreen.opacity(0.15))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: "camera.fill")
                                .font(.title3)
                                .foregroundColor(.mintGreen)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Capture Nature")
                                .font(.bodyLarge)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            
                            Text("Take photos during your walk using the Digital Skills tab")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Text("Look for: 🌳 Trees • 🌸 Flowers • 🐦 Birds • ☁️ Clouds • 🍂 Leaves")
                        .font(.caption)
                        .foregroundColor(.primary)
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

struct NatureFactCard: View {
    let fact: WellbeingContent
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.mintGreen.opacity(0.15))
                    .frame(width: 50, height: 50)
                
                Image(systemName: fact.icon)
                    .font(.title3)
                    .foregroundColor(.mintGreen)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(fact.title)
                    .font(.bodyMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text(fact.description)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            
            Spacer()
        }
        .padding(16)
        .cardStyle()
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


