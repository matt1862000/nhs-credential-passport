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
  UPLOAD_TO_FIREBASE: false,  // Set to true after setting up service account
  FIREBASE_STORAGE_BUCKET: 'doctorwaittimes.firebasestorage.app',
  FIREBASE_FILE_NAME: 'prepopulated_pois.json',
  FIREBASE_PROJECT_ID: 'doctorwaittimes',
  
  // Or save to Google Drive
  SAVE_TO_DRIVE: true,
  DRIVE_FOLDER_NAME: 'WalkingWR Database',
  DRIVE_FILE_NAME: 'prepopulated_pois.json',
  
  // Version increment
  AUTO_INCREMENT_VERSION: true
};

// Postcode area center coordinates (must match PrePopulatedPOIGenerator.swift)
const POSTCODE_CENTERS = {
  "WF2 0GU": { lat: 53.7029, lon: -1.5496, radius: 2500 },   // Wakefield area
  "S5 7JT":  { lat: 53.4109, lon: -1.4603, radius: 2500 },   // Sheffield area (Northern General Hospital)
  "S35 0JW": { lat: 53.4200, lon: -1.4800, radius: 2500 },   // Sheffield area
  "S1 4JP":  { lat: 53.3800, lon: -1.4700, radius: 2500 },   // Sheffield city centre
  "S5 7AU":  { lat: 53.4100, lon: -1.4500, radius: 2500 },   // Sheffield area
  "S8 8BG":  { lat: 53.3500, lon: -1.4800, radius: 2500 },   // Sheffield area
  "S35 1RQ": { lat: 53.4300, lon: -1.4900, radius: 2500 },   // Sheffield area
  "S11 9BF": { lat: 53.3700, lon: -1.5000, radius: 2500 }    // Sheffield area
};

/**
 * Main function: Convert current sheet to JSON database
 */
function convertSheetToJSON() {
  try {
    const sheet = SpreadsheetApp.getActiveSheet();
    const data = sheet.getDataRange().getValues();
    
    if (data.length < 2) {
      throw new Error('Sheet must have at least a header row and one data row');
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
      
      // Update POIs for each postcode area and fix any missing center coordinates
      for (const area of database.postcodeAreas) {
        if (poisByPostcode[area.postcode]) {
          area.pois = poisByPostcode[area.postcode].pois;
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
        uploadToFirebase(jsonString);
        firebaseStatus = '\n   ✅ Uploaded to Firebase Storage';
      } catch (error) {
        firebaseStatus = `\n   ⚠️  Firebase upload failed: ${error}`;
        Logger.log(`Firebase upload error: ${error}`);
      }
    }
    
    // Show success message
    const message = `✅ Converted ${Object.keys(poisByPostcode).length} postcode areas\n` +
                   `   Total POIs: ${Object.values(poisByPostcode).reduce((sum, p) => sum + p.pois.length, 0)}\n` +
                   `   Version: ${database.version}\n` +
                   `   Saved to Google Drive${firebaseStatus}`;
    
    SpreadsheetApp.getUi().alert('Success', message, SpreadsheetApp.getUi().ButtonSet.OK);
    
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
    
    if (files.hasNext()) {
      const file = files.next();
      const content = file.getBlob().getDataAsString();
      
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
        
        Logger.log(`Loaded existing database with ${parsed.postcodeAreas.length} postcode areas`);
        return parsed;
      } catch (parseError) {
        Logger.log(`Error parsing existing database: ${parseError} - will create new`);
        return null;
      }
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
 * Create menu in Google Sheets
 */
function onOpen() {
  const ui = SpreadsheetApp.getUi();
  ui.createMenu('WalkingWR POI Database')
    .addItem('Convert to JSON', 'convertSheetToJSON')
    .addItem('Convert & Show JSON', 'convertAndShowJSON')
    .addSeparator()
    .addItem('Setup Firebase Upload', 'setupFirebaseServiceAccount')
    .addSeparator()
    .addItem('About', 'showAbout')
    .addToUi();
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
                 '• Auto-increments version\n' +
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
