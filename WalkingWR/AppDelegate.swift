import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {
    
    // Notification category identifier
    static let delayNotificationCategory = "DELAY_UPDATE"
    static let stopNotificationsAction = "STOP_NOTIFICATIONS"
    static let viewDetailsAction = "VIEW_DETAILS"
    
    // Store pending notification for cold launch
    static var pendingNotification: [String: String]? = nil
    // Flag to suppress in-app alerts when coming from push
    static var suppressInAppAlertsFlag: Bool = false
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Configure Firebase FIRST
        FirebaseApp.configure()
        
        // Set messaging delegate
        Messaging.messaging().delegate = self
        
        // Register notification categories with actions
        registerNotificationCategories()
        
        // Request notification permissions
        UNUserNotificationCenter.current().delegate = self
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(options: authOptions) { granted, error in
            print("📱 Notification permission granted: \(granted)")
            if let error = error {
                print("📱 Notification permission error: \(error)")
            }
        }
        
        // Register for remote notifications
        DispatchQueue.main.async {
            application.registerForRemoteNotifications()
        }
        
        return true
    }
    
    private func registerNotificationCategories() {
        // "Stop Notifications" action - doesn't open app, runs in background
        let stopAction = UNNotificationAction(
            identifier: AppDelegate.stopNotificationsAction,
            title: "Stop Notifications",
            options: [.destructive]  // Shows in red
        )
        
        // "View Details" action - opens app
        let viewAction = UNNotificationAction(
            identifier: AppDelegate.viewDetailsAction,
            title: "View Details",
            options: [.foreground]  // Opens the app
        )
        
        // Create category with both actions
        let delayCategory = UNNotificationCategory(
            identifier: AppDelegate.delayNotificationCategory,
            actions: [viewAction, stopAction],
            intentIdentifiers: [],
            options: []
        )
        
        // Register the category
        UNUserNotificationCenter.current().setNotificationCategories([delayCategory])
        print("📱 Registered notification categories with actions")
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 APNs Token received: \(tokenString)")
        Messaging.messaging().apnsToken = deviceToken
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error.localizedDescription)")
    }
    
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("🔥 FCM Token: \(fcmToken ?? "none")")
        
        // Verify token is valid
        if let token = fcmToken {
            print("🔥 FCM Token length: \(token.count) characters")
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
        
        print("📱 Notification action: \(actionIdentifier)")
        print("📱 Notification data: \(userInfo)")
        
        switch actionIdentifier {
        case AppDelegate.stopNotificationsAction:
            // User tapped "Stop Notifications"
            handleStopNotifications(userInfo: userInfo)
            
        case AppDelegate.viewDetailsAction, UNNotificationDefaultActionIdentifier:
            // User tapped "View Details" or tapped the notification itself
            // Post notification so app can show dialog with OK/Stop options
            print("📱 User tapped notification - showing dialog")
            
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
        // Extract clinician topic from notification data
        if let topic = userInfo["topic"] as? String {
            print("🔕 Unsubscribing from topic: \(topic)")
            
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
            // Fallback: unsubscribe from all clinician topics
            print("🔕 No topic in notification, cannot unsubscribe specific clinician")
        }
    }
}
