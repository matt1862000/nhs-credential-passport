# Pre-Populated Database Deployment Guide

This guide walks you through generating and deploying the POI and route database to GitHub.

## Step 1: Generate the Database

### Option A: Using the Debug Button (Recommended)

1. **Build and run the app** in DEBUG mode
2. Go to **Profile → Settings** (gear icon)
3. Scroll to **"Debug Tests"** section
4. Tap **"Generate POI Database"**
5. Wait for generation to complete (this may take 5-10 minutes as it fetches POIs from OSM and Geograph for all 8 postcode areas)
6. The file will be saved to:
   - App Documents directory
   - Your Desktop (for easy access)

### Option B: Using Xcode Console

If you prefer to run it programmatically, add this to your app initialization:

```swift
#if DEBUG
Task {
    let generator = PrePopulatedPOIGenerator()
    do {
        let fileURL = try await generator.generateAndSaveDatabase()
        print("✅ Database saved to: \(fileURL.path)")
    } catch {
        print("❌ Error: \(error)")
    }
}
#endif
```

## Step 2: Verify the Generated Database

The generated file should contain:
- **8 postcode areas** (WF2 0GU, S5 7JT, S35 0JW, S1 4JP, S5 7AU, S8 8BG, S35 1RQ, S11 9BF)
- **POIs** from OSM and Geograph (typically 50-200 POIs per area)
- **Routes** for durations: 5, 10, 15, 20, 30, 45, 60 minutes (up to 3 routes per duration per area)

Check the file size - it should be 100KB - 2MB depending on how many POIs/routes were found.

## Step 3: Add to GitHub Repository

### Option A: Add to Main Repository

1. Copy `prepopulated_pois.json` from Desktop to your project root:
   ```bash
   cp ~/Desktop/prepopulated_pois.json /Users/raihant/Documents/WalkingWR/
   ```

2. Add to git:
   ```bash
   cd /Users/raihant/Documents/WalkingWR
   git add prepopulated_pois.json
   git commit -m "Add pre-populated POI and route database"
   git push
   ```

3. Get the GitHub raw URL:
   - Go to your repository on GitHub
   - Navigate to `prepopulated_pois.json`
   - Click the **"Raw"** button
   - Copy the URL (should look like: `https://raw.githubusercontent.com/yourusername/WalkingWR/main/prepopulated_pois.json`)

### Option B: Create Separate Data Repository (Recommended)

This keeps your main repo clean:

1. Create a new GitHub repository (e.g., `WalkingWR-Data`)
2. Add the file:
   ```bash
   mkdir WalkingWR-Data
   cd WalkingWR-Data
   cp ~/Desktop/prepopulated_pois.json .
   git init
   git add prepopulated_pois.json
   git commit -m "Initial database"
   git remote add origin https://github.com/yourusername/WalkingWR-Data.git
   git push -u origin main
   ```

3. Get the raw URL: `https://raw.githubusercontent.com/yourusername/WalkingWR-Data/main/prepopulated_pois.json`

## Step 4: Update the App to Use GitHub URL

1. Open `WalkingWR/Services/PrePopulatedPOIService.swift`
2. Find the `databaseURL` property (around line 32)
3. Update it with your GitHub raw URL:

```swift
private var databaseURL: URL? {
    // GitHub raw URL
    return URL(string: "https://raw.githubusercontent.com/yourusername/WalkingWR/main/prepopulated_pois.json")
    // OR if using separate repo:
    // return URL(string: "https://raw.githubusercontent.com/yourusername/WalkingWR-Data/main/prepopulated_pois.json")
}
```

4. Build and run - the app will download the database on first launch!

## Step 5: Test the Deployment

1. **Clear the app's database** (delete and reinstall, or clear UserDefaults)
2. **Launch the app**
3. **Check console logs** - you should see:
   ```
   📦 Pre-populated DB: Starting download from server...
   📦 Pre-populated DB: Downloaded successfully! X POIs across 8 postcode areas
   ```

4. **Test POI fetching** - go to a location near one of the postcode areas and generate a route. It should use the pre-populated database (no API calls needed).

## Updating the Database

When you want to update the database:

1. **Regenerate** using the debug button (Step 1)
2. **Replace the file** in your GitHub repository
3. **Commit and push**:
   ```bash
   git add prepopulated_pois.json
   git commit -m "Update POI and route database"
   git push
   ```

4. **Increment the version** in the JSON file (change `"version": 1` to `"version": 2`) so the app knows to re-download

5. The app will automatically download the new version on next launch (if version changed) or you can clear the download flag in UserDefaults

## Troubleshooting

### "Download failed - invalid response"
- Check the URL is correct (must be `raw.githubusercontent.com`, not `github.com`)
- Make sure the file exists at that path
- Check the branch name (main vs master)

### "Download failed - network error"
- Check internet connection
- GitHub might be down (rare)
- Try again later

### "No bundled database available"
- This is normal if download fails and no bundled file exists
- Check your GitHub URL is correct
- Make sure the file is accessible (not in a private repo without auth)

### Database is empty (0 POIs)
- The generator might have failed to fetch POIs
- Check console logs for errors
- Some areas might have fewer POIs available
- Try running the generator again

## File Size Considerations

- **Typical database**: 200KB - 2MB
- **GitHub allows**: Files up to 100MB (free tier)
- **If database grows large**:
  - Consider splitting by region
  - Or using Git LFS for files > 100MB

## Benefits of GitHub Hosting

✅ **Free** - No server costs  
✅ **Reliable** - GitHub's CDN is fast and reliable  
✅ **Version Control** - Easy to track changes and rollback  
✅ **Easy Updates** - Just push a new file  
✅ **Public or Private** - Can be public (free) or private (if you have GitHub Pro)  
✅ **No Maintenance** - No server to manage  

## Next Steps

After deployment:
1. Monitor cache hit rates in console logs
2. Verify routes are loading from pre-populated database
3. Update database periodically as new POIs are discovered
4. Consider adding more postcode areas if needed
