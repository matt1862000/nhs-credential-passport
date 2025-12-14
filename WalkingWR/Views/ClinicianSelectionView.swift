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
                        
                        // Clinician list
                        VStack(spacing: 12) {
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
                        
                        // Info note
                        HStack(spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.tealAccent)
                            
                            Text("Wait times are estimates and updated in real-time from the clinic system.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .cardStyle()
                        
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Select Clinician")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.hasSelectedClinician {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isPresented = false
                        }
                    }
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
                    
                    Text(clinician.specialty)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Wait time
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                            .foregroundColor(.softAmber)
                        
                        Text("~\(clinician.formattedWaitTime) delay")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.softAmber)
                        
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

#Preview {
    ClinicianSelectionView(
        viewModel: WaitingRoomViewModel(),
        isPresented: .constant(true)
    )
}

