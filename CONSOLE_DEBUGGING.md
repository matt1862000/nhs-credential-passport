# Console Output Debugging

## What Should Happen

When you tap "Run Deduplication Tests", you should see output in the **Xcode Console**.

## How to View Console Output

1. **Open Xcode Console:**
   - Press `Cmd+Shift+Y` (or View → Debug Area → Activate Console)
   - Make sure the console is visible at the bottom of Xcode

2. **Check Console Filters:**
   - Look for a filter/search box in the console
   - Make sure it's not filtering out messages
   - Try clearing any filters

3. **Look for These Messages:**
   ```
   🔵🔵🔵 DEDUPLICATION TEST RUNNER CALLED 🔵🔵🔵
   ═══════════════════════════════════════════════════════════
   🧪 DEDUPLICATION TEST SUITE - Starting Tests
   ═══════════════════════════════════════════════════════════
   ```

## If Nothing Appears

### 1. Check if Button is Working
- Look for: `🔵 [DEBUG] Test button tapped!`
- If you don't see this, the button might not be calling the function

### 2. Check Console Settings
- Make sure "All Output" is selected (not "Errors Only")
- Try clicking the console filter dropdown and selecting "All Output"

### 3. Check if Running on Device vs Simulator
- Console output works on both, but make sure you're looking at the right console
- If running on device, make sure it's connected and selected in Xcode

### 4. Try NSLog Instead
- The code now uses both `print()` and `NSLog()`
- `NSLog()` should always appear in console
- Look for messages starting with timestamp like: `2026-01-21 22:00:00.123`

### 5. Check for Crashes
- If the function crashes silently, you might see nothing
- Check for any red error messages in console
- Check if the alert appears (if alert appears but no console, function ran but print failed)

## Expected Full Output

```
🔵🔵🔵 DEDUPLICATION TEST RUNNER CALLED 🔵🔵🔵
═══════════════════════════════════════════════════════════
🧪 DEDUPLICATION TEST SUITE - Starting Tests
═══════════════════════════════════════════════════════════

🔵 [TEST] Running Test 1: Lindale Methodist Church variants...
✅ Test 1: PASSED - Lindale Methodist Church variants

🔵 [TEST] Running Test 2: War Memorial variants...
✅ Test 2: PASSED - War Memorial variants

... (more tests)

═══════════════════════════════════════════════════════════
📊 TEST SUMMARY
═══════════════════════════════════════════════════════════
✅ Passed: 5
❌ Failed: 0
📋 Total: 5

🎉 All tests passed!
═══════════════════════════════════════════════════════════
```

## Quick Test

1. Tap the button
2. Immediately check Xcode console (Cmd+Shift+Y)
3. Look for `🔵🔵🔵` - this should appear immediately
4. If you see this, the function is being called
5. If you don't see this, the button might not be working

## Alternative: Check Device Console

If Xcode console doesn't show output, you can also check:
- Window → Devices and Simulators
- Select your device/simulator
- Click "Open Console" button
- Look for the test messages there
