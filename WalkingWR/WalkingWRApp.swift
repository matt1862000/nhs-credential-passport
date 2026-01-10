//
//  WalkingWRApp.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import SwiftUI
import FirebaseCore
import FirebaseMessaging
import UserNotifications

@main
struct WalkingWRApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    
    var selectedTheme: AppTheme {
        AppTheme(rawValue: appTheme) ?? .system
    }
    
    init() {
        // Firebase is configured in AppDelegate
        
        // Configure tab bar
        UITabBar.appearance().unselectedItemTintColor = .darkGray
        
        // v1.7.13: ALWAYS cancel stale walk notifications on launch
        // This handles force-close scenario where hasActiveWalk flag is stale
        // Only cancels walk-specific notifications, preserves delay notifications
        DispatchQueue.main.async {
            NotificationService.shared.cancelStaleWalkNotifications()
            // Also reset the active walk flag since no walk survives a force-close
            UserDefaults.standard.set(false, forKey: "hasActiveWalk")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(selectedTheme.colorScheme)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                // v1.7.14: ALWAYS cancel timed walk notifications when going to background
                // If user force-closes during a walk, we can't track progress anyway
                // If they return, notifications will be rescheduled
                print("📱 App entering background - cancelling timed walk notifications")
                NotificationService.shared.cancelAllWalkingNotifications()
                
                // Also clear the active walk flag since the walk can't continue
                // without the app running
                UserDefaults.standard.set(false, forKey: "hasActiveWalk")
            }
        }
    }
}
