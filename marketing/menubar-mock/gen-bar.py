#!/usr/bin/env python3
"""Fully synthetic menu bar compositor — no screenshot base, everything is
drawn, so every element is configurable: background, icons, system widgets,
clock text, battery level. One config drives three outputs:

  bar-anim.svg                     the bar in action (real Smooth choreography)
  renders/bar-collapsed.png        static collapsed shot (@2x)
  renders/bar-revealed-bignames.png  static revealed shot (@2x)

Regenerate: python3 gen-bar.py   (rsvg-convert required for the PNGs)
Preview the animation: anim-test.html (getAnimations scrub — Playwright
screenshots freeze CSS animations)."""
import base64, pathlib, subprocess

MOCK = pathlib.Path(__file__).parent

# ================= EDIT ME =================
W, H = 1150, 80                       # @2x canvas; display at half width
BACKGROUND = ('#190265', '#2B0386')   # wallpaper gradient, left -> right
                                      # (or set BG_IMAGE to a png path)
BG_IMAGE = None

# Hidden section (left of the chevron, appears on reveal), left -> right.
#   {'glyph': 'name'}  white template SVG from glyphs/
#   {'sep': True}      pipe separator
HIDDEN = [
    {'glyph': 'spotify'},
    {'glyph': '1password'},
    {'sep': True},
    {'glyph': 'raycast'},
    {'glyph': 'dropbox'},
    {'glyph': 'docker'},
]

# Visible cluster (right of the chevron), left -> right. System widgets:
#   sconce                     Sconce's real Berth mark (exact app geometry)
#   battery (pct/bolt)         real macOS percentage style (body+fill+nub)
#   controlcenter, siri, location   Apple's ACTUAL glyphs — real SF Symbols
#                              rendered by fetch-sfsymbol.swift into
#                              glyphs-system/ (switch.2, siri, location.fill)
VISIBLE = [
    {'system': 'sconce'},
    {'system': 'battery', 'pct': 74, 'bolt': True},
    {'system': 'controlcenter'},
    {'system': 'siri'},
]

CLOCK = 'Mon Sep 1  9:41'        # any string (plain spaces only —
                                 # rsvg mangles exotic whitespace)
# =========== END EDIT ME ===========

GLYPH = 36            # app glyph size
GAP = 34              # space between item edges (real bar ~= this @2x)
RIGHT_MARGIN = 26
CY = H // 2
INK = '#fff'          # menu bar template color
DARK = BACKGROUND[0]  # ink for battery pct text
FONT = "font-family=\"-apple-system,'SF Pro Text','Helvetica Neue',sans-serif\""

SHOW = 'cubic-bezier(.16,1,.3,1)'    # StatusItemFader.showCurve
HIDE = 'cubic-bezier(.55,0,.8,.4)'   # StatusItemFader.hideCurve
R0, R1 = 18, 25       # reveal slide window (% of the 5.7s brand cycle)
C0, C1 = 62, 69       # conceal tuck window


def b64(p): return base64.b64encode(p.read_bytes()).decode()


def png_size(p):
    d = p.read_bytes()
    import struct
    w, h = struct.unpack('>II', d[16:24])
    return w, h


def sf(name, cx, height, opacity=.92):
    """Real SF Symbol render (white template PNG from fetch-sfsymbol.swift),
    placed centered at cx with the given display height, natural aspect."""
    p = MOCK / 'glyphs-system' / f'{name}.png'
    w, h = png_size(p)
    dw = height * w / h
    return (f'<image x="{cx-dw/2}" y="{CY-height/2}" width="{dw}" height="{height}" '
            f'opacity="{opacity}" href="data:image/png;base64,{b64(p)}"/>'), dw


def rr(x, y, w, h, r, fill, extra=''):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" {extra}/>'


