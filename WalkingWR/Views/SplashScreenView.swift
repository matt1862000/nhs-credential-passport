//
//  SplashScreenView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 08/12/2025.
//

import SwiftUI

struct SplashScreenView: View {
    @State private var isActive = false
    @State private var logoOpacity = 0.0
    @State private var improvingLivesOpacity = 0.0
    @State private var scaleEffect = 0.9
    
    var body: some View {
        if isActive {
            MainTabView()
        } else {
            ZStack {
                // NHS Blue background
                Color(red: 0.85, green: 0.91, blue: 0.96)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    Spacer()
                    
                    // NHS Trust Logo (full logo as single image)
                    Image("NHSLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320)
                        .opacity(logoOpacity)
                        .scaleEffect(scaleEffect)
                    
                    Spacer()
                    
                    // Improving Lives Logo (full logo with text as single image)
                    Image("ImprovingLivesLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 140)
                        .opacity(improvingLivesOpacity)
                        .padding(.bottom, 60)
                }
                .padding(.horizontal, 30)
            }
            .onAppear {
                // Animate logos appearing
                withAnimation(.easeOut(duration: 0.8)) {
                    logoOpacity = 1.0
                    scaleEffect = 1.0
                }
                
                withAnimation(.easeOut(duration: 0.8).delay(0.4)) {
                    improvingLivesOpacity = 1.0
                }
                
                // Transition to main app after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        isActive = true
                    }
                }
            }
        }
    }
}

#Preview {
    SplashScreenView()
}

