//
//  AppTheme.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI

// MARK: - Theme Setting
enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - Custom Colors
extension Color {
    // Primary palette - Calming healthcare with warmth
    static let nhsBlue = Color(red: 0.0, green: 0.37, blue: 0.58)
    static let nhsDarkBlue = Color(red: 0.0, green: 0.19, blue: 0.38)
    
    // Custom accent colors (these work well in both modes)
    static let tealAccent = Color(red: 0.18, green: 0.64, blue: 0.64)
    static let mintGreen = Color(red: 0.56, green: 0.82, blue: 0.73)
    static let forestGreen = Color(red: 0.20, green: 0.47, blue: 0.35)
    static let softAmber = Color(red: 0.95, green: 0.77, blue: 0.42)
    static let coralPink = Color(red: 0.95, green: 0.55, blue: 0.55)
    static let lavenderMist = Color(red: 0.73, green: 0.68, blue: 0.87)
    
    // Backgrounds - Light mode
    static let warmCream = Color(red: 0.99, green: 0.97, blue: 0.94)
    static let softGray = Color(red: 0.96, green: 0.96, blue: 0.97)
    
    // Text colors
    static let deepNavy = Color(red: 0.08, green: 0.11, blue: 0.18)
    
    // Gradients - Light mode
    static let calmGradientStart = Color(red: 0.93, green: 0.97, blue: 0.98)
    static let calmGradientEnd = Color(red: 0.85, green: 0.93, blue: 0.95)
    
    // Dark mode variants
    static let darkBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let darkCardBackground = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let darkGradientStart = Color(red: 0.12, green: 0.14, blue: 0.18)
    static let darkGradientEnd = Color(red: 0.08, green: 0.10, blue: 0.14)
}

// MARK: - Adaptive Colors
extension Color {
    static func adaptiveBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .darkBackground : .calmGradientStart
    }
    
    static func adaptiveCardBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .darkCardBackground : .white
    }
    
    static func adaptiveText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .deepNavy
    }
    
    static func adaptiveSecondaryText(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.7) : .deepNavy.opacity(0.7)
    }
}

// MARK: - Custom Fonts (renamed to avoid conflicts)
extension Font {
    static let appDisplayLarge = Font.system(size: 48, weight: .bold, design: .rounded)
    static let appDisplayMedium = Font.system(size: 32, weight: .semibold, design: .rounded)
    static let appTitleLarge = Font.system(size: 24, weight: .semibold, design: .rounded)
    static let appTitleMedium = Font.system(size: 20, weight: .medium, design: .rounded)
    static let appBodyLarge = Font.system(size: 17, weight: .regular, design: .rounded)
    static let appBodyMedium = Font.system(size: 15, weight: .regular, design: .rounded)
    static let appCaption = Font.system(size: 13, weight: .medium, design: .rounded)
    static let appMicro = Font.system(size: 11, weight: .medium, design: .rounded)
    
    // Convenience aliases that match what's used in views
    static var displayLarge: Font { appDisplayLarge }
    static var displayMedium: Font { appDisplayMedium }
    static var titleLarge: Font { appTitleLarge }
    static var titleMedium: Font { appTitleMedium }
    static var bodyLarge: Font { appBodyLarge }
    static var bodyMedium: Font { appBodyMedium }
    static var micro: Font { appMicro }
}

// MARK: - View Modifiers
struct CardStyle: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var cornerRadius: CGFloat = 20
    var shadowRadius: CGFloat = 8
    
    func body(content: Content) -> some View {
        content
            .background(colorScheme == .dark ? Color.darkCardBackground : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: shadowRadius, x: 0, y: 4)
    }
}

struct GlassCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 5)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .tealAccent
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appTitleMedium)
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(color)
                    .shadow(color: color.opacity(0.4), radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 2 : 4)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = .tealAccent
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appBodyLarge)
            .fontWeight(.medium)
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(color, lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = 20) -> some View {
        modifier(CardStyle(cornerRadius: cornerRadius))
    }
    
    func glassCard() -> some View {
        modifier(GlassCardStyle())
    }
}

// MARK: - Animated Background
struct AnimatedGradientBackground: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark ? [
                Color.darkGradientStart,
                Color.darkGradientEnd,
                Color.tealAccent.opacity(0.1)
            ] : [
                Color.calmGradientStart,
                Color.calmGradientEnd,
                Color.mintGreen.opacity(0.2)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}


// MARK: - Loading Animation
struct PulsingDot: View {
    @State private var scale: CGFloat = 1.0
    let color: Color
    let delay: Double
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .animation(
                .easeInOut(duration: 0.6)
                .repeatForever(autoreverses: true)
                .delay(delay),
                value: scale
            )
            .onAppear {
                scale = 1.4
            }
    }
}

struct LoadingDots: View {
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            PulsingDot(color: color, delay: 0)
            PulsingDot(color: color, delay: 0.2)
            PulsingDot(color: color, delay: 0.4)
        }
    }
}
