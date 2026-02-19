#!/usr/bin/env python3
"""
Simple upload script using Firebase REST API
Uses Firebase CLI token for authentication
"""

import os
import sys
import json
import subprocess
import requests
from pathlib import Path

PROJECT_ID = "doctorwaittimes"
STORAGE_BUCKET = "doctorwaittimes.firebasestorage.app"
FILE_PATH = "WalkingWR/prepopulated_pois.json"
STORAGE_PATH = "prepopulated_pois.json"

def get_firebase_token():
    """Get Firebase access token"""
    try:
        result = subprocess.run(
            ["firebase", "login:ci", "--no-localhost"],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            # The token is usually in the output
            output = result.stdout.strip()
            if "token" in output.lower() or len(output) > 50:
                return output
    except:
        pass
    return None

def upload_via_console_instructions():
    """Provide manual upload instructions"""
    file_path = Path(FILE_PATH)
    if not file_path.exists():
        print(f"❌ File not found: {FILE_PATH}")
        return
    
    file_size = file_path.stat().st_size / (1024 * 1024)
    abs_path = file_path.absolute()
    
    print("=" * 60)
    print("📤 MANUAL UPLOAD INSTRUCTIONS")
    print("=" * 60)
    print()
    print("Since automatic upload requires additional setup, please upload manually:")
    print()
    print("1. Go to: https://console.firebase.google.com/project/doctorwaittimes/storage")
    print("2. Click 'Get started' if Storage isn't set up yet")
    print("3. Click 'Upload file'")
    print(f"4. Select file: {abs_path}")
    print("5. Set path to: prepopulated_pois.json (root of bucket)")
    print("6. Click 'Upload'")
    print()
    print("7. After upload, set Storage Rules (make it readable):")
    print("   - Click 'Rules' tab")
    print("   - Add this rule:")
    print("     match /prepopulated_pois.json {")
    print("       allow read: if true;")
    print("     }")
    print("   - Click 'Publish'")
    print()
    print(f"File size: {file_size:.2f} MB")
    print("=" * 60)

if __name__ == "__main__":
    upload_via_console_instructions()
