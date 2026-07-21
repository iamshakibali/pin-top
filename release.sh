#!/bin/bash
# Build Pin Top for distribution as the first beta release.
# Produces a release-optimized binary, bundles it into PinTop.app, signs it,
# and zips the app into dist/PinTop-<version>.zip for GitHub Releases.
set -e

cd "$(dirname "$0")"

VERSION="$(grep -A1 CFBundleShortVersionString Resources/Info.plist | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/')"
APP="PinTop.app"
DIST="dist"
APP_EXECUTABLE="$PWD/$APP/Contents/MacOS/PinTop"

echo "==> Building Pin Top $VERSION (release)"

# Kill any running copy before replacing the bundle.
if pgrep -f "$APP_EXECUTABLE" >/dev/null 2>&1; then
  echo "==> Stopping running Pin Top"
  pkill -f "$APP_EXECUTABLE" || true
  sleep 1
fi

swift build -c release

# Rewrite the Mach-O + Info.plist in place (keeps TCC designator stable).
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/PinTop "$APP/Contents/MacOS/PinTop"
cp Sources/PinTop/Resources/PinTop.icns "$APP/Contents/Resources/PinTop.icns"

# Strip local symbols for a smaller, cleaner distributable.
strip -x "$APP/Contents/MacOS/PinTop" || true

# Sign: prefer Apple Development cert, then the "Pin Top Local Signing"
# self-signed identity (stable across rebuilds → grants persist), else ad-hoc.
ENTITLEMENTS="Resources/entitlements.plist"
SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(security find-identity 2>/dev/null | sed -n 's/.*"\(Pin Top Local Signing\)".*/\1/p' | head -1)"
fi
if [ -n "$SIGNING_IDENTITY" ]; then
  echo "==> Signing with: $SIGNING_IDENTITY"
  codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
else
  echo "Warning: no signing identity; ad-hoc signing. Gatekeeper will warn on first launch (right-click → Open)." >&2
  codesign --force --sign - "$APP"
fi

# Verify the bundle.
echo "==> Verifying"
codesign --verify --verbose=1 "$APP"

# Package for distribution.
mkdir -p "$DIST"
rm -f "$DIST/PinTop-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$DIST/PinTop-$VERSION.zip"

echo "==> Done"
echo "    App:  $APP"
echo "    Zip:  $DIST/PinTop-$VERSION.zip"
echo "    Next: create a GitHub release and upload the zip"