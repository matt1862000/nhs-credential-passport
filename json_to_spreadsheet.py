#!/usr/bin/env python3
"""
Convert prepopulated_pois.json to CSV/Excel format for easy editing
Then convert back to JSON format

Usage:
    # Convert JSON to Excel
    python3 json_to_spreadsheet.py --to-excel
    
    # Convert JSON to CSV
    python3 json_to_spreadsheet.py --to-csv
    
    # Convert Excel/CSV back to JSON
    python3 json_to_spreadsheet.py --from-excel pois_edited.xlsx
    python3 json_to_spreadsheet.py --from-csv pois_edited.csv
"""

import json
import sys
import argparse
from pathlib import Path
from typing import List, Dict, Any

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False
    print("⚠️  pandas not installed. Install with: pip3 install pandas openpyxl")
    print("   CSV export will still work, but Excel requires pandas")

def load_json_database(json_path: str = "WalkingWR/prepopulated_pois.json") -> Dict[str, Any]:
    """Load the JSON database"""
    with open(json_path, 'r') as f:
        return json.load(f)

def save_json_database(data: Dict[str, Any], output_path: str):
    """Save the JSON database"""
    with open(output_path, 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"✅ Saved JSON database to: {output_path}")

def json_to_csv(json_path: str = "WalkingWR/prepopulated_pois.json", output_path: str = "pois_export.csv"):
    """Convert JSON database to CSV format"""
    data = load_json_database(json_path)
    
    # Flatten POIs with postcode area info
    rows = []
    for area in data['postcodeAreas']:
        for poi in area['pois']:
            row = {
                'postcode': area['postcode'],
                'placeId': poi['placeId'],
                'name': poi['name'],
                'latitude': poi['latitude'],
                'longitude': poi['longitude'],
                'types': ', '.join(poi['types']) if poi['types'] else '',
                'vicinity': poi.get('vicinity') or '',
                'source': poi['source'],
                'rating': poi.get('rating') or ''  # Optional rating field
            }
            rows.append(row)
    
    # Write CSV
    import csv
    if rows:
        fieldnames = ['postcode', 'placeId', 'name', 'latitude', 'longitude', 'types', 'vicinity', 'source', 'rating']
        with open(output_path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        
        print(f"✅ Exported {len(rows)} POIs to CSV: {output_path}")
        print(f"   You can now edit this file in Excel, Numbers, or Google Sheets")
        print(f"   Then convert back using: python3 json_to_spreadsheet.py --from-csv {output_path}")
    else:
        print("❌ No POIs found in database")

def json_to_excel(json_path: str = "WalkingWR/prepopulated_pois.json", output_path: str = "pois_export.xlsx"):
    """Convert JSON database to Excel format"""
    if not HAS_PANDAS:
        print("❌ pandas not installed. Use --to-csv instead or install: pip3 install pandas openpyxl")
        return
    
    data = load_json_database(json_path)
    
    # Flatten POIs with postcode area info
    rows = []
    for area in data['postcodeAreas']:
        for poi in area['pois']:
            row = {
                'postcode': area['postcode'],
                'placeId': poi['placeId'],
                'name': poi['name'],
                'latitude': poi['latitude'],
                'longitude': poi['longitude'],
                'types': ', '.join(poi['types']) if poi['types'] else '',
                'vicinity': poi.get('vicinity') or '',
                'source': poi['source'],
                'rating': poi.get('rating') or ''  # Optional rating field
            }
            rows.append(row)
    
    if rows:
        df = pd.DataFrame(rows)
        df.to_excel(output_path, index=False, engine='openpyxl')
        print(f"✅ Exported {len(rows)} POIs to Excel: {output_path}")
        print(f"   You can now edit this file in Excel")
        print(f"   Then convert back using: python3 json_to_spreadsheet.py --from-excel {output_path}")
    else:
        print("❌ No POIs found in database")

def csv_to_json(csv_path: str, output_path: str = "WalkingWR/prepopulated_pois.json"):
    """Convert CSV back to JSON database format"""
    import csv
    
    # Load original JSON to preserve structure
    original_data = load_json_database()
    
    # Read CSV
    pois_by_postcode = {}
    with open(csv_path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            postcode = row['postcode']
            if postcode not in pois_by_postcode:
                pois_by_postcode[postcode] = []
            
            # Parse types (comma-separated)
            types = [t.strip() for t in row['types'].split(',')] if row['types'] else []
            
            # Parse rating (optional)
            rating = None
            if row.get('rating') and row['rating'].strip():
                try:
                    rating = float(row['rating'].strip())
                except ValueError:
                    rating = None
            
            poi = {
                'placeId': row['placeId'],
                'name': row['name'],
                'latitude': float(row['latitude']),
                'longitude': float(row['longitude']),
                'types': types,
                'vicinity': row['vicinity'] if row['vicinity'] else None,
                'source': row['source'],
                'rating': rating  # Include rating if provided
            }
            pois_by_postcode[postcode].append(poi)
    
    # Update original database structure
    for area in original_data['postcodeAreas']:
        postcode = area['postcode']
        if postcode in pois_by_postcode:
            # Update POIs (preserve order if possible, otherwise replace)
            area['pois'] = pois_by_postcode[postcode]
            print(f"✅ Updated {len(pois_by_postcode[postcode])} POIs for {postcode}")
    
    # Save updated database
    save_json_database(original_data, output_path)
    print(f"✅ Converted CSV back to JSON: {output_path}")

def excel_to_json(excel_path: str, output_path: str = "WalkingWR/prepopulated_pois.json"):
    """Convert Excel back to JSON database format"""
    if not HAS_PANDAS:
        print("❌ pandas not installed. Install with: pip3 install pandas openpyxl")
        return
    
    # Load original JSON to preserve structure
    original_data = load_json_database()
    
    # Read Excel
    df = pd.read_excel(excel_path, engine='openpyxl')
    
    # Group by postcode
    pois_by_postcode = {}
    for _, row in df.iterrows():
        postcode = str(row['postcode'])
        if postcode not in pois_by_postcode:
            pois_by_postcode[postcode] = []
        
        # Parse types (comma-separated)
        types_str = str(row['types']) if pd.notna(row['types']) else ''
        types = [t.strip() for t in types_str.split(',')] if types_str else []
        
        # Parse rating (optional)
        rating = None
        if pd.notna(row.get('rating')):
            try:
                rating = float(row['rating'])
            except (ValueError, TypeError):
                rating = None
        
        poi = {
            'placeId': str(row['placeId']),
            'name': str(row['name']),
            'latitude': float(row['latitude']),
            'longitude': float(row['longitude']),
            'types': types,
            'vicinity': str(row['vicinity']) if pd.notna(row['vicinity']) and str(row['vicinity']).strip() else None,
            'source': str(row['source']),
            'rating': rating  # Include rating if provided
        }
        pois_by_postcode[postcode].append(poi)
    
    # Update original database structure
    for area in original_data['postcodeAreas']:
        postcode = area['postcode']
        if postcode in pois_by_postcode:
            area['pois'] = pois_by_postcode[postcode]
            print(f"✅ Updated {len(pois_by_postcode[postcode])} POIs for {postcode}")
    
    # Save updated database
    save_json_database(original_data, output_path)
    print(f"✅ Converted Excel back to JSON: {output_path}")

def main():
    parser = argparse.ArgumentParser(description='Convert POI database between JSON and spreadsheet formats')
    parser.add_argument('--to-csv', action='store_true', help='Convert JSON to CSV')
    parser.add_argument('--to-excel', action='store_true', help='Convert JSON to Excel')
    parser.add_argument('--from-csv', type=str, help='Convert CSV back to JSON')
    parser.add_argument('--from-excel', type=str, help='Convert Excel back to JSON')
    parser.add_argument('--input', type=str, default='WalkingWR/prepopulated_pois.json', help='Input JSON file')
    parser.add_argument('--output', type=str, help='Output file (default: auto-determined)')
    
    args = parser.parse_args()
    
    if args.to_csv:
        output = args.output or 'pois_export.csv'
        json_to_csv(args.input, output)
    elif args.to_excel:
        output = args.output or 'pois_export.xlsx'
        json_to_excel(args.input, output)
    elif args.from_csv:
        output = args.output or args.input.replace('.csv', '.json')
        csv_to_json(args.from_csv, output)
    elif args.from_excel:
        output = args.output or args.from_excel.replace('.xlsx', '.json')
        excel_to_json(args.from_excel, output)
    else:
        parser.print_help()
        print("\nExamples:")
        print("  python3 json_to_spreadsheet.py --to-excel")
        print("  python3 json_to_spreadsheet.py --from-excel pois_edited.xlsx")

if __name__ == "__main__":
    main()
