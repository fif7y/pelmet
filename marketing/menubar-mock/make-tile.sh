#!/bin/zsh
# make-tile.sh <slug> <brand-hex-no-#>
# Recreates a macOS-style app icon from glyphs/<slug>.svg: rounded-rect tile
# in the brand color, white glyph inlined (rsvg-convert won't follow external
# hrefs, so the glyph's markup is embedded directly).
set -e
cd "$(dirname "$0")"
slug=$1; color=$2
python3 - "$slug" "$color" <<'EOF'
import re, subprocess, sys
slug, color = sys.argv[1], sys.argv[2]
svg = open(f'glyphs/{slug}.svg').read()
inner = re.sub(r'</?svg[^>]*>', '', svg)
inner = re.sub(r'fill="[^"]*"', '', inner)
tile = f'''<svg width="128" height="128" xmlns="http://www.w3.org/2000/svg">
<rect x="8" y="8" width="112" height="112" rx="26" fill="#{color}"/>
<g transform="translate(34,34) scale(2.5)" fill="#FFFFFF">{inner}</g>
</svg>'''
open(f'/tmp/tile-{slug}.svg', 'w').write(tile)
subprocess.run(['rsvg-convert','-w','128','-h','128',
                f'/tmp/tile-{slug}.svg','-o',f'icons/{slug}.png'], check=True)
print(f'icons/{slug}.png (recreated, #{color})')
EOF
