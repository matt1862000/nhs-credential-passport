//
//  ClinicianSelectionView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 09/12/2025.
//

import SwiftUI

struct ClinicianSelectionView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var isPresented: Bool
    var onNavigateToWalk: (() -> Void)? = nil
    var onNavigateToBreathing: (() -> Void)? = nil
    var onNavigateToDigitalSkills: (() -> Void)? = nil
    @State private var searchText = ""
    @Environment(\.colorScheme) var colorScheme
    
    var filteredClinicians: [Clinician] {
        if searchText.isEmpty {
            return viewModel.availableClinicians
        }
        return viewModel.availableClinicians.filter { clinician in
            clinician.name.localizedCaseInsensitiveContains(searchText) ||
            clinician.specialty.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedGradientBackground()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 50))
                                .foregroundColor(.tealAccent)
                            
                            Text("Who are you seeing today?")
                                .font(.titleLarge)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text("Choose your clinician to receive real-time updates as clinic times change")
                                .font(.bodyMedium)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 20)
                        
                        // Search bar
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            
                            TextField("Search by name or specialty", text: $searchText)
                                .font(.bodyMedium)
                                .foregroundColor(.primary)
                        }
                        .padding(12)
                        .background(colorScheme == .dark ? Color.darkCardBackground : Color.white.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        
                        // Last updated info
                        if !viewModel.availableClinicians.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                                Text("Last updated:")
                                    .font(.caption)
                                Text(viewModel.waitTimeInfo.lastUpdated, style: .time)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                        }
                        
                        // Clinician list
                        VStack(spacing: 12) {
                            if filteredClinicians.isEmpty {
                                // Empty state with feature shortcuts
                                VStack(spacing: 20) {
                                    Image(systemName: "moon.zzz.fill")
                                        .font(.system(size: 50))
                                        .foregroundColor(.secondary.opacity(0.6))
                                    
                                    Text("No Active Clinics")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.primary)
                                    
                                    Text("Clinics are currently closed.\nCheck back during clinic hours.")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                    
                                    // Feature shortcuts
                                    VStack(spacing: 12) {
                                        Text("While You Wait")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.secondary)
                                            .padding(.top, 8)
                                        
                                        // Take a Walk
                                        FeatureShortcutButton(
                                            icon: "figure.walk",
                                            title: "Take a Walk",
                                            subtitle: "Discover routes nearby",
                                            color: .tealAccent
                                        ) {
                                            viewModel.hasSkippedClinicianSelection = true
                                            isPresented = false
                                            // Navigate to Walk tab and open route picker (delay for dismiss animation)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                                onNavigateToWalk?()
                                            }
                                        }
                                        
                                        // Breathing Exercises
                                        FeatureShortcutButton(
                                            icon: "wind",
                                            title: "Breathing Exercises",
                                            subtitle: "Calm your mind",
                                            color: .lavenderMist
                                        ) {
                                            viewModel.hasSkippedClinicianSelection = true
                                            isPresented = false
                                            // Navigate to Wellbeing and open random breathing exercise (delay for dismiss animation)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                                onNavigateToBreathing?()
                                            }
                                        }
                                        
                                        // Digital Skills
                                        FeatureShortcutButton(
                                            icon: "iphone.gen3",
                                            title: "Digital Skills",
                                            subtitle: "Learn something new",
                                            color: .tealAccent
                                        ) {
                                            viewModel.hasSkippedClinicianSelection = true
                                            isPresented = false
                                            // Navigate to Wellbeing > Digital Skills (delay for dismiss animation)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                                onNavigateToDigitalSkills?()
                                            }
                                        }
                                    }
                                    .padding(.top, 8)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 16)
                                .padding(.bottom, 20)
                            } else {
                                ForEach(filteredClinicians) { clinician in
                                    ClinicianCard(
                                        clinician: clinician,
                                        isSelected: viewModel.selectedClinician?.id == clinician.id,
                                        onSelect: {
                                            viewModel.selectClinician(clinician)
                                            
                                            // Dismiss after short delay
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                isPresented = false
                                            }
                                        }
                                    )
                                }
                            }
                        }
                        
                        // Info note - only show when clinicians are available
                        if !filteredClinicians.isEmpty {
                            HStack(spacing: 12) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.tealAccent)
                                
                                Text("Delay times are estimates. Thank you for your patience.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(16)
                            .cardStyle()
                        }
                        
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Select Clinician")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.hasSelectedClinician ? "Cancel" : "Skip") {
                        if !viewModel.hasSelectedClinician {
                            viewModel.hasSkippedClinicianSelection = true
                        }
                        isPresented = false
                    }
                }
            }
            // Delay alerts with Stop Alerts option (for cold launch from push notification)
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
                    if info.newMinutes == 0 {
                        Text("The clinic is now running on time.")
                    } else {
                        Text("The clinic delay has reduced to \(info.newMinutes) minutes.")
                    }
                } else {
                    Text("The clinic delay has been updated.")
                }
            }
            .onAppear {
                // Check for pending push notification (cold launch)
                checkPendingNotification()
            }
        }
    }
    
    private func checkPendingNotification() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let pending = AppDelegate.pendingNotification {
                // Keep suppress flag ON to prevent duplicate alerts
                AppDelegate.suppressInAppAlertsFlag = true
                AppDelegate.pendingNotification = nil
                
                let body = pending["body"] ?? ""
                
                if body.contains("increased") {
                    viewModel.waitTimeChangeInfo = (oldMinutes: 0, newMinutes: viewModel.waitTimeInfo.estimatedMinutes, isIncrease: true)
                    viewModel.showWaitTimeIncreasedAlert = true
                } else {
                    viewModel.waitTimeChangeInfo = (oldMinutes: 0, newMinutes: viewModel.waitTimeInfo.estimatedMinutes, isIncrease: false)
                    viewModel.showWaitTimeDecreasedAlert = true
                }
                
                print("📱 Showing alert from push on clinician selection screen")
                
                // Clear suppress flag after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    AppDelegate.suppressInAppAlertsFlag = false
                }
            }
        }
    }
}

