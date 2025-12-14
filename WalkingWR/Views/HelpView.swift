//
//  HelpView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 08/12/2025.
//

import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) var openURL
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.coralPink.opacity(0.15))
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 36))
                                .foregroundColor(.coralPink)
                        }
                        
                        Text("We're Here to Help")
                            .font(.titleLarge)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("Support is available 24/7")
                            .font(.bodyMedium)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)
                    
                    // Contact Reception - Primary
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Clinic Contact")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .textCase(.uppercase)
                        
                        HelpContactCard(
                            icon: "phone.fill",
                            title: "Contact Reception",
                            subtitle: "0114 271 8840",
                            description: "Speak to our staff",
                            color: .tealAccent,
                            action: { openURL(URL(string: "tel:01142718840")!) }
                        )
                    }
                    .padding(.horizontal, 20)
                    
                    // Emergency
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Emergency")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .textCase(.uppercase)
                        
                        HelpContactCard(
                            icon: "exclamationmark.triangle.fill",
                            title: "Call 999",
                            subtitle: "Emergency Services",
                            description: "If life is at risk or you need immediate help",
                            color: .red,
                            isEmergency: true,
                            action: { openURL(URL(string: "tel:999")!) }
                        )
                    }
                    .padding(.horizontal, 20)
                    
                    // Mental Health Support
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "heart.circle.fill")
                                .foregroundColor(.mintGreen)
                            Text("Mental Health Support")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .textCase(.uppercase)
                        }
                        
                        HelpContactCard(
                            icon: "cross.circle.fill",
                            title: "NHS 111",
                            subtitle: "Call 111",
                            description: "Mental health advice and support",
                            color: .mintGreen,
                            action: { openURL(URL(string: "tel:111")!) }
                        )
                        
                        HelpContactCard(
                            icon: "phone.bubble.fill",
                            title: "Samaritans",
                            subtitle: "116 123",
                            description: "Free, 24/7 confidential support",
                            color: .forestGreen,
                            action: { openURL(URL(string: "tel:116123")!) }
                        )
                        
                        HelpContactCard(
                            icon: "message.fill",
                            title: "Shout Crisis Text Line",
                            subtitle: "Text SHOUT to 85258",
                            description: "Free, confidential text support",
                            color: .lavenderMist,
                            action: { openURL(URL(string: "sms:85258&body=SHOUT")!) }
                        )
                    }
                    .padding(.horizontal, 20)
                    
                    // NHS Website Link
                    Button(action: {
                        if let url = URL(string: "https://www.nhs.uk/nhs-services/mental-health-services/where-to-get-urgent-help-for-mental-health/") {
                            openURL(url)
                        }
                    }) {
                        HStack {
                            Image(systemName: "safari")
                            Text("More NHS mental health resources")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.bodyMedium)
                        .foregroundColor(.tealAccent)
                        .padding(16)
                        .cardStyle()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    
                    Spacer(minLength: 40)
                }
            }
            .background(AnimatedGradientBackground())
            .navigationTitle("Need Help?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(.tealAccent)
                }
            }
        }
    }
}

struct HelpContactCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
    let color: Color
    var isEmergency: Bool = false
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(color.opacity(isEmergency ? 0.2 : 0.15))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(color)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text(subtitle)
                        .font(.bodyMedium)
                        .fontWeight(.medium)
                        .foregroundColor(color)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: icon == "message.fill" ? "bubble.right.fill" : "phone.arrow.up.right")
                    .font(.body)
                    .foregroundColor(color)
            }
            .padding(16)
            .cardStyle()
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isEmergency ? color.opacity(0.5) : Color.clear, lineWidth: isEmergency ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HelpView()
}

