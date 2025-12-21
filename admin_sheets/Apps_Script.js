// ========================================
// 🔥 FIREBASE CONFIGURATION - UPDATE THESE
// ========================================

const FIREBASE_PROJECT_ID = 'doctorwaittimes';
const SERVICE_ACCOUNT_EMAIL = 'firebase-adminsdk-fbsvc@doctorwaittimes.iam.gserviceaccount.com';
const PRIVATE_KEY = '-----BEGIN PRIVATE KEY-----\nMIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDlIm1To7/DH30E\ne8OdMER/s3OiQIGlVOQ6oPj5/RaSbylMphzvI+1FQwqN4POKp4qiIM6HiXmAMi8i\noRyliqJL1pnfXNsSHoJl+qb+1xK3/9WyAAa7nKCcAqnREXn917OlkweQOkN1tOwQ\nRFXaQGbqHAwpdHi7vBVqjSxLc8AHJSqhUkr8pRICeZ51CsSdHfFhMRGHO7lblUUn\nmmUVIzidL4y4YhzzR1HeJRy30pAdy0rXA2TiTjR5uZX1z8eUAZVJTg3pe19tunh0\nBPj5Cjb6njrKHCrntE1yxVqaZVP0NDtvssY35o7VrQxng1jzeNsHQK4stVbkzU6r\n2yisfUTvAgMBAAECggEAHOLYMYElPa4MjrIjmP9qw0aWP1Auh+9JznJYsPtNCyzk\nYftXDnbTBLZM8FH5ofM5MPM91ixomta4xn7VI7F0gGcPgu8r1v7tpXmR7/KhM30X\nLZd/QcufG8viKK8xV+UHisocW/xcYMxsLijPQfJ4hu7+QYOjbNdrQ8GEYga3oK67\nvKJJcs4uJosrlT9+LGxUUEhwwIl4UpmuNMhgT11e3nXx9ghiWGfhInOZBQDtkCvm\nj2pbBvDgtG06b3LZL7hvCnafa4P5hzwfSMVKN15Z/hSDwJtq1+wjsr+Kn+E5alDp\nixFW/EUs4V2BpWLn1CytAXdvrTcEFqyES87rM5dYcQKBgQD1mXMpqAomcfgQ7J4q\nAKYXOgD3sIexwcA7YNxqhon2KF+CI54/NYZR6/mpI/Gn6PIYw+16Ub1bz9czYRPh\nzIBih8h9SMfTrMesW/ilztcF7zpcgRv/FJkAy7LatI4nSWPfzJkV0otrlBN4Qpv3\nreHU93JHPNyDajiBkcnFElu3VQKBgQDu1nr7vhckLtyVY+PqPvBsgiMd9d4UvIkZ\ncMVhnzd2hEexd+BMhRsefLaHk1KLF70pizfM5xRb0I5TkCucU6G1jDzQs29odHzZ\n8pmmH3YjtRyLpM39/KiKuDMdkZC8ZBhvGLFkH1MLwLB59wdRrwxMFX5svfB1WvUi\nnGqIhUrDMwKBgQDZxUG/Oxgc9MuQPi8UcVTUnYMEHYyEipcoT3/CGR+1nCDr5SdJ\nRu2eME5EsvFxAHXCjeBBqL7t7QIVtcuKWOmx9FJK/MDrKXY3l6mHZDt3MKOgKH8p\nlBsDAJvLn3O41DNx2xoWpoUnU7pb1Tw0xwLK8spq7kVdZU9LXHj7fIbErQKBgQCG\nosGRSAcjjocqb7T7R5+gi3vgV8lpRx7CCKA799T8KnV/xWPbvu0aspLyukm9vxQT\nZzd9eoYve9G/qXXsGfj+rp9Zxsz2xTPcaLXUv8eJOX9t+OlmVBdum4e1E2nTyVk8\nx164YjAeX/Ebz/WARn1YJoWuJyR2A2BMsoAblYgfoQKBgQCS0UEAEiocr8XoNGfE\n1oFJs+8mhS2ZAk+oOUjfxBKaEF3GVBNmpVNPEqILsdL/yHY764/XN0GRcqqUQRlN\nP94Z1Ku7HTXLJyWiEqqB3vHj0HpVXCivunYu7Ow53eFdNK2FDznvFllXs3AzDzsf\nIrkcmiMTb1MN6GWTd6J3/Bdbcg==\n-----END PRIVATE KEY-----';

