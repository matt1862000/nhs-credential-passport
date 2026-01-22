import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {
    
    // Notification action identifiers (must match NotificationService)
    static let delayNotificationCategory = "DELAY_NOTIFICATION"  // Updated to match NotificationService
    static let stopNotificationsAction = "STOP_NOTIFICATIONS"
    static let viewDetailsAction = "VIEW_DETAILS"
    
    // Store pending notification for cold launch
    static var pendingNotification: [String: String]? = nil
    // Flag to suppress in-app alerts when coming from push
    static var suppressInAppAlertsFlag: Bool = false
    // Flag to suppress walk alerts (halfway/return) when coming from walk push notification
    static var cameFromWalkNotification: Bool = false
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Configure Firebase FIRST
        FirebaseApp.configure()
        
        // Set messaging delegate
        Messaging.messaging().delegate = self
        
        // Register notification categories with actions
        registerNotificationCategories()
        
        // Set delegate for handling notifications (but don't request permission yet)
        // Permission will be requested after splash/onboarding screen
        UNUserNotificationCenter.current().delegate = self
        
        // Register for remote notifications (this is safe even before permission is granted)
        DispatchQueue.main.async {
            application.registerForRemoteNotifications()
        }
        
        return true
    }
    
    private func registerNotificationCategories() {
        // v1.7.4: Categories are now registered in NotificationService.registerNotificationCategories()
        // which includes "Stop Notifications" action on ALL notification types.
        // This avoids the issue where setNotificationCategories() would overwrite each other.
        // The action handlers are still processed here in userNotificationCenter(didReceive:)
        print("📱 Notification categories will be registered by NotificationService")
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 APNs Token received: \(tokenString.prefix(20))...")
        Messaging.messaging().apnsToken = deviceToken
        print("📱 APNs Token set on Messaging - ready for FCM")
        
        // Post notification so other parts of the app can retry FCM operations
        NotificationCenter.default.post(name: Notification.Name("APNSTokenReady"), object: nil)
        print("📱 Posted APNSTokenReady notification - FCM operations can now proceed")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error.localizedDescription)")
    }
    
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("🔥 FCM Token: \(fcmToken ?? "none")")
        
        // Verify token is valid
        if let token = fcmToken {
            print("🔥 FCM Token length: \(token.count) characters")
            print("🔥 FCM Token (first 20 chars): \(String(token.prefix(20)))...")
        } else {
            print("❌ WARNING: FCM Token is nil - push notifications will not work!")
        }
    }
    
    // Handle incoming remote notification
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("📬 Received remote notification: \(userInfo)")
        completionHandler(.newData)
    }
    
    // When app is in foreground, don't show banner - the in-app alert handles it
    // Banners only show when app is in background/closed
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Don't show banner when app is open - in-app alerts handle this
        completionHandler([])
    }
    
    // Handle notification action responses
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        
        print("📱 Notification action: \(actionIdentifier)")
        print("📱 Notification category: \(categoryIdentifier)")
        print("📱 Notification data: \(userInfo)")
        
        // Only handle delay notifications with OK/Stop dialog
        // Walking notifications (halfway, return, etc.) just open the app
        let isDelayNotification = categoryIdentifier == AppDelegate.delayNotificationCategory ||
                                   categoryIdentifier.isEmpty // FCM push notifications may not have category set
        
        // Check if this is a walk notification (halfway, return, marker arrival, etc.)
        let isWalkNotification = categoryIdentifier == "WALKING_ALERT" || 
                                  categoryIdentifier == "RETURN_ALERT"
        
        switch actionIdentifier {
        case AppDelegate.stopNotificationsAction:
            // User tapped "Stop Notifications"
            handleStopNotifications(userInfo: userInfo)
            
        case AppDelegate.viewDetailsAction, UNNotificationDefaultActionIdentifier:
            // User tapped "View Details" or tapped the notification itself
            
            // If this is a walk notification, set flag to suppress in-app duplicate alerts
            if isWalkNotification {
                AppDelegate.cameFromWalkNotification = true
                print("📱 Walk notification tapped (\(categoryIdentifier)) - suppressing in-app walk alerts")
                
                // Post notification to reset any already-shown alerts
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("ResetWalkAlerts"),
                        object: nil
                    )
                }
                
                // Reset the flag after a short delay (so the app has time to check it)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    AppDelegate.cameFromWalkNotification = false
                }
                
                completionHandler()
                return
            }
            
            // Only show delay dialog for delay-related notifications
            guard isDelayNotification else {
                print("📱 Non-delay notification tapped (\(categoryIdentifier)) - just opening app")
                completionHandler()
                return
            }
            
            // Post notification so app can show dialog with OK/Stop options
            print("📱 User tapped delay notification - showing dialog")
            
            let title = response.notification.request.content.title
            let body = response.notification.request.content.body
            let topic = userInfo["topic"] as? String ?? ""
            
            // Immediately suppress in-app alerts
            AppDelegate.suppressInAppAlertsFlag = true
            
            let notificationData = [
                "title": title,
                "body": body,
                "topic": topic
            ]
            
            // Store for pending check - this is the single source of truth
            AppDelegate.pendingNotification = notificationData
            print("📱 Stored pending notification: \(title), suppressing in-app alerts")
            
        case UNNotificationDismissActionIdentifier:
            // User dismissed the notification
            print("📱 User dismissed notification")
            
        default:
            break
        }
        
        completionHandler()
    }
    
    private func handleStopNotifications(userInfo: [AnyHashable: Any]) {
        // Check if this is a clinician/delay notification (has topic)
        if let topic = userInfo["topic"] as? String {
            // Unsubscribe from this clinician's FCM topic
            print("🔕 Unsubscribing from clinician topic: \(topic)")
            
            Messaging.messaging().unsubscribe(fromTopic: topic) { error in
                if let error = error {
                    print("❌ Failed to unsubscribe: \(error.localizedDescription)")
                } else {
                    print("✅ Successfully unsubscribed from \(topic)")
                    
                    // Post notification so UI can update if app is open
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: Notification.Name("NotificationsDisabled"),
                            object: nil,
                            userInfo: ["topic": topic]
                        )
                    }
                }
            }
        } else {
            // This is a walking notification (no topic) - cancel all pending walk notifications
            print("🔕 Walking notification - cancelling all pending walk notifications")
            
            // v1.7.8: Do all operations async to prevent blocking the notification handler
            DispatchQueue.global(qos: .utility).async {
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                
                // Also clear the active walk flag so no more are scheduled
                UserDefaults.standard.set(false, forKey: "hasActiveWalk")
                
                // Post notification so ViewModel knows to stop the walk
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("WalkNotificationsStopped"),
                        object: nil
                    )
                }
                print("✅ Walk notifications stopped")
            }
        }
    }
}
