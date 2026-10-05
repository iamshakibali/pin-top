#!/bin/bash
set -e
swift build
APP="PinTop.app"
APP_EXECUTABLE="$PWD/$APP/Contents/MacOS/PinTop"

# Do not replace the bundle while its previous process is still running.
if pgrep -f "$APP_EXECUTABLE" >/dev/null 2>&1; then
  pkill -f "$APP_EXECUTABLE"
  sleep 1
fi

# Preserve the bundle across rebuilds: TCC (Screen Recording / Accessibility
# grants) tracks the app by bundle path AND designator. Removing + recreating
# the bundle breaks the link and resets grants on recent macOS. Instead we
# rewrite the Mach-O and Info.plist in place, then re-sign in place.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/debug/PinTop "$APP/Contents/MacOS/PinTop"
cp Sources/PinTop/Resources/PinTop.icns "$APP/Contents/Resources/PinTop.icns"

# Prefer a real Apple Development cert; fall back to a self-signed
# "Pin Top Local Signing" identity if present (stable across rebuilds
# so TCC keeps the Screen Recording grant); finally fall back to ad-hoc.
ENTITLEMENTS="Resources/entitlements.plist"
SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(security find-identity 2>/dev/null | sed -n 's/.*"\(Pin Top Local Signing\)".*/\1/p' | head -1)"
fi
if [ -n "$SIGNING_IDENTITY" ]; then
  codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
else
  # Ad-hoc (identity-less) signing bakes a new CDHash into every build, and
  # TCC tracks Screen Recording by that identity — so every rebuild silently
  # invalidated the grant and PinTop started re-prompting for a permission
  # that was still toggled ON in System Settings. Fail loudly instead; the
  # stable identity is one command away.
  echo "ERROR: no signing identity found (looked for 'Apple Development:*' and 'Pin Top Local Signing')." >&2
  echo "Signing ad-hoc would reset the Screen Recording grant on this very build." >&2
  echo "Create the stable identity once:  ./setup-signing.sh" >&2
  echo "To build anyway (permissions WILL reset):  FORCE_ADHOC=1 ./run.sh" >&2
  if [ "${FORCE_ADHOC:-0}" = "1" ]; then
    codesign --force --sign - "$APP"
  else
    exit 1
  fi
fi
open "$APP"
echo "Built and opened $APP"