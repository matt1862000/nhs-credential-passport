//
//  ClinicianSelectionView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 09/12/2025.
//

import SwiftUI
import CoreLocation

struct ClinicianSelectionView: View {
    @ObservedObject var viewModel: WaitingRoomViewModel
    @Binding var isPresented: Bool
    var onNavigateToWalk: (() -> Void)? = nil
    var onNavigateToBreathing: (() -> Void)? = nil
    var onNavigateToDigitalSkills: (() -> Void)? = nil
    @State private var searchText = ""
    @Environment(\.colorScheme) var colorScheme
    
    // Location for sorting by proximity
    @StateObject private var locationHelper = ClinicianLocationHelper()
    
    // v1.9.56: Appointment time picker state
    @State private var showAppointmentTimePicker = false
    @State private var selectedAppointmentTime = Date()
    @State private var pendingClinician: Clinician? = nil
    
    /// Clinicians sorted by proximity (if location available) then filtered by search
    var filteredClinicians: [Clinician] {
        // First sort by proximity if we have location
        var clinicians = viewModel.availableClinicians
        
        if let userLocation = locationHelper.currentLocation {
            clinicians = ClinicLocationService.shared.sortByProximity(
                clinicians: clinicians,
                userLocation: userLocation
            )
        }
        
        // Then filter by search
        if searchText.isEmpty {
            return clinicians
        }
        return clinicians.filter { clinician in
            clinician.name.localizedCaseInsensitiveContains(searchText) ||
            clinician.specialty.localizedCaseInsensitiveContains(searchText) ||
            clinician.location.localizedCaseInsensitiveContains(searchText)
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
                                    let isSelectedClinician = pendingClinician?.id == clinician.id
                                    let shouldShow = !showAppointmentTimePicker || isSelectedClinician
                                    
                                    if shouldShow {
                                        VStack(spacing: 12) {
                                            ClinicianCard(
                                                clinician: clinician,
                                                isSelected: viewModel.selectedClinician?.id == clinician.id,
                                                userLocation: locationHelper.currentLocation,
                                                onSelect: {
                                                    viewModel.selectClinician(clinician)
                                                    
                                                    // 🚀 Early prefetch POIs now that we have location + clinician
                                                    // This speeds up route generation when user wants to walk
                                                    if let location = locationHelper.currentLocation {
                                                        GoogleMapsService.shared.prefetchPOIsEarly(
                                                            location: location.coordinate
                                                        )
                                                    }
                                                    
                                                    // v1.9.56: Show appointment time picker instead of immediate dismiss
                                                    pendingClinician = clinician
                                                    // Default to next quarter hour
                                                    let now = Date()
                                                    let calendar = Calendar.current
                                                    let minute = calendar.component(.minute, from: now)
                                                    let roundedMinute = ((minute / 15) + 1) * 15
                                                    if let defaultTime = calendar.date(bySettingHour: calendar.component(.hour, from: now), minute: roundedMinute % 60, second: 0, of: now) {
                                                        selectedAppointmentTime = roundedMinute >= 60 
                                                            ? calendar.date(byAdding: .hour, value: 1, to: defaultTime) ?? defaultTime
                                                            : defaultTime
                                                    }
                                                    withAnimation(.easeOut(duration: 0.3)) {
                                                        showAppointmentTimePicker = true
                                                    }
                                                }
                                            )
                                            
                                            // v1.9.56: Inline appointment time picker - appears directly under selected clinician
                                            if showAppointmentTimePicker && isSelectedClinician {
                                                AppointmentTimePickerCard(
                                                    clinician: clinician,
                                                    selectedTime: $selectedAppointmentTime,
                                                    onSetTime: {
                                                        viewModel.setAppointmentTime(selectedAppointmentTime)
                                                        withAnimation {
                                                            showAppointmentTimePicker = false
                                                        }
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                            isPresented = false
                                                        }
                                                    },
                                                    onSkip: {
                                                        viewModel.clearAppointmentTime()
                                                        withAnimation {
                                                            showAppointmentTimePicker = false
                                                        }
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                            isPresented = false
                                                        }
                                                    },
                                                    onChangeClinician: {
                                                        // v1.9.58: Allow changing clinician
                                                        withAnimation(.easeOut(duration: 0.3)) {
                                                            showAppointmentTimePicker = false
                                                            pendingClinician = nil
                                                        }
                                                    }
                                                )
                                                .transition(.asymmetric(
                                                    insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity
                                                ))
                                            }
                                        }
                                    }
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
                // Request location permission to sort clinicians by proximity
                locationHelper.requestLocationPermission()
                
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
    let userLocation: CLLocation?  // For showing distance
    let onSelect: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    /// Formatted distance to this clinician's location
    private var distanceText: String? {
        guard let userLoc = userLocation else { return nil }
        return ClinicLocationService.shared.formattedDistance(from: userLoc, to: clinician.location)
    }
    
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
                    
                    // Location badge with distance
                    if !clinician.location.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.coralPink)
                            Text(clinician.location)
                                .font(.caption)
                                .foregroundColor(.coralPink)
                                .fontWeight(.medium)
                            
                            // Show distance if available
                            if let distance = distanceText {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(distance)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
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

// MARK: - Appointment Time Picker Card (v1.9.56)
struct AppointmentTimePickerCard: View {
    let clinician: Clinician
    @Binding var selectedTime: Date
    let onSetTime: () -> Void
    let onSkip: () -> Void
    var onChangeClinician: (() -> Void)? = nil  // v1.9.58: Optional callback to change clinician
    @Environment(\.colorScheme) var colorScheme
    
    // Time formatter
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.title2)
                    .foregroundColor(.tealAccent)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("What time is your appointment?")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("Optional — helps us show when you'll be seen")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Time picker
            DatePicker(
                "Appointment Time",
                selection: $selectedTime,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(height: 120)
            
            // Preview of estimated time to be seen
            if clinician.currentWaitMinutes > 0 {
                let estimatedSeen = Calendar.current.date(byAdding: .minute, value: clinician.currentWaitMinutes, to: selectedTime) ?? selectedTime
                
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundColor(.softAmber)
                    
                    Text("With \(clinician.currentWaitMinutes) min delay, estimated to be seen: **\(timeFormatter.string(from: estimatedSeen))**")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.softAmber.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            
            // Buttons
            HStack(spacing: 12) {
                // Skip button
                Button(action: onSkip) {
                    Text("Skip")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(colorScheme == .dark ? Color.darkCardBackground : Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                
                // Set time button
                Button(action: onSetTime) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                        Text("Set Time")
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.tealAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            
            // v1.9.58: Wrong clinician? Change button
            if let onChangeClinician = onChangeClinician {
                Button(action: onChangeClinician) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption)
                        Text("Wrong clinician? Change")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(colorScheme == .dark ? Color.darkCardBackground : Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.tealAccent.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 8, y: 4)
    }
}

// MARK: - Location Helper for Clinician Proximity Sorting
class ClinicianLocationHelper: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = locationManager.authorizationStatus
    }
    
    func requestLocationPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        default:
            break
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            self.authorizationStatus = status
            
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        DispatchQueue.main.async {
            self.currentLocation = locations.last
            if let loc = locations.last {
                print("📍 ClinicianLocationHelper got location: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("📍 Location error: \(error.localizedDescription)")
    }
}

#Preview {
    ClinicianSelectionView(
        viewModel: WaitingRoomViewModel(),
        isPresented: .constant(true)
    )
}

