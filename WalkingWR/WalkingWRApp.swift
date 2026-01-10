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
        
        // v1.7.8: Cancel orphaned walk notifications ASYNC to avoid blocking init
        // This handles the case where app was force-closed during a walk
        DispatchQueue.main.async {
            Self.cancelOrphanedWalkNotifications()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(selectedTheme.colorScheme)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                // v1.7.5: Cancel walk notifications when app goes to background
                // This prevents "halfway" notifications firing after user closed the app
                print("📱 App entering background - cancelling walk notifications")
                cancelWalkNotificationsIfNoActiveWalk()
            }
        }
    }
    
    /// Cancel orphaned walk notifications on app launch
    private static func cancelOrphanedWalkNotifications() {
        // Check if there's an active walk by looking at UserDefaults flag
        let hasActiveWalk = UserDefaults.standard.bool(forKey: "hasActiveWalk")
        
        if !hasActiveWalk {
            print("📱 No active walk on launch - cancelling any orphaned walk notifications")
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
    }
    
    /// Cancel walk notifications if no active walk (called when going to background)
    private func cancelWalkNotificationsIfNoActiveWalk() {
        // Post notification so ViewModel can check and set the flag
        NotificationCenter.default.post(name: Notification.Name("CheckActiveWalkForBackground"), object: nil)
        
        // Give the ViewModel a moment to respond, then check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasActiveWalk = UserDefaults.standard.bool(forKey: "hasActiveWalk")
            if !hasActiveWalk {
                print("📱 No active walk - cancelling pending walk notifications")
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            } else {
                print("📱 Active walk detected - keeping walk notifications")
            }
        }
    }
}
