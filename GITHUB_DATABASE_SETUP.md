# Setting Up Pre-Populated Database on GitHub

## Overview

You can host the pre-populated POI and route database on GitHub and have the app download it automatically. This is free, reliable, and allows easy updates.

## Step 1: Generate the Database

1. Run the generator in your app (see `GENERATE_POI_DATABASE.md`)
2. This creates `prepopulated_pois.json` in your Documents directory

## Step 2: Add to GitHub Repository

### Option A: Add to Existing Repository

1. Copy `prepopulated_pois.json` to your WalkingWR repository
2. Commit and push:
   ```bash
   git add prepopulated_pois.json
   git commit -m "Add pre-populated POI and route database"
   git push
   ```

### Option B: Create a Separate Repository (Recommended)

Create a dedicated repository for the database (keeps app repo clean):

1. Create a new GitHub repository (e.g., `WalkingWR-Data`)
2. Add the JSON file:
   ```bash
   git init
   git add prepopulated_pois.json
   git commit -m "Initial database"
   git remote add origin https://github.com/yourusername/WalkingWR-Data.git
   git push -u origin main
   ```

## Step 3: Get the Raw URL

GitHub raw URLs follow this format:
```
https://raw.githubusercontent.com/USERNAME/REPO/BRANCH/PATH/TO/FILE.json
```

**Examples:**
- Main branch, root: `https://raw.githubusercontent.com/yourusername/WalkingWR/main/prepopulated_pois.json`
- Main branch, data folder: `https://raw.githubusercontent.com/yourusername/WalkingWR/main/data/prepopulated_pois.json`
- Separate repo: `https://raw.githubusercontent.com/yourusername/WalkingWR-Data/main/prepopulated_pois.json`

**How to get it:**
1. Go to your file on GitHub
2. Click "Raw" button
3. Copy the URL from the address bar

## Step 4: Update the App

1. Open `WalkingWR/Services/PrePopulatedPOIService.swift`
2. Find the `databaseURL` property (around line 31)
3. Update it with your GitHub raw URL:

```swift
private var databaseURL: URL? {
    // GitHub raw URL
    return URL(string: "https://raw.githubusercontent.com/yourusername/WalkingWR/main/prepopulated_pois.json")
}
```

4. Build and run - the app will download the database on first launch!

## Step 5: Test It

1. Clear the app's database (delete and reinstall, or clear UserDefaults)
2. Launch the app
3. Check console logs - you should see:
   ```
   📦 Pre-populated DB: Starting download from server...
   📦 Pre-populated DB: Downloaded successfully! X POIs across Y postcode areas
   ```

## Updating the Database

When you want to update the database:

1. Regenerate it using the generator
2. Replace the file in your GitHub repository
3. Commit and push:
   ```bash
   git add prepopulated_pois.json
   git commit -m "Update POI and route database"
   git push
   ```

4. The app will automatically download the new version on next launch (if you increment the version number in the JSON, or clear the download flag)

## Benefits of GitHub Hosting

✅ **Free** - No server costs  
✅ **Reliable** - GitHub's CDN is fast and reliable  
✅ **Version Control** - Easy to track changes and rollback  
✅ **Easy Updates** - Just push a new file  
✅ **Public or Private** - Can be public (free) or private (if you have GitHub Pro)  
✅ **No Maintenance** - No server to manage  

## File Size Considerations

- Typical database: 200-800 KB
- GitHub allows files up to 100 MB (free tier)
- If your database grows large, consider:
  - Splitting by region
  - Compressing (though JSON is already pretty compact)
  - Using Git LFS for files > 100 MB

## Security

If your database contains sensitive data:
- Use a **private repository** (requires GitHub Pro/Team)
- Or use your own server with authentication
- Or bundle with the app (no download)

For POI/route data (public information), a public repository is fine.

## Troubleshooting

**"Download failed - invalid response"**
- Check the URL is correct (must be raw.githubusercontent.com, not github.com)
- Make sure the file exists at that path
- Check the branch name (main vs master)

**"Download failed - network error"**
- Check internet connection
- GitHub might be down (rare)
- Try again later

**"No bundled database available"**
- This is normal if download fails and no bundled file exists
- Check your GitHub URL is correct
- Make sure the file is accessible (not in a private repo without auth)

## Example: Complete Setup

```swift
// In PrePopulatedPOIService.swift
private var databaseURL: URL? {
    // Your GitHub raw URL
    return URL(string: "https://raw.githubusercontent.com/raihant/WalkingWR/main/prepopulated_pois.json")
}
```

That's it! The app will automatically download and use it.
