# How to Use the Notification Test Plan

## Quick Start Guide

### Step 1: Open the Test Plan
The test plan is saved as `NOTIFICATION_TEST_PLAN.md` in your project root. You can:
- Open it in any text editor
- View it in Xcode (right-click → Open With → TextEdit)
- Or I can show you specific sections as you test

### Step 2: Set Up Your Testing Environment

**Before you start testing:**

1. **Use a Real Device** (not simulator)
   - Push notifications don't work in the iOS Simulator
   - Connect your iPhone/iPad via USB

2. **Enable Notifications**
   - Go to iOS Settings → WalkingWR → Notifications
   - Make sure "Allow Notifications" is ON
   - Enable all notification types

3. **Prepare Your Test Setup**
   - Select a clinician in the app
   - Have access to Firebase Console (to change delays)
   - Keep Xcode console open to see logs

4. **Use a Short Walk for Testing**
   - Create a 5-10 minute walk (faster to test)
   - Or use the simulator's time acceleration if testing in-app alerts only

---

## Step 3: How to Run Each Test

### Example: Testing "Halfway Alert (50%) - All Alerts Enabled"

1. **Read the test description:**
   ```
   Test 1.1.1: Halfway Alert (50%) - All Alerts Enabled
   - Setup: Start a walk, walking alerts enabled
   - Expected: In-app alert appears at 50% progress
   ```

2. **Follow the setup:**
   - Open the WalkingWR app
   - Select a clinician (if needed)
   - Create and start a walk
   - Make sure you haven't disabled walking alerts

3. **Wait for the condition:**
   - Walk until you reach 50% progress
   - Or use simulator time acceleration to speed it up

4. **Check the expected results:**
   - ✅ Did the alert appear? → "Halfway Point!" alert
   - ✅ Did it auto-dismiss after 10 seconds?
   - ✅ Are the buttons correct? → "Stop Alerts" (top), "OK" (bottom)
   - ✅ Check Xcode console for logs

5. **Record your results:**
   - Mark as ✅ Pass if everything matches
   - Mark as ❌ Fail if something is wrong
   - Note any issues in the "Notes" section

---

## Step 4: Testing Push Notifications (Background/Killed)

### For Background Testing:

1. **Start the walk** in the app
2. **Background the app:**
   - Press the home button (or swipe up on newer iPhones)
   - Or swipe up from bottom to go to home screen
3. **Wait for the notification** to arrive
4. **Check your lock screen or notification center**
5. **Tap the notification** to see if app opens correctly

### For Killed App Testing:

1. **Start the walk** in the app
2. **Force quit the app:**
   - Swipe up to see app switcher
   - Swipe up on the WalkingWR app card to close it
3. **Wait for the notification** to arrive
4. **Tap the notification** to see if app launches correctly

---

## Step 5: Testing Delay Changes

### To Change Clinician Delay:

1. **Open Firebase Console:**
   - Go to https://console.firebase.google.com
   - Select your project
   - Go to Firestore Database

2. **Find the clinician document:**
   - Navigate to `clinicians` collection
   - Find the clinician you selected in the app

3. **Edit the delay field:**
   - Click on the document
   - Edit the `delay` field (change the number)
   - Save

4. **Wait for notification:**
   - If app is backgrounded: Push notification should arrive
   - If app is foreground: In-app alert should appear

---

## Step 6: Testing Different Scenarios

### Test Walking Alerts Disabled:

1. **Start a walk**
2. **Tap "Stop Alerts"** button (from ActiveWalkCard or from an alert)
3. **Continue walking** and verify:
   - No in-app alerts appear
   - No push notifications arrive
   - Console shows: "🔕 Halfway alert blocked"

### Test Delay Notifications Disabled:

1. **Select a clinician**
2. **When a delay alert appears, tap "Stop Notifications"**
3. **Change the delay in Firebase**
4. **Verify:**
   - No push notification arrives
   - No in-app alert appears
   - Data still updates (delay changes in UI)

---

## Step 7: What to Check in Xcode Console

### Important Log Messages:

