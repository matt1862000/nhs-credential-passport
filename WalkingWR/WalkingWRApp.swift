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
                // v1.7.13: Cancel walk notifications when app goes to background
                // Only if there's no active walk (user just closed the app without ending walk)
                print("📱 App entering background")
                cancelWalkNotificationsIfNoActiveWalk()
            }
        }
    }
    
    /// Cancel walk notifications if no active walk (called when going to background)
    private func cancelWalkNotificationsIfNoActiveWalk() {
        // Check the flag - ViewModel sets this to true when walk is active
        let hasActiveWalk = UserDefaults.standard.bool(forKey: "hasActiveWalk")
        
        if !hasActiveWalk {
            print("📱 No active walk - cancelling walk notifications (keeping delay notifications)")
            NotificationService.shared.cancelAllWalkingNotifications()
        } else {
            print("📱 Active walk detected - keeping walk notifications")
        }
    }
}
