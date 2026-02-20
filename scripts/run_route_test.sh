#!/bin/bash
# Route Generation Test Harness — Automated Simulator Runner
# Usage: ./scripts/run_route_test.sh
# Boots the iOS Simulator, sets WF2 location, builds and launches the app,
# waits for the diagnostic to complete, pulls results, and runs analysis.

set -euo pipefail

# Configuration
SIM_UDID="C2EA6332-2143-4212-B857-1998FEBB2A88"  # iPhone 16 Pro, iOS 18
SIM_NAME="iPhone 16 Pro"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="WalkingWR"
BUNDLE_ID="com.nhs.WalkingWR"  # Adjust if different
LAT="53.6825"
LNG="-1.4915"
TRIGGER_FILE="diagnostic_trigger.txt"
OUTPUT_FILE="diagnostic_routes.json"
TIMEOUT=600  # 10 minutes max
POLL_INTERVAL=5

echo "═══════════════════════════════════════════════════════════"
echo "  Route Generation Test Harness"
echo "  Location: WF2 Kirkhamgate ($LAT, $LNG)"
echo "  Simulator: $SIM_NAME ($SIM_UDID)"
echo "═══════════════════════════════════════════════════════════"

# Step 1: Boot simulator
echo ""
echo "▶ Step 1: Booting simulator..."
SIM_STATE=$(xcrun simctl list devices | grep "$SIM_UDID" | grep -o "(Booted)\|(Shutdown)" || echo "Unknown")
if [[ "$SIM_STATE" == *"Shutdown"* ]]; then
    xcrun simctl boot "$SIM_UDID"
    echo "  Simulator booting..."
    sleep 5
elif [[ "$SIM_STATE" == *"Booted"* ]]; then
    echo "  Simulator already booted"
else
    echo "  ⚠️  Unknown state: $SIM_STATE — attempting boot"
    xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
    sleep 5
fi

# Open Simulator.app so we can see it
open -a Simulator

# Step 2: Set location
echo ""
echo "▶ Step 2: Setting location to WF2 ($LAT, $LNG)..."
xcrun simctl location "$SIM_UDID" set "$LAT","$LNG"
echo "  Location set"

# Step 3: Build the app
echo ""
echo "▶ Step 3: Building app for simulator..."
cd "$PROJECT_DIR"

# Find the Xcode project or workspace
if [ -d "WalkingWR.xcworkspace" ]; then
    BUILD_CMD="xcodebuild -workspace WalkingWR.xcworkspace -scheme $SCHEME"
elif [ -d "WalkingWR.xcodeproj" ]; then
    BUILD_CMD="xcodebuild -project WalkingWR.xcodeproj -scheme $SCHEME"
else
    echo "  ❌ No Xcode project/workspace found!"
    exit 1
fi

$BUILD_CMD \
    -sdk iphonesimulator \
    -destination "id=$SIM_UDID" \
    -configuration Debug \
    -derivedDataPath "$PROJECT_DIR/DerivedDataTerminal" \
    build 2>&1 | tail -5

BUILD_EXIT=${PIPESTATUS[0]}
if [ $BUILD_EXIT -ne 0 ]; then
    echo "  ❌ Build failed with exit code $BUILD_EXIT"
    exit 1
fi
echo "  ✅ Build succeeded"

# Step 4: Install the app
echo ""
echo "▶ Step 4: Installing app..."
APP_PATH=$(find "$PROJECT_DIR/DerivedDataTerminal" -name "WalkingWR.app" -path "*/Debug-iphonesimulator/*" | head -1)
if [ -z "$APP_PATH" ]; then
    echo "  ❌ Could not find built .app bundle"
    exit 1
fi
xcrun simctl install "$SIM_UDID" "$APP_PATH"
echo "  ✅ Installed: $APP_PATH"

