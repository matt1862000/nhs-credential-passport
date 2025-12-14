//
//  ClinicianProfileView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ClinicianProfileView: View {
    @Environment(\.dismiss) private var dismiss
    
    let clinician: Clinician
    
    // For backwards compatibility
    init(clinician: Clinician) {
        self.clinician = clinician
    }
    
    init(clinicianName: String) {
        // Try to find clinician by name, or create a default
        if let found = Clinician.sampleClinicians.first(where: { $0.fullTitle == clinicianName || $0.name.contains(clinicianName.replacingOccurrences(of: "Dr. ", with: "")) }) {
            self.clinician = found
        } else {
            self.clinician = Clinician.sampleClinicians[0]
        }
    }
    
    var initials: String {
        let parts = clinician.name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))"
        }
        return String(clinician.name.prefix(2)).uppercased()
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Profile header
                    VStack(spacing: 16) {
                        // Profile image
                        ClinicianProfilePhotoView(clinician: clinician, size: 140)
                        
                        VStack(spacing: 8) {
                            Text(clinician.fullTitle)
                                .font(.appTitleLarge)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text(clinician.specialty)
                                .font(.appBodyMedium)
                                .foregroundColor(.tealAccent)
                                .fontWeight(.medium)
                            
                            HStack(spacing: 4) {
                                Image(systemName: "building.2")
                                    .font(.caption)
                                Text("Longley Centre, Sheffield")
                                    .font(.caption)
                            }
                            .foregroundColor(.primary)
                        }
                    }
                    .padding(.top, 20)
                    
                    // Bio sections
                    VStack(alignment: .leading, spacing: 20) {
                        // About
                        BioSection(title: "About", icon: "person.fill") {
                            Text(clinician.bio)
                                .font(.appBodyMedium)
                                .foregroundColor(.primary)
                                .lineSpacing(4)
                        }
                        
                        // Expertise
                        BioSection(title: "Clinical Expertise", icon: "brain.head.profile") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(clinician.expertiseDescription)
                                    .font(.appBodyMedium)
                                    .foregroundColor(.primary)
                                    .lineSpacing(4)
                                
                                // Specialty tags
                                FlowLayout(spacing: 8) {
                                    ForEach(clinician.expertiseTags, id: \.self) { tag in
                                        SpecialtyTag(text: tag)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                        
                        // Achievements
                        BioSection(title: "Recognition & Achievements", icon: "trophy.fill") {
                            Text(clinician.achievements)
                                .font(.appBodyMedium)
                                .foregroundColor(.primary)
                                .lineSpacing(4)
                        }
                        
                        // Publications
                        BioSection(title: "Publications & Advocacy", icon: "book.fill") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(clinician.publicationsIntro)
                                    .font(.appBodyMedium)
                                    .foregroundColor(.primary)
                                
                                if let pubTitle = clinician.publicationTitle {
                                    HStack(spacing: 12) {
                                        Image(systemName: "book.closed.fill")
                                            .font(.title2)
                                            .foregroundColor(.tealAccent)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(pubTitle)
                                                .font(.appBodyLarge)
                                                .fontWeight(.semibold)
                                                .foregroundColor(.primary)
                                            if let subtitle = clinician.publicationSubtitle {
                                                Text(subtitle)
                                                    .font(.caption)
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                    }
                                    .padding(12)
                                    .background(Color.tealAccent.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                
                                Text(clinician.publicationsOutro)
                                    .font(.appBodyMedium)
                                    .foregroundColor(.primary)
                                    .lineSpacing(4)
                            }
                        }
                        
                        // Personal
                        BioSection(title: "Outside Work", icon: "leaf.fill") {
                            Text(clinician.interestsDescription)
                                .font(.appBodyMedium)
                                .foregroundColor(.primary)
                                .lineSpacing(4)
                        }
                    }
                    .padding(.horizontal, 20)
                    
                    Spacer(minLength: 40)
                }
            }
            .background(AnimatedGradientBackground())
            .navigationTitle("Your Clinician")
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
        }
    }
}

// MARK: - Supporting Views

struct CredentialBadge: View {
    @Environment(\.colorScheme) var colorScheme
    let icon: String
    let text: String
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.tealAccent)
            
            Text(text)
                .font(.micro)
                .fontWeight(.medium)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.adaptiveCardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
    }
}

struct BioSection<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(.tealAccent)
                
                Text(title)
                    .font(.appTitleMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.adaptiveCardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 8, y: 4)
    }
}

struct SpecialtyTag: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.tealAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tealAccent.opacity(0.1))
            .clipShape(Capsule())
    }
}

struct InterestBadge: View {
    let icon: String
    let text: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.mintGreen)
            
            Text(text)
                .font(.micro)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

// Simple flow layout for tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth, x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                
                self.size.width = max(self.size.width, x)
            }
            
            self.size.height = y + rowHeight
        }
    }
}

#Preview {
    ClinicianProfileView(clinicianName: "Dr. Sarah Mitchell")
}

