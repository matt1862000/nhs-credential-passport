#!/usr/bin/env python3
"""
Upload all prepopulated_pois_<district>.json files to Firebase Storage.

Use after building JSON from generator TSV (build_postcode_json_from_tsv.py).
Same credentials as upload_to_firebase_storage.py.

Usage:
  python3 upload_all_postcodes_to_firebase.py [--dir .]

Requires: pip install firebase-admin
"""

import argparse
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

STORAGE_BUCKET = "doctorwaittimes.firebasestorage.app"


def init_firebase():
    # Try service account key file first (works without gcloud)
    for path in [
        os.path.join(os.path.dirname(__file__) or ".", "serviceAccountKey.json"),
        "serviceAccountKey.json",
        "google-services.json",
        os.path.expanduser("~/.config/gcloud/application_default_credentials.json"),
    ]:
        path = os.path.abspath(path)
        if os.path.exists(path):
            try:
                cred = credentials.Certificate(path)
                if not firebase_admin._apps:
                    firebase_admin.initialize_app(cred, {"storageBucket": STORAGE_BUCKET})
                print(f"✅ Firebase initialized ({path})")
                return
            except Exception as e:
                continue
    # Fall back to Application Default Credentials (gcloud auth application-default login)
    try:
        if not firebase_admin._apps:
            cred = credentials.ApplicationDefault()
            firebase_admin.initialize_app(cred, {"storageBucket": STORAGE_BUCKET})
        print("✅ Firebase initialized (Application Default Credentials)")
        return
    except Exception as e:
        print("❌ No Firebase credentials found.")
        print("   Option 1: Download a service account key from Firebase Console:")
        print("     Project Settings → Service accounts → Generate new private key")
        print("     Save as 'serviceAccountKey.json' in this directory.")
        print("   Option 2: Run: gcloud auth application-default login")
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description="Upload all prepopulated_pois_*.json to Firebase Storage")
    ap.add_argument("--dir", default=".", help="Directory containing prepopulated_pois_*.json (default: current)")
    args = ap.parse_args()
    base = Path(args.dir).resolve()
    files = sorted(base.glob("prepopulated_pois_*.json"))
    if not files:
        print(f"No prepopulated_pois_*.json found in {base}")
        sys.exit(1)
    init_firebase()
    bucket = storage.bucket()
    ok = 0
    for f in files:
        name = f.name
        try:
            blob = bucket.blob(name)
            blob.upload_from_filename(str(f))
            # Don't call make_public() — bucket uses uniform bucket-level access (IAM), not per-object ACLs
            ok += 1
            print(f"  ✅ {name}")
        except Exception as e:
            print(f"  ❌ {name}: {e}")
    print(f"\nUploaded {ok}/{len(files)} files to {STORAGE_BUCKET}")


if __name__ == "__main__":
    main()