**When alerts work:**
- `🚶 Showing halfway alert (50%)` ✅
- `🔥 FCM Token: [token]` ✅
- `📱 APNs Token received: [token]` ✅

**When alerts are blocked:**
- `🔕 Halfway alert blocked - walkingAlertsEnabled = false` ✅ (expected if disabled)
- `🔕 Notifications disabled - skipping delay alert` ✅ (expected if disabled)

**When there are issues:**
- `❌ WARNING: FCM Token is nil` ❌ (problem!)
- `Error sending message` ❌ (problem!)

---

## Step 8: Recording Results

### Simple Method:
Just check off tests as you go:
- ✅ = Pass
- ❌ = Fail
- ⚠️ = Partial (works but has issues)

### Detailed Method:
For each test, note:
- **Status**: Pass/Fail/Partial
- **Device**: iPhone 13 Pro, iOS 17.0
- **App Version**: 1.9.14 (build 185)
- **Notes**: "Alert appeared but didn't auto-dismiss"
- **Screenshots**: Take screenshots of any issues

---

## Step 9: Testing Order Recommendation

### Start with Simple Tests:
1. **In-app alerts (foreground)** - Easiest to test
2. **Walking alerts enabled/disabled** - Quick to verify
3. **Delay alerts (foreground)** - Easy to trigger

### Then Test Push Notifications:
4. **Push notifications (background)** - Requires real device
5. **Push notifications (killed)** - Requires real device
6. **Notification actions** - Long-press notifications

### Finally Test Edge Cases:
7. **Combined scenarios** - Multiple settings
8. **App state transitions** - Background/foreground
9. **Multiple notifications** - Sequence testing

---

## Step 10: Common Issues & Solutions

### "Push notifications not arriving"
- ✅ Check: Real device (not simulator)
- ✅ Check: Notification permissions enabled
- ✅ Check: FCM token in console logs
- ✅ Check: App is backgrounded/killed (not just minimized)

### "In-app alerts not appearing"
- ✅ Check: `walkingAlertsEnabled = true` (not disabled)
- ✅ Check: App is in foreground
- ✅ Check: Progress actually reached 50%/80%/100%
- ✅ Check: Console logs for blocking messages

### "Duplicate alerts appearing"
- ✅ Check: `AppDelegate.cameFromWalkNotification` flag
- ✅ Check: `AppDelegate.suppressInAppAlertsFlag` flag
- ✅ Check: Console for suppression messages

### "Notifications not cancelling"
- ✅ Check: `cancelAllWalkingNotifications()` is called
- ✅ Check: Console shows cancellation logs
- ✅ Check: FCM topic unsubscription

---

## Quick Reference: Test Categories

### Category 1: Walking Notifications
- **1.1**: In-app alerts (app in foreground)
- **1.2**: Push notifications (app backgrounded/killed)

### Category 2: Delay Notifications
- **2.1**: In-app alerts (app in foreground)
- **2.2**: Push notifications (app backgrounded/killed)

### Category 3: Combined Scenarios
- **3.1**: Walking disabled, delay enabled
- **3.2**: Delay disabled, walking enabled
- **3.3**: All notifications disabled

### Category 4: Edge Cases
- **4.1**: Notification permissions
- **4.2**: App state transitions
- **4.3**: Multiple clinicians
- **4.4**: Walk session management
- **4.5**: Notification timing
- **4.6**: Notification actions

### Category 5: Delivery & Reliability
- **5.1**: Push notification delivery
- **5.2**: Notification content accuracy

---

## Tips for Efficient Testing

1. **Test in batches**: Group similar tests together
2. **Use short walks**: 5-10 minutes for faster testing
3. **Keep console open**: Watch for log messages
4. **Take notes**: Write down any unexpected behavior
5. **Test systematically**: Don't skip tests, but prioritize critical ones
6. **Use screenshots**: Capture any issues for reference

---

## Need Help?

If you encounter issues:
1. Check the console logs for error messages
2. Review the "Expected" section of the test
3. Check the "Common Issues & Solutions" section
4. Ask me to help debug specific tests

---

**Ready to start?** Begin with Test 1.1.1 and work through them systematically!
