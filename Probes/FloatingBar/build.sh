#!/bin/zsh
# Build one probe into a signed PeriscopeProbe.app, install it in ~/Applications and launch it.
#   ./build.sh ShadowDemo            # the floating-bar demo (default)
#   ./build.sh PeriscopeProbe        # probe A: per-item off-screen window capture (fails on macOS 27)
#   ./build.sh WindowList            # CLI: raw CGWindowList dump of bar-level windows
# Logs land in ./out. The app needs Screen Recording + Accessibility (one-time, identity-stable
# because it is signed with the Developer ID). Never name a stored Bool `shown` on a *Delegate
# class: XProtect's MACOS.ADLOAD.I matches the mangled symbol and trashes the app.
set -euo pipefail
cd "$(dirname "$0")"
SRC="${1:-ShadowDemo}.swift"
APP=PeriscopeProbe.app
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')

if [[ "$SRC" == "WindowList.swift" ]]; then
  xcrun swiftc -O "$SRC" -o windowlist && ./windowlist
  exit 0
fi

mkdir -p "$APP/Contents/MacOS" out
cp Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos26.0" "$SRC" \
  -o "$APP/Contents/MacOS/PeriscopeProbe" -framework AppKit -framework ScreenCaptureKit
if grep -q 'DelegateC5shownSbvpWvd' "$APP/Contents/MacOS/PeriscopeProbe"; then
  echo "refusing: binary matches XProtect MACOS.ADLOAD.I (a Delegate class with a stored \`shown: Bool\`)"; exit 1
fi
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
pkill -f "$APP/Contents/MacOS" || true
rm -rf ~/Applications/"$APP" && cp -R "$APP" ~/Applications/
open ~/Applications/"$APP" --args "$PWD/out" "${2:-3}"
echo "launched; log: out/$(grep -o '"[a-z0-9]*\.log"' "$SRC" | head -1 | tr -d '"')"
