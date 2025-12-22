//
//  ClinicianPhotoView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 10/12/2025.
//

import SwiftUI

/// A view that displays a clinician's photo from either a local asset or remote URL
/// Uses 24-hour caching to avoid unnecessary network requests
/// Falls back to showing initials if no photo is available
struct ClinicianPhotoView: View {
    let clinician: Clinician
    let size: CGFloat
    var showBorder: Bool = false
    
    @State private var cachedImage: UIImage?
    @State private var isLoading = true
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.tealAccent.opacity(0.15))
                .frame(width: size, height: size)
            
            // Photo or initials
            if let image = cachedImage {
                // Cached remote photo
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if let photoName = clinician.photoName, UIImage(named: photoName) != nil {
                // Local asset photo
                Image(photoName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if isLoading && clinician.photoURL != nil {
                // Loading state
                ProgressView()
                    .frame(width: size, height: size)
            } else {
                // No photo - show initials
                initialsView
            }
        }
        .overlay(
            Circle()
                .stroke(showBorder ? Color.white : Color.clear, lineWidth: showBorder ? 4 : 0)
        )
        .onAppear {
            loadCachedImage()
        }
        .onChange(of: clinician.photoURL) { _, newURL in
            // Reload if clinician changes
            cachedImage = nil
            isLoading = true
            loadCachedImage()
        }
        .id(clinician.photoURL ?? clinician.name) // Force view refresh when clinician changes
    }
    
    private func loadCachedImage() {
        guard let photoURL = clinician.photoURL else {
            isLoading = false
            return
        }
        
        // Debug: Print URL being loaded
        print("📷 Loading photo for \(clinician.name): \(photoURL)")
        
        ImageCacheService.shared.getImage(for: photoURL) { image in
            if image != nil {
                print("✅ Photo loaded for \(clinician.name)")
            } else {
                print("❌ Failed to load photo for \(clinician.name)")
            }
            self.cachedImage = image
            self.isLoading = false
        }
    }
    
    private var initialsView: some View {
        Text(clinician.name.prefix(1).uppercased())
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundColor(.tealAccent)
    }
}

/// A larger version for profile pages with gradient background
/// Uses 24-hour caching to avoid unnecessary network requests
struct ClinicianProfilePhotoView: View {
    let clinician: Clinician
    let size: CGFloat
    
    @State private var cachedImage: UIImage?
    @State private var isLoading = true
    
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
            if let image = cachedImage {
                // Cached remote photo
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 4)
                    )
                    .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
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
            } else if isLoading && clinician.photoURL != nil {
                ProgressView()
                    .frame(width: size, height: size)
            } else {
                initialsView
            }
        }
        .onAppear {
            loadCachedImage()
        }
    }
    
    private func loadCachedImage() {
        guard let photoURL = clinician.photoURL else {
            isLoading = false
            return
        }
        
        ImageCacheService.shared.getImage(for: photoURL) { image in
            self.cachedImage = image
            self.isLoading = false
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

