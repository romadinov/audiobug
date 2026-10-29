#!/bin/bash
# Builds Audiobug (with the embedded Watch app) and installs it on a connected or Wi-Fi-paired iPhone.
# The Watch app follows through the Watch app on the phone (General › Automatic App Install) or can be
# installed from My Watch › Available Apps.
# Usage: scripts/install-iphone.sh             (first paired physical iPhone)
#        scripts/install-iphone.sh <device-id> (see: xcrun devicectl list devices)
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bump-build.sh
xcodegen generate >/dev/null
if [ -n "${1:-}" ]; then DEVICE="$1"; else
  TMP=$(mktemp); xcrun devicectl list devices --json-output "$TMP" >/dev/null 2>&1 || true
  DEVICE=$(python3 -c "
import json
d=json.load(open('$TMP'))
for x in d.get('result',{}).get('devices',[]):
    hp=x.get('hardwareProperties',{}); cp=x.get('connectionProperties',{})
    if hp.get('deviceType')=='iPhone' and hp.get('reality')=='physical' and cp.get('pairingState')=='paired':
        print(x['identifier']); break
"); rm -f "$TMP"
fi
[ -n "$DEVICE" ] || { echo "No iPhone found. Connect it or pass a device id (xcrun devicectl list devices)."; exit 1; }
xcodebuild -project Audiobug.xcodeproj -scheme Audiobug -configuration Debug -derivedDataPath build -allowProvisioningUpdates \
  -destination "generic/platform=iOS" build > build/xcodebuild.log 2>&1 || { grep -E "error:|BUILD" build/xcodebuild.log; echo "Build failed; nothing installed."; exit 1; }
grep -E "BUILD" build/xcodebuild.log
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Debug-iphoneos/Audiobug.app
echo "Installed on $DEVICE. Open Audiobug once so iCloud creates iCloud Drive › Audiobug › Inbox."
