#!/usr/bin/env python3
"""
Automated script to update POI database from Google Sheets
Can be run manually, scheduled, or triggered automatically

Usage:
    # Run once
    python3 auto_update_from_sheets.py
    
    # Run with custom URL
    python3 auto_update_from_sheets.py --url 'YOUR_GOOGLE_SHEETS_URL'
    
    # Run continuously (watches for changes)
    python3 auto_update_from_sheets.py --watch --interval 300
"""

import sys
import os
import time
import subprocess
from pathlib import Path
from datetime import datetime

# Configuration - Set your Google Sheets URL here
DEFAULT_GOOGLE_SHEETS_URL = os.environ.get('GOOGLE_SHEETS_URL', '')
DEFAULT_OUTPUT = "WalkingWR/prepopulated_pois.json"
DEFAULT_INTERVAL = 300  # 5 minutes

def update_from_sheets(sheets_url: str, output_path: str = DEFAULT_OUTPUT) -> bool:
    """Update JSON database from Google Sheets"""
    script_path = Path(__file__).parent / "google_sheets_to_json.py"
    
    if not script_path.exists():
        print(f"❌ Script not found: {script_path}")
        return False
    
    print(f"🔄 Updating from Google Sheets...")
    print(f"   Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    try:
        result = subprocess.run(
            [sys.executable, str(script_path), "--via-csv", sheets_url, "--output", output_path],
            capture_output=True,
            text=True,
            timeout=120
        )
        
        if result.returncode == 0:
            print("✅ Update successful!")
            print(result.stdout)
            return True
        else:
            print("❌ Update failed:")
            print(result.stderr)
            return False
            
    except subprocess.TimeoutExpired:
        print("❌ Update timed out")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def watch_and_update(sheets_url: str, interval: int = DEFAULT_INTERVAL, output_path: str = DEFAULT_OUTPUT):
    """Continuously watch Google Sheets and update when changed"""
    print(f"👀 Watching Google Sheets for changes...")
    print(f"   URL: {sheets_url}")
    print(f"   Check interval: {interval} seconds ({interval//60} minutes)")
    print(f"   Press Ctrl+C to stop")
    print()
    
    last_success_time = None
    
    while True:
        try:
            success = update_from_sheets(sheets_url, output_path)
            
            if success:
                last_success_time = datetime.now()
                print(f"✅ Last successful update: {last_success_time.strftime('%H:%M:%S')}")
            else:
                if last_success_time:
                    print(f"⚠️  Update failed (last success: {last_success_time.strftime('%H:%M:%S')})")
            
            print(f"⏳ Waiting {interval} seconds until next check...")
            print()
            time.sleep(interval)
            
        except KeyboardInterrupt:
            print("\n\n👋 Stopped watching")
            break
        except Exception as e:
            print(f"❌ Error: {e}")
            time.sleep(interval)

def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='Auto-update POI database from Google Sheets')
    parser.add_argument('--url', type=str, default=DEFAULT_GOOGLE_SHEETS_URL,
                       help='Google Sheets URL (or set GOOGLE_SHEETS_URL environment variable)')
    parser.add_argument('--watch', action='store_true',
                       help='Watch for changes continuously')
    parser.add_argument('--interval', type=int, default=DEFAULT_INTERVAL,
                       help=f'Watch interval in seconds (default: {DEFAULT_INTERVAL})')
    parser.add_argument('--output', type=str, default=DEFAULT_OUTPUT,
                       help=f'Output JSON file (default: {DEFAULT_OUTPUT})')
    
    args = parser.parse_args()
    
    if not args.url:
        print("❌ Google Sheets URL required!")
        print("   Set it with: --url 'YOUR_GOOGLE_SHEETS_URL'")
        print("   Or set environment variable: export GOOGLE_SHEETS_URL='YOUR_URL'")
        print()
        print("   Example:")
        print("   python3 auto_update_from_sheets.py --url 'https://docs.google.com/spreadsheets/d/ABC123/edit'")
        sys.exit(1)
    
    if args.watch:
        watch_and_update(args.url, args.interval, args.output)
    else:
        success = update_from_sheets(args.url, args.output)
        sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
