//
//  WalkingWRApp.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import FirebaseCore
import FirebaseMessaging

@main
struct WalkingWRApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue
    
    var selectedTheme: AppTheme {
        AppTheme(rawValue: appTheme) ?? .system
    }
    
    init() {
        // Initialize Firebase
        FirebaseApp.configure()
        
        // Configure tab bar
        UITabBar.appearance().unselectedItemTintColor = .darkGray
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(selectedTheme.colorScheme)
        }
    }
}
