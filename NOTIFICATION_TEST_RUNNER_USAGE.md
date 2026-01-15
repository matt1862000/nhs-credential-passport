# Notification Test Runner - Usage Guide

## Quick Start

The automated notification test runner is now built into the app! It runs comprehensive tests and logs all results to the Xcode console.

## How to Use

### Step 1: Build and Run
1. Open the project in Xcode
2. Build and run on a **real device** (push notifications don't work in simulator)
3. Make sure you're in **DEBUG mode** (the test button only appears in debug builds)

### Step 2: Access the Test Runner
1. Open the app
2. Go to the **"Your Progress"** tab (Profile tab)
3. Look for the **test tube icon** (🧪) in the **top-left corner** of the navigation bar
4. Tap it to run all tests

### Step 3: View Results
1. Open **Xcode Console** (View → Debug Area → Activate Console, or Cmd+Shift+Y)
2. All test results will be logged with clear formatting:
   - ✅ = Test passed
   - ❌ = Test failed
   - ℹ️ = Informational message
   - ⚠️ = Warning

## What Gets Tested

The test runner automatically checks:

1. **Walking Alerts - Enabled State**
   - Checks if `walkingAlertsEnabled` is true
   - Verifies initial alert flags are false
   
2. **Walking Alerts - Disabled State**
   - Tests disabling alerts
   - Tests re-enabling alerts
   - Verifies state changes

3. **Notification Permissions**
   - Checks if notifications are authorized
   - Shows current authorization status

4. **FCM/APNs Token Status**
   - Provides info on where to check token registration
   - Points to console logs for token verification

5. **Scheduled Notifications**
   - Lists all pending notifications
   - Shows notification details (title, body, category, scheduled time)

6. **Alert State Checks**
   - Checks if walk session is active
   - Shows current walk progress
   - Shows which alerts have been sent
   - Shows estimated return time

## Example Console Output

```
================================================================================
🧪 NOTIFICATION TEST SUITE - Starting Automated Tests
================================================================================

--------------------------------------------------------------------------------
🧪 TEST: Walking Alerts - Enabled State
--------------------------------------------------------------------------------
✅ walkingAlertsEnabled:
   Expected: true
   Actual: true
   Result: PASS
✅ showHalfwayAlert (initial):
   Expected: false
   Actual: false
   Result: PASS
...

================================================================================
📊 TEST SUMMARY
================================================================================

✅ Passed: 8
❌ Failed: 0
⚠️ Errors: 0
📋 Total: 8

✅ All tests passed!
```

## When to Run Tests

### Before Testing Manually:
Run the test suite to get a baseline of the current state:
- Notification permissions status
- Current alert states
- Pending notifications
- Walk session status

### After Making Changes:
Run tests after:
- Changing notification settings
- Starting/ending a walk
- Disabling/enabling alerts
- Changing clinician selection

### During Development:
Run tests to verify:
- Code changes didn't break notification logic
- Alert states are correct
- Permissions are properly configured

## Understanding the Results

### ✅ PASS
- The test condition matches expected behavior
- Everything is working as intended

### ❌ FAIL
- The test condition doesn't match expected behavior
- Something may be misconfigured
- Review the "Expected" vs "Actual" values

### ⚠️ WARNING
- Informational message
- May indicate a potential issue
- Usually safe to ignore, but worth reviewing

### ℹ️ INFO
- Helpful information about current state
- Not a pass/fail, just context

## Tips

1. **Run tests in different states:**
   - With walk active
   - With walk inactive
   - With alerts enabled
   - With alerts disabled

2. **Check console before manual testing:**
   - Get baseline state
   - Verify permissions
   - See pending notifications

3. **Use for debugging:**
   - If notifications aren't working, run tests
   - Check which tests fail
   - Use results to pinpoint issues

4. **Compare before/after:**
   - Run tests before making changes
   - Make changes
   - Run tests again
   - Compare results to see what changed

## Limitations

- **Cannot test push notifications delivery** (requires actual push from Firebase)
- **Cannot test app background/killed states** (requires manual testing)
- **Cannot test notification tapping** (requires manual interaction)
- **Cannot simulate actual walk progress** (requires real movement or time)

## Next Steps

After running automated tests:
1. Review the test summary
2. Note any failures
3. Use the manual test plan (`NOTIFICATION_TEST_PLAN.md`) for scenarios the automated tests can't cover
4. Fix any issues found
5. Re-run tests to verify fixes

---

**The test runner is a DEBUG-only feature** - it won't appear in release builds, so it's safe to leave in the code.