# --- item builders: return (width, svg_fragment_centered_at_cx) ------------
def item_svg(it, cx):
    if it.get('sep'):
        return f'<rect x="{cx-1.5}" y="{CY-15}" width="3" height="30" rx="2" fill="{INK}" fill-opacity=".5"/>'
    if 'glyph' in it:
        g = b64(MOCK / 'glyphs' / f"{it['glyph']}.svg")
        return (f'<image x="{cx-GLYPH/2}" y="{CY-GLYPH/2}" width="{GLYPH}" height="{GLYPH}" '
                f'href="data:image/svg+xml;base64,{g}"/>')
    kind = it['system']
    if kind == 'sconce':
        # Sconce's REAL Berth mark, exact locked geometry from the app's
        # MenubarIconRenderer (24-grid: outer 2.5->21.5 R6.6, berth knockout
        # 8x8 r2.6 at home origin 10.2,10.2 = bottom-right), 18pt = 36px @2x.
        u = 36 / 24
        ox, oy = cx - 18, CY - 18
        def rrect(x, y, w, h, r):
            return (f'M{ox+x*u+r*u} {oy+y*u} h{(w-2*r)*u} a{r*u} {r*u} 0 0 1 {r*u} {r*u} '
                    f'v{(h-2*r)*u} a{r*u} {r*u} 0 0 1 {-r*u} {r*u} h{-(w-2*r)*u} '
                    f'a{r*u} {r*u} 0 0 1 {-r*u} {-r*u} v{-(h-2*r)*u} '
                    f'a{r*u} {r*u} 0 0 1 {r*u} {-r*u} z')
        return (f'<path fill-rule="evenodd" fill="{INK}" fill-opacity=".92" '
                f'd="{rrect(2.5, 2.5, 19, 19, 6.6)} {rrect(10.2, 10.2, 8, 8, 2.6)}"/>')
    if kind == 'battery':
        # Real macOS 27 percentage battery, geometry measured off an actual
        # capture (@2x): body 46x24 r8 at 40% white, solid charge fill,
        # 4x10 nub, dark digits + bolt drawn over.
        pct, bolt = it.get('pct', 80), it.get('bolt', False)
        bw, bh, r = 46, 24, 8
        x0, y0 = cx - (bw + 4) / 2, CY - bh / 2
        out = rr(x0, y0, bw, bh, r, INK, 'fill-opacity=".4"')
        fill_w = max(r * 2, bw * pct / 100)
        out += (f'<clipPath id="bat{round(cx)}"><rect x="{x0}" y="{y0}" width="{fill_w}" '
                f'height="{bh}" rx="{r}"/></clipPath>'
                + rr(x0, y0, bw, bh, r, INK, f'fill-opacity=".95" clip-path="url(#bat{round(cx)})"'))
        out += (f'<path d="M{x0+bw+1} {CY-5} q4 0 4 5 q0 5 -4 5 z" fill="{INK}" fill-opacity=".4"/>')
        out += (f'<text x="{x0 + bw/2 - (5 if bolt else 0)}" y="{CY+6.5}" text-anchor="middle" {FONT} '
                f'font-size="19" font-weight="600" fill="{DARK}">{pct}</text>')
        if bolt:
            bx = x0 + bw - 13
            out += (f'<path d="M{bx+3} {CY-9} L{bx-3} {CY+1.5} L{bx+0.5} {CY+1.5} L{bx-1.5} {CY+9} '
                    f'L{bx+4.5} {CY-1.5} L{bx+1} {CY-1.5} Z" fill="{DARK}"/>')
        return out
    # Apple's actual glyphs — real SF Symbol renders from fetch-sfsymbol.swift.
    if kind in SF_ITEMS:
        return sf(SF_ITEMS[kind][0], cx, SF_ITEMS[kind][1])[0]
    raise ValueError(kind)


# system -> (SF Symbol name, display height @2x). switch.2 IS the Control
# Center menu bar icon; siri is the circle-with-wave Siri glyph.
SF_ITEMS = {
    'controlcenter': ('switch.2', 34),
    'siri': ('siri', 31),
    'location': ('location.fill', 29),
}


def item_width(it):
    if it.get('sep'): return 12
    if 'glyph' in it: return GLYPH
    kind = it['system']
    if kind in SF_ITEMS:
        name, height = SF_ITEMS[kind]
        w, h = png_size(MOCK / 'glyphs-system' / f'{name}.png')
        return height * w / h
    return {'sconce': 40, 'battery': 50}[kind]


def chevron(direction):
    # Real chevron.compact.left/right SF Symbol renders, centered at origin.
    p = MOCK / 'glyphs-system' / f'chevron.compact.{direction}.png'
    w, h = png_size(p)
    dh = 30
    dw = dh * w / h
    return (f'<image x="{-dw/2}" y="{-dh/2}" width="{dw}" height="{dh}" opacity=".9" '
            f'href="data:image/png;base64,{b64(p)}"/>')


