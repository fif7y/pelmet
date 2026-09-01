#!/usr/bin/env python3
"""Generate marketing/menubar-mock/editor-anim.svg — Spotify tile drags from
Always Hidden to Hidden; Slack + Google Drive close/reopen the gap."""
import base64, pathlib, subprocess, tempfile

MOCK = pathlib.Path(__file__).parent

def b64(p): return base64.b64encode(p.read_bytes()).decode()

def icon128(name):
    out = pathlib.Path(tempfile.gettempdir()) / f'{name}-128.png'
    subprocess.run(['sips', '-Z', '128', str(MOCK / 'icons' / f'{name}.png'),
                    '--out', str(out)], check=True, capture_output=True)
    return b64(out)

base = b64(MOCK / 'editor-anim-base.png')
spot = icon128('spotify')
slack = icon128('slack')
gdrive = icon128('gdrive')

LABEL = 'rgb(152,146,162)'
FONT = "font-family=\"-apple-system,'SF Pro Text','Segoe UI',system-ui,sans-serif\" font-size=\"24\" font-weight=\"400\" letter-spacing=\".2\""
EASE = 'cubic-bezier(.4,0,.2,1)'

# tile: (left, top, width, b64, label)
tiles = {
    'spot':   (1008, 900, 85, spot, 'Spotify'),
    'slack':  (916, 900, 66, slack, 'Slack'),
    'gdrive': (760, 900, 130, gdrive, 'Google Drive'),
}

def tile_g(cls, key):
    l, t, w, data, label = tiles[key]
    ix = l + (w - 64) / 2
    cx = l + w / 2
    return (f'<g class="g {cls}">'
            f'<image x="{ix}" y="{t}" width="64" height="64" href="data:image/png;base64,{data}"/>'
            f'<text x="{cx}" y="{t + 95}" text-anchor="middle" fill="{LABEL}" {FONT}>{label}</text>'
            f'</g>')

# Spotify travel: A (in Always Hidden) -> B (left end of Hidden row)
DX, DY = -260, -236   # 748-1008, 664-900
SHIFT = 111           # spotify width 85 + gap 26

css = f'''
.g{{transform-box:fill-box;transform-origin:50% 50%}}
.spot{{animation:spot 5.7s {EASE} 0.8s infinite both}}
@keyframes spot{{
 0%,14%{{transform:none}}
 19%{{transform:scale(1.12)}}
 33%{{transform:translate({DX}px,{DY}px) scale(1.12)}}
 37%,60%{{transform:translate({DX}px,{DY}px)}}
 65%{{transform:translate({DX}px,{DY}px) scale(1.12)}}
 79%{{transform:scale(1.12)}}
 83%,100%{{transform:none}}
}}
.n{{animation:ngap 5.7s {EASE} 0.8s infinite both}}
@keyframes ngap{{
 0%,19%{{transform:none}}
 30%,67%{{transform:translateX({SHIFT}px)}}
 78%,100%{{transform:none}}
}}
.cur{{animation:cur 5.7s {EASE} 0.8s infinite both}}
@keyframes cur{{
 0%,10%{{opacity:0;transform:none}}
 14%{{opacity:1;transform:none}}
 19%{{transform:none}}
 33%{{transform:translate({DX}px,{DY}px)}}
 40%{{opacity:1;transform:translate({DX}px,{DY}px)}}
 45%,56%{{opacity:0;transform:translate({DX}px,{DY}px)}}
 60%{{opacity:1;transform:translate({DX}px,{DY}px)}}
 65%{{transform:translate({DX}px,{DY}px)}}
 79%{{transform:none}}
 83%{{opacity:1;transform:none}}
 88%,100%{{opacity:0;transform:none}}
}}
@media (prefers-reduced-motion: reduce){{.g,.cur{{animation:none !important}}}}
'''.strip()

# macOS-style arrow cursor, tip at spotify icon center-ish (1050, 934), drawn @2x
cursor = ('<g class="g cur" opacity="0">'
          '<path d="M1050 926 l0 46 12 -11 8 19 8 -3.5 -8 -18.5 16 0 z" '
          'fill="#000" stroke="#fff" stroke-width="3" stroke-linejoin="round"/></g>')

svg = f'''<svg width="640" height="738" viewBox="0 0 1560 1800" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Pelmet layout editor: dragging an icon from Always Hidden to Hidden reflows both sections">
<style>{css}</style>
<image x="0" y="0" width="1560" height="1800" href="data:image/png;base64,{base}"/>
{tile_g('n', 'gdrive')}
{tile_g('n', 'slack')}
{tile_g('spot', 'spot')}
{cursor}
</svg>'''

out = MOCK / 'editor-anim.svg'
out.write_text(svg)
print(out, len(svg))
