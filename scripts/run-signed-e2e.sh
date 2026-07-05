#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-FonosApp.xcodeproj}"
APP_SCHEME="${APP_SCHEME:-FonosApp}"
UI_SCHEME="${UI_SCHEME:-FonosAppUITests}"
BUNDLE_ID="${BUNDLE_ID:-com.fonos.ios}"
SIM_ID="${FONOS_SIMULATOR_ID:-ADE7F898-98C0-403D-B2B7-D1F7721ADBC5}"
DESTINATION="${FONOS_DESTINATION:-platform=iOS Simulator,name=iPhone 16,OS=18.6}"

DERIVED_DATA="${DERIVED_DATA:-/tmp/FonosSignedE2E-DD}"
UI_DERIVED_DATA="${UI_DERIVED_DATA:-/tmp/FonosSignedE2E-UITests-DD}"
BUILD_RESULT="${BUILD_RESULT:-/tmp/FonosSignedE2E-build.xcresult}"
UI_RESULT="${UI_RESULT:-/tmp/FonosSignedE2E-ui.xcresult}"
LOG_FILE="${LOG_FILE:-/tmp/FonosSignedE2E-app.log}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/FonosApp.app"

step() {
  printf '\n==> %s\n' "$*"
}

rm -rf "$DERIVED_DATA" "$UI_DERIVED_DATA" "$BUILD_RESULT" "$UI_RESULT" "$LOG_FILE"

step "Booting simulator $SIM_ID"
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_ID" -b

step "Building signed app"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$APP_SCHEME" \
  -destination "id=$SIM_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$BUILD_RESULT"

step "Installing signed app"
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM_ID" "$APP_PATH"

step "Granting microphone permission"
xcrun simctl privacy "$SIM_ID" grant microphone "$BUNDLE_ID" || true

step "Launching signed app"
xcrun simctl launch --terminate-running-process "$SIM_ID" "$BUNDLE_ID"
sleep 8

step "Collecting app group, CoreData, and permission logs"
xcrun simctl spawn "$SIM_ID" log show \
  --style compact \
  --last 30s \
  --predicate 'process == "FonosApp" AND (eventMessage CONTAINS "group.com.fonos.ios" OR eventMessage CONTAINS "not entitled" OR eventMessage CONTAINS "NSCocoaErrorDomain" OR eventMessage CONTAINS "Failed to create file" OR eventMessage CONTAINS "microphone" OR eventMessage CONTAINS "Speech")' \
  > "$LOG_FILE" || true

cat "$LOG_FILE"

if grep -qi "not entitled" "$LOG_FILE"; then
  echo "ERROR: signed app still emitted an App Group entitlement failure." >&2
  exit 1
fi

if grep -Eq "NSCocoaErrorDomain|Failed to create file" "$LOG_FILE"; then
  echo "WARNING: CoreData/store initialization logged a recoverable startup issue. See $LOG_FILE." >&2
fi

step "Running signed UI tests"
xcodebuild test \
  -project "$PROJECT" \
  -scheme "$UI_SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$UI_DERIVED_DATA" \
  -resultBundlePath "$UI_RESULT"

step "UI test summary"
xcrun xcresulttool get test-results summary --path "$UI_RESULT"

step "Signed E2E completed"
printf 'Build result: %s\nUI result: %s\nLog file: %s\n' "$BUILD_RESULT" "$UI_RESULT" "$LOG_FILE"
