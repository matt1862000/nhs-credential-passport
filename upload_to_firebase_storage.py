#!/usr/bin/env python3
"""
Upload prepopulated_pois.json to Firebase Storage
Requires: pip install firebase-admin google-cloud-storage
"""

import os
import sys
from pathlib import Path

try:
    import firebase_admin
    from firebase_admin import credentials, storage
except ImportError:
    print("❌ Error: firebase-admin not installed")
    print("   Install with: pip3 install firebase-admin")
    sys.exit(1)

# Project configuration
PROJECT_ID = "doctorwaittimes"
STORAGE_BUCKET = "doctorwaittimes.firebasestorage.app"
FILE_PATH = "WalkingWR/prepopulated_pois.json"
STORAGE_PATH = "prepopulated_pois.json"

def upload_file():
    """Upload file to Firebase Storage"""
    
    # Check if file exists
    file_path = Path(FILE_PATH)
    if not file_path.exists():
        print(f"❌ Error: File not found at {FILE_PATH}")
        sys.exit(1)
    
    file_size = file_path.stat().st_size / (1024 * 1024)  # MB
    print(f"📦 File: {FILE_PATH}")
    print(f"📦 Size: {file_size:.2f} MB")
    print(f"📦 Destination: {STORAGE_BUCKET}/{STORAGE_PATH}")
    
    # Initialize Firebase Admin SDK
    # Try to use default credentials (from gcloud auth application-default login)
    # Or use service account key if available
    try:
        # Check if already initialized
        if not firebase_admin._apps:
            # Try to initialize with default credentials
            cred = credentials.ApplicationDefault()
            firebase_admin.initialize_app(cred, {
                'storageBucket': STORAGE_BUCKET
            })
            print("✅ Firebase Admin SDK initialized with default credentials")
        else:
            print("✅ Firebase Admin SDK already initialized")
    except Exception as e:
        print(f"⚠️  Could not initialize with default credentials: {e}")
        print("   Trying alternative authentication...")
        
        # Try to find service account key
        service_account_paths = [
            "serviceAccountKey.json",
            "google-services.json",
            os.path.expanduser("~/.config/gcloud/application_default_credentials.json")
        ]
        
        cred = None
        for path in service_account_paths:
            if os.path.exists(path):
                try:
                    cred = credentials.Certificate(path)
                    print(f"✅ Found credentials at: {path}")
                    break
                except:
                    continue
        
        if not cred:
            print("❌ Error: No Firebase credentials found")
            print("   Options:")
            print("   1. Run: gcloud auth application-default login")
            print("   2. Download service account key from Firebase Console")
            print("   3. Place it as 'serviceAccountKey.json' in this directory")
            sys.exit(1)
        
        if not firebase_admin._apps:
            firebase_admin.initialize_app(cred, {
                'storageBucket': STORAGE_BUCKET
            })
    
    # Upload file
    try:
        bucket = storage.bucket()
        blob = bucket.blob(STORAGE_PATH)
        
        print(f"📤 Uploading to Firebase Storage...")
        blob.upload_from_filename(str(file_path))
        
        # Make it publicly readable
        blob.make_public()
        
        # Get download URL
        download_url = blob.public_url
        print(f"✅ Upload successful!")
        print(f"📦 Download URL: {download_url}")
        print(f"📦 File is publicly accessible")
        
        return download_url
        
    except Exception as e:
        print(f"❌ Upload failed: {e}")
        print(f"   Error type: {type(e).__name__}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    upload_file()
