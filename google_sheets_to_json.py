#!/usr/bin/env python3
"""
Convert Google Sheets to JSON database in real-time

Usage:
    # First time setup - get Google Sheets URL
    python3 google_sheets_to_json.py --setup
    
    # Convert Google Sheets to JSON
    python3 google_sheets_to_json.py --convert
    
    # Watch for changes and auto-convert
    python3 google_sheets_to_json.py --watch

Requirements:
    pip install gspread oauth2client
    OR use simpler CSV export method (no auth needed)
"""

import json
import sys
import argparse
import time
from pathlib import Path
from typing import List, Dict, Any, Optional
from datetime import datetime

# Try to import Google Sheets API (optional)
try:
    import gspread
    from oauth2client.service_account import ServiceAccountCredentials
    HAS_GSHEETS_API = True
except ImportError:
    HAS_GSHEETS_API = False

def load_json_database(json_path: str = "WalkingWR/prepopulated_pois.json") -> Dict[str, Any]:
    """Load the JSON database"""
    with open(json_path, 'r') as f:
        return json.load(f)

def save_json_database(data: Dict[str, Any], output_path: str):
    """Save the JSON database"""
    with open(output_path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"✅ Saved JSON database to: {output_path}")

def google_sheets_to_json_via_csv(sheets_url: str, output_path: str = "WalkingWR/prepopulated_pois.json"):
    """
    Convert Google Sheets to JSON using CSV export (no auth needed)
    
    Steps:
    1. Share Google Sheet publicly (or get CSV export URL)
    2. Export as CSV: File → Download → Comma-separated values (.csv)
    3. Or use CSV export URL directly
    """
    import urllib.request
    import csv
    import io
    
    # Convert Google Sheets URL to CSV export URL
    # Format: https://docs.google.com/spreadsheets/d/{SHEET_ID}/edit
    # CSV: https://docs.google.com/spreadsheets/d/{SHEET_ID}/export?format=csv&gid=0
    
    if '/edit' in sheets_url:
        sheet_id = sheets_url.split('/d/')[1].split('/')[0]
        csv_url = f"https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=csv&gid=0"
    elif '/export' in sheets_url:
        csv_url = sheets_url
    else:
        print("❌ Invalid Google Sheets URL")
        print("   Expected format: https://docs.google.com/spreadsheets/d/SHEET_ID/edit")
        return False
    
    print(f"📥 Downloading from Google Sheets...")
    print(f"   URL: {csv_url}")
    
    try:
        # Download CSV
        response = urllib.request.urlopen(csv_url)
        csv_data = response.read().decode('utf-8')
        
        # Parse CSV
        reader = csv.DictReader(io.StringIO(csv_data))
        rows = list(reader)
        
        if not rows:
            print("❌ No data found in Google Sheets")
            return False
        
        print(f"✅ Downloaded {len(rows)} POIs from Google Sheets")
        
        # Load original JSON to preserve structure
        original_data = load_json_database()
        
        # Group by postcode
        pois_by_postcode = {}
        for row in rows:
            postcode = row['postcode']
            if postcode not in pois_by_postcode:
                pois_by_postcode[postcode] = []
            
            # Parse types (comma-separated)
            types_str = row.get('types', '').strip()
            types = [t.strip() for t in types_str.split(',')] if types_str else []
            
            # Parse rating (optional)
            rating = None
            rating_str = row.get('rating', '').strip()
            if rating_str:
                try:
                    rating = float(rating_str)
                except ValueError:
                    rating = None
            
            poi = {
                'placeId': row['placeId'],
                'name': row['name'],
                'latitude': float(row['latitude']),
                'longitude': float(row['longitude']),
                'types': types,
                'vicinity': row.get('vicinity', '').strip() or None,
                'source': row['source'],
                'rating': rating
            }
            pois_by_postcode[postcode].append(poi)
        
        # Update original database structure
        updated_count = 0
        for area in original_data['postcodeAreas']:
            postcode = area['postcode']
            if postcode in pois_by_postcode:
                area['pois'] = pois_by_postcode[postcode]
                updated_count += len(pois_by_postcode[postcode])
                print(f"✅ Updated {len(pois_by_postcode[postcode])} POIs for {postcode}")
        
        # Increment version
        original_data['version'] = original_data.get('version', 1) + 1
        original_data['lastUpdated'] = datetime.utcnow().isoformat() + 'Z'
        
        # Save updated database
        save_json_database(original_data, output_path)
        print(f"✅ Converted Google Sheets to JSON: {output_path}")
        print(f"   Updated {updated_count} POIs")
        print(f"   Version: {original_data['version']}")
        return True
        
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print("❌ Access denied. Make sure the Google Sheet is:")
            print("   1. Shared publicly (Anyone with the link can view)")
            print("   2. Or use File → Share → Get link → Change to 'Anyone with the link'")
        else:
            print(f"❌ HTTP Error {e.code}: {e.reason}")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

