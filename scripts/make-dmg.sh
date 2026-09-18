#!/usr/bin/env bash
# Build a styled DMG: background picture, the app on the left, an Applications
# alias on the right, icon positions and window size baked into the volume's
# .DS_Store through Finder. No external tool needed (create-dmg does the same
# dance). Usage: scripts/make-dmg.sh <Pelmet.app> <out.dmg>
set -euo pipefail

APP="$1"; OUT="$2"
VOLNAME="Pelmet"
HERE="$(cd "$(dirname "$0")" && pwd)"
BG="$HERE/dmg/background.tiff"   # 1x + 2x, see scripts/dmg/README.md

# Window geometry — must match the picture (660×400) and its arrow placement.
WIN_X=400; WIN_Y=200; WIN_W=660; WIN_H=400
ICON_SIZE=128
APP_POS="168, 182"      # icon centre, left of the dots
APPS_POS="492, 182"     # icon centre, right of the dots

STAGE=$(mktemp -d)
RW="$STAGE/rw.dmg"
mkdir "$STAGE/vol"
cp -R "$APP" "$STAGE/vol/"
ln -s /Applications "$STAGE/vol/Applications"
mkdir "$STAGE/vol/.background"
cp "$BG" "$STAGE/vol/.background/background.tiff"

# Read-write image first so Finder can write the layout into it.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE/vol" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/\/Volumes\// {print $1; exit}')
MOUNT="/Volumes/$VOLNAME"
trap 'hdiutil detach "$DEV" -quiet 2>/dev/null || true; rm -rf "$STAGE"' EXIT

osascript <<EOF
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {$WIN_X, $WIN_Y, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$(basename "$APP")" of container window to {$APP_POS}
        set position of item "Applications" of container window to {$APPS_POS}
        close
        open
        close
    end tell
end tell
EOF

# Hide the background folder from the volume listing (chflags survives the convert).
chflags hidden "$MOUNT/.background"
sleep 2   # let Finder flush .DS_Store
sync
hdiutil detach "$DEV" -quiet
trap 'rm -rf "$STAGE"' EXIT

rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "dmg: $OUT"
