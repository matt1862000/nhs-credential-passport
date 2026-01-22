#!/usr/bin/env python3
import subprocess
import json
import requests
from pathlib import Path

# Get Firebase token
try:
    result = subprocess.run(["firebase", "token"], capture_output=True, text=True, timeout=10)
    token = result.stdout.strip() if result.returncode == 0 else None
except:
    token = None

if not token:
    print("Please run: firebase login")
    print("Then run this script again")
    exit(1)

# Upload file
file_path = Path("WalkingWR/prepopulated_pois.json")
bucket = "doctorwaittimes.firebasestorage.app"
file_name = "prepopulated_pois.json"

print(f"Uploading {file_path} to Firebase Storage...")
print(f"Bucket: {bucket}")
print(f"Path: {file_name}")

# Use gsutil if available, otherwise provide instructions
print("\nSince gsutil is not available, please upload manually:")
print(f"1. Go to: https://console.firebase.google.com/project/doctorwaittimes/storage")
print(f"2. Upload file: {file_path.absolute()}")
print(f"3. Set path to: {file_name}")
