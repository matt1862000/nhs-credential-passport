//
//  SplashScreenView.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 08/12/2025.
//

import SwiftUI

struct SplashScreenView: View {
    // Create ViewModel early so data starts loading immediately
    @StateObject private var viewModel = WaitingRoomViewModel()
    
    @State private var minimumTimeElapsed = false
    @State private var logoOpacity = 0.0
    @State private var improvingLivesOpacity = 0.0
    @State private var scaleEffect = 0.9
    
    // Show main app only when BOTH conditions are met:
    // 1. Minimum splash time has passed (for animations)
    // 2. Data is ready (clinician restored or confirmed no saved clinician)
    private var shouldShowMainApp: Bool {
        minimumTimeElapsed && viewModel.isDataReady
    }
    
    var body: some View {
        if shouldShowMainApp {
            MainTabView(viewModel: viewModel)
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
                
                // Set minimum time elapsed after 2.5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        minimumTimeElapsed = true
                    }
                }
            }
            // Also watch for data ready changes to trigger transition
            .onChange(of: viewModel.isDataReady) { _, isReady in
                if isReady && minimumTimeElapsed {
                    // Both conditions met - will transition via shouldShowMainApp
                    print("✅ Data ready + minimum time elapsed - transitioning to main app")
                }
            }
        }
    }
}

#Preview {
    SplashScreenView()
}