// ========================================
// 📋 SHEET NAMES
// ========================================

const ALL_CLINICIANS_SHEET = "All Clinicians";
const TODAYS_CLINIC_SHEET = "Today's Clinic";

// ========================================
// 🔒 LOCK TO PREVENT DUPLICATE TRIGGERS
// ========================================

var isProcessing = false;

// ========================================
// 🔍 DEBUG FUNCTION - RUN THIS FIRST!
// ========================================

function debugSheets() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var allSheets = ss.getSheets();
  
  Logger.log("========== ALL SHEETS IN WORKBOOK ==========");
  for (var i = 0; i < allSheets.length; i++) {
    var sheet = allSheets[i];
    var name = sheet.getName();
    var lastRow = sheet.getLastRow();
    Logger.log((i+1) + ". '" + name + "' - " + lastRow + " rows");
  }
  
  Logger.log("\n========== TODAY'S CLINIC DATA ==========");
  var todaysClinic = ss.getSheetByName(TODAYS_CLINIC_SHEET);
  
  if (!todaysClinic) {
    Logger.log("❌ Sheet '" + TODAYS_CLINIC_SHEET + "' NOT FOUND!");
    return;
  }
  
  var lastRow = todaysClinic.getLastRow();
  var lastCol = todaysClinic.getLastColumn();
  Logger.log("Sheet found! Last row: " + lastRow + ", Last col: " + lastCol);
  
  if (lastRow > 0) {
    var allData = todaysClinic.getDataRange().getValues();
    Logger.log("Total rows of data: " + allData.length);
    
    for (var r = 0; r < Math.min(allData.length, 10); r++) {
      Logger.log("Row " + (r+1) + ": " + JSON.stringify(allData[r]));
    }
  } else {
    Logger.log("Sheet appears empty (lastRow = 0)");
  }
  
  Logger.log("\n========== ALL CLINICIANS DATA ==========");
  var allClinicians = ss.getSheetByName(ALL_CLINICIANS_SHEET);
  if (allClinicians) {
    var acLastRow = allClinicians.getLastRow();
    Logger.log("All Clinicians has " + acLastRow + " rows");
    
    if (acLastRow > 0) {
      var headers = allClinicians.getRange(1, 1, 1, allClinicians.getLastColumn()).getValues()[0];
      Logger.log("Headers: " + JSON.stringify(headers));
    }
  } else {
    Logger.log("❌ Sheet '" + ALL_CLINICIANS_SHEET + "' NOT FOUND!");
  }
}

// ========================================
// 🔄 MAIN EDIT HANDLER
// ========================================

function onEdit(e) {
  try {
    var sheet = e.source.getActiveSheet();
    var sheetName = sheet.getName();
    var range = e.range;
    var value = e.value;
    var row = range.getRow();
    var col = range.getColumn();
    
    // Skip header row
    if (row < 2) return;
    
    // Handle "Add to Clinic?" checkbox on All Clinicians tab (Column A)
    if (sheetName === ALL_CLINICIANS_SHEET && col === 1 && value === "TRUE") {
      // Use lock to prevent duplicate execution
      var lock = LockService.getScriptLock();
      var hasLock = lock.tryLock(100); // Try to get lock for 100ms
      
      if (!hasLock) {
        Logger.log("⏳ Another process is running, skipping...");
        return;
      }
      
      try {
        // FIRST: Uncheck the box immediately to prevent re-triggering
        range.setValue(false);
        SpreadsheetApp.flush();
        
        // THEN: Add the clinician
        addClinicianToTodaysClinic(sheet, row);
      } finally {
        lock.releaseLock();
      }
      return;
    }
    
    // Handle Today's Clinic tab
    if (sheetName === TODAYS_CLINIC_SHEET) {
      // Column E (5): Finished checkbox
      if (col === 5 && value === "TRUE") {
        removeClinicianFromTodaysClinic(sheet, row);
        return;
      }
      
      // Column D (4): Delay edited - will sync on next trigger run
      if (col === 4) {
        Logger.log("Delay changed in row " + row);
        return;
      }
    }
  } catch (error) {
    Logger.log("onEdit error: " + error.message);
  }
}

