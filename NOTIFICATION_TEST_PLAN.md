# WalkingWR Notification Test Plan

## Test Environment Setup
- **Device**: Real iOS device (push notifications don't work in simulator)
- **App State**: Test foreground, background, and killed states
- **Notification Permissions**: Ensure notifications are enabled in iOS Settings
- **Clinician**: Select a clinician and subscribe to delay notifications
- **Walk Duration**: Use a short walk (5-10 min) for faster testing

---

## 1. WALKING NOTIFICATIONS (50%, 80%, 100%)

### 1.1 In-App Walking Alerts (App in Foreground)

#### Test 1.1.1: Halfway Alert (50%) - All Alerts Enabled
- **Setup**: Start a walk, walking alerts enabled
- **Expected**: 
  - In-app alert appears at 50% progress: "Halfway Point!"
  - Alert auto-dismisses after 10 seconds
  - Alert has "Stop Alerts" (top) and "OK" (bottom) buttons
  - No push notification (app is foreground)

#### Test 1.1.2: Return Now Alert (80%) - All Alerts Enabled
- **Setup**: Start a walk, walking alerts enabled, pass 50% mark
- **Expected**:
  - In-app alert appears at 80% progress: "Time to Head Back"
  - Previous 50% alert is dismissed automatically
  - Alert auto-dismisses after 10 seconds
  - Alert has "Stop Alerts" (top) and "OK" (bottom) buttons

#### Test 1.1.3: Walk Complete Alert (100%) - All Alerts Enabled
- **Setup**: Start a walk, walking alerts enabled, pass 50% and 80% marks
- **Expected**:
  - In-app alert appears at 100% progress: "Walk Complete!"
  - Previous 50% and 80% alerts are dismissed automatically
  - Alert auto-dismisses after 10 seconds
  - Alert has ONLY "End & Save Progress" button (no "Stop Alerts")

#### Test 1.1.4: Walking Alerts Disabled - No In-App Alerts
- **Setup**: Start a walk, tap "Stop Alerts" from ActiveWalkCard or from 50% alert
- **Expected**:
  - No in-app alerts appear at 50%, 80%, or 100%
  - Console shows: "🔕 Halfway alert blocked - walkingAlertsEnabled = false"
  - Push notifications are also cancelled

#### Test 1.1.5: Auto-Dismiss Timer - Manual Dismissal
- **Setup**: Start a walk, 50% alert appears
- **Expected**:
  - Alert auto-dismisses after 10 seconds if not interacted with
  - If user taps "OK" or "Stop Alerts" before 10 seconds, timer is cancelled
  - If user taps "OK", timer is cancelled and alert dismisses immediately

#### Test 1.1.6: Alert Progression - Independent Checks
- **Setup**: Start a walk, don't dismiss 50% alert
- **Expected**:
  - When 80% alert appears, 50% alert is automatically dismissed
  - When 100% alert appears, both 50% and 80% alerts are dismissed
  - Each alert triggers independently based on progress

---

### 1.2 Push Walking Notifications (App in Background/Killed)

#### Test 1.2.1: Halfway Push Notification - App Backgrounded
- **Setup**: 
  - Start a walk
  - Background the app (home button/swipe up)
  - Wait for 50% progress
- **Expected**:
  - Push notification appears: "Halfway Point! 🚶"
  - Body: "You've completed half of your X-minute walk. Check the app for your clinic delay."
  - Notification has "Stop Notifications" action button
  - Tapping notification opens app
  - In-app alert does NOT appear (suppressed because came from push)

#### Test 1.2.2: Return Now Push Notification - App Backgrounded
- **Setup**: 
  - Start a walk, background app
  - Wait for 80% progress
- **Expected**:
  - Push notification: "Time to Head Back 🏥"
  - Body: "You've completed 80% of your X-minute walk. Consider heading back to the clinic."
  - Tapping opens app, no duplicate in-app alert

#### Test 1.2.3: Walk Complete Push Notification - App Backgrounded
- **Setup**: 
  - Start a walk, background app
  - Wait for 100% progress
- **Expected**:
  - Push notification: "Walk Complete! 🎉"
  - Body: "You've completed your X-minute walk. Great job!"
  - Tapping opens app, no duplicate in-app alert

#### Test 1.2.4: Walking Notifications - App Killed
- **Setup**: 
  - Start a walk
  - Force quit the app (swipe up in app switcher)
  - Wait for 50%, 80%, 100% progress
- **Expected**:
  - Push notifications still arrive (scheduled before app was killed)
  - Tapping notification launches app
  - App state is restored (walk session continues)

#### Test 1.2.5: "Stop Notifications" Action from Push
- **Setup**: 
  - Start a walk, background app
  - When push notification arrives, long-press and tap "Stop Notifications"
- **Expected**:
  - All pending walking notifications are cancelled
  - `walkingAlertsEnabled` is set to false
  - No further walking notifications arrive
  - Delay notifications are NOT affected (still work)

#### Test 1.2.6: Multiple Walking Notifications - Sequence
- **Setup**: 
  - Start a walk, background app
  - Wait for 50%, 80%, 100% to trigger
- **Expected**:
  - All three push notifications arrive in sequence
  - Each can be tapped independently
  - No duplicate notifications

---

## 2. DELAY CHANGE NOTIFICATIONS

### 2.1 In-App Delay Alerts (App in Foreground)

#### Test 2.1.1: Delay Increase - In-App Alert
- **Setup**: 
  - Select a clinician
  - App in foreground
  - Change clinician delay in Firebase (e.g., 10 → 15 min)
- **Expected**:
  - In-app alert appears: "Wait Time Increased"
  - Shows old delay and new delay
  - Alert has "View Details" and "Stop Notifications" buttons
  - Alert auto-dismisses after 10 seconds

#### Test 2.1.2: Delay Decrease - In-App Alert
- **Setup**: 
  - Select a clinician
  - App in foreground
  - Change clinician delay in Firebase (e.g., 15 → 5 min)
- **Expected**:
  - In-app alert appears: "Wait Time Decreased"
  - Shows old delay and new delay
  - Alert has "View Details" and "Stop Notifications" buttons

#### Test 2.1.3: Delay to Zero - In-App Alert
- **Setup**: 
  - Select a clinician with delay (e.g., 10 min)
  - App in foreground
  - Change clinician delay to 0 in Firebase
- **Expected**:
  - In-app alert: "The clinic is now running on time."
  - Alert appears correctly

#### Test 2.1.4: Delay Notifications Disabled - No In-App Alert
- **Setup**: 
  - Select a clinician
  - Tap "Stop Notifications" from a delay alert
  - Change clinician delay in Firebase
- **Expected**:
  - No in-app alert appears
  - Console shows: "🔕 Notifications disabled - skipping delay alert"
  - Data still updates (delay changes in UI)

#### Test 2.1.5: Multiple Delay Changes - Rapid Updates
- **Setup**: 
  - Select a clinician
  - App in foreground
  - Change delay multiple times quickly (e.g., 10 → 15 → 20 → 5)
- **Expected**:
  - Each change triggers a new in-app alert
  - Previous alerts are dismissed
  - Most recent delay is shown

---

### 2.2 Push Delay Notifications (App in Background/Killed)

#### Test 2.2.1: Delay Increase - Push Notification (Backgrounded)
- **Setup**: 
  - Select a clinician
  - Background the app
  - Change clinician delay in Firebase (e.g., 10 → 15 min)
- **Expected**:
  - Push notification arrives: "[Clinician]'s Clinic"
  - Body: "Delay increased by X min (now Y min). Thank you for your patience."
  - Notification has "View Details" and "Stop Notifications" action buttons
  - Badge count increases
  - High priority delivery (apns-priority: 10)

#### Test 2.2.2: Delay Decrease - Push Notification (Backgrounded)
- **Setup**: 
  - Select a clinician
  - Background the app
  - Change clinician delay in Firebase (e.g., 15 → 5 min)
- **Expected**:
  - Push notification: "Delay reduced to X min. Thank you for waiting."
  - Notification arrives promptly

#### Test 2.2.3: Delay to Zero - Push Notification (Backgrounded)
- **Setup**: 
  - Select a clinician with delay
  - Background the app
  - Change clinician delay to 0 in Firebase
- **Expected**:
  - Push notification: "The clinic is now running on time."
  - Notification arrives correctly

#### Test 2.2.4: Delay Notification - App Killed
- **Setup**: 
  - Select a clinician
  - Force quit the app
  - Change clinician delay in Firebase
- **Expected**:
  - Push notification arrives
  - Tapping notification launches app
  - In-app alert appears after app opens (from pending notification)
  - App state is restored

#### Test 2.2.5: "View Details" Action from Push
- **Setup**: 
  - Select a clinician
  - Background app
  - When push notification arrives, long-press and tap "View Details"
- **Expected**:
  - App opens
  - In-app alert appears showing delay change details
  - No duplicate alert (suppressed flag prevents duplicate)

#### Test 2.2.6: "Stop Notifications" Action from Push
- **Setup**: 
  - Select a clinician
  - Background app
  - When push notification arrives, long-press and tap "Stop Notifications"
- **Expected**:
  - App opens
  - User is unsubscribed from clinician's FCM topic
  - No further delay notifications for this clinician
  - Walking notifications are NOT affected (still work)

#### Test 2.2.7: Cold Launch from Delay Push Notification
- **Setup**: 
  - Select a clinician
  - Force quit the app
  - Change clinician delay in Firebase
  - Tap the push notification when it arrives
- **Expected**:
  - App launches
  - Pending notification is stored in AppDelegate
  - In-app alert appears after app fully loads
  - Alert shows correct delay change information

#### Test 2.2.8: Multiple Delay Changes - Backgrounded
- **Setup**: 
  - Select a clinician
  - Background app
  - Change delay multiple times (e.g., 10 → 15 → 20 → 5)
- **Expected**:
  - Each change triggers a push notification
  - All notifications arrive
  - Most recent delay is reflected when app is reopened

---

## 3. COMBINED SCENARIOS

### 3.1 Walking Alerts Disabled, Delay Alerts Enabled

#### Test 3.1.1: Walking Disabled, Delay Enabled - Walk in Progress
- **Setup**: 
  - Start a walk
  - Tap "Stop Alerts" to disable walking alerts
  - Keep delay notifications enabled
  - Background app
- **Expected**:
  - No walking push notifications (50%, 80%, 100%)
  - Delay push notifications still work
  - If delay changes during walk, push notification arrives

#### Test 3.1.2: Walking Disabled, Delay Enabled - In-App
- **Setup**: 
  - Start a walk
  - Tap "Stop Alerts" to disable walking alerts
  - Keep delay notifications enabled
  - App in foreground
- **Expected**:
  - No in-app walking alerts (50%, 80%, 100%)
  - Delay in-app alerts still work
  - If delay changes, in-app alert appears

---

### 3.2 Delay Alerts Disabled, Walking Alerts Enabled

#### Test 3.2.1: Delay Disabled, Walking Enabled - Walk in Progress
- **Setup**: 
  - Select a clinician
  - Tap "Stop Notifications" from a delay alert
  - Start a walk
  - Background app
- **Expected**:
  - Walking push notifications work (50%, 80%, 100%)
  - Delay push notifications do NOT arrive
  - If delay changes, no push notification

#### Test 3.2.2: Delay Disabled, Walking Enabled - In-App
- **Setup**: 
  - Select a clinician
  - Tap "Stop Notifications" from a delay alert
  - Start a walk
  - App in foreground
- **Expected**:
  - Walking in-app alerts work (50%, 80%, 100%)
  - Delay in-app alerts do NOT appear
  - If delay changes, no in-app alert (data still updates)

---

### 3.3 All Notifications Disabled

#### Test 3.3.1: All Disabled - Walk in Progress
- **Setup**: 
  - Disable walking alerts ("Stop Alerts")
  - Disable delay notifications ("Stop Notifications")
  - Start a walk
  - Background app
- **Expected**:
  - No push notifications (walking or delay)
  - No in-app alerts
  - Data still updates (delay changes reflected in UI)

#### Test 3.3.2: All Disabled - In-App
- **Setup**: 
  - Disable walking alerts
  - Disable delay notifications
  - Start a walk
  - App in foreground
- **Expected**:
  - No in-app alerts (walking or delay)
  - Console shows blocking messages
  - Data still updates

---

## 4. EDGE CASES & SPECIAL SCENARIOS

### 4.1 Notification Permissions

#### Test 4.1.1: Notifications Denied in iOS Settings
- **Setup**: 
  - Deny notification permissions in iOS Settings
  - Start a walk
  - Try to receive notifications
- **Expected**:
  - No push notifications arrive
  - In-app alerts still work (they don't require permissions)
  - App handles gracefully (no crashes)

#### Test 4.1.2: Notifications Re-Enabled
- **Setup**: 
  - Deny notifications, then re-enable in iOS Settings
  - Start a walk
- **Expected**:
  - Push notifications work again
  - FCM token is re-registered
  - Subscriptions are restored

---

### 4.2 App State Transitions

#### Test 4.2.1: Foreground → Background During Alert
- **Setup**: 
  - Start a walk, app in foreground
  - When 50% alert appears, immediately background app
- **Expected**:
  - In-app alert is dismissed
  - Push notification may still arrive (if scheduled)
  - No duplicate alerts

#### Test 4.2.2: Background → Foreground During Alert
- **Setup**: 
  - Start a walk, background app
  - When push notification arrives, tap it immediately
- **Expected**:
  - App opens
  - In-app alert appears (from pending notification)
  - No duplicate push notification shown

#### Test 4.2.3: App Killed → Launched from Notification
- **Setup**: 
  - Start a walk
  - Force quit app
  - Wait for push notification
  - Tap notification
- **Expected**:
  - App launches
  - Walk session is restored
  - In-app alert appears (from pending notification)
  - App state is correct

---

### 4.3 Multiple Clinicians

#### Test 4.3.1: Switch Clinicians During Walk
- **Setup**: 
  - Select Clinician A, start a walk
  - Switch to Clinician B
  - Change Clinician B's delay
- **Expected**:
  - Push notification arrives for Clinician B
  - Clinician A's notifications stop (unsubscribed)
  - Walking notifications continue (not clinician-specific)

#### Test 4.3.2: Multiple Clinicians - Different Delays
- **Setup**: 
  - Select Clinician A (10 min delay)
  - Switch to Clinician B (15 min delay)
  - Background app
  - Change both delays
- **Expected**:
  - Only Clinician B's delay change triggers notification (currently selected)
  - Clinician A's change does not trigger notification (not subscribed)

---

### 4.4 Walk Session Management

#### Test 4.4.1: Start New Walk - Alerts Reset
- **Setup**: 
  - Start Walk 1, disable walking alerts
  - End Walk 1
  - Start Walk 2
- **Expected**:
  - `walkingAlertsEnabled` resets to `true` for Walk 2
  - Walking alerts work again in Walk 2

#### Test 4.4.2: End Walk - Notifications Cancelled
- **Setup**: 
  - Start a walk
  - Background app
  - End walk before reaching 50%
- **Expected**:
  - All pending walking notifications are cancelled
  - No push notifications arrive for 50%, 80%, 100%
  - Delay notifications continue (not walk-specific)

#### Test 4.4.3: Walk Complete - Home Arrival
- **Setup**: 
  - Start a walk, complete all waypoints
  - Return to start/end point
- **Expected**:
  - Home arrival screen appears
  - Walking notifications stop
  - "Walk Complete!" notification may have already fired at 100%
  - No further walking notifications

---

### 4.5 Notification Timing

#### Test 4.5.1: Rapid Progress - Multiple Alerts
- **Setup**: 
  - Start a very short walk (5 min)
  - Progress quickly through 50%, 80%, 100%
- **Expected**:
  - Alerts appear in sequence
  - Previous alerts are dismissed
  - No overlapping alerts
  - Auto-dismiss timers work correctly

#### Test 4.5.2: Slow Progress - Delayed Alerts
- **Setup**: 
  - Start a long walk (30 min)
  - Pause or move slowly
  - Progress slowly through 50%, 80%, 100%
- **Expected**:
  - Alerts appear when thresholds are reached
  - Timing is based on actual progress, not elapsed time
  - No false triggers

---

### 4.6 Notification Actions

#### Test 4.6.1: "Stop Alerts" from Walking Alert
- **Setup**: 
  - Start a walk
  - When 50% alert appears, tap "Stop Alerts"
- **Expected**:
  - Alert dismisses
  - `walkingAlertsEnabled = false`
  - All pending walking notifications cancelled
  - No further walking alerts (80%, 100%)
  - Delay notifications still work

#### Test 4.6.2: "Stop Notifications" from Delay Alert
- **Setup**: 
  - Select a clinician
  - When delay alert appears, tap "Stop Notifications"
- **Expected**:
  - User unsubscribed from clinician's FCM topic
  - No further delay notifications for this clinician
  - Walking notifications still work

#### Test 4.6.3: "View Details" from Delay Alert
- **Setup**: 
  - Select a clinician
  - When delay alert appears, tap "View Details"
- **Expected**:
  - Alert dismisses
  - App navigates to relevant screen (if applicable)
  - No additional action needed

---

## 5. NOTIFICATION DELIVERY & RELIABILITY

### 5.1 Push Notification Delivery

#### Test 5.1.1: FCM Token Registration
- **Setup**: 
  - Fresh app install
  - Grant notification permissions
- **Expected**:
  - FCM token is registered
  - Console shows: "🔥 FCM Token: [token]"
  - APNs token is registered
  - Console shows: "📱 APNs Token received: [token]"

#### Test 5.1.2: Topic Subscription
- **Setup**: 
  - Select a clinician
  - Check Firebase console or logs
- **Expected**:
  - User is subscribed to clinician's FCM topic
  - Console shows subscription confirmation
  - Topic format: `clinician_[Name]` (sanitized)

#### Test 5.1.3: High Priority Delivery (Backgrounded)
- **Setup**: 
  - Select a clinician
  - Background app
  - Change delay in Firebase
- **Expected**:
  - Push notification arrives immediately (not delayed)
  - `apns-priority: 10` ensures high priority
  - Badge count updates

#### Test 5.1.4: Network Issues - Offline
- **Setup**: 
  - Select a clinician
  - Turn off Wi-Fi and cellular
  - Change delay in Firebase (from another device)
  - Re-enable network
- **Expected**:
  - When network is restored, push notification arrives
  - FCM handles offline delivery
  - Notification is not lost

---

### 5.2 Notification Content

#### Test 5.2.1: Notification Text Accuracy
- **Setup**: 
  - Start a 10-minute walk
  - Check all notification texts
- **Expected**:
  - "Walk Started": Shows correct route name and duration
  - "Halfway Point": Shows correct duration (10 min)
  - "Time to Head Back": Shows correct duration
  - "Walk Complete": Shows correct duration

#### Test 5.2.2: Delay Notification Text Accuracy
- **Setup**: 
  - Select a clinician
  - Change delay multiple times
- **Expected**:
  - Increase: "Delay increased by X min (now Y min)"
  - Decrease: "Delay reduced to X min" or "The clinic is now running on time"
  - Clinician name is correct (short name format)

---

## 6. TESTING CHECKLIST

### Pre-Test Setup
- [ ] Real iOS device (not simulator)
- [ ] Notification permissions granted
- [ ] Clinician selected and subscribed
- [ ] FCM token registered (check console)
- [ ] APNs token registered (check console)
- [ ] Firebase console access (for delay changes)

### Test Execution
- [ ] All walking notification tests (1.1 - 1.2)
- [ ] All delay notification tests (2.1 - 2.2)
- [ ] All combined scenario tests (3.1 - 3.3)
- [ ] All edge case tests (4.1 - 4.6)
- [ ] All delivery tests (5.1 - 5.2)

### Post-Test Verification
- [ ] No crashes or errors
- [ ] Console logs are clean
- [ ] Notification permissions still work
- [ ] FCM subscriptions are correct
- [ ] App state is preserved correctly

---

## 7. DEBUGGING TIPS

### Console Logs to Monitor
- `🚶 Showing halfway alert (50%)` - In-app alert triggered
- `🔕 Halfway alert blocked - walkingAlertsEnabled = false` - Alert blocked
- `📱 Skipping halfway in-app alert - user came from push notification` - Suppressed duplicate
- `🔥 FCM Token: [token]` - FCM registration
- `📱 APNs Token received: [token]` - APNs registration
- `🔕 Unsubscribing from clinician topic: [topic]` - Topic unsubscription
- `✅ Successfully sent message: [response]` - Firebase Cloud Function success

### Common Issues
1. **Push notifications not arriving**: Check FCM token, APNs token, topic subscription
2. **Duplicate alerts**: Check `AppDelegate.suppressInAppAlertsFlag` and `AppDelegate.cameFromWalkNotification`
3. **Alerts not appearing**: Check `walkingAlertsEnabled` and `notificationsEnabled` flags
4. **Notifications not cancelled**: Check `cancelAllWalkingNotifications()` is called
5. **Topic subscription issues**: Check topic format matches Firebase Cloud Function

---

## 8. TEST RESULTS TEMPLATE

### Test: [Test Name]
- **Status**: ✅ Pass / ❌ Fail / ⚠️ Partial
- **Device**: [Device model, iOS version]
- **App Version**: [Version and build]
- **Notes**: [Any observations, issues, or edge cases found]
- **Screenshots**: [If applicable]

---

**Last Updated**: v1.9.14 (build 185)
