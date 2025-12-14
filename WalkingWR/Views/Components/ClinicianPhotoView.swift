//
//  ClinicianPhotoView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 10/12/2025.
//

import SwiftUI

/// A view that displays a clinician's photo from either a local asset or remote URL
/// Falls back to showing initials if no photo is available
struct ClinicianPhotoView: View {
    let clinician: Clinician
    let size: CGFloat
    var showBorder: Bool = false
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.tealAccent.opacity(0.15))
                .frame(width: size, height: size)
            
            // Photo or initials
            if let photoURL = clinician.photoURL, let url = URL(string: photoURL) {
                // Remote photo from Google Sheets
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        // Loading state
                        ProgressView()
                            .frame(width: size, height: size)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                    case .failure:
                        // Failed to load - show initials
                        initialsView
                    @unknown default:
                        initialsView
                    }
                }
            } else if let photoName = clinician.photoName, UIImage(named: photoName) != nil {
                // Local asset photo
                Image(photoName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                // No photo - show initials
                initialsView
            }
        }
        .overlay(
            Circle()
                .stroke(showBorder ? Color.white : Color.clear, lineWidth: showBorder ? 4 : 0)
        )
    }
    
    private var initialsView: some View {
        Text(clinician.name.prefix(1).uppercased())
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundColor(.tealAccent)
    }
}

/// A larger version for profile pages with gradient background
struct ClinicianProfilePhotoView: View {
    let clinician: Clinician
    let size: CGFloat
    
    var body: some View {
        ZStack {
            // Gradient background
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.tealAccent.opacity(0.3), Color.mintGreen.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size + 10, height: size + 10)
            
            // Photo or initials
            if let photoURL = clinician.photoURL, let url = URL(string: photoURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: size, height: size)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 4)
                            )
                            .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
                    case .failure:
                        initialsView
                    @unknown default:
                        initialsView
                    }
                }
            } else if let photoName = clinician.photoName, let uiImage = UIImage(named: photoName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                    )
                    .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
            } else {
                initialsView
            }
        }
    }
    
    private var initialsView: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.tealAccent, Color.mintGreen],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Text(clinician.name.split(separator: " ").map { String($0.prefix(1)) }.joined())
                    .font(.system(size: size * 0.35, weight: .bold))
                    .foregroundColor(.white)
            )
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 4)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
    }
}

#Preview {
    VStack(spacing: 20) {
        ClinicianPhotoView(
            clinician: Clinician.sampleClinicians[0],
            size: 60
        )
        
        ClinicianProfilePhotoView(
            clinician: Clinician.sampleClinicians[0],
            size: 140
        )
    }
}

