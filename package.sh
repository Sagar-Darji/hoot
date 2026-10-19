#!/bin/bash
# Makes dist/Hoot-<version>.dmg to share: open it, drag Hoot to Applications.
#
#   ./package.sh
#
# For a download that opens with no security warning, sign with an Apple Developer ID and notarize:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=hoot ./package.sh
# (one-time: xcrun notarytool store-credentials hoot --apple-id you@example.com --team-id TEAMID)
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION=$(defaults read "$PWD/build/Hoot.app/Contents/Info" CFBundleShortVersionString)
STAGE=build/dmg
DMG="dist/Hoot-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" dist
cp -R build/Hoot.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Read Me First.txt" "$STAGE/"
# macOS 27 replaced hdiutil (its images no longer open there); fall back to hdiutil on older systems.
if diskutil image create from -h >/dev/null 2>&1; then
  diskutil image create from --format UDZO --volumeName "Hoot $VERSION" "$STAGE" "$DMG" >/dev/null
else
  hdiutil create -volname "Hoot $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Notarized — opens without warnings on any Mac."
fi
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