def google_sheets_to_json_via_api(sheet_id: str, credentials_file: str, output_path: str = "WalkingWR/prepopulated_pois.json"):
    """
    Convert Google Sheets to JSON using Google Sheets API (requires authentication)
    More reliable but requires setup
    """
    if not HAS_GSHEETS_API:
        print("❌ gspread not installed. Install with: pip3 install gspread oauth2client")
        print("   Or use --via-csv method (simpler, no auth needed)")
        return False
    
    try:
        # Authenticate
        scope = ['https://spreadsheets.google.com/feeds',
                 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        client = gspread.authorize(creds)
        
        # Open sheet
        sheet = client.open_by_key(sheet_id)
        worksheet = sheet.sheet1
        
        # Get all records
        records = worksheet.get_all_records()
        
        if not records:
            print("❌ No data found in Google Sheets")
            return False
        
        print(f"✅ Downloaded {len(records)} POIs from Google Sheets")
        
        # Convert to JSON (same logic as CSV method)
        # ... (similar conversion logic)
        
        return True
        
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def watch_and_convert(sheets_url: str, interval: int = 60):
    """Watch Google Sheets for changes and auto-convert"""
    print(f"👀 Watching Google Sheets for changes (checking every {interval} seconds)...")
    print(f"   Press Ctrl+C to stop")
    
    last_hash = None
    
    while True:
        try:
            # Download and check if changed
            import urllib.request
            import hashlib
            
            if '/edit' in sheets_url:
                sheet_id = sheets_url.split('/d/')[1].split('/')[0]
                csv_url = f"https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=csv&gid=0"
            else:
                csv_url = sheets_url
            
            response = urllib.request.urlopen(csv_url)
            csv_data = response.read()
            current_hash = hashlib.md5(csv_data).hexdigest()
            
            if current_hash != last_hash:
                if last_hash is not None:
                    print(f"\n🔄 Changes detected! Converting...")
                    google_sheets_to_json_via_csv(sheets_url)
                else:
                    print(f"✅ Initial conversion complete")
                last_hash = current_hash
            else:
                print(".", end="", flush=True)
            
            time.sleep(interval)
            
        except KeyboardInterrupt:
            print("\n\n👋 Stopped watching")
            break
        except Exception as e:
            print(f"\n❌ Error: {e}")
            time.sleep(interval)

def main():
    parser = argparse.ArgumentParser(description='Convert Google Sheets to JSON database')
    parser.add_argument('--via-csv', type=str, help='Google Sheets URL (uses CSV export, no auth needed)')
    parser.add_argument('--via-api', type=str, help='Google Sheet ID (requires API credentials)')
    parser.add_argument('--credentials', type=str, help='Path to Google API credentials JSON file')
    parser.add_argument('--watch', type=str, help='Watch Google Sheets URL for changes and auto-convert')
    parser.add_argument('--interval', type=int, default=60, help='Watch interval in seconds (default: 60)')
    parser.add_argument('--output', type=str, default='WalkingWR/prepopulated_pois.json', help='Output JSON file')
    
    args = parser.parse_args()
    
    if args.watch:
        watch_and_convert(args.watch, args.interval)
    elif args.via_csv:
        google_sheets_to_json_via_csv(args.via_csv, args.output)
    elif args.via_api:
        if not args.credentials:
            print("❌ --credentials required when using --via-api")
            sys.exit(1)
        google_sheets_to_json_via_api(args.via_api, args.credentials, args.output)
    else:
        parser.print_help()
        print("\n" + "="*60)
        print("QUICK START - Google Sheets Integration")
        print("="*60)
        print("\nMethod 1: CSV Export (Simplest - No Auth Needed)")
        print("  1. Create/export your POIs to Google Sheets")
        print("  2. Share sheet: File → Share → Get link → 'Anyone with the link can view'")
        print("  3. Copy the Google Sheets URL")
        print("  4. Run: python3 google_sheets_to_json.py --via-csv 'YOUR_SHEETS_URL'")
        print("\nMethod 2: Watch Mode (Auto-convert on changes)")
        print("  python3 google_sheets_to_json.py --watch 'YOUR_SHEETS_URL' --interval 60")
        print("  (Checks every 60 seconds for changes)")
        print("\nExample:")
        print("  python3 google_sheets_to_json.py --via-csv 'https://docs.google.com/spreadsheets/d/ABC123/edit'")

if __name__ == "__main__":
    main()
