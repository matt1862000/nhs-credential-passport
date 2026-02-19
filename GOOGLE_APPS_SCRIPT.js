  /**
   * Google Apps Script for WalkingWR POI Database
   * 
   * This script runs inside Google Sheets and automatically converts
   * your POI data to JSON format, matching the prepopulated_pois.json structure
   * 
   * Setup:
   * 1. Open your Google Sheet
   * 2. Extensions → Apps Script
   * 3. Paste this code
   * 4. Save and run
   */

  // Configuration
  const CONFIG = {
    // Firebase Storage upload
    UPLOAD_TO_FIREBASE: true,  // Set to true after setting up service account
    FIREBASE_STORAGE_BUCKET: 'doctorwaittimes.firebasestorage.app',
    FIREBASE_FILE_NAME: 'prepopulated_pois.json',
    FIREBASE_PROJECT_ID: 'doctorwaittimes',
    
    // Split database by postcode for smaller downloads (~500KB vs 11MB)
    SPLIT_BY_POSTCODE: true,  // Creates prepopulated_pois_S10.json, etc.
    
    // Or save to Google Drive
    SAVE_TO_DRIVE: true,
    DRIVE_FOLDER_NAME: 'WalkingWR Database',
    DRIVE_FILE_NAME: 'prepopulated_pois.json',
    
    // Version increment
    AUTO_INCREMENT_VERSION: true,
    
    // Route regeneration
    REGENERATE_ROUTES: true,  // Automatically regenerate routes when POIs change
    ROUTE_DURATIONS: [5, 10, 15, 20, 30, 45, 60],  // Route durations to generate
    EXPORT_ROUTES_TO_SHEET: true  // Export routes to second tab
  };

  // Postcode area center coordinates (must match PrePopulatedPOIGenerator.swift and generate_database.py)
  const POSTCODE_CENTERS = {
    "WF2 0GU": { lat: 53.7029, lon: -1.5496, radius: 2500 },   // Wakefield area
    "S1": { lat: 53.3800, lon: -1.4700, radius: 2500 },        // Sheffield city centre
    "S2": { lat: 53.3750, lon: -1.4600, radius: 2500 },       // Sheffield S2
    "S3": { lat: 53.3850, lon: -1.4850, radius: 2500 },       // Sheffield S3
    "S4": { lat: 53.3900, lon: -1.4700, radius: 2500 },       // Sheffield S4
    "S5": { lat: 53.4100, lon: -1.4600, radius: 2500 },       // Sheffield S5
    "S6": { lat: 53.4000, lon: -1.5000, radius: 2500 },       // Sheffield S6
    "S7": { lat: 53.3600, lon: -1.4900, radius: 2500 },       // Sheffield S7
    "S8": { lat: 53.3500, lon: -1.4800, radius: 2500 },       // Sheffield S8
    "S9": { lat: 53.3900, lon: -1.4400, radius: 2500 },       // Sheffield S9
    "S10": { lat: 53.3800, lon: -1.5000, radius: 2500 },      // Sheffield S10
    "S11": { lat: 53.3700, lon: -1.5000, radius: 2500 },      // Sheffield S11
    "S12": { lat: 53.3600, lon: -1.4400, radius: 2500 },      // Sheffield S12
    "S13": { lat: 53.3850, lon: -1.4200, radius: 2500 },      // Sheffield S13
    "S14": { lat: 53.4000, lon: -1.4400, radius: 2500 },      // Sheffield S14
    "S17": { lat: 53.3550, lon: -1.5100, radius: 2500 },      // Sheffield S17
    "S20": { lat: 53.3400, lon: -1.4500, radius: 2500 },      // Sheffield S20
    "S21": { lat: 53.3300, lon: -1.4800, radius: 2500 },      // Sheffield S21
    "S25": { lat: 53.4200, lon: -1.4200, radius: 2500 },      // Sheffield S25
    "S26": { lat: 53.3450, lon: -1.4200, radius: 2500 },      // Sheffield S26
    "S35": { lat: 53.4200, lon: -1.4800, radius: 2500 },      // Sheffield S35
    "S36": { lat: 53.4350, lon: -1.5000, radius: 2500 }       // Sheffield S36
  };

  /**
   * Main function: Convert current sheet to JSON database
   */
  function convertSheetToJSON() {
    try {
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      let sheet = SpreadsheetApp.getActiveSheet();
      const sheetName = sheet.getName();
      
      // If user is on Routes sheet, try to find the main POI sheet
      if (sheetName === 'Routes' || sheetName.toLowerCase().includes('route')) {
        Logger.log(`⚠️  Active sheet is "${sheetName}" - looking for main POI sheet...`);
        
        // Try to find the first sheet that's not "Routes"
        const allSheets = spreadsheet.getSheets();
        for (const s of allSheets) {
          const name = s.getName();
          if (name !== 'Routes' && !name.toLowerCase().includes('route')) {
            sheet = s;
            Logger.log(`✅ Using sheet "${name}" instead`);
            break;
          }
        }
        
        // If we couldn't find another sheet, show error
        if (sheet.getName() === sheetName) {
          throw new Error(
            `You're currently on the "Routes" sheet, but "Convert to JSON" needs the main POI data sheet.\n\n` +
            `Please:\n` +
            `1. Switch to the sheet with your POI data (columns: Postcode, Place ID, Name, Latitude, Longitude, etc.)\n` +
            `2. Then run "Convert to JSON" again`
          );
        }
      }
      
      Logger.log(`📊 Processing sheet: "${sheet.getName()}"`);
      
      const data = sheet.getDataRange().getValues();
      
      if (data.length < 2) {
        throw new Error(`Sheet "${sheet.getName()}" must have at least a header row and one data row`);
      }
      
      // Get headers
      const headers = data[0];
      const headerMap = {};
      headers.forEach((header, index) => {
        headerMap[header.toLowerCase()] = index;
      });
      
      // Map common column name variations
      const columnMapping = {
        'postcode': ['postcode', 'post code', 'postal code', 'postalcode'],
        'placeid': ['placeid', 'place id', 'place_id', 'placeId'],
        'name': ['name', 'poi name', 'poiname', 'title'],
        'latitude': ['latitude', 'lat', 'lat.', 'y'],
        'longitude': ['longitude', 'long', 'lon', 'lng', 'long.', 'x'],
        'types': ['types', 'type', 'categories', 'category'],
        'source': ['source', 'data source', 'datasource'],
        'vicinity': ['vicinity', 'address', 'location'],
        'rating': ['rating', 'score', 'stars']
      };
      
      // Find actual column indices (handle variations)
      const columnIndices = {};
      for (const [key, variations] of Object.entries(columnMapping)) {
        let found = false;
        let foundIndex = null;
        
        for (const variation of variations) {
          const lowerVariation = variation.toLowerCase().trim();
          // Check if column exists (use !== undefined because index 0 is falsy!)
          if (headerMap[lowerVariation] !== undefined) {
            foundIndex = headerMap[lowerVariation];
            found = true;
            break;
          }
        }
        
        if (found) {
          columnIndices[key] = foundIndex;
        } else if (['postcode', 'placeid', 'name', 'latitude', 'longitude', 'types', 'source'].includes(key)) {
          // Show helpful error with available columns
          const availableColumns = headers.map((h, i) => `"${h}"`).join(', ');
          const headerMapKeys = Object.keys(headerMap).join(', ');
          throw new Error(
            `Missing required column: "${key}"\n\n` +
            `Required columns: postcode, placeId, name, latitude, longitude, types, source\n` +
            `Found columns: ${availableColumns}\n` +
            `Header map keys: ${headerMapKeys}\n\n` +
            `Tip: Column names are case-insensitive. Make sure your sheet has a column named "${key}" (or similar).`
          );
        }
      }
      
      // Group POIs by postcode
      const poisByPostcode = {};
      const postcodeAreas = [];
      const processedPostcodes = new Set();
      
      // Process data rows (skip header)
      for (let i = 1; i < data.length; i++) {
        const row = data[i];
        
        const postcode = String(row[columnIndices['postcode']] || '').trim();
        if (!postcode) continue;
        
        // Get POI data
        const placeId = String(row[columnIndices['placeid']] || '').trim();
        const name = String(row[columnIndices['name']] || '').trim();
        const lat = parseFloat(row[columnIndices['latitude']] || 0);
        const lon = parseFloat(row[columnIndices['longitude']] || 0);
        const typesStr = String(row[columnIndices['types']] || '').trim();
        const types = typesStr ? typesStr.split(',').map(t => t.trim()).filter(t => t) : [];
        const vicinity = columnIndices['vicinity'] !== undefined ? String(row[columnIndices['vicinity']] || '').trim() : null;
        const vicinityValue = vicinity && vicinity.length > 0 ? vicinity : null;
        const source = String(row[columnIndices['source']] || '').trim();
        const ratingStr = columnIndices['rating'] !== undefined ? String(row[columnIndices['rating']] || '').trim() : '';
        const rating = ratingStr ? parseFloat(ratingStr) : null;
        
        // Create POI object
        const poi = {
          placeId: placeId,
          name: name,
          latitude: lat,
          longitude: lon,
          types: types,
          vicinity: vicinityValue,
          source: source,
          rating: rating
        };
        
        // Group by postcode
        if (!poisByPostcode[postcode]) {
          poisByPostcode[postcode] = {
            postcode: postcode,
            pois: []
          };
        }
        poisByPostcode[postcode].pois.push(poi);
      }
      
      // Load existing database structure (if available) or create new
      let database = {
        version: 1,
        lastUpdated: new Date().toISOString(),
        postcodeAreas: []
      };
      
      // Try to load existing structure from Drive (to preserve routes)
      const existingDb = loadExistingDatabase();
      if (existingDb) {
        database = existingDb;
        // Always update lastUpdated to ISO8601 string format (never numeric)
        database.lastUpdated = new Date().toISOString();
        
        // Ensure version is a number (not string)
        if (typeof database.version === 'string') {
          database.version = parseInt(database.version, 10) || 1;
        }
        
        if (CONFIG.AUTO_INCREMENT_VERSION) {
          database.version = (database.version || 1) + 1;
        }
        
        // Track which postcode areas changed (for route regeneration)
        const updatedPostcodes = [];
        
        // Update POIs for each postcode area and fix any missing center coordinates
        for (const area of database.postcodeAreas) {
          const oldPoiCount = area.pois ? area.pois.length : 0;
          
          if (poisByPostcode[area.postcode]) {
            area.pois = poisByPostcode[area.postcode].pois;
            const newPoiCount = area.pois.length;
            
            // Track if POI count changed (indicates new POIs added)
            if (oldPoiCount !== newPoiCount) {
              updatedPostcodes.push({
                postcode: area.postcode,
                lat: area.centerLatitude,
                lon: area.centerLongitude
              });
              Logger.log(`📊 POI count changed for '${area.postcode}': ${oldPoiCount} → ${newPoiCount}`);
            }
          }
          
          // Fix missing or invalid center coordinates (0, 0)
          if (!area.centerLatitude || !area.centerLongitude || 
              (area.centerLatitude === 0 && area.centerLongitude === 0)) {
            const center = POSTCODE_CENTERS[area.postcode];
            if (center) {
              area.centerLatitude = center.lat;
              area.centerLongitude = center.lon;
              area.radiusMeters = center.radius;
              Logger.log(`🔧 Fixed center coordinates for '${area.postcode}': (${center.lat}, ${center.lon})`);
            } else {
              Logger.log(`⚠️  Postcode '${area.postcode}' has (0, 0) coordinates but is not in POSTCODE_CENTERS!`);
            }
          }
        }
        
        // Check if Routes sheet exists and has data - if so, use those routes instead of regenerating
        const routesSheet = spreadsheet.getSheetByName('Routes');
        let useRoutesFromSheet = false;

        if (routesSheet) {
          const routeData = routesSheet.getDataRange().getValues();
          // Check if Routes sheet has data (header + at least 1 route)
          if (routeData.length >= 2) {
            // Check if it has the expected columns (Postcode, Polyline, etc.)
            const headers = routeData[0];
            const hasPostcodeCol = headers.some(h => h.toString().toLowerCase().includes('postcode'));
            const hasPolylineCol = headers.some(h => h.toString().toLowerCase().includes('polyline'));

            if (hasPostcodeCol && hasPolylineCol) {
              useRoutesFromSheet = true;
              Logger.log(`📋 Routes sheet found with ${routeData.length - 1} route(s) - importing instead of regenerating`);
            }
          }
        }

        if (useRoutesFromSheet) {
          // Import routes from Routes sheet
          Logger.log(`📥 Importing routes from Routes sheet...`);
          try {
            const routeData = routesSheet.getDataRange().getValues();
            const routesByPostcode = {};

            // Get POI data from main sheet for waypoint matching
            const poiData = sheet.getDataRange().getValues();
            const poiHeaders = poiData[0];
            const nameIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('name'));
            const latIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('lat'));
            const lonIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('lon'));
            const placeIdIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('placeid'));
            const typesIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('types'));
            const sourceIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('source'));
            const vicinityIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('vicinity'));

            // Process routes from sheet
            for (let i = 1; i < routeData.length; i++) {
              const row = routeData[i];
              const postcode = row[0]; // Column A
              const duration = row[1]; // Column B
              const name = row[3] || null; // Column D
              const description = row[4] || null; // Column E
              const waypoint1 = row[6]; // Column G
              const waypoint2 = row[7]; // Column H
              const waypoint3 = row[8]; // Column I
              const distanceM = row[9] || 0; // Column J
              const durationSec = row[10] || 0; // Column K
              const polyline = row[11] || ''; // Column L

              if (!postcode || !polyline) continue; // Skip invalid rows

              // Find POIs for waypoints
              const waypointPOIs = [];
              [waypoint1, waypoint2, waypoint3].forEach(wp => {
                if (wp) {
                  const wpName = wp.split(' (')[0].trim();
                  for (let j = 1; j < poiData.length; j++) {
                    const poiName = String(poiData[j][nameIndex] || '').trim();
                    if (poiName === wpName || poiName.toLowerCase() === wpName.toLowerCase()) {
                      const typesStr = poiData[j][typesIndex] || '';
                      waypointPOIs.push({
                        placeId: poiData[j][placeIdIndex] || '',
                        name: poiData[j][nameIndex] || '',
                        latitude: parseFloat(poiData[j][latIndex]) || 0,
                        longitude: parseFloat(poiData[j][lonIndex]) || 0,
                        types: typesStr ? typesStr.split(',').map(t => t.trim()).filter(t => t) : [],
                        vicinity: poiData[j][vicinityIndex] || null,
                        source: poiData[j][sourceIndex] || 'manual',
                        rating: null
                      });
                      break;
                    }
                  }
                }
              });

              if (waypointPOIs.length === 0) continue;

              // Group by postcode and duration
              const key = `${postcode}_${duration}`;
              if (!routesByPostcode[key]) {
                routesByPostcode[key] = {
                  postcode: postcode,
                  duration: duration,
                  routes: []
                };
              }

              routesByPostcode[key].routes.push({
                places: waypointPOIs,
                polyline: polyline,
                distanceMeters: distanceM,
                durationSeconds: durationSec,
                name: name,
                description: description,
                directions: null
              });
            }

            // Update database with imported routes
            for (const area of database.postcodeAreas) {
              const routesByDuration = {};
              for (const key in routesByPostcode) {
                const routeGroup = routesByPostcode[key];
                if (routeGroup.postcode === area.postcode) {
                  routesByDuration[routeGroup.duration] = routeGroup.routes;
                }
              }

              if (Object.keys(routesByDuration).length > 0) {
                area.routes = Object.keys(routesByDuration).map(duration => ({
                  durationMinutes: parseInt(duration, 10),
                  routes: routesByDuration[duration]
                }));
              }
            }

            Logger.log(`✅ Successfully imported routes from Routes sheet`);
          } catch (importError) {
            Logger.log(`⚠️  Error importing routes from sheet: ${importError}`);
            Logger.log(`   Falling back to route regeneration...`);
            // Fall back to regeneration if import fails
            if (CONFIG.REGENERATE_ROUTES && updatedPostcodes.length > 0) {
              Logger.log(`🔄 Regenerating routes for ${updatedPostcodes.length} updated postcode area(s)...`);
              regenerateRoutesForPostcodes(database, updatedPostcodes);
            }
          }
        } else {
          // No Routes sheet or it's empty - regenerate routes if needed
          if (CONFIG.REGENERATE_ROUTES && updatedPostcodes.length > 0) {
            Logger.log(`🔄 Regenerating routes for ${updatedPostcodes.length} updated postcode area(s)...`);
            regenerateRoutesForPostcodes(database, updatedPostcodes);
          }
        }
      } else {
        // Create new structure using predefined center coordinates
        for (const postcode in poisByPostcode) {
          const center = POSTCODE_CENTERS[postcode];
          if (center) {
            postcodeAreas.push({
              postcode: postcode,
              centerLatitude: center.lat,
              centerLongitude: center.lon,
              radiusMeters: center.radius,
              pois: poisByPostcode[postcode].pois,
              routes: null // Routes can be generated separately
            });
            Logger.log(`✅ Created postcode area '${postcode}' with center (${center.lat}, ${center.lon})`);
          } else {
            Logger.log(`⚠️  Postcode '${postcode}' not in POSTCODE_CENTERS - using (0, 0). Add it to the config!`);
            postcodeAreas.push({
              postcode: postcode,
              centerLatitude: 0,
              centerLongitude: 0,
              radiusMeters: 2500,
              pois: poisByPostcode[postcode].pois,
              routes: null
            });
          }
        }
        database.postcodeAreas = postcodeAreas;
      }
      
      // Validate database before converting
      if (database.postcodeAreas.length === 0) {
        throw new Error('No POIs found in sheet. Make sure your sheet has data rows (not just headers).');
      }
      
      // Convert to JSON
      let jsonString;
      try {
        jsonString = JSON.stringify(database, null, 2);
        
        // Validate JSON was created
        if (!jsonString || jsonString.length < 50) {
          throw new Error('Generated JSON is too short - something went wrong');
        }
      } catch (jsonError) {
        throw new Error(`Failed to convert to JSON: ${jsonError}`);
      }
      
      // Save to Drive
      if (CONFIG.SAVE_TO_DRIVE) {
        try {
          saveToDrive(jsonString);
        } catch (driveError) {
          Logger.log(`Error saving to Drive: ${driveError}`);
          throw new Error(`Failed to save to Google Drive: ${driveError}`);
        }
      }
      
      // Upload to Firebase (if configured)
      let firebaseStatus = '';
      if (CONFIG.UPLOAD_TO_FIREBASE) {
        try {
          // Upload full database
          uploadToFirebase(jsonString);
          firebaseStatus = '\n   ✅ Uploaded to Firebase Storage';
          
          // Also split and upload postcode-specific files (smaller downloads for app)
          if (CONFIG.SPLIT_BY_POSTCODE) {
            try {
              const splitCount = splitAndUploadByPostcode(database);
              firebaseStatus += `\n   ✅ Split into ${splitCount} postcode files`;
            } catch (splitError) {
              firebaseStatus += `\n   ⚠️  Split upload failed: ${splitError}`;
              Logger.log(`Split upload error: ${splitError}`);
            }
          }
        } catch (error) {
          firebaseStatus = `\n   ⚠️  Firebase upload failed: ${error}`;
          Logger.log(`Firebase upload error: ${error}`);
        }
      }
      
      // Export routes to second tab if enabled
      if (CONFIG.EXPORT_ROUTES_TO_SHEET) {
        try {
          Logger.log('📊 Exporting routes to Routes sheet...');
          exportRoutesToSheet(database);
          Logger.log('✅ Routes export completed');
        } catch (routeError) {
          Logger.log(`⚠️  Error exporting routes to sheet: ${routeError}`);
          Logger.log(`   Error details: ${routeError.stack || routeError.message || routeError}`);
        }
      }
      
      // Show success message
      const totalRoutes = database.postcodeAreas.reduce((sum, area) => {
        if (area.routes) {
          return sum + area.routes.reduce((s, rg) => s + (rg.routes ? rg.routes.length : 0), 0);
        }
        return sum;
      }, 0);
      
      const totalPOIs = database.postcodeAreas.reduce((sum, area) => {
        return sum + (area.pois ? area.pois.length : 0);
      }, 0);
      
      const message = `✅ Converted ${database.postcodeAreas.length} postcode areas\n` +
                    `   Total POIs: ${totalPOIs}\n` +
                    `   Total Routes: ${totalRoutes}\n` +
                    `   Version: ${database.version}\n` +
                    `   Saved to Google Drive${firebaseStatus}`;
      
      try {
        SpreadsheetApp.getUi().alert('Success', message, SpreadsheetApp.getUi().ButtonSet.OK);
      } catch (alertError) {
        Logger.log(`⚠️ Could not show success alert: ${alertError}`);
        // Don't throw - the operation was successful even if alert fails
      }
      
      return jsonString;
      
    } catch (error) {
      // Log full error details for debugging
      Logger.log(`❌ Error in convertSheetToJSON: ${error}`);
      Logger.log(`   Stack: ${error.stack || 'No stack trace'}`);
      
      // Show user-friendly error
      const errorMessage = error.toString() || 'Unknown error occurred';
      SpreadsheetApp.getUi().alert(
        'Error Converting Sheet', 
        `An error occurred while converting your sheet:\n\n${errorMessage}\n\nCheck the Apps Script execution log for more details.`, 
        SpreadsheetApp.getUi().ButtonSet.OK
      );
      throw error;
    }
  }

  /**
   * Load existing database from Google Drive (to preserve routes)
   */
  function loadExistingDatabase() {
    try {
      const folders = DriveApp.getFoldersByName(CONFIG.DRIVE_FOLDER_NAME);
      if (!folders.hasNext()) {
        Logger.log('No existing database folder found - will create new');
        return null;
      }
      
      const folder = folders.next();
      const files = folder.getFilesByName(CONFIG.DRIVE_FILE_NAME);
      
      // Get the most recent file (in case there are multiple with same name)
      let mostRecentFile = null;
      let mostRecentDate = null;
      
      while (files.hasNext()) {
        const file = files.next();
        const lastModified = file.getLastUpdated();
        if (!mostRecentFile || lastModified > mostRecentDate) {
          mostRecentFile = file;
          mostRecentDate = lastModified;
        }
      }
      
      if (!mostRecentFile) {
        Logger.log('No database file found in folder');
        return null;
      }
      
      Logger.log(`📦 Found database file: ${mostRecentFile.getName()}`);
      Logger.log(`📦 Last modified: ${mostRecentDate}`);
      Logger.log(`📦 File size: ${(mostRecentFile.getSize() / 1024 / 1024).toFixed(2)} MB`);
      
      const content = mostRecentFile.getBlob().getDataAsString();
      
      // Check if content is empty or invalid
      if (!content || content.trim().length === 0) {
        Logger.log('Existing database file is empty - will create new');
        return null;
      }
      
      try {
        const parsed = JSON.parse(content);
        
        // Validate structure
        if (!parsed.postcodeAreas || !Array.isArray(parsed.postcodeAreas)) {
          Logger.log('Existing database has invalid structure - will create new');
          return null;
        }
        
        // Fix old format: if lastUpdated is a number, convert to ISO8601 string
        if (typeof parsed.lastUpdated === 'number') {
          Logger.log('⚠️  Old format detected: converting numeric timestamp to ISO8601 string');
          const date = new Date(parsed.lastUpdated * 1000); // Convert Unix timestamp to Date
          parsed.lastUpdated = date.toISOString();
        } else if (typeof parsed.lastUpdated !== 'string') {
          // If it's not a string or number, set to current time
          Logger.log('⚠️  Invalid lastUpdated format: setting to current time');
          parsed.lastUpdated = new Date().toISOString();
        }
        
        // Ensure version is a number
        if (typeof parsed.version === 'string') {
          parsed.version = parseInt(parsed.version, 10) || 1;
        }
        
        Logger.log(`✅ Loaded existing database with ${parsed.postcodeAreas.length} postcode areas`);
        const totalPOIs = parsed.postcodeAreas.reduce((sum, area) => sum + (area.pois ? area.pois.length : 0), 0);
        Logger.log(`✅ Total POIs in database: ${totalPOIs}`);
        Logger.log(`✅ Postcodes: ${parsed.postcodeAreas.map(a => a.postcode).join(', ')}`);
        return parsed;
      } catch (parseError) {
        Logger.log(`Error parsing existing database: ${parseError} - will create new`);
        return null;
      }
    } catch (e) {
      Logger.log(`Error loading existing database: ${e} - will create new`);
    }
    return null;
  }

  /**
   * Save JSON to Google Drive
   */
  function saveToDrive(jsonString) {
    try {
      // Get or create folder
      let folder;
      const folders = DriveApp.getFoldersByName(CONFIG.DRIVE_FOLDER_NAME);
      if (folders.hasNext()) {
        folder = folders.next();
      } else {
        folder = DriveApp.createFolder(CONFIG.DRIVE_FOLDER_NAME);
      }
      
      // Check if file exists
      const files = folder.getFilesByName(CONFIG.DRIVE_FILE_NAME);
      let file;
      
      if (files.hasNext()) {
        file = files.next();
        file.setContent(jsonString);
        Logger.log('Updated existing file');
      } else {
        file = folder.createFile(CONFIG.DRIVE_FILE_NAME, jsonString, 'application/json');
        Logger.log('Created new file');
      }
      
      // Make file accessible
      file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
      
      Logger.log(`✅ Saved to: ${file.getUrl()}`);
      return file.getUrl();
      
    } catch (error) {
      Logger.log(`❌ Error saving to Drive: ${error}`);
      throw error;
    }
  }

  /**
   * Extract postcode district from full postcode (e.g., 'S1 4JP' -> 'S1', 'WF2 0GU' -> 'WF2')
   */
  function extractPostcodeDistrict(postcode) {
    // For full postcodes with space (like "WF2 0GU"), take only the outward code (before space)
    if (postcode.includes(' ')) {
      return postcode.split(' ')[0].toUpperCase();
    }
    
    // For postcodes without space, extract district
    const cleaned = postcode.toUpperCase();
    let district = '';
    for (const char of cleaned) {
      if (/\d/.test(char)) break;
      district += char;
    }
    for (const char of cleaned.slice(district.length)) {
      if (/\d/.test(char)) {
        district += char;
      } else {
        break;
      }
    }
    return district;
  }

  /**
   * Split database by postcode district and upload each as a separate file
   * This allows the app to download only the relevant postcode (~500KB vs 11MB)
   */
  function splitAndUploadByPostcode(database) {
    Logger.log('📦 Splitting database by postcode district...');
    
    // Group areas by district
    const areasByDistrict = {};
    for (const area of database.postcodeAreas) {
      const district = extractPostcodeDistrict(area.postcode);
      if (!areasByDistrict[district]) {
        areasByDistrict[district] = [];
      }
      areasByDistrict[district].push(area);
    }
    
    const districts = Object.keys(areasByDistrict);
    Logger.log(`   Found ${districts.length} postcode districts`);
    
    // Get access token once for all uploads
    const serviceAccountJson = PropertiesService.getScriptProperties().getProperty('FIREBASE_SERVICE_ACCOUNT');
    if (!serviceAccountJson) {
      throw new Error('Firebase service account not configured');
    }
    const serviceAccount = JSON.parse(serviceAccountJson);
    const accessToken = getFirebaseAccessToken(serviceAccount);
    
    // Upload each district as a separate file
    let uploadedCount = 0;
    for (const district of districts) {
      const districtDatabase = {
        version: database.version,
        lastUpdated: database.lastUpdated,
        postcodeAreas: areasByDistrict[district]
      };
      
      const districtJson = JSON.stringify(districtDatabase, null, 2);
      const fileName = `prepopulated_pois_${district}.json`;
      
      try {
        uploadToFirebaseWithToken(districtJson, fileName, accessToken);
        const totalPois = areasByDistrict[district].reduce((sum, a) => sum + (a.pois?.length || 0), 0);
        Logger.log(`   ✅ ${fileName}: ${areasByDistrict[district].length} area(s), ${totalPois} POIs`);
        uploadedCount++;
      } catch (e) {
        Logger.log(`   ❌ Failed to upload ${fileName}: ${e}`);
      }
      
      // Small delay between uploads
      Utilities.sleep(200);
    }
    
    Logger.log(`✅ Uploaded ${uploadedCount}/${districts.length} postcode files`);
    return uploadedCount;
  }

  /**
   * Upload to Firebase Storage with a pre-obtained access token
   */
  function uploadToFirebaseWithToken(jsonString, fileName, accessToken) {
    const bucket = CONFIG.FIREBASE_STORAGE_BUCKET;
    const uploadUrl = `https://storage.googleapis.com/upload/storage/v1/b/${bucket}/o?uploadType=media&name=${encodeURIComponent(fileName)}`;
    
    const options = {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json'
      },
      payload: jsonString,
      muteHttpExceptions: true
    };
    
    const response = UrlFetchApp.fetch(uploadUrl, options);
    
    if (response.getResponseCode() !== 200) {
      throw new Error(`Upload failed: ${response.getResponseCode()}`);
    }
    
    return JSON.parse(response.getContentText());
  }

  /**
   * Upload to Firebase Storage using REST API
   * Requires service account key stored in Script Properties
   */
  function uploadToFirebase(jsonString) {
    try {
      // Get service account key from Script Properties
      const serviceAccountJson = PropertiesService.getScriptProperties().getProperty('FIREBASE_SERVICE_ACCOUNT');
      
      if (!serviceAccountJson) {
        throw new Error('Firebase service account not configured. Run setupFirebaseServiceAccount() first.');
      }
      
      const serviceAccount = JSON.parse(serviceAccountJson);
      
      // Generate OAuth2 access token
      let accessToken;
      try {
        accessToken = getFirebaseAccessToken(serviceAccount);
      } catch (tokenError) {
        throw new Error(`Failed to get Firebase access token: ${tokenError.message || tokenError}`);
      }
      
      if (!accessToken) {
        throw new Error('Access token is null or undefined');
      }
      
      // Upload to Firebase Storage using REST API
      const bucket = CONFIG.FIREBASE_STORAGE_BUCKET;
      const fileName = CONFIG.FIREBASE_FILE_NAME;
      const uploadUrl = `https://storage.googleapis.com/upload/storage/v1/b/${bucket}/o?uploadType=media&name=${encodeURIComponent(fileName)}`;
      
      const options = {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${accessToken}`,
          'Content-Type': 'application/json'
        },
        payload: jsonString
      };
      
      Logger.log(`📤 Uploading to Firebase Storage: ${fileName}`);
      const response = UrlFetchApp.fetch(uploadUrl, options);
      
      if (response.getResponseCode() !== 200) {
        const errorText = response.getContentText();
        throw new Error(`Firebase upload failed: ${response.getResponseCode()} - ${errorText}`);
      }
      
      const result = JSON.parse(response.getContentText());
      Logger.log(`✅ Upload successful! File: ${result.name}`);
      
      // Make file publicly readable (update metadata)
      const metadataUrl = `https://storage.googleapis.com/storage/v1/b/${bucket}/o/${encodeURIComponent(fileName)}`;
      const metadataOptions = {
        method: 'PATCH',
        headers: {
          'Authorization': `Bearer ${accessToken}`,
          'Content-Type': 'application/json'
        },
        payload: JSON.stringify({
          metadata: {
            firebaseStorageDownloadTokens: result.metadata?.firebaseStorageDownloadTokens || ''
          }
        })
      };
      
      // Try to make public (may require Storage rules)
      try {
        UrlFetchApp.fetch(metadataUrl, metadataOptions);
      } catch (e) {
        Logger.log(`⚠️  Could not update metadata (this is OK if Storage rules allow public read)`);
      }
      
      return result;
      
    } catch (error) {
      Logger.log(`❌ Firebase upload error: ${error}`);
      throw error;
    }
  }

  /**
   * Get OAuth2 access token from service account
   */
  function getFirebaseAccessToken(serviceAccount) {
    try {
      // Validate service account has required fields
      if (!serviceAccount.client_email) {
        throw new Error('Service account missing client_email');
      }
      if (!serviceAccount.private_key) {
        throw new Error('Service account missing private_key');
      }
      
      Logger.log('Creating JWT for service account...');
      const jwt = createJWT(serviceAccount);
      
      if (!jwt || jwt.length < 100) {
        throw new Error('JWT creation failed - token too short');
      }
      
      Logger.log('Requesting OAuth2 access token...');
      const tokenUrl = 'https://oauth2.googleapis.com/token';
      const payload = {
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: jwt
      };
      
      const options = {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        payload: Object.keys(payload).map(key => 
          `${encodeURIComponent(key)}=${encodeURIComponent(payload[key])}`
        ).join('&')
      };
      
      const response = UrlFetchApp.fetch(tokenUrl, options);
      const responseCode = response.getResponseCode();
      const responseText = response.getContentText();
      
      Logger.log(`Token request response code: ${responseCode}`);
      
      if (responseCode !== 200) {
        throw new Error(`OAuth2 token request failed with code ${responseCode}: ${responseText}`);
      }
      
      const result = JSON.parse(responseText);
      
      if (result.access_token) {
        Logger.log('✅ Successfully obtained access token');
        return result.access_token;
      } else {
        throw new Error(`Token request failed - no access_token in response: ${JSON.stringify(result)}`);
      }
      
    } catch (error) {
      Logger.log(`❌ Error getting access token: ${error}`);
      Logger.log(`   Error type: ${error.name || typeof error}`);
      Logger.log(`   Error message: ${error.message || error}`);
      throw error; // Re-throw so caller can see the actual error
    }
  }

  /**
   * Create JWT for service account authentication
   */
  function createJWT(serviceAccount) {
    try {
      const now = Math.floor(Date.now() / 1000);
      const header = {
        alg: 'RS256',
        typ: 'JWT'
      };
      
      const claim = {
        iss: serviceAccount.client_email,
        scope: 'https://www.googleapis.com/auth/devstorage.read_write',
        aud: 'https://oauth2.googleapis.com/token',
        exp: now + 3600, // 1 hour
        iat: now
      };
      
      const encodedHeader = Utilities.base64EncodeWebSafe(JSON.stringify(header));
      const encodedClaim = Utilities.base64EncodeWebSafe(JSON.stringify(claim));
      const signatureInput = `${encodedHeader}.${encodedClaim}`;
      
      // Prepare private key for Google Apps Script
      // Google Apps Script's computeRsaSha256Signature is very picky about key format
      let privateKey = serviceAccount.private_key;
      if (!privateKey) {
        throw new Error('Private key is empty or missing');
      }
      
      // Try different key formats - Google Apps Script can be picky
      let signature;
      let lastError = null;
      
      // Format 1: Remove PEM headers, keep only base64 content, no whitespace
      let keyFormat1 = privateKey.trim();
      keyFormat1 = keyFormat1.replace(/-----BEGIN PRIVATE KEY-----\s*/g, '');
      keyFormat1 = keyFormat1.replace(/\s*-----END PRIVATE KEY-----/g, '');
      keyFormat1 = keyFormat1.replace(/\s/g, '');
      
      // Format 2: Keep PEM format with proper line breaks
      let keyFormat2 = privateKey.trim();
      if (!keyFormat2.includes('\n') && keyFormat2.length > 64) {
        // If it's all on one line, try to add line breaks every 64 chars (PEM standard)
        keyFormat2 = keyFormat2.replace(/(.{64})/g, '$1\n');
      }
      
      // Format 3: Original key as-is
      let keyFormat3 = privateKey.trim();
      
      // Try each format
      const formats = [
        { name: 'Base64 only (no PEM headers)', key: keyFormat1 },
        { name: 'PEM format with line breaks', key: keyFormat2 },
        { name: 'Original format', key: keyFormat3 }
      ];
      
      for (const format of formats) {
        try {
          Logger.log(`Trying key format: ${format.name} (length: ${format.key.length})`);
          signature = Utilities.computeRsaSha256Signature(signatureInput, format.key);
          Logger.log(`✅ Success with format: ${format.name}`);
          break; // Success!
        } catch (formatError) {
          lastError = formatError;
          Logger.log(`❌ Failed with ${format.name}: ${formatError.message || formatError}`);
          continue; // Try next format
        }
      }
      
      // If all formats failed
      if (!signature) {
        throw new Error(`All key format attempts failed. Last error: ${lastError ? lastError.message || lastError : 'Unknown error'}. Make sure your service account key is valid.`);
      }
      
      if (!signature || signature.length === 0) {
        throw new Error('Signature generation returned empty result');
      }
      
      const encodedSignature = Utilities.base64EncodeWebSafe(signature);
      const jwt = `${signatureInput}.${encodedSignature}`;
      
      if (!jwt || jwt.length < 100) {
        throw new Error('Generated JWT is invalid (too short)');
      }
      
      return jwt;
      
    } catch (error) {
      Logger.log(`❌ Error creating JWT: ${error}`);
      throw new Error(`JWT creation failed: ${error.message || error}`);
    }
  }

  /**
   * Setup Firebase Service Account (run this once)
   * 
   * Instructions:
   * 1. Go to Firebase Console → Project Settings → Service Accounts
   * 2. Click "Generate new private key"
   * 3. Copy the entire JSON content
   * 4. Run this function and paste the JSON when prompted
   */
  function setupFirebaseServiceAccount() {
    const ui = SpreadsheetApp.getUi();
    
    const response = ui.prompt(
      'Firebase Service Account Setup',
      'Paste your Firebase service account JSON key:\n\n' +
      '1. Go to Firebase Console → Project Settings → Service Accounts\n' +
      '2. Click "Generate new private key"\n' +
      '3. Copy the entire JSON and paste here:',
      ui.ButtonSet.OK_CANCEL
    );
    
    if (response.getSelectedButton() === ui.Button.OK) {
      const jsonKey = response.getResponseText().trim();
      
      try {
        // Validate JSON
        if (!jsonKey || jsonKey.length < 100) {
          throw new Error('JSON key appears to be too short. Make sure you copied the entire key.');
        }
        
        const parsed = JSON.parse(jsonKey);
        
        // Check for required fields
        if (!parsed.client_email) {
          throw new Error('Missing client_email field in service account key');
        }
        if (!parsed.private_key) {
          throw new Error('Missing private_key field in service account key');
        }
        if (!parsed.project_id && !parsed.projectId) {
          Logger.log('Warning: project_id not found in service account key (may still work)');
        }
        
        // Validate private key format
        if (!parsed.private_key.includes('BEGIN PRIVATE KEY')) {
          throw new Error('Private key format appears invalid - should contain "BEGIN PRIVATE KEY"');
        }
        
        // Store in Script Properties (encrypted by Google)
        PropertiesService.getScriptProperties().setProperty('FIREBASE_SERVICE_ACCOUNT', jsonKey);
        
        Logger.log('✅ Service account stored successfully');
        Logger.log(`   Client email: ${parsed.client_email}`);
        
        ui.alert(
          'Success', 
          'Firebase service account configured!\n\n' +
          `Client email: ${parsed.client_email}\n\n` +
          'You can now enable UPLOAD_TO_FIREBASE in CONFIG.', 
          ui.ButtonSet.OK
        );
        
      } catch (error) {
        Logger.log(`❌ Error setting up service account: ${error}`);
        ui.alert('Error', `Failed to configure service account:\n\n${error.message || error}`, ui.ButtonSet.OK);
      }
    }
  }

  /**
   * Calculate distance between two coordinates (Haversine formula)
   */
  function haversineDistance(lat1, lon1, lat2, lon2) {
    const R = 6371000; // Earth radius in meters
    const phi1 = lat1 * Math.PI / 180;
    const phi2 = lat2 * Math.PI / 180;
    const deltaPhi = (lat2 - lat1) * Math.PI / 180;
    const deltaLambda = (lon2 - lon1) * Math.PI / 180;
    
    const a = Math.sin(deltaPhi / 2) * Math.sin(deltaPhi / 2) +
              Math.cos(phi1) * Math.cos(phi2) *
              Math.sin(deltaLambda / 2) * Math.sin(deltaLambda / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    
    return R * c;
  }

  /**
   * Select waypoints for a route based on target duration
   */
  function selectWaypointsForRoute(pois, originLat, originLon, targetDurationMin) {
    if (!pois || pois.length === 0) return [];
    
    const WALKING_SPEED_M_PER_MIN = 80;
    const idealDistance = targetDurationMin * WALKING_SPEED_M_PER_MIN * 0.65;
    
    // Sort POIs by distance from origin
    const poisWithDistance = pois.map(poi => ({
      poi: poi,
      distance: haversineDistance(originLat, originLon, poi.latitude, poi.longitude)
    })).sort((a, b) => a.distance - b.distance);
    
    // Select waypoints
    const selected = [];
    let cumulativeDistance = 0;
    
    for (const { poi, distance } of poisWithDistance) {
      if (cumulativeDistance + distance * 2 <= idealDistance) {
        selected.push([poi.latitude, poi.longitude]);
        cumulativeDistance += distance * 2;
        if (selected.length >= 3) break; // Max 3 waypoints
      }
    }
    
    return selected;
  }

  /**
   * Generate a route using OSRM API
   */
  function generateRouteOSRM(originLat, originLon, waypoints, targetDurationMin) {
    try {
      // Build coordinates: origin → waypoints → origin (loop)
      const coords = [`${originLon},${originLat}`];
      waypoints.forEach(([lat, lon]) => coords.push(`${lon},${lat}`));
      coords.push(`${originLon},${originLat}`);
      
      const coordsStr = coords.join(';');
      const url = `http://router.project-osrm.org/route/v1/driving/${coordsStr}?overview=full&geometries=polyline&steps=true`;
      
      const response = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
      
      if (response.getResponseCode() === 200) {
        const data = JSON.parse(response.getContentText());
        
        if (data.code === 'Ok' && data.routes && data.routes.length > 0) {
          const route = data.routes[0];
          const distanceM = route.distance || 0;
          const geometry = route.geometry || '';
          
          // Convert driving time to walking time (80m/min)
          const walkingSpeedMPerMin = 80.0;
          const walkingMinutes = distanceM / walkingSpeedMPerMin;
          const walkingDurationSec = Math.round(walkingMinutes * 60);
          
          // Check if duration is within acceptable range (70-130% of target)
          const targetSec = targetDurationMin * 60;
          const minAcceptable = targetSec * 0.70;
          const maxAcceptable = targetSec * 1.30;
          
          if (walkingDurationSec >= minAcceptable && walkingDurationSec <= maxAcceptable) {
            return {
              polyline: geometry,
              distanceMeters: Math.round(distanceM),
              durationSeconds: walkingDurationSec
            };
          }
        }
      }
    } catch (e) {
      Logger.log(`⚠️ OSRM route generation failed: ${e}`);
    }
    
    return null;
  }

  /**
   * Regenerate routes for postcode areas that had POI changes
   */
  function regenerateRoutesForPostcodes(database, updatedPostcodes) {
    for (const { postcode, lat, lon } of updatedPostcodes) {
      Logger.log(`🗺️ Regenerating routes for ${postcode}...`);
      
      // Find the area in database
      const area = database.postcodeAreas.find(a => a.postcode === postcode);
      if (!area) {
        Logger.log(`⚠️ Postcode area ${postcode} not found in database`);
        continue;
      }
      
      const pois = area.pois || [];
      if (pois.length === 0) {
        Logger.log(`⚠️ No POIs for ${postcode}, skipping route generation`);
        continue;
      }
      
      // Generate routes for all durations
      const routesByDuration = {};
      
      for (const duration of CONFIG.ROUTE_DURATIONS) {
        Logger.log(`   Generating ${duration}min route...`);
        
        for (let attempt = 0; attempt < 5; attempt++) {
          const waypoints = selectWaypointsForRoute(pois, lat, lon, duration);
          if (waypoints.length === 0) break;
          
          const routeData = generateRouteOSRM(lat, lon, waypoints, duration);
          if (routeData) {
            if (!routesByDuration[duration]) {
              routesByDuration[duration] = [];
            }
            
            if (routesByDuration[duration].length < 3) {
              // Get POI details for waypoints
              const routePOIs = waypoints.map(([wpLat, wpLon]) => {
                // Find matching POI
                return pois.find(poi => 
                  Math.abs(poi.latitude - wpLat) < 0.0001 && 
                  Math.abs(poi.longitude - wpLon) < 0.0001
                );
              }).filter(poi => poi).map(poi => ({
                placeId: poi.placeId,
                name: poi.name,
                latitude: poi.latitude,
                longitude: poi.longitude,
                types: poi.types,
                vicinity: poi.vicinity,
                source: poi.source,
                rating: poi.rating
              }));
              
              const routeEntry = {
                places: routePOIs,
                polyline: routeData.polyline,
                distanceMeters: routeData.distanceMeters,
                durationSeconds: routeData.durationSeconds,
                name: null,
                description: null,
                directions: null
              };
              
              routesByDuration[duration].push(routeEntry);
              Logger.log(`   ✅ Generated ${duration}min route (${routesByDuration[duration].length}/3)`);
              break;
            }
          }
          
          // Small delay to be respectful to OSRM API
          Utilities.sleep(500);
        }
      }
      
      // Update area with new routes
      const routeGroups = [];
      for (const duration in routesByDuration) {
        const routes = routesByDuration[duration];
        if (routes.length > 0) {
          routeGroups.push({
            durationMinutes: parseInt(duration, 10),
            routes: routes
          });
        }
      }
      
      area.routes = routeGroups;
      const totalRoutes = routeGroups.reduce((sum, rg) => sum + rg.routes.length, 0);
      Logger.log(`✅ Generated ${totalRoutes} routes across ${routeGroups.length} duration groups for ${postcode}`);
    }
  }

  /**
   * Export routes to a second tab in the Google Sheet
   */
  function exportRoutesToSheet(database) {
    try {
      // Check if database exists and is valid
      if (!database) {
        throw new Error('Database is null or undefined');
      }
      
      if (!database.postcodeAreas || !Array.isArray(database.postcodeAreas)) {
        throw new Error('Database does not have a valid postcodeAreas array');
      }
      
      Logger.log('📊 Starting routes export...');
      Logger.log(`   Database has ${database.postcodeAreas.length} postcode areas`);
      
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      let routesSheet = spreadsheet.getSheetByName('Routes');
      
      // Create Routes sheet if it doesn't exist
      if (!routesSheet) {
        routesSheet = spreadsheet.insertSheet('Routes');
        Logger.log('✅ Created Routes sheet');
      } else {
        // Clear existing data and validation rules
        // Clear all data validations first (before clear() which might preserve some)
        try {
          const lastRow = routesSheet.getLastRow();
          const lastCol = routesSheet.getLastColumn();
          if (lastRow > 0 && lastCol > 0) {
            const dataRange = routesSheet.getRange(1, 1, lastRow, lastCol);
            dataRange.clearDataValidations();
          }
        } catch (e) {
          // Ignore errors when clearing validations
        }
        routesSheet.clear();
        Logger.log('✅ Cleared existing Routes sheet');
      }
      
      // Headers
      const headers = [
        'Postcode', 'Duration (min)', 'Route Index', 'Waypoints', 'Waypoint Count',
        'Distance (m)', 'Duration (sec)', 'Duration (formatted)', 'Name', 'Description', 'Polyline'
      ];
      routesSheet.getRange(1, 1, 1, headers.length).setValues([headers]);
      routesSheet.getRange(1, 1, 1, headers.length).setFontWeight('bold');
      
      // Data rows
      const rows = [];
      let areasWithRoutes = 0;
      let totalRouteGroups = 0;
      
      for (const area of database.postcodeAreas) {
        const postcode = area.postcode || '';
        const routes = area.routes || [];
        
        if (routes.length > 0) {
          areasWithRoutes++;
          totalRouteGroups += routes.length;
        }
        
        for (const routeGroup of routes) {
          const duration = routeGroup.durationMinutes || 0;
          const routeList = routeGroup.routes || [];
          
          Logger.log(`   Processing ${postcode}: ${routeList.length} routes for ${duration}min`);
          
          for (let routeIdx = 0; routeIdx < routeList.length; routeIdx++) {
            const route = routeList[routeIdx];
            const waypointNames = (route.places || []).map(p => p.name || '').join(' → ');
            const polyline = route.polyline || '';
            const polylineDisplay = polyline.length > 100 ? polyline.substring(0, 100) + '...' : polyline;
            
            rows.push([
              postcode,
              duration,
              routeIdx + 1,
              waypointNames,
              (route.places || []).length,
              route.distanceMeters || 0,
              route.durationSeconds || 0,
              `${Math.floor((route.durationSeconds || 0) / 60)}min`,
              route.name || '',
              route.description || '',
              polylineDisplay
            ]);
          }
        }
      }
      
      Logger.log(`📊 Found ${areasWithRoutes} areas with routes, ${totalRouteGroups} route groups, ${rows.length} total routes`);
      
      if (rows.length > 0) {
        routesSheet.getRange(2, 1, rows.length, headers.length).setValues(rows);
        Logger.log(`✅ Exported ${rows.length} routes to Routes sheet`);
      } else {
        Logger.log('⚠️ No routes found to export');
        Logger.log('   This might mean the database in Google Drive doesn\'t have routes yet');
        Logger.log('   Try running "Regenerate Routes Only" to generate routes');
      }
      
      // Auto-resize columns
      routesSheet.autoResizeColumns(1, headers.length);
      
    } catch (error) {
      const errorMsg = error.message || error.toString();
      Logger.log(`❌ Error exporting routes to sheet: ${errorMsg}`);
      Logger.log(`   Stack: ${error.stack || 'No stack trace'}`);
      
      // Provide helpful error message to user
      if (errorMsg.includes('null') || errorMsg.includes('undefined') || errorMsg.includes('postcodeAreas')) {
        throw new Error(`Database error: ${errorMsg}\n\nPlease run "Convert to JSON" first to create/load the database.`);
      }
      
      throw error;
    }
  }

  /**
   * Export routes for manual editing with dropdowns for waypoint selection
   */
  function exportRoutesForManualEditing() {
    try {
      const existingDb = loadExistingDatabase();
      if (!existingDb) {
        SpreadsheetApp.getUi().alert('Error', 'No existing database found. Run "Convert to JSON" first.', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      let routesSheet = spreadsheet.getSheetByName('Routes');
      
      // Create Routes sheet if it doesn't exist
      if (!routesSheet) {
        routesSheet = spreadsheet.insertSheet('Routes');
      } else {
        // Delete and recreate to ensure no validation rules remain
        const sheetIndex = routesSheet.getIndex();
        spreadsheet.deleteSheet(routesSheet);
        routesSheet = spreadsheet.insertSheet('Routes', sheetIndex);
      }
      
      // Find the POI sheet (not Routes sheet, and has POI data)
      let mainSheet = null;
      const allSheets = spreadsheet.getSheets();
      
      // First, try to find "poi_export" sheet specifically
      for (const s of allSheets) {
        const sheetName = s.getName().toLowerCase();
        if (sheetName === 'poi_export' || sheetName === 'poi export') {
          const testData = s.getDataRange().getValues();
          if (testData.length > 1) {
            const headers = testData[0];
            const hasName = headers.some(h => h.toString().toLowerCase().includes('name'));
            const hasPostcode = headers.some(h => h.toString().toLowerCase().includes('postcode'));
            if (hasName && hasPostcode) {
              mainSheet = s;
              Logger.log(`✅ Found POI sheet: "${s.getName()}"`);
              break;
            }
          }
        }
      }
      
      // If not found, try to find any sheet with "poi" in the name or that's not "Routes"
      if (!mainSheet) {
        for (const s of allSheets) {
          const sheetName = s.getName().toLowerCase();
          if (sheetName !== 'routes' && !sheetName.includes('route')) {
            // Check if this sheet has POI-like columns
            const testData = s.getDataRange().getValues();
            if (testData.length > 1) {
              const headers = testData[0];
              const hasName = headers.some(h => h.toString().toLowerCase().includes('name'));
              const hasPostcode = headers.some(h => h.toString().toLowerCase().includes('postcode'));
              if (hasName && hasPostcode) {
                mainSheet = s;
                Logger.log(`✅ Found POI sheet: "${s.getName()}"`);
                break;
              }
            }
          }
        }
      }
      
      // Fallback to first non-Routes sheet
      if (!mainSheet) {
        for (const s of allSheets) {
          if (s.getName() !== 'Routes') {
            mainSheet = s;
            Logger.log(`⚠️ Using fallback sheet: "${s.getName()}"`);
            break;
          }
        }
      }
      
      if (!mainSheet) {
        throw new Error('Could not find POI data sheet. Make sure you have a sheet with POI data (columns: Name, Postcode).');
      }
      
      const poiData = mainSheet.getDataRange().getValues();
      const poiHeaders = poiData[0];
      const nameIndex = poiHeaders.findIndex(h => h.toString().toLowerCase().includes('name'));
      const postcodeIndex = poiHeaders.findIndex(h => h.toString().toLowerCase().includes('postcode'));
      
      if (nameIndex === -1 || postcodeIndex === -1) {
        throw new Error(`POI sheet "${mainSheet.getName()}" is missing required columns: Name and Postcode`);
      }
      
      // Build POI list for dropdowns (format: "POI Name (postcode)")
      // Also group by postcode for filtered dropdowns
      const poiList = [];
      const poisByPostcode = {}; // Group POIs by postcode for filtered dropdowns
      
      for (let i = 1; i < poiData.length; i++) {
        const name = String(poiData[i][nameIndex] || '').trim();
        const postcode = String(poiData[i][postcodeIndex] || '').trim();
        if (name) {
          const poiEntry = `${name} (${postcode})`;
          poiList.push(poiEntry);
          
          // Group by postcode
          if (!poisByPostcode[postcode]) {
            poisByPostcode[postcode] = [];
          }
          poisByPostcode[postcode].push(poiEntry);
        }
      }
      
      Logger.log(`📋 Built POI list with ${poiList.length} POIs for dropdowns`);
      Logger.log(`📋 Grouped by ${Object.keys(poisByPostcode).length} postcodes`);
      
    // Helper function to format waypoint for dropdown matching
    const formatWaypoint = (waypoint, routePostcode) => {
      if (!waypoint) return '';
      const wpName = (waypoint.name || '').trim();
      if (!wpName) return '';
      
      // First try exact match with postcode
      const formatted = `${wpName} (${routePostcode})`;
      if (poiList.includes(formatted)) {
        return formatted;
      }
      
      // Try to find matching POI by name (case-insensitive)
      const match = poiList.find(poi => {
        const poiName = poi.split(' (')[0].trim();
        return poiName === wpName || poiName.toLowerCase() === wpName.toLowerCase();
      });
      
      // If match found, return it; otherwise return formatted version anyway (will show warning but work)
      return match || formatted;
    };
      
      // Headers for editable routes
      const headers = [
        'Postcode', 'Duration (min)', 'Route Index', 
        'Name', 'Description',
        'Waypoint Count', 'Waypoint 1', 'Waypoint 2', 'Waypoint 3',
        'Distance (m)', 'Duration (sec)', 'Polyline', 'Generate Polyline'
      ];
      routesSheet.getRange(1, 1, 1, headers.length).setValues([headers]);
      routesSheet.getRange(1, 1, 1, headers.length).setFontWeight('bold');
      
      // Data rows
      const rows = [];
      let totalAreas = 0;
      let totalRouteGroups = 0;
      let totalRoutes = 0;
      
      Logger.log(`📊 Starting route export...`);
      Logger.log(`   Database structure check:`);
      Logger.log(`   - postcodeAreas exists: ${!!existingDb.postcodeAreas}`);
      Logger.log(`   - postcodeAreas is array: ${Array.isArray(existingDb.postcodeAreas)}`);
      Logger.log(`   - Found ${existingDb.postcodeAreas ? existingDb.postcodeAreas.length : 0} postcode areas`);
      
      if (existingDb.postcodeAreas && existingDb.postcodeAreas.length > 0) {
        Logger.log(`   - First area sample: ${JSON.stringify(existingDb.postcodeAreas[0]).substring(0, 200)}...`);
      }
      
      for (const area of existingDb.postcodeAreas || []) {
        totalAreas++;
        const postcode = area.postcode || '';
        const routes = area.routes || [];
        
        Logger.log(`   Processing area ${totalAreas}: ${postcode} (${routes.length} route groups)`);
        
        for (const routeGroup of routes) {
          totalRouteGroups++;
          const duration = routeGroup.durationMinutes || 0;
          const routeList = routeGroup.routes || [];
          
          Logger.log(`     Route group ${totalRouteGroups}: ${duration}min, ${routeList.length} routes`);
          
          for (let routeIdx = 0; routeIdx < routeList.length; routeIdx++) {
            totalRoutes++;
            const route = routeList[routeIdx];
            const waypoints = route.places || [];
            const waypoint1 = formatWaypoint(waypoints[0], postcode);
            const waypoint2 = formatWaypoint(waypoints[1], postcode);
            const waypoint3 = formatWaypoint(waypoints[2], postcode);
            
            rows.push([
              postcode,
              duration,
              routeIdx + 1,
              route.name || '',
              route.description || '',
              waypoints.length,
              waypoint1,
              waypoint2,
              waypoint3,
              route.distanceMeters || 0,
              route.durationSeconds || 0,
              route.polyline || '',
              'Click to Generate' // Button column
            ]);
          }
        }
      }
      
      Logger.log(`📊 Export summary: ${totalAreas} areas, ${totalRouteGroups} route groups, ${totalRoutes} routes, ${rows.length} rows to export`);
      
      if (rows.length === 0) {
        SpreadsheetApp.getUi().alert(
          'No Routes Found', 
          'No routes found in the database.\n\n' +
          'Make sure you have:\n' +
          '1. Run "Convert to JSON" to load the database\n' +
          '2. The database contains route data in postcodeAreas',
          SpreadsheetApp.getUi().ButtonSet.OK
        );
        return;
      }
      
      // Write data - sheet is fresh so no validations exist
      try {
        const targetRange = routesSheet.getRange(2, 1, rows.length, headers.length);
        targetRange.setValues(rows);
        Logger.log(`✅ Successfully wrote ${rows.length} rows to sheet`);
      } catch (writeError) {
        Logger.log(`❌ Error writing data: ${writeError.message || writeError}`);
        Logger.log(`   Error details: ${JSON.stringify(writeError)}`);
        throw new Error(`Failed to write routes to sheet: ${writeError.message || writeError}`);
      }
      
      // Add dropdown validation to waypoint columns (G, H, I)
      // Filter dropdowns by postcode from column A for each row
      const waypointCols = [7, 8, 9]; // Waypoint 1, 2, 3 columns (G, H, I)
      
      if (poiList.length === 0) {
        Logger.log(`⚠️ Warning: No POIs found for dropdowns. Make sure your POI sheet has data.`);
        SpreadsheetApp.getUi().alert('Warning', 'No POIs found for dropdowns. Waypoint columns will be free text.', SpreadsheetApp.getUi().ButtonSet.OK);
      }
      
      for (const col of waypointCols) {
        const headerCell = routesSheet.getRange(1, col);
        headerCell.setNote('Select POI from dropdown (filtered by postcode in column A). Import will match by name.');
        
        // Add dropdown validation per row, filtered by postcode in column A
        if (rows.length > 0 && Object.keys(poisByPostcode).length > 0) {
          let successCount = 0;
          let errorCount = 0;
          
          for (let rowIdx = 0; rowIdx < rows.length; rowIdx++) {
            try {
              const row = rows[rowIdx];
              const postcode = String(row[0] || '').trim(); // Column A (index 0) contains postcode
              const rowNum = rowIdx + 2; // +2 because row 1 is header, data starts at row 2
              
              // Get POIs for this postcode
              let filteredPoiList = poisByPostcode[postcode] || [];
              
              // If no exact match, try to find similar postcodes (e.g., "WF2 0GU" vs "WF2")
              if (filteredPoiList.length === 0 && postcode) {
                // Try matching by postcode district (first part before space)
                const postcodeDistrict = postcode.split(' ')[0];
                for (const pc in poisByPostcode) {
                  if (pc.startsWith(postcodeDistrict) || pc === postcodeDistrict) {
                    filteredPoiList = filteredPoiList.concat(poisByPostcode[pc]);
                  }
                }
              }
              
              // Limit to 500 items (Google Sheets limit)
              if (filteredPoiList.length > 500) {
                filteredPoiList = filteredPoiList.slice(0, 500);
                Logger.log(`⚠️ Row ${rowNum}: ${filteredPoiList.length} POIs for postcode "${postcode}", limited to 500`);
              }
              
              if (filteredPoiList.length > 0) {
                const cell = routesSheet.getRange(rowNum, col);
                const rule = SpreadsheetApp.newDataValidation()
                  .requireValueInList(filteredPoiList, true) // true = show dropdown
                  .setAllowInvalid(false) // Don't allow values not in list
                  .setHelpText(`Select a POI for ${postcode} (${filteredPoiList.length} options)`)
                  .build();
                cell.setDataValidation(rule);
                successCount++;
              } else {
                Logger.log(`⚠️ Row ${rowNum}: No POIs found for postcode "${postcode}"`);
              }
            } catch (validationError) {
              errorCount++;
              Logger.log(`❌ Error adding dropdown to row ${rowIdx + 2}, column ${col}: ${validationError}`);
            }
          }
          
          Logger.log(`✅ Added dropdown validation to column ${String.fromCharCode(64 + col)}: ${successCount} rows, ${errorCount} errors`);
        }
      }
      
      // Format "Generate Polyline" column as button-like
      const buttonCol = 13; // Column M (Generate Polyline)
      const buttonRange = routesSheet.getRange(2, buttonCol, rows.length, 1);
      buttonRange.setBackground('#4285f4');
      buttonRange.setFontColor('#ffffff');
      buttonRange.setFontWeight('bold');
      
      // Auto-resize columns
      routesSheet.autoResizeColumns(1, headers.length);
      
      Logger.log(`✅ Routes exported successfully - ${rows.length} routes`);
      SpreadsheetApp.getUi().alert(
        'Success', 
        `✅ Exported ${rows.length} routes for manual editing\n\n` +
        `You can now:\n` +
        `- Edit route names and descriptions (free text)\n` +
        `- Edit waypoints (columns G, H, I) - type any POI name\n` +
        `- Click "Generate Polyline" to create route paths\n` +
        `- Run "Import Routes from Sheet" to update database`,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
      
    } catch (error) {
      Logger.log(`❌ Error exporting routes for editing: ${error}`);
      SpreadsheetApp.getUi().alert('Error', `Failed to export routes: ${error}`, SpreadsheetApp.getUi().ButtonSet.OK);
    }
  }

  /**
   * Generate polyline for a specific route row
   */
  function generatePolylineForRoute() {
    try {
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      const routesSheet = spreadsheet.getSheetByName('Routes');
      
      if (!routesSheet) {
        SpreadsheetApp.getUi().alert('Error', 'Routes sheet not found. Run "Export Routes for Manual Editing" first.', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      const activeRange = spreadsheet.getActiveRange();
      if (!activeRange) {
        SpreadsheetApp.getUi().alert('Error', 'Please select a row in the Routes sheet first.', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      const row = activeRange.getRow();
      if (row < 2) {
        SpreadsheetApp.getUi().alert('Error', 'Please select a data row (not header).', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      // Get route data from row
      const postcode = routesSheet.getRange(row, 1).getValue();
      const waypoint1 = routesSheet.getRange(row, 7).getValue();
      const waypoint2 = routesSheet.getRange(row, 8).getValue();
      const waypoint3 = routesSheet.getRange(row, 9).getValue();
      
      // Find the POI sheet (same logic as exportRoutesForManualEditing)
      let mainSheet = null;
      const allSheets = spreadsheet.getSheets();
      
      // First, try to find "poi_export" sheet specifically
      for (const s of allSheets) {
        const sheetName = s.getName().toLowerCase();
        if (sheetName === 'poi_export' || sheetName === 'poi export') {
          const testData = s.getDataRange().getValues();
          if (testData.length > 1) {
            const headers = testData[0];
            const hasName = headers.some(h => h.toString().toLowerCase().includes('name'));
            const hasPostcode = headers.some(h => h.toString().toLowerCase().includes('postcode'));
            if (hasName && hasPostcode) {
              mainSheet = s;
              Logger.log(`✅ Found POI sheet: "${s.getName()}"`);
              break;
            }
          }
        }
      }
      
      // If not found, try to find any sheet with "poi" in the name or that's not "Routes"
      if (!mainSheet) {
        for (const s of allSheets) {
          const sheetName = s.getName().toLowerCase();
          if (sheetName !== 'routes' && !sheetName.includes('route')) {
            const testData = s.getDataRange().getValues();
            if (testData.length > 1) {
              const headers = testData[0];
              const hasName = headers.some(h => h.toString().toLowerCase().includes('name'));
              const hasPostcode = headers.some(h => h.toString().toLowerCase().includes('postcode'));
              if (hasName && hasPostcode) {
                mainSheet = s;
                Logger.log(`✅ Found POI sheet: "${s.getName()}"`);
                break;
              }
            }
          }
        }
      }
      
      if (!mainSheet) {
        SpreadsheetApp.getUi().alert('Error', 'Could not find POI data sheet. Make sure you have a sheet with POI data (columns: Name, Postcode).', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      // Get POI coordinates from POI sheet
      const poiData = mainSheet.getDataRange().getValues();
      const poiHeaders = poiData[0];
      const nameIndex = poiHeaders.findIndex(h => h.toString().toLowerCase().includes('name'));
      const latIndex = poiHeaders.findIndex(h => h.toString().toLowerCase().includes('lat'));
      const lonIndex = poiHeaders.findIndex(h => h.toString().toLowerCase().includes('lon'));
      
      if (nameIndex === -1 || latIndex === -1 || lonIndex === -1) {
        SpreadsheetApp.getUi().alert('Error', `POI sheet "${mainSheet.getName()}" is missing required columns: Name, Latitude, Longitude.`, SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      // Find waypoint coordinates
      const waypoints = [];
      [waypoint1, waypoint2, waypoint3].forEach((wp, idx) => {
        if (wp) {
          const wpName = wp.split(' (')[0].trim(); // Extract name before " (postcode)"
          Logger.log(`   Looking for waypoint ${idx + 1}: "${wpName}"`);
          
          let found = false;
          for (let i = 1; i < poiData.length; i++) {
            const poiName = String(poiData[i][nameIndex] || '').trim();
            if (poiName === wpName || poiName.toLowerCase() === wpName.toLowerCase()) {
              const lat = parseFloat(poiData[i][latIndex]) || 0;
              const lon = parseFloat(poiData[i][lonIndex]) || 0;
              if (lat !== 0 && lon !== 0) {
                waypoints.push([lat, lon]);
                Logger.log(`   ✅ Found waypoint ${idx + 1}: "${poiName}" at (${lat}, ${lon})`);
                found = true;
                break;
              }
            }
          }
          
          if (!found) {
            Logger.log(`   ⚠️ Could not find waypoint ${idx + 1}: "${wpName}" in POI sheet`);
          }
        }
      });
      
      if (waypoints.length < 2) {
        const foundCount = waypoints.length;
        const waypointNames = [waypoint1, waypoint2, waypoint3].filter(wp => wp).map(wp => wp.split(' (')[0].trim()).join(', ');
        SpreadsheetApp.getUi().alert(
          'Error', 
          `Need at least 2 waypoints to generate a route.\n\n` +
          `Found ${foundCount} waypoint(s) out of ${[waypoint1, waypoint2, waypoint3].filter(wp => wp).length}.\n\n` +
          `Waypoints: ${waypointNames || 'none'}\n\n` +
          `Make sure the waypoint names match exactly with POI names in the "${mainSheet.getName()}" sheet.`,
          SpreadsheetApp.getUi().ButtonSet.OK
        );
        Logger.log(`❌ Only found ${foundCount} waypoints. Looking for: ${waypointNames}`);
        return;
      }
      
      // Get postcode center for origin
      const center = POSTCODE_CENTERS[postcode];
      if (!center) {
        SpreadsheetApp.getUi().alert('Error', `Postcode center not found for ${postcode}. Add it to POSTCODE_CENTERS config.`, SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      // Build OSRM route: origin → waypoints → origin (using walking profile)
      const coords = [`${center.lon},${center.lat}`];
      waypoints.forEach(([lat, lon]) => coords.push(`${lon},${lat}`));
      coords.push(`${center.lon},${center.lat}`);
      
      const coordsStr = coords.join(';');
      const url = `http://router.project-osrm.org/route/v1/walking/${coordsStr}?overview=full&geometries=polyline`;
      
      Logger.log(`🗺️ Generating walking route polyline for: ${postcode}`);
      const response = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
      
      if (response.getResponseCode() === 200) {
        const data = JSON.parse(response.getContentText());
        
        if (data.code === 'Ok' && data.routes && data.routes.length > 0) {
          const route = data.routes[0];
          const polyline = route.geometry || '';
          const distanceM = route.distance || 0;
          const durationSec = Math.round(route.duration || 0); // OSRM walking profile returns actual walking time in seconds
          
          // Update row with polyline, distance, and duration
          routesSheet.getRange(row, 12).setValue(polyline); // Polyline column
          routesSheet.getRange(row, 10).setValue(Math.round(distanceM)); // Distance column
          routesSheet.getRange(row, 11).setValue(durationSec); // Duration column
          
          Logger.log(`✅ Generated walking route: ${Math.round(distanceM)}m, ${Math.floor(durationSec / 60)}min`);
          SpreadsheetApp.getUi().alert(
            'Success', 
            `✅ Walking route generated!\n\nDistance: ${Math.round(distanceM)}m\nDuration: ${Math.floor(durationSec / 60)}min`,
            SpreadsheetApp.getUi().ButtonSet.OK
          );
        } else {
          throw new Error('OSRM returned no route');
        }
      } else {
        throw new Error(`OSRM API error: ${response.getResponseCode()}`);
      }
      
    } catch (error) {
      Logger.log(`❌ Error generating polyline: ${error}`);
      SpreadsheetApp.getUi().alert('Error', `Failed to generate polyline: ${error}`, SpreadsheetApp.getUi().ButtonSet.OK);
    }
  }

  /**
   * Import routes from Routes sheet back to database
   */
  function importRoutesFromSheet() {
    try {
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      const routesSheet = spreadsheet.getSheetByName('Routes');
      const mainSheet = spreadsheet.getActiveSheet();
      
      if (!routesSheet) {
        SpreadsheetApp.getUi().alert('Error', 'Routes sheet not found. Run "Export Routes for Manual Editing" first.', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      // Load existing database
      let database = loadExistingDatabase();
      if (!database) {
        SpreadsheetApp.getUi().alert('Error', 'No existing database found. Run "Convert to JSON" first.', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      // Get POI data from main sheet
      const poiData = mainSheet.getDataRange().getValues();
      const poiHeaders = poiData[0];
      const nameIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('name'));
      const latIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('lat'));
      const lonIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('lon'));
      const placeIdIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('placeid'));
      const typesIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('types'));
      const sourceIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('source'));
      const vicinityIndex = poiHeaders.findIndex(h => h.toLowerCase().includes('vicinity'));
      
      // Get route data from Routes sheet
      const routeData = routesSheet.getDataRange().getValues();
      if (routeData.length < 2) {
        SpreadsheetApp.getUi().alert('Error', 'No route data found in Routes sheet.', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      // Group routes by postcode and duration
      const routesByPostcode = {};
      
      for (let i = 1; i < routeData.length; i++) {
        const row = routeData[i];
        const postcode = row[0]; // Column A
        const duration = row[1]; // Column B
        const routeIndex = row[2]; // Column C
        const name = row[3] || null; // Column D
        const description = row[4] || null; // Column E
        const waypointCount = row[5] || 0; // Column F
        const waypoint1 = row[6]; // Column G
        const waypoint2 = row[7]; // Column H
        const waypoint3 = row[8]; // Column I
        const distanceM = row[9] || 0; // Column J
        const durationSec = row[10] || 0; // Column K
        const polyline = row[11] || ''; // Column L
        
        if (!postcode || !polyline) continue; // Skip invalid rows
        
        // Find POIs for waypoints
        const waypointPOIs = [];
        [waypoint1, waypoint2, waypoint3].forEach(wp => {
          if (wp) {
            const wpName = wp.split(' (')[0].trim();
            for (let j = 1; j < poiData.length; j++) {
              const poiName = String(poiData[j][nameIndex] || '').trim();
              if (poiName === wpName || poiName.toLowerCase() === wpName.toLowerCase()) {
                const typesStr = poiData[j][typesIndex] || '';
                waypointPOIs.push({
                  placeId: poiData[j][placeIdIndex] || '',
                  name: poiData[j][nameIndex] || '',
                  latitude: parseFloat(poiData[j][latIndex]) || 0,
                  longitude: parseFloat(poiData[j][lonIndex]) || 0,
                  types: typesStr ? typesStr.split(',').map(t => t.trim()).filter(t => t) : [],
                  vicinity: poiData[j][vicinityIndex] || null,
                  source: poiData[j][sourceIndex] || 'manual',
                  rating: null
                });
                break;
              }
            }
          }
        });
        
        if (waypointPOIs.length === 0) continue;
        
        // Group by postcode and duration
        const key = `${postcode}_${duration}`;
        if (!routesByPostcode[key]) {
          routesByPostcode[key] = {
            postcode: postcode,
            duration: duration,
            routes: []
          };
        }
        
        routesByPostcode[key].routes.push({
          places: waypointPOIs,
          polyline: polyline,
          distanceMeters: distanceM,
          durationSeconds: durationSec,
          name: name,
          description: description,
          directions: null
        });
      }
      
      // Update database with imported routes
      let updatedCount = 0;
      for (const area of database.postcodeAreas) {
        // Group routes by duration for this postcode
        const routesByDuration = {};
        for (const key in routesByPostcode) {
          const routeGroup = routesByPostcode[key];
          if (routeGroup.postcode === area.postcode) {
            routesByDuration[routeGroup.duration] = routeGroup.routes;
          }
        }
        
        if (Object.keys(routesByDuration).length > 0) {
          // Replace all routes for this postcode area
          area.routes = Object.keys(routesByDuration).map(duration => ({
            durationMinutes: parseInt(duration, 10),
            routes: routesByDuration[duration]
          }));
          updatedCount += Object.keys(routesByDuration).length;
        }
      }
      
      // Save updated database
      const jsonString = JSON.stringify(database, null, 2);
      if (CONFIG.SAVE_TO_DRIVE) {
        saveToDrive(jsonString);
      }
      
      if (CONFIG.UPLOAD_TO_FIREBASE) {
        try {
          uploadToFirebase(jsonString);
          if (CONFIG.SPLIT_BY_POSTCODE) {
            splitAndUploadByPostcode(database);
          }
        } catch (error) {
          Logger.log(`Firebase upload error: ${error}`);
        }
      }
      
      SpreadsheetApp.getUi().alert('Success', `✅ Imported ${updatedCount} route groups from Routes sheet\n\nDatabase updated and uploaded to Firebase!`, SpreadsheetApp.getUi().ButtonSet.OK);
      Logger.log(`✅ Imported ${updatedCount} route groups from Routes sheet`);
      
    } catch (error) {
      Logger.log(`❌ Error importing routes: ${error}`);
      SpreadsheetApp.getUi().alert('Error', `Failed to import routes: ${error}`, SpreadsheetApp.getUi().ButtonSet.OK);
    }
  }

  /**
   * Create menu in Google Sheets
   */
  function onOpen() {
    const ui = SpreadsheetApp.getUi();
    ui.createMenu('WalkingWR POI Database')
      .addItem('Sync from Database', 'syncDatabaseToSheet')
      .addSeparator()
      .addItem('Convert to JSON', 'convertSheetToJSON')
      .addItem('Convert & Show JSON', 'convertAndShowJSON')
      .addItem('Regenerate Routes Only', 'regenerateAllRoutes')
      .addSeparator()
      .addItem('Export Routes to Sheet (Read-Only)', 'exportRoutesFromDatabase')
      .addItem('Export Routes for Manual Editing', 'exportRoutesForManualEditing')
      .addItem('Import Routes from Sheet', 'importRoutesFromSheet')
      .addItem('Generate Polyline for Selected Route', 'generatePolylineForRoute')
      .addSeparator()
      .addItem('Setup Firebase Upload', 'setupFirebaseServiceAccount')
      .addSeparator()
      .addItem('About', 'showAbout')
      .addToUi();
  }

  /**
   * Export routes from database to Routes sheet (manual trigger)
   */
  function exportRoutesFromDatabase() {
    try {
      Logger.log('🔍 Starting database load...');
      Logger.log(`   Looking for folder: ${CONFIG.DRIVE_FOLDER_NAME}`);
      Logger.log(`   Looking for file: ${CONFIG.DRIVE_FILE_NAME}`);
      
      const existingDb = loadExistingDatabase();
      
      Logger.log(`   loadExistingDatabase returned: ${existingDb ? 'object' : 'null/undefined'}`);
      Logger.log(`   Type: ${typeof existingDb}`);
      
      if (!existingDb) {
        const errorMsg = 'No existing database found. Run "Convert to JSON" first to create the database.';
        Logger.log(`❌ ${errorMsg}`);
        SpreadsheetApp.getUi().alert('Error', errorMsg, SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      if (!existingDb.postcodeAreas || !Array.isArray(existingDb.postcodeAreas)) {
        const errorMsg = 'Database found but has invalid structure (missing postcodeAreas array).';
        Logger.log(`❌ ${errorMsg}`);
        Logger.log(`   Database keys: ${Object.keys(existingDb).join(', ')}`);
        SpreadsheetApp.getUi().alert('Error', errorMsg, SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      Logger.log('📊 Exporting routes from database to Routes sheet...');
      Logger.log(`   Database structure: ${existingDb.postcodeAreas.length} postcode areas`);
      exportRoutesToSheet(existingDb);
      
      const totalRoutes = existingDb.postcodeAreas.reduce((sum, area) => {
        if (area.routes) {
          return sum + area.routes.reduce((s, rg) => s + (rg.routes ? rg.routes.length : 0), 0);
        }
        return sum;
      }, 0);
      
      SpreadsheetApp.getUi().alert('Success', `✅ Exported ${totalRoutes} routes to Routes sheet`, SpreadsheetApp.getUi().ButtonSet.OK);
      
    } catch (error) {
      const errorMsg = error.message || error.toString();
      Logger.log(`❌ Error exporting routes: ${errorMsg}`);
      Logger.log(`   Stack: ${error.stack || 'No stack trace'}`);
      
      // Provide helpful guidance based on error type
      let userMessage = `Failed to export routes: ${errorMsg}`;
      if (errorMsg.includes('null') || errorMsg.includes('undefined') || errorMsg.includes('Database')) {
        userMessage = `Database not found or invalid.\n\n` +
          `Please run "Convert to JSON" first to create the database from your sheet data.`;
      }
      
      SpreadsheetApp.getUi().alert('Error', userMessage, SpreadsheetApp.getUi().ButtonSet.OK);
    }
  }

  /**
   * Sync all POIs from existing database to current sheet
   * This downloads all POIs from the database so you can edit them
   */
  function syncDatabaseToSheet() {
    try {
      const existingDb = loadExistingDatabase();
      if (!existingDb) {
        SpreadsheetApp.getUi().alert(
          'No Database Found',
          'No existing database found in Google Drive.\n\n' +
          'The database will be created when you run "Convert to JSON" for the first time.',
          SpreadsheetApp.getUi().ButtonSet.OK
        );
        return;
      }
      
      const sheet = SpreadsheetApp.getActiveSheet();
      
      // Ask user if they want to clear existing data
      const ui = SpreadsheetApp.getUi();
      const response = ui.alert(
        'Sync from Database',
        'This will replace all data in the current sheet with POIs from the database.\n\n' +
        'Continue?',
        ui.ButtonSet.YES_NO
      );
      
      if (response !== ui.Button.YES) {
        return;
      }
      
      // Flatten all POIs from all postcode areas
      const rows = [];
      
      // Headers
      const headers = ['postcode', 'placeId', 'name', 'latitude', 'longitude', 'types', 'vicinity', 'source', 'rating'];
      rows.push(headers);
      
      // Add all POIs
      for (const area of existingDb.postcodeAreas) {
        const postcode = area.postcode || '';
        const pois = area.pois || [];
        
        for (const poi of pois) {
          rows.push([
            postcode,
            poi.placeId || '',
            poi.name || '',
            poi.latitude || 0,
            poi.longitude || 0,
            (poi.types || []).join(', '),
            poi.vicinity || '',
            poi.source || '',
            poi.rating || ''
          ]);
        }
      }
      
      if (rows.length <= 1) {
        SpreadsheetApp.getUi().alert('Empty Database', 'The database contains no POIs.', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      // Clear existing sheet and write new data
      sheet.clear();
      const numRows = rows.length;
      const numCols = headers.length;
      
      sheet.getRange(1, 1, numRows, numCols).setValues(rows);
      
      // Format header row
      sheet.getRange(1, 1, 1, numCols).setFontWeight('bold');
      sheet.setFrozenRows(1);
      
      // Auto-resize columns
      sheet.autoResizeColumns(1, numCols);
      
      const totalPOIs = numRows - 1; // Exclude header
      const totalPostcodes = existingDb.postcodeAreas.length;
      
      SpreadsheetApp.getUi().alert(
        'Sync Complete',
        `✅ Synced ${totalPOIs} POIs from ${totalPostcodes} postcode areas\n\n` +
        `You can now edit the data and run "Convert to JSON" to update the database.`,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
      
      Logger.log(`✅ Synced ${totalPOIs} POIs from database to sheet`);
      
    } catch (error) {
      Logger.log(`❌ Error syncing database to sheet: ${error}`);
      SpreadsheetApp.getUi().alert(
        'Error',
        `Failed to sync from database:\n\n${error}`,
        SpreadsheetApp.getUi().ButtonSet.OK
      );
    }
  }

  /**
   * Regenerate routes for all postcode areas (manual trigger)
   */
  function regenerateAllRoutes() {
    try {
      const existingDb = loadExistingDatabase();
      if (!existingDb) {
        SpreadsheetApp.getUi().alert('Error', 'No existing database found. Run "Convert to JSON" first.', SpreadsheetApp.getUi().ButtonSet.OK);
        return;
      }
      
      const allPostcodes = existingDb.postcodeAreas.map(area => ({
        postcode: area.postcode,
        lat: area.centerLatitude,
        lon: area.centerLongitude
      }));
      
      Logger.log(`🔄 Regenerating routes for all ${allPostcodes.length} postcode areas...`);
      regenerateRoutesForPostcodes(existingDb, allPostcodes);
      
      // Save updated database
      const jsonString = JSON.stringify(existingDb, null, 2);
      if (CONFIG.SAVE_TO_DRIVE) {
        saveToDrive(jsonString);
      }
      
      // Export routes to sheet
      if (CONFIG.EXPORT_ROUTES_TO_SHEET) {
        try {
          Logger.log('📊 Exporting routes to Routes sheet...');
          exportRoutesToSheet(existingDb);
        } catch (routeError) {
          Logger.log(`⚠️  Error exporting routes: ${routeError}`);
        }
      }
      
      SpreadsheetApp.getUi().alert('Success', `✅ Regenerated routes for ${allPostcodes.length} postcode areas`, SpreadsheetApp.getUi().ButtonSet.OK);
      
    } catch (error) {
      Logger.log(`❌ Error regenerating routes: ${error}`);
      SpreadsheetApp.getUi().alert('Error', `Failed to regenerate routes: ${error}`, SpreadsheetApp.getUi().ButtonSet.OK);
    }
  }

  /**
   * Convert and show JSON in a dialog
   */
  function convertAndShowJSON() {
    try {
      const jsonString = convertSheetToJSON();
      const html = HtmlService.createHtmlOutput(
        '<pre style="font-family: monospace; white-space: pre-wrap;">' +
        jsonString.substring(0, 5000) + // Show first 5000 chars
        (jsonString.length > 5000 ? '\n\n... (truncated, full JSON saved to Drive)' : '') +
        '</pre>'
      )
      .setWidth(800)
      .setHeight(600)
      .setTitle('POI Database JSON');
      
      SpreadsheetApp.getUi().showModalDialog(html, 'JSON Output');
    } catch (error) {
      SpreadsheetApp.getUi().alert('Error', error.toString(), SpreadsheetApp.getUi().ButtonSet.OK);
    }
  }

  /**
   * Show about dialog
   */
  function showAbout() {
    const message = 'WalkingWR POI Database Converter\n\n' +
                  'This script converts your Google Sheet to JSON format\n' +
                  'matching the prepopulated_pois.json structure.\n\n' +
                  'Features:\n' +
                  '• Sync from Database - Download all POIs to sheet\n' +
                  '• Auto-increments version\n' +
                  '• Auto-regenerates routes when POIs change\n' +
                  '• Exports routes to second tab\n' +
                  '• Preserves existing routes\n' +
                  '• Saves to Google Drive\n' +
                  '• Can be triggered on edit';
    
    SpreadsheetApp.getUi().alert('About', message, SpreadsheetApp.getUi().ButtonSet.OK);
  }

  /**
   * Auto-convert on edit (optional - can be enabled)
   * Uncomment to enable automatic conversion when sheet is edited
   */
  /*
  function onEdit(e) {
    // Only convert if a significant change (e.g., rating column changed)
    const range = e.range;
    const column = range.getColumn();
    const header = SpreadsheetApp.getActiveSheet().getRange(1, column).getValue();
    
    // If rating column or name column was edited, auto-convert
    if (header && (header.toLowerCase() === 'rating' || header.toLowerCase() === 'name')) {
      // Debounce: wait 2 seconds after last edit
      Utilities.sleep(2000);
      convertSheetToJSON();
    }
  }
  */