// ========================================
// ➕ ADD CLINICIAN TO TODAY'S CLINIC
// ========================================

function addClinicianToTodaysClinic(allCliniciansSheet, row) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var todaysClinic = ss.getSheetByName(TODAYS_CLINIC_SHEET);
  
  if (!todaysClinic) {
    Logger.log("❌ Error: Sheet '" + TODAYS_CLINIC_SHEET + "' not found!");
    return;
  }
  
  // Get clinician data from All Clinicians
  var lastCol = allCliniciansSheet.getLastColumn();
  var data = allCliniciansSheet.getRange(row, 1, 1, lastCol).getValues()[0];
  var headers = allCliniciansSheet.getRange(1, 1, 1, lastCol).getValues()[0];
  
  // Build column lookup
  var cols = {};
  for (var h = 0; h < headers.length; h++) {
    var headerName = headers[h].toString().toLowerCase().trim().replace(/ /g, '_').replace(/[?]/g, '');
    cols[headerName] = h;
  }
  
  // Get clinician details
  var name = data[cols['name']] || '';
  var title = data[cols['title']] || '';
  var specialty = data[cols['specialty']] || '';
  
  if (!name || name === '') {
    Logger.log("❌ Error: No name found in row " + row);
    return;
  }
  
  // Check if already in Today's Clinic - CRITICAL CHECK
  var todaysData = todaysClinic.getDataRange().getValues();
  for (var i = 1; i < todaysData.length; i++) {
    var existingName = todaysData[i][0];
    if (existingName && existingName.toString().trim() === name.toString().trim()) {
      Logger.log("⚠️ " + name + " is already in Today's Clinic (row " + (i+1) + ")");
      SpreadsheetApp.getUi().alert("⚠️ " + name + " is already in Today's Clinic!");
      return; // EXIT - don't add duplicate
    }
  }
  
  // Find first empty row in Today's Clinic
  var nextRow = todaysClinic.getLastRow() + 1;
  
  // Add to Today's Clinic: Name, Title, Specialty, Delay, Finished?
  todaysClinic.getRange(nextRow, 1, 1, 5).setValues([[name, title, specialty, 0, false]]);
  
  // Add checkbox to Finished column
  todaysClinic.getRange(nextRow, 5).insertCheckboxes();
  
  Logger.log("✅ Added " + name + " to Today's Clinic at row " + nextRow);
  
  // Force the spreadsheet to update
  SpreadsheetApp.flush();
}

// ========================================
// ➖ REMOVE CLINICIAN FROM TODAY'S CLINIC
// ========================================

function removeClinicianFromTodaysClinic(sheet, row) {
  var name = sheet.getRange(row, 1).getValue();
  
  if (!name || name === '') {
    Logger.log("Row " + row + " is already empty");
    return;
  }
  
  // Clear the row content
  sheet.getRange(row, 1, 1, 5).clearContent();
  
  Logger.log("✅ Removed " + name + " from Today's Clinic");
  
  // Force the spreadsheet to update
  SpreadsheetApp.flush();
}

// ========================================
// 🔴 END ALL CLINICS (Button Function)
// ========================================

