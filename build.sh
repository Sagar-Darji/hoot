#!/bin/bash
# Builds Hoot.app and (optionally) installs it to /Applications.
#   ./build.sh            -> build/Hoot.app
#   ./build.sh install    -> also copies to /Applications and launches it
# The speech engine (whisper.cpp + ggml, from Homebrew on this Mac) is copied into the app so it runs anywhere.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Hoot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingNotes "$APP/Contents/MacOS/MeetingNotes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Version from the VERSION file; build number from the commit count (so every release build is unique).
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# --- Bundle the speech engine -------------------------------------------------------------------
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
ENGINE="$APP/Contents/Resources/whisper"
mkdir -p "$ENGINE"
cp -L "$BREW/bin/whisper-server" "$ENGINE/"
cp -L "$BREW/opt/whisper-cpp/lib/libwhisper.1.dylib" "$ENGINE/"
cp -L "$BREW/opt/ggml/lib/libggml.0.dylib" "$BREW/opt/ggml/lib/libggml-base.0.dylib" "$ENGINE/"
# ggml picks its Metal/CPU backends at runtime and looks for them next to the executable.
cp -L "$BREW"/opt/ggml/libexec/libggml-*.so "$ENGINE/"
# Pull in whatever else they link from Homebrew (e.g. libomp for the CPU backend), until nothing is missing.
while :; do
  missing=$(otool -L "$ENGINE"/* | awk '{print $1}' | grep -E '^(/opt/homebrew|/usr/local)/' | sort -u |
            while read -r dep; do [[ -e "$ENGINE/$(basename "$dep")" ]] || echo "$dep"; done)
  [[ -z "$missing" ]] && break
  for dep in $missing; do cp -L "$dep" "$ENGINE/"; done
done
chmod u+w "$ENGINE"/*
for f in "$ENGINE"/*; do
  # Point every Homebrew/@rpath library reference at the copy sitting next to it.
  otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew|/usr/local|@rpath)' | while read -r dep; do
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f" 2>/dev/null
  done
  case "$f" in *.dylib) install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null ;; esac
done
if otool -L "$ENGINE"/* | grep -qE '/opt/homebrew|/usr/local|@rpath'; then
  echo "error: speech engine still references Homebrew paths" >&2; exit 1
fi

# --- Sign ------------------------------------------------------------------------------------------
# DEVELOPER_ID="Developer ID Application: Name (TEAMID)" signs for public distribution (see package.sh).
# Otherwise use the stable local identity if it exists (keeps macOS permissions across rebuilds),
# or ad-hoc as a last resort (macOS then asks for permissions again after each rebuild).
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  IDENTITY="$DEVELOPER_ID"; FLAGS=(--options runtime --timestamp --entitlements Resources/Hoot.entitlements)
elif security find-certificate -c "${SIGN_IDENTITY:-MeetingNotes Local}" >/dev/null 2>&1; then
  IDENTITY="${SIGN_IDENTITY:-MeetingNotes Local}"; FLAGS=()
else
  IDENTITY="-"; FLAGS=()
fi
for f in "$ENGINE"/*; do codesign --force --sign "$IDENTITY" ${FLAGS[@]+"${FLAGS[@]}"} "$f"; done
codesign --force --sign "$IDENTITY" ${FLAGS[@]+"${FLAGS[@]}"} "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD)"

if [[ "${1:-}" == "install" ]]; then
  pkill -x MeetingNotes 2>/dev/null || true
  pkill -f 'whisper-server.*--port 8178' 2>/dev/null || true   # its speech engine, so the new build starts its own
  for _ in {1..20}; do pgrep -x MeetingNotes >/dev/null || break; sleep 0.25; done   # let it quit before reopening
  rm -rf /Applications/MeetingNotes.app /Applications/Hoot.app   # MeetingNotes.app was the old name
  cp -R "$APP" /Applications/
  open /Applications/Hoot.app
  echo "Installed to /Applications/Hoot.app"
fi
