//
//  FirebaseMessagingHelper.swift
//  WalkingWR
//
//  Helper to safely perform FCM operations after APNS token is ready
//

import Foundation
import FirebaseMessaging

extension Messaging {
    /// Check if APNS token is available for FCM operations
    static var isAPNSTokenReady: Bool {
        return Messaging.messaging().apnsToken != nil
    }
    
    /// Safely subscribe to a topic, waiting for APNS token if needed
    /// - Parameters:
    ///   - topic: The topic to subscribe to
    ///   - maxRetries: Maximum number of retries if APNS token isn't ready
    ///   - retryDelay: Delay between retries in seconds
    ///   - completion: Completion handler with optional error
    static func safeSubscribe(
        toTopic topic: String,
        maxRetries: Int = 5,
        retryDelay: TimeInterval = 0.5,
        completion: @escaping (Error?) -> Void
    ) {
        // If APNS token is ready, subscribe immediately
        if isAPNSTokenReady {
            Messaging.messaging().subscribe(toTopic: topic, completion: completion)
            return
        }
        
        // Otherwise, wait for APNS token and retry
        print("⏳ APNS token not ready - waiting before subscribing to: \(topic)")
        
        var retryCount = 0
        let retryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: true) { timer in
            retryCount += 1
            
            if isAPNSTokenReady {
                timer.invalidate()
                print("✅ APNS token ready - subscribing to: \(topic)")
                Messaging.messaging().subscribe(toTopic: topic, completion: completion)
            } else if retryCount >= maxRetries {
                timer.invalidate()
                let error = NSError(
                    domain: "FirebaseMessagingHelper",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "APNS token not available after \(maxRetries) retries"]
                )
                print("❌ Failed to subscribe to \(topic): APNS token not ready after \(maxRetries) retries")
                completion(error)
            } else {
                print("⏳ Retry \(retryCount)/\(maxRetries) - waiting for APNS token...")
            }
        }
        
        // Also listen for APNS token ready notification
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("APNSTokenReady"),
            object: nil,
            queue: .main
        ) { _ in
            retryTimer.invalidate()
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
            }
            
            if isAPNSTokenReady {
                print("✅ APNS token ready (via notification) - subscribing to: \(topic)")
                Messaging.messaging().subscribe(toTopic: topic, completion: completion)
            } else {
                // Still not ready, continue with timer-based retries
                print("⚠️ APNS token notification received but token still not set")
            }
        }
    }
    
    /// Safely unsubscribe from a topic, waiting for APNS token if needed
    /// - Parameters:
    ///   - topic: The topic to unsubscribe from
    ///   - maxRetries: Maximum number of retries if APNS token isn't ready
    ///   - retryDelay: Delay between retries in seconds
    ///   - completion: Completion handler with optional error
    static func safeUnsubscribe(
        fromTopic topic: String,
        maxRetries: Int = 5,
        retryDelay: TimeInterval = 0.5,
        completion: @escaping (Error?) -> Void
    ) {
        // If APNS token is ready, unsubscribe immediately
        if isAPNSTokenReady {
            Messaging.messaging().unsubscribe(fromTopic: topic, completion: completion)
            return
        }
        
        // Otherwise, wait for APNS token and retry
        print("⏳ APNS token not ready - waiting before unsubscribing from: \(topic)")
        
        var retryCount = 0
        let retryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: true) { timer in
            retryCount += 1
            
            if isAPNSTokenReady {
                timer.invalidate()
                print("✅ APNS token ready - unsubscribing from: \(topic)")
                Messaging.messaging().unsubscribe(fromTopic: topic, completion: completion)
            } else if retryCount >= maxRetries {
                timer.invalidate()
                let error = NSError(
                    domain: "FirebaseMessagingHelper",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "APNS token not available after \(maxRetries) retries"]
                )
                print("❌ Failed to unsubscribe from \(topic): APNS token not ready after \(maxRetries) retries")
                completion(error)
            } else {
                print("⏳ Retry \(retryCount)/\(maxRetries) - waiting for APNS token...")
            }
        }
        
        // Also listen for APNS token ready notification
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("APNSTokenReady"),
            object: nil,
            queue: .main
        ) { _ in
            retryTimer.invalidate()
            if let observer = observer {
                NotificationCenter.default.removeObserver(observer)
            }
            
            if isAPNSTokenReady {
                print("✅ APNS token ready (via notification) - unsubscribing from: \(topic)")
                Messaging.messaging().unsubscribe(fromTopic: topic, completion: completion)
            } else {
                // Still not ready, continue with timer-based retries
                print("⚠️ APNS token notification received but token still not set")
            }
        }
    }
}
