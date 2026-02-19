# Testing Firebase Storage Download

## Quick Test Methods

### Method 1: Using Debug Button (Easiest)

1. **Build and run the app** in DEBUG mode
2. Go to **Profile → Settings** (gear icon)
3. Scroll to **"Debug Tests"** section
4. Tap **"Clear Pre-populated DB (Test Firebase)"**
5. **Force quit the app** (swipe up from app switcher)
6. **Relaunch the app**
7. **Watch console logs** for:
   ```
   📦 Pre-populated DB: Got Firebase Storage URL: https://...
   📦 Pre-populated DB: Starting download from Firebase Storage...
   📦 ✅ Pre-populated DB: Downloaded successfully from Firebase Storage!
   ```

### Method 2: Clear via Terminal/Code

Run this in Xcode console or add to code:
```swift
PrePopulatedPOIService.shared.clearDatabase()
```

Then restart the app.

### Method 3: Delete and Reinstall App

1. Delete the app from your device/simulator
2. Reinstall and launch
3. Watch for Firebase download logs

## What to Look For in Logs

### ✅ Success Indicators:
```
📦 Pre-populated DB: Got Firebase Storage URL: https://firebasestorage.googleapis.com/...
📦 Pre-populated DB: Starting download from Firebase Storage...
📦 Pre-populated DB: Downloaded successfully from Firebase Storage!
📦   Version: 1
📦   Postcode areas: 8
📦   Total POIs: 12083
📦   Total routes: 16
```

### ❌ Failure Indicators:
```
📦 Pre-populated DB: Failed to get Firebase Storage URL: ...
📦 Pre-populated DB: No Firebase Storage URL available, using bundled database
```

## Testing Version Updates

1. **Upload a new version** to Firebase Storage with a higher version number
2. **Clear the database** using the debug button
3. **Restart the app**
4. **Verify** it downloads the new version

## Testing Fallback

1. **Turn off WiFi/Cellular** (or block Firebase Storage in network settings)
2. **Clear the database**
3. **Restart the app**
4. **Verify** it falls back to bundled database:
   ```
   📦 Pre-populated DB: No Firebase Storage URL available, using bundled database
   📦 ✅ Pre-populated DB: Loaded from bundle!
   ```

## Expected Behavior

- **First launch**: Downloads from Firebase Storage
- **Subsequent launches**: Uses cached database (unless version is newer)
- **Offline**: Falls back to bundled database
- **Version update**: Downloads new version if Firebase has higher version number