# Step 5: Write trigger file
echo ""
echo "▶ Step 5: Writing diagnostic trigger file..."
# Get app container
APP_CONTAINER=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null || echo "")
if [ -z "$APP_CONTAINER" ]; then
    echo "  ⚠️  App container not found — launching app first to create it..."
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
    sleep 3
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    sleep 1
    APP_CONTAINER=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)
fi
DOCS_DIR="$APP_CONTAINER/Documents"
mkdir -p "$DOCS_DIR"
echo "trigger" > "$DOCS_DIR/$TRIGGER_FILE"
# Remove old output
rm -f "$DOCS_DIR/$OUTPUT_FILE"
rm -f "$DOCS_DIR/${OUTPUT_FILE}.started"
echo "  ✅ Trigger file written to $DOCS_DIR/$TRIGGER_FILE"

# Step 6: Launch the app and start log capture
echo ""
echo "▶ Step 6: Launching app..."
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
sleep 1

# Start log capture in background
LOG_FILE="$PROJECT_DIR/scripts/diagnostic_log.txt"
xcrun simctl spawn "$SIM_UDID" log stream --predicate "processImagePath contains \"WalkingWR\"" --level debug > "$LOG_FILE" 2>&1 &
LOG_PID=$!

xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
echo "  ✅ App launched, log capture PID=$LOG_PID"

# Step 7: Poll for results
echo ""
echo "▶ Step 7: Waiting for diagnostic to complete (timeout: ${TIMEOUT}s)..."
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    # Re-fetch container in case it changed
    APP_CONTAINER=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null || echo "$APP_CONTAINER")
    DOCS_DIR="$APP_CONTAINER/Documents"
    
    if [ -f "$DOCS_DIR/$OUTPUT_FILE" ]; then
        # Check it's not empty and has valid JSON
        FILE_SIZE=$(stat -f%z "$DOCS_DIR/$OUTPUT_FILE" 2>/dev/null || echo "0")
        if [ "$FILE_SIZE" -gt 100 ]; then
            echo "  ✅ Results file found ($FILE_SIZE bytes) after ${ELAPSED}s"
            break
        fi
    fi
    
    # Show progress
    if [ -f "$DOCS_DIR/${OUTPUT_FILE}.started" ]; then
        if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
            echo "  ⏳ Diagnostic running... (${ELAPSED}s elapsed)"
        fi
    fi
    
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Kill log capture
kill $LOG_PID 2>/dev/null || true

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "  ❌ Timed out after ${TIMEOUT}s!"
    echo "  Check log: $LOG_FILE"
    exit 1
fi

# Step 8: Pull results and analyze
echo ""
echo "▶ Step 8: Pulling results..."
RESULTS_FILE="$PROJECT_DIR/scripts/diagnostic_routes.json"
cp "$DOCS_DIR/$OUTPUT_FILE" "$RESULTS_FILE"
echo "  ✅ Results saved to $RESULTS_FILE"

# Also check if log has the JSON
if grep -q "DIAGNOSTIC_JSON_START" "$LOG_FILE" 2>/dev/null; then
    echo "  ✅ JSON also captured in console log"
fi

# Step 9: Run analysis
echo ""
echo "▶ Step 9: Running analysis..."
if [ -f "$PROJECT_DIR/scripts/analyze_routes.py" ]; then
    python3 "$PROJECT_DIR/scripts/analyze_routes.py" "$RESULTS_FILE"
else
    echo "  ⚠️  analyze_routes.py not found — showing raw JSON summary:"
    python3 -c "
import json, sys
with open('$RESULTS_FILE') as f:
    d = json.load(f)
print(f'Total routes: {d.get(\"totalRoutes\", \"?\")}')
print(f'In-band: {d.get(\"totalInBand\", \"?\")}')
print(f'Total time: {d.get(\"totalTimeSeconds\", \"?\")}s')
" 2>/dev/null || cat "$RESULTS_FILE" | python3 -m json.tool | head -20
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Done! Results: $RESULTS_FILE"
echo "  Console log: $LOG_FILE"
echo "═══════════════════════════════════════════════════════════"