function endAllClinics() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var todaysClinic = ss.getSheetByName(TODAYS_CLINIC_SHEET);
  
  if (!todaysClinic) {
    Logger.log("❌ Error: Sheet '" + TODAYS_CLINIC_SHEET + "' not found!");
    SpreadsheetApp.getUi().alert("❌ Error: Sheet '" + TODAYS_CLINIC_SHEET + "' not found!");
    return;
  }
  
  var lastRow = todaysClinic.getLastRow();
  
  // Keep header row (row 1), clear all data rows
  if (lastRow > 1) {
    todaysClinic.getRange(2, 1, lastRow - 1, 5).clearContent();
    Logger.log("✅ Cleared all clinicians from Today's Clinic");
  } else {
    Logger.log("Today's Clinic is already empty");
  }
  
  SpreadsheetApp.flush();
  
  // Show confirmation
  SpreadsheetApp.getUi().alert("✅ All clinics ended!\n\nThe app will update within 1 minute.");
}

// ========================================
// 🧹 CLEANUP DUPLICATES
// ========================================

function cleanupDuplicates() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var todaysClinic = ss.getSheetByName(TODAYS_CLINIC_SHEET);
  
  if (!todaysClinic) {
    SpreadsheetApp.getUi().alert("❌ Sheet not found!");
    return;
  }
  
  var data = todaysClinic.getDataRange().getValues();
  var seenNames = {};
  var rowsToDelete = [];
  
  // Find duplicate rows (skip header)
  for (var i = 1; i < data.length; i++) {
    var name = data[i][0];
    if (!name || name === '') continue;
    
    if (seenNames[name]) {
      rowsToDelete.push(i + 1); // +1 because rows are 1-indexed
      Logger.log("Found duplicate: " + name + " at row " + (i + 1));
    } else {
      seenNames[name] = true;
    }
  }
  
  // Delete rows from bottom to top (to preserve row numbers)
  for (var j = rowsToDelete.length - 1; j >= 0; j--) {
    todaysClinic.deleteRow(rowsToDelete[j]);
    Logger.log("Deleted row " + rowsToDelete[j]);
  }
  
  SpreadsheetApp.getUi().alert("✅ Cleaned up " + rowsToDelete.length + " duplicate(s)!");
}

// ========================================
// 🔥 FIREBASE SYNC (from Today's Clinic)
// ========================================

