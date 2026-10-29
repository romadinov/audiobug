#!/bin/bash
# Builds for the simulators, installs on a paired iPhone + Watch pair, seeds a sample book, and launches both.
# Usage: scripts/run-simulators.sh [path/to/book.m4b]
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
PAIR=$(xcrun simctl list pairs | grep -A2 "(active" | head -3)
WATCH=$(echo "$PAIR" | sed -nE 's/.*Watch: .*\(([0-9A-F-]{36})\).*/\1/p' | head -1)
PHONE=$(echo "$PAIR" | sed -nE 's/.*Phone: .*\(([0-9A-F-]{36})\).*/\1/p' | head -1)
[ -n "$WATCH" ] && [ -n "$PHONE" ] || { echo "No paired simulators (xcrun simctl list pairs)."; exit 1; }
xcodebuild -project Audiobug.xcodeproj -scheme Audiobug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build-sim CODE_SIGNING_ALLOWED=NO build -quiet
xcodebuild -project Audiobug.xcodeproj -scheme AudiobugWatch -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath build-sim CODE_SIGNING_ALLOWED=NO build -quiet
xcrun simctl boot "$PHONE" 2>/dev/null || true
xcrun simctl boot "$WATCH" 2>/dev/null || true
open -a Simulator
xcrun simctl install "$PHONE" build-sim/Build/Products/Debug-iphonesimulator/Audiobug.app
xcrun simctl install "$WATCH" build-sim/Build/Products/Debug-watchsimulator/AudiobugWatch.app
if [ -n "${1:-}" ]; then
  C=$(xcrun simctl get_app_container "$PHONE" com.romadinov.audiobug data)
  mkdir -p "$C/Documents/Books" && cp "$1" "$C/Documents/Books/"
fi
xcrun simctl launch "$PHONE" com.romadinov.audiobug
xcrun simctl launch "$WATCH" com.romadinov.audiobug.watchkitapp
