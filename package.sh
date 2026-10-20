#!/bin/bash
# Makes dist/Hoot-<version>.dmg to share. Opening it shows the classic install window: drag Hoot onto
# the Applications folder.
#
#   ./package.sh
#
# For a download that opens with no security warning, sign with an Apple Developer ID and notarize:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=hoot ./package.sh
# (one-time: xcrun notarytool store-credentials hoot --apple-id you@example.com --team-id TEAMID)
#
# The install window's look is in Resources/dmg: the background (drawn by InstallerBackground.swift,
# `MeetingNotes --render-installer <dir>`) and Finder's layout for it (see layout.py). The volume has
# to be named "Hoot" for Finder to find the background.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION=$(defaults read "$PWD/build/Hoot.app/Contents/Info" CFBundleShortVersionString)
DMG="dist/Hoot-$VERSION.dmg"
WORK=build/dmg
VOLUME="$WORK/Hoot"
rm -rf "$WORK" "$DMG"
mkdir -p "$VOLUME" dist

# macOS 27 replaced hdiutil (its images no longer open there). Copying a folder into an image there
# leaves out .DS_Store — the window's layout — so fill a writable image, then compress it.
MODERN=false
diskutil image create from -h >/dev/null 2>&1 && MODERN=true
if $MODERN; then
  SIZE=$(( $(du -sm build/Hoot.app | cut -f1) + 40 ))m
  diskutil image create blank --size "$SIZE" --volumeName Hoot --fs APFS "$WORK/rw.dmg" >/dev/null
  diskutil image attach --nobrowse --mountPoint "$PWD/$VOLUME" "$WORK/rw.dmg" >/dev/null
  trap 'diskutil eject "$PWD/$VOLUME" >/dev/null 2>&1 || true' EXIT
fi
ditto build/Hoot.app "$VOLUME/Hoot.app"
ln -s /Applications "$VOLUME/Applications"
mkdir -p "$VOLUME/.background"
cp Resources/dmg/background.tiff "$VOLUME/.background/"
cp Resources/dmg/DS_Store "$VOLUME/.DS_Store"
cp Resources/AppIcon.icns "$VOLUME/.VolumeIcon.icns"
if $MODERN; then
  # The disk shows Hoot's icon (Finder's "has custom icon" flag on the volume).
  xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$VOLUME"
  rm -rf "$VOLUME/.fseventsd"
  diskutil eject "$PWD/$VOLUME" >/dev/null
  diskutil image create from --format ULMO "$WORK/rw.dmg" "$DMG" >/dev/null
else
  hdiutil create -volname Hoot -srcfolder "$VOLUME" -ov -format ULMO "$DMG" >/dev/null
fi
rm -rf "$WORK"

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Notarized — opens without warnings on any Mac."
fi
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
