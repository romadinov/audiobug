#!/bin/bash
# Publishes a GitHub release: archives a Release build, exports a development-signed IPA (iPhone app with the
# embedded Watch app; installs on your registered devices only), tags v<version>-<build> and uploads the IPA.
# Usage: scripts/release.sh ["release notes"]
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
VERSION=$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)".*/\1/p' project.yml)
BUILD=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "([^"]+)".*/\1/p' project.yml)
TAG="v$VERSION-$BUILD"
OUT=build/release
rm -rf "$OUT"; mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>teamID</key><string>SZVSSCJQFN</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -project Audiobug.xcodeproj -scheme Audiobug -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$OUT/Audiobug.xcarchive" -allowProvisioningUpdates archive > "$OUT/archive.log" 2>&1 \
  || { grep -E "error:" "$OUT/archive.log"; echo "Archive failed."; exit 1; }
xcodebuild -exportArchive -archivePath "$OUT/Audiobug.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates > "$OUT/export.log" 2>&1 \
  || { grep -E "error:" "$OUT/export.log"; echo "Export failed."; exit 1; }
mv "$OUT/export/Audiobug.ipa" "$OUT/Audiobug-$TAG.ipa"
git tag -f "$TAG" && git push -q origin "$TAG"
gh release create "$TAG" "$OUT/Audiobug-$TAG.ipa" --title "Audiobug $VERSION (build $BUILD)" \
  --notes "${1:-Development-signed IPA (iPhone app with the embedded Apple Watch app). Installs on registered devices: xcrun devicectl device install app --device <id> Audiobug-$TAG.ipa}"
