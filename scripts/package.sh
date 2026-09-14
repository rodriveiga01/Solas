#!/bin/sh
# Packages the release binary as Ask.app with a stable identity
# (LSUIElement accessory + fixed bundle id for hotkeys/TCC).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
APP="$ROOT/Ask.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/Ask" "$APP/Contents/MacOS/Ask"
cp "resources/Ask.app-Info.plist" "$APP/Contents/Info.plist"
# Stamp build identity: visible in the help card + launch log, so a stale
# /Applications copy can never masquerade as the new build.
TAG="$(date +%Y%m%d-%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TAG" "$APP/Contents/Info.plist"
# Sign with a real Apple Development identity when available: TCC then
# keys the Accessibility grant to (team, bundle id), so rebuilds stop
# invalidating it. Falls back to ad-hoc (grants die on every rebuild).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o 'Apple Development: [^"]*' | head -n 1)"
if [ -n "$IDENTITY" ]; then
  codesign -s "$IDENTITY" -f --deep "$APP"
  echo "Signed: $IDENTITY"
else
  codesign -s - -f "$APP" 2>/dev/null || true
  echo "Signed ad-hoc (grants expire on rebuild)"
fi
echo "Packaged: $APP ($TAG)"
