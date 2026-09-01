#!/bin/zsh
# fetch-icon.sh <slug> "<App Store search term>" [simpleicons-slug|-]
#
# Grabs marketing assets for one app, fully automated:
#   icons/<slug>.png   128px app icon — local /Applications extract if the app
#                      is installed, else official App Store artwork
#                      (iTunes Search API, entity=macSoftware then software)
#   glyphs/<slug>.svg  white monochrome menubar-style glyph from Simple Icons
#                      (cdn.simpleicons.org, CC0) — pass "-" to skip
#
# Examples:
#   ./fetch-icon.sh slack "Slack" slack
#   ./fetch-icon.sh 1password "1Password" 1password
#   ./fetch-icon.sh fantastical "Fantastical" -
set -e
cd "$(dirname "$0")"
mkdir -p icons glyphs
slug=$1; term=$2; si=${3:-$1}

# 1) local extract beats a download
for app in /Applications/*.app; do
  name=$(basename "$app" .app)
  if [[ "${name:l}" == "${term:l}" ]]; then
    icn=$(defaults read "$app/Contents/Info" CFBundleIconFile 2>/dev/null || true)
    f="$app/Contents/Resources/${icn%.icns}.icns"
    if [[ -f "$f" ]]; then
      sips -s format png -Z 128 "$f" --out "icons/$slug.png" >/dev/null && echo "icon: $slug.png (local)"
    fi
  fi
done

# 2) App Store artwork
if [[ ! -f "icons/$slug.png" ]]; then
  for entity in macSoftware software; do
    url=$(curl -s "https://itunes.apple.com/search?term=$(echo "$term" | sed 's/ /+/g')&entity=$entity&limit=1" \
      | python3 -c 'import sys,json;r=json.load(sys.stdin)["results"];print(r[0]["artworkUrl512"] if r else "")')
    if [[ -n "$url" ]]; then
      curl -s "$url" -o "icons/$slug-512.png" && sips -Z 128 "icons/$slug-512.png" --out "icons/$slug.png" >/dev/null
      rm -f "icons/$slug-512.png"
      echo "icon: $slug.png (App Store: $url)"
      break
    fi
  done
fi
[[ -f "icons/$slug.png" ]] || echo "icon: $slug NOT FOUND"

# 3) monochrome menubar glyph
if [[ "$si" != "-" ]]; then
  if curl -sf "https://cdn.simpleicons.org/$si/white" -o "glyphs/$slug.svg"; then
    echo "glyph: $slug.svg (simpleicons:$si)"
  else
    rm -f "glyphs/$slug.svg"; echo "glyph: $slug not on simpleicons ($si)"
  fi
fi
