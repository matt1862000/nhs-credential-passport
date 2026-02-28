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
    
    /// Tracks whether we've already tried to dismiss stale walk Live Activity this launch (so we don't end one the user just started).
    private static var hasTriedEndingStaleWalkActivity = false
    
    var selectedTheme: AppTheme {
        AppTheme(rawValue: appTheme) ?? .system
    }
    
    init() {
        // Firebase is configured in AppDelegate
        
        // Configure tab bar
        UITabBar.appearance().unselectedItemTintColor = .darkGray
        
        // v1.9.80: Detect if app crashed during a walk
        let hadActiveWalk = UserDefaults.standard.bool(forKey: "hasActiveWalk")
        if hadActiveWalk {
            // Log crash detection immediately (before clearing flag)
            DebugLogger.shared.log("💥💥💥 APP CRASHED DURING WALK 💥💥💥", category: "WALK_LIFECYCLE")
            DebugLogger.shared.log("⚠️ Previous walk session was not properly ended - app likely crashed", category: "WALK_LIFECYCLE")
            DebugLogger.shared.log("🔄 App relaunched - previous walk session terminated", category: "WALK_LIFECYCLE")
        }
        
        // v1.7.13: ALWAYS cancel stale walk notifications on launch
        // This handles force-close scenario where hasActiveWalk flag is stale
        // Only cancels walk-specific notifications, preserves delay notifications
        DispatchQueue.main.async {
            NotificationService.shared.cancelStaleWalkNotifications()
            // Also reset the active walk flag since no walk survives a force-close
            UserDefaults.standard.set(false, forKey: "hasActiveWalk")
            // Clear persisted pill state so next walk starts with fresh pill (no stale 77 from crashed session)
            WaitingRoomViewModel.clearPersistedPillState()
            // Dismiss the walk Live Activity (Dynamic Island / Lock Screen) so user doesn't see a frozen "walk in progress" after force-close.
            // Activity.activities can be empty immediately at launch; delay so the system has time to restore the list.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                WalkLiveActivityBridge.endIfAvailable()
            }
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
                WaitingRoomViewModel.clearPersistedPillState()
            } else if newPhase == .active, !Self.hasTriedEndingStaleWalkActivity {
                // First time becoming active this launch: dismiss any stale walk Live Activity
                // (e.g. from force-close). Activity.activities may only be populated once scene is active.
                Self.hasTriedEndingStaleWalkActivity = true
                WalkLiveActivityBridge.endIfAvailable()
            }
        }
    }
}
