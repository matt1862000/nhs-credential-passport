//
//  NotificationService.swift
//  WalkingWR
//
//  Created by Raihan Talukdar on 07/12/2025.
//

import Foundation
import UserNotifications
import Combine

class NotificationService: ObservableObject {
    static let shared = NotificationService()
    
    @Published var isAuthorized: Bool = false
    
    private init() {
        checkAuthorization()
        registerNotificationCategories()
    }
    
    func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }
    
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge, .criticalAlert]
            )
            await MainActor.run {
                self.isAuthorized = granted
            }
            return granted
        } catch {
            return false
        }
    }
    
    private func registerNotificationCategories() {
        // Walking alert actions
        let openMapAction = UNNotificationAction(
            identifier: "OPEN_MAP",
            title: "Open Map",
            options: .foreground
        )
        
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: .destructive
        )
        
        // Categories
        let walkingCategory = UNNotificationCategory(
            identifier: "WALKING_ALERT",
            actions: [openMapAction, dismissAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        let returnCategory = UNNotificationCategory(
            identifier: "RETURN_ALERT",
            actions: [openMapAction],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        let clinicianCategory = UNNotificationCategory(
            identifier: "CLINICIAN_READY",
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([
            walkingCategory,
            returnCategory,
            clinicianCategory
        ])
    }
    
    // MARK: - Walking Notifications
    
    func sendWalkStartedNotification(routeName: String, duration: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Walk Started! 🚶‍♂️"
        content.body = "You're walking the \(routeName) route. We'll notify you when it's time to head back."
        content.sound = .default
        content.categoryIdentifier = "WALKING_ALERT"
        
        // Small delay so it shows as a proper notification
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(
            identifier: "walk-started-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func scheduleHalfwayNotification(in seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Halfway Point! 🚶"
        content.body = "Time to consider heading back to the clinic. Check the app for your current wait time."
        content.sound = .default
        content.categoryIdentifier = "WALKING_ALERT"
        content.interruptionLevel = .timeSensitive
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(
            identifier: "halfway-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func scheduleReturnNowNotification(in seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Return Now 🏥"
        content.body = "Please consider heading back to the waiting area. Check the app for your current wait time."
        content.sound = .defaultCritical
        content.categoryIdentifier = "RETURN_ALERT"
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(
            identifier: "return-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func scheduleClinicianReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Clinician Ready! ✨"
        content.body = "Your clinician is ready to see you now. Please return to reception."
        content.sound = .defaultCritical
        content.categoryIdentifier = "CLINICIAN_READY"
        
        let request = UNNotificationRequest(
            identifier: "clinician-ready-\(UUID().uuidString)",
            content: content,
            trigger: nil // Immediate
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func sendMarkerArrivalNotification(markerName: String) {
        let content = UNMutableNotificationContent()
        content.title = "📍 You've arrived!"
        content.body = "You're at \(markerName). Take a moment to capture nature around you!"
        content.sound = .default
        content.categoryIdentifier = "WALKING_ALERT"
        
        // Immediate notification
        let request = UNNotificationRequest(
            identifier: "marker-arrival-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Walking Direction Notifications
    
    /// Send a direction notification when approaching a turn
    func sendDirectionNotification(instruction: String, distance: String, stepNumber: Int, totalSteps: Int) {
        let content = UNMutableNotificationContent()
        content.title = "🧭 Next: \(getDirectionEmoji(from: instruction))"
        content.body = instruction
        content.subtitle = "\(distance) • Step \(stepNumber) of \(totalSteps)"
        content.sound = .default
        content.categoryIdentifier = "WALKING_ALERT"
        content.interruptionLevel = .timeSensitive
        
        // Immediate notification
        let request = UNNotificationRequest(
            identifier: "direction-\(stepNumber)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Get an appropriate emoji for the direction type
    private func getDirectionEmoji(from instruction: String) -> String {
        let lowercased = instruction.lowercased()
        
        if lowercased.contains("left") {
            return "↰ Turn Left"
        } else if lowercased.contains("right") {
            return "↱ Turn Right"
        } else if lowercased.contains("straight") || lowercased.contains("continue") {
            return "↑ Continue"
        } else if lowercased.contains("destination") || lowercased.contains("arrive") {
            return "📍 Arriving"
        } else if lowercased.contains("roundabout") {
            return "🔄 Roundabout"
        } else {
            return "👣 Walking"
        }
    }
    
    /// Cancel all direction notifications
    func cancelDirectionNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let directionIds = requests
                .filter { $0.identifier.starts(with: "direction-") }
                .map { $0.identifier }
            center.removePendingNotificationRequests(withIdentifiers: directionIds)
        }
    }
    
    func scheduleDelayUpdateNotification(newWaitMinutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Wait Time Updated"
        content.body = "Your estimated wait is now \(newWaitMinutes) minutes. We'll keep you updated."
        content.sound = .default
        content.categoryIdentifier = "DELAY_UPDATE"
        
        let request = UNNotificationRequest(
            identifier: "delay-update-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func sendWaitTimeIncreasedNotification(oldMinutes: Int, newMinutes: Int, isWalking: Bool) {
        let increase = newMinutes - oldMinutes
        let content = UNMutableNotificationContent()
        content.title = "Clinic Delay Updated ⏰"
        
        // Focus on the change - patient may have arrived early so delay ≠ total wait
        content.body = "The clinic delay has increased by \(increase) minutes (now \(newMinutes) min delay). We apologise for any inconvenience. Feel free to explore our wellbeing activities while you wait."
        
        content.sound = .default
        content.categoryIdentifier = "DELAY_UPDATE"
        content.interruptionLevel = .timeSensitive
        
        let request = UNNotificationRequest(
            identifier: "wait-increased-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func sendWaitTimeDecreasedNotification(oldMinutes: Int, newMinutes: Int, isWalking: Bool) {
        let decrease = oldMinutes - newMinutes
        let content = UNMutableNotificationContent()
        content.title = "Good News! 🎉"
        
        // Focus on the change - patient may have arrived early so delay ≠ total wait
        if newMinutes == 0 {
            content.body = "The clinic is now running on time. Please check in with reception when you're ready for your appointment."
        } else if newMinutes <= 5 {
            content.body = "The clinic delay has reduced to just \(newMinutes) minutes. The clinic is nearly back on schedule."
        } else {
            content.body = "The clinic delay has reduced by \(decrease) minutes (now \(newMinutes) min delay). We'll keep you updated."
        }
        
        content.sound = .default
        content.categoryIdentifier = "DELAY_UPDATE"
        content.interruptionLevel = .timeSensitive
        
        let request = UNNotificationRequest(
            identifier: "wait-decreased-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Encouragement Notifications
    
    func scheduleEncouragementNotification(message: String, in seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Keep Going! 💪"
        content.body = message
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(
            identifier: "encouragement-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func cancelAllWalkingNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
    }
    
    func cancelNotification(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
    }
}