// MARK: - Clinician Card
struct ClinicianCard: View {
    let clinician: Clinician
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // Photo or initial
                ZStack {
                    ClinicianPhotoView(clinician: clinician, size: 56)
                    
                    if isSelected {
                        Circle()
                            .stroke(Color.tealAccent, lineWidth: 3)
                            .frame(width: 62, height: 62)
                    }
                }
                
                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(clinician.fullTitle)
                            .font(.bodyLarge)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.mintGreen)
                                .font(.caption)
                        }
                    }
                    
                    // Location badge
                    if !clinician.location.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.coralPink)
                            Text(clinician.location)
                                .font(.caption)
                                .foregroundColor(.coralPink)
                                .fontWeight(.medium)
                        }
                    }
                    
                    Text(clinician.specialty)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Wait time
                    HStack(spacing: 6) {
                        Image(systemName: clinician.isOnTime ? "checkmark.circle.fill" : "clock.fill")
                            .font(.caption2)
                            .foregroundColor(clinician.isOnTime ? .mintGreen : .softAmber)
                        
                        Text(clinician.isOnTime ? "On Time" : "~\(clinician.formattedWaitTime) delay")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(clinician.isOnTime ? .mintGreen : .softAmber)
                        
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(isSelected ? Color.tealAccent.opacity(0.15) : (colorScheme == .dark ? Color.darkCardBackground : Color.white.opacity(0.8)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.tealAccent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Feature Shortcut Button
struct FeatureShortcutButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon circle
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(color)
                }
                
                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(colorScheme == .dark ? Color.darkCardBackground : Color.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ClinicianSelectionView(
        viewModel: WaitingRoomViewModel(),
        isPresented: .constant(true)
    )
}