function syncToFirestore() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var todaysClinic = ss.getSheetByName(TODAYS_CLINIC_SHEET);
  var allClinicians = ss.getSheetByName(ALL_CLINICIANS_SHEET);
  
  if (!todaysClinic) {
    Logger.log("❌ Error: Sheet '" + TODAYS_CLINIC_SHEET + "' not found!");
    return;
  }
  
  if (!allClinicians) {
    Logger.log("❌ Error: Sheet '" + ALL_CLINICIANS_SHEET + "' not found!");
    return;
  }
  
  // Build lookup from All Clinicians
  var allData = allClinicians.getDataRange().getValues();
  var allHeaders = allData[0];
  var allCols = {};
  for (var h = 0; h < allHeaders.length; h++) {
    allCols[allHeaders[h].toString().toLowerCase().trim().replace(/ /g, '_').replace(/[?]/g, '')] = h;
  }
  
  var clinicianLookup = {};
  for (var i = 1; i < allData.length; i++) {
    var name = allData[i][allCols['name']];
    if (name) {
      clinicianLookup[name] = allData[i];
    }
  }
  
  // Get Today's Clinic data
  var todaysData = todaysClinic.getDataRange().getValues();
  
  Logger.log("Today's Clinic has " + todaysData.length + " rows (including header)");
  
  var activeNames = [];
  
  // Sync each active clinician (skip header, skip empty rows)
  for (var j = 1; j < todaysData.length; j++) {
    var row = todaysData[j];
    var name = row[0]; // Column A = Name
    
    // Skip empty rows
    if (!name || name === '' || name.toString().trim() === '') {
      continue;
    }
    
    // Skip if we already processed this name (handles duplicates)
    if (activeNames.indexOf(name) !== -1) {
      Logger.log("⚠️ Skipping duplicate: " + name);
      continue;
    }
    
    activeNames.push(name);
    
    // Get full details from All Clinicians
    var fullData = clinicianLookup[name];
    if (!fullData) {
      Logger.log("⚠️ Warning: " + name + " not found in All Clinicians");
      continue;
    }
    
    // Get delay from Today's Clinic (Column D = index 3)
    var delay = parseInt(row[3]) || 0;
    
    var clinicianData = {
      name: name,
      title: fullData[allCols['title']] || '',
      specialty: fullData[allCols['specialty']] || 'Clinician',
      delay: delay,
      bio: fullData[allCols['bio']] || 'Profile information coming soon.',
      photo_url: fullData[allCols['photo_url']] || '',
      expertise: fullData[allCols['expertise']] || '',
      expertise_tags: fullData[allCols['expertise_tags']] || '',
      achievements: fullData[allCols['achievements']] || '',
      publications: fullData[allCols['publications']] || '',
      interests: fullData[allCols['interests']] || '',
      updated_at: new Date().toISOString()
    };
    
    Logger.log("📤 Syncing: " + name + " (delay: " + delay + " min)");
    
    var docId = sanitizeDocId(name);
    updateFirestoreDocument('clinicians', docId, clinicianData);
  }
  
  // Delete clinicians no longer in Today's Clinic
  deleteRemovedClinicians(activeNames);
  
  Logger.log("✅ Sync complete! " + activeNames.length + " active clinicians.");
}

// ========================================
// 🛠️ HELPER FUNCTIONS
// ========================================

function sanitizeDocId(name) {
  return name.replace(/[\/\.#\$\[\]]/g, '_').replace(/\s+/g, '_').replace(/'/g, '');
}

function updateFirestoreDocument(collection, docId, data) {
  var token = getFirebaseToken();
  var url = 'https://firestore.googleapis.com/v1/projects/' + FIREBASE_PROJECT_ID + '/databases/(default)/documents/' + collection + '/' + docId;
  
  var firestoreData = { fields: {} };
  
  for (var key in data) {
    var value = data[key];
    if (typeof value === 'number') {
      firestoreData.fields[key] = { integerValue: value };
    } else if (typeof value === 'boolean') {
      firestoreData.fields[key] = { booleanValue: value };
    } else {
      firestoreData.fields[key] = { stringValue: value.toString() };
    }
  }
  
  var options = {
    method: 'PATCH',
    contentType: 'application/json',
    headers: { 'Authorization': 'Bearer ' + token },
    payload: JSON.stringify(firestoreData),
    muteHttpExceptions: true
  };
  
  var response = UrlFetchApp.fetch(url, options);
  
  if (response.getResponseCode() === 200) {
    Logger.log("✅ Updated: " + docId);
  } else {
    Logger.log("❌ Error updating " + docId + ": " + response.getContentText());
  }
}

function deleteRemovedClinicians(activeNames) {
  var token = getFirebaseToken();
  var url = 'https://firestore.googleapis.com/v1/projects/' + FIREBASE_PROJECT_ID + '/databases/(default)/documents/clinicians';
  
  var options = {
    method: 'GET',
    headers: { 'Authorization': 'Bearer ' + token },
    muteHttpExceptions: true
  };
  
  var response = UrlFetchApp.fetch(url, options);
  
  if (response.getResponseCode() !== 200) {
    Logger.log("Error fetching existing documents: " + response.getContentText());
    return;
  }
  
  var result = JSON.parse(response.getContentText());
  var documents = result.documents || [];
  
  var normalizedActiveNames = activeNames.map(function(name) {
    return sanitizeDocId(name);
  });
  
  for (var j = 0; j < documents.length; j++) {
    var doc = documents[j];
    var docPath = doc.name;
    var docId = docPath.split('/').pop();
    
    if (normalizedActiveNames.indexOf(docId) === -1) {
      Logger.log("🗑️ Removing inactive clinician: " + docId);
      deleteFirestoreDocument('clinicians', docId);
    }
  }
}

function deleteFirestoreDocument(collection, docId) {
  var token = getFirebaseToken();
  var url = 'https://firestore.googleapis.com/v1/projects/' + FIREBASE_PROJECT_ID + '/databases/(default)/documents/' + collection + '/' + docId;
  
  var options = {
    method: 'DELETE',
    headers: { 'Authorization': 'Bearer ' + token },
    muteHttpExceptions: true
  };
  
  UrlFetchApp.fetch(url, options);
}

function getFirebaseToken() {
  var now = Math.floor(Date.now() / 1000);
  var expiry = now + 3600;
  
  var claimSet = {
    iss: SERVICE_ACCOUNT_EMAIL,
    sub: SERVICE_ACCOUNT_EMAIL,
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: expiry,
    scope: 'https://www.googleapis.com/auth/datastore'
  };
  
  var header = { alg: 'RS256', typ: 'JWT' };
  
  var toSign = Utilities.base64EncodeWebSafe(JSON.stringify(header)) + '.' + Utilities.base64EncodeWebSafe(JSON.stringify(claimSet));
  
  var signatureBytes = Utilities.computeRsaSha256Signature(toSign, PRIVATE_KEY);
  var signature = Utilities.base64EncodeWebSafe(signatureBytes);
  
  var jwt = toSign + '.' + signature;
  
  var tokenResponse = UrlFetchApp.fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    contentType: 'application/x-www-form-urlencoded',
    payload: {
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt
    },
    muteHttpExceptions: true
  });
  
  var tokenData = JSON.parse(tokenResponse.getContentText());
  
  if (tokenData.error) {
    Logger.log("Auth error: " + tokenData.error_description);
    throw new Error("Authentication failed");
  }
  
  return tokenData.access_token;
}