def background():
    if BG_IMAGE:
        return f'<image x="0" y="0" width="{W}" height="{H}" href="data:image/png;base64,{b64(MOCK / BG_IMAGE)}"/>'
    return (f'<defs><linearGradient id="wp" x1="0" y1="0" x2="1" y2=".18">'
            f'<stop offset="0" stop-color="{BACKGROUND[0]}"/>'
            f'<stop offset="1" stop-color="{BACKGROUND[1]}"/></linearGradient></defs>'
            f'<rect width="{W}" height="{H}" fill="url(#wp)"/>')


# --- layout: right to left ---------------------------------------------------
clock_w = round(len(CLOCK) * 12.6)
cursor = W - RIGHT_MARGIN - clock_w / 2
clock_frag = (f'<text x="{cursor}" y="{CY+9}" text-anchor="middle" {FONT} '
              f'font-size="26" font-weight="500" fill="{INK}" fill-opacity=".95">{CLOCK}</text>')
cursor -= clock_w / 2 + GAP

visible_frags = []
for it in reversed(VISIBLE):
    w = item_width(it)
    cursor -= w / 2
    visible_frags.append(item_svg(it, cursor))
    cursor -= w / 2 + GAP

CHEV_W = 22
cursor -= CHEV_W / 2
CHEV_X = cursor
cursor -= CHEV_W / 2 + GAP

hidden_placed = []   # (dx_to_chevron, frag) leftmost first after reversal
for it in reversed(HIDDEN):
    w = item_width(it)
    cursor -= w / 2
    hidden_placed.append((CHEV_X - cursor, item_svg(it, cursor)))
    cursor -= w / 2 + GAP
hidden_placed.reverse()

BASE = background() + ''.join(visible_frags) + clock_frag


def static_svg(state):
    chev = (f'<g transform="translate({CHEV_X},{CY})">'
            f'{chevron("left" if state == "collapsed" else "right")}</g>')
    body = '' if state == 'collapsed' else ''.join(f for _, f in hidden_placed)
    return (f'<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg">'
            f'{BASE}{body}{chev}</svg>')


def anim_svg():
    css, groups = [], []
    for i, (dx, frag) in enumerate(hidden_placed):
        groups.append(f'<g class="it i{i}">{frag}</g>')
        css.append(
            f'.i{i}{{animation:s{i} 5.7s linear .8s infinite both}}'
            f'@keyframes s{i}{{'
            f'0%,{R0}%{{transform:translateX({dx}px);opacity:0;animation-timing-function:{SHOW}}}'
            f'{R1}%,{C0}%{{transform:none;opacity:1;animation-timing-function:{HIDE}}}'
            f'{C1}%,100%{{transform:translateX({dx}px);opacity:0}}}}')
    css.append(
        f'.cL{{animation:cL 5.7s linear .8s infinite both}}'
        f'@keyframes cL{{0%,{R0}%{{opacity:1}}{R0+2}%,{C0-2}%{{opacity:0}}{C0}%,100%{{opacity:1}}}}'
        f'.cR{{animation:cR 5.7s linear .8s infinite both}}'
        f'@keyframes cR{{0%,{R0}%{{opacity:0}}{R0+2}%,{C0-2}%{{opacity:1}}{C0}%,100%{{opacity:0}}}}')
    style = ('.it{transform-box:fill-box}' + ''.join(css) +
             '@media (prefers-reduced-motion: reduce){.it,.cL,.cR{animation:none !important}}')
    return (f'<svg width="{W//2}" height="{H//2}" viewBox="0 0 {W} {H}" '
            f'xmlns="http://www.w3.org/2000/svg" role="img" '
            f'aria-label="Pelmet: hidden menu bar icons slide out from the chevron on hover, then tuck back away">'
            f'<style>{style}</style>{BASE}{"".join(groups)}'
            f'<g class="cL" transform="translate({CHEV_X},{CY})">{chevron("left")}</g>'
            f'<g class="cR" transform="translate({CHEV_X},{CY})">{chevron("right")}</g>'
            f'</svg>')


(MOCK / 'bar-anim.svg').write_text(anim_svg())
print('bar-anim.svg', (MOCK / 'bar-anim.svg').stat().st_size)
for state, png in [('collapsed', 'renders/bar-collapsed.png'),
                   ('revealed', 'renders/bar-revealed-bignames.png')]:
    tmp = pathlib.Path(f'/tmp/bar-{state}.svg')
    tmp.write_text(static_svg(state))
    subprocess.run(['rsvg-convert', '-w', str(W), '-h', str(H), str(tmp),
                    '-o', str(MOCK / png)], check=True)
    print(png)