// ========================================
// 🧪 TEST & MANUAL FUNCTIONS
// ========================================

function testConnection() {
  try {
    var token = getFirebaseToken();
    Logger.log("✅ Authentication successful!");
    SpreadsheetApp.getUi().alert("✅ Firebase connection successful!");
  } catch (e) {
    Logger.log("❌ Authentication failed: " + e.message);
    SpreadsheetApp.getUi().alert("❌ Firebase connection failed: " + e.message);
  }
}

function manualSync() {
  syncToFirestore();
  SpreadsheetApp.getUi().alert("✅ Manual sync complete! Check the logs for details.");
}

// ========================================
// ⏰ SETUP TIME-DRIVEN TRIGGER
// ========================================

function setupAutoSync() {
  // Delete existing triggers for syncToFirestore
  var triggers = ScriptApp.getProjectTriggers();
  for (var i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === 'syncToFirestore') {
      ScriptApp.deleteTrigger(triggers[i]);
      Logger.log("Deleted existing syncToFirestore trigger");
    }
  }
  
  // Create new trigger to run every 1 minute
  ScriptApp.newTrigger('syncToFirestore')
    .timeBased()
    .everyMinutes(1)
    .create();
  
  Logger.log("✅ Created new syncToFirestore trigger (every 1 minute)");
  SpreadsheetApp.getUi().alert("✅ Auto-sync enabled!\n\nThe app will update every 1 minute automatically.");
}

function disableAutoSync() {
  var triggers = ScriptApp.getProjectTriggers();
  var count = 0;
  for (var i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === 'syncToFirestore') {
      ScriptApp.deleteTrigger(triggers[i]);
      count++;
    }
  }
  
  Logger.log("Deleted " + count + " syncToFirestore triggers");
  SpreadsheetApp.getUi().alert("✅ Auto-sync disabled!\n\nDeleted " + count + " trigger(s).");
}
