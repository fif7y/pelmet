#!/usr/bin/env python3
"""Contextualized marketing renders: windows and bar mocks composed on the
iPhone14-3 wallpaper. Reads the existing kit outputs (editor-anim.svg,
bar-anim.svg, window base PNGs) and emits concept renders into renders/.

Concepts:
  1  window on wallpaper card  -> screenshot-settings-ctx.png, editor-anim-ctx.svg
  2  bar on desktop card       -> bar-anim-desktop.svg (+ static png preview)
  3  bar in floating window    -> bar-anim-window.svg  (+ static png preview)
"""
import base64, io, pathlib, re, subprocess
from PIL import Image, ImageDraw, ImageFilter

MOCK = pathlib.Path(__file__).parent
OUT = MOCK / 'renders'

# ================= EDIT ME =================
WALL = MOCK / 'wallpaper.png'   # iPhone14-3 gradient
WIN_R = 26                      # window corner radius @2x
CARD_R = 40                     # backdrop card corner radius @2x
PAD = 150                       # window inset from card edge @2x
JPEG_Q = 92                     # embedded background quality
# =========== END EDIT ME ===========

wall = Image.open(WALL).convert('RGB')


def cover_crop(w, h, y_bias=0.5):
    """Scale-crop the wallpaper to exactly (w, h). y_bias 0=top 1=bottom."""
    s = max(w / wall.width, h / wall.height)
    im = wall.resize((round(wall.width * s), round(wall.height * s)), Image.LANCZOS)
    x = (im.width - w) // 2
    y = round((im.height - h) * y_bias)
    return im.crop((x, y, x + w, y + h))


def jpeg_b64(im):
    buf = io.BytesIO()
    im.save(buf, 'JPEG', quality=JPEG_Q)
    return base64.b64encode(buf.getvalue()).decode()


def rounded(im, r):
    mask = Image.new('L', im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height - 1], r, fill=255)
    out = im.convert('RGBA')
    out.putalpha(mask)
    return out


# --- concept 1a: static window PNGs on a wallpaper card ----------------------
def window_card(base_png, out_png, y_bias=0.35):
    win = rounded(Image.open(MOCK / base_png).convert('RGB'), WIN_R)
    W, H = win.width + 2 * PAD, win.height + 2 * PAD
    card = cover_crop(W, H, y_bias).convert('RGBA')
    # soft drop shadow
    sh = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        [PAD, PAD + 14, PAD + win.width, PAD + win.height + 14], WIN_R, fill=(10, 0, 40, 150))
    card.alpha_composite(sh.filter(ImageFilter.GaussianBlur(28)))
    card.alpha_composite(win, (PAD, PAD))
    out = rounded(card.convert('RGB'), CARD_R)
    out.save(MOCK / out_png)
    print(out_png, out.size)


# --- concept 1b: editor anim SVG rewrapped on the wallpaper card -------------
def split_svg(path):
    t = (MOCK / path).read_text()
    style = re.search(r'<style>(.*?)</style>', t, re.S).group(1)
    body = t[t.index('</style>') + 8:t.rindex('</svg>')]
    vb = re.search(r'viewBox="0 0 (\d+) (\d+)"', t)
    return style, body, int(vb.group(1)), int(vb.group(2))


def editor_ctx():
    style, body, w, h = split_svg('editor-anim.svg')
    # round the base window image via clip; overlay anim elements ride along
    W, H = w + 2 * PAD, h + 2 * PAD
    bg = jpeg_b64(cover_crop(W, H, 0.35))
    svg = (
        f'<svg width="{round(W/2.44)}" height="{round(H/2.44)}" viewBox="0 0 {W} {H}" '
        f'xmlns="http://www.w3.org/2000/svg" role="img" '
        f'aria-label="Pelmet layout editor: dragging an icon from Always Hidden to Hidden">'
        f'<style>{style}</style>'
        f'<defs>'
        f'<clipPath id="card"><rect width="{W}" height="{H}" rx="{CARD_R}"/></clipPath>'
        f'<clipPath id="win"><rect x="{PAD}" y="{PAD}" width="{w}" height="{h}" rx="{WIN_R}"/></clipPath>'
        f'<filter id="sh" x="-20%" y="-20%" width="140%" height="140%">'
        f'<feDropShadow dx="0" dy="14" stdDeviation="28" flood-color="#0a0028" flood-opacity=".55"/>'
        f'</filter></defs>'
        f'<g clip-path="url(#card)">'
        f'<image x="0" y="0" width="{W}" height="{H}" href="data:image/jpeg;base64,{bg}"/>'
        f'<rect x="{PAD}" y="{PAD}" width="{w}" height="{h}" rx="{WIN_R}" filter="url(#sh)"/>'
        f'<g clip-path="url(#win)"><g transform="translate({PAD},{PAD})">{body}</g></g>'
        f'</g></svg>')
    (MOCK / 'editor-anim-ctx.svg').write_text(svg)
    print('editor-anim-ctx.svg', len(svg) // 1024, 'KB')


# --- bar concepts ------------------------------------------------------------
BAR_BG = re.compile(r'<defs><linearGradient id="wp".*?</defs><rect width="\d+" height="\d+" fill="url\(#wp\)"/>', re.S)


def bar_parts():
    style, body, w, h = split_svg('bar-anim.svg')
    return style, BAR_BG.sub('', body), w, h


def bar_desktop():
    """Concept 2: the bar living on top of the wallpaper, desktop-style card."""
    style, bar, bw, bh = bar_parts()
    W, H = bw, 470
    bg = jpeg_b64(cover_crop(W, H, 0.0))
    svg = (
        f'<svg width="{W//2}" height="{H//2}" viewBox="0 0 {W} {H}" '
        f'xmlns="http://www.w3.org/2000/svg" role="img" '
        f'aria-label="Pelmet on the desktop: hidden icons slide out from the chevron, then tuck away">'
        f'<style>{style}</style>'
        f'<defs><clipPath id="card"><rect width="{W}" height="{H}" rx="{CARD_R}"/></clipPath></defs>'
        f'<g clip-path="url(#card)">'
        f'<image x="0" y="0" width="{W}" height="{H}" href="data:image/jpeg;base64,{bg}"/>'
        f'{bar}'
        f'</g></svg>')
    (MOCK / 'bar-anim-desktop.svg').write_text(svg)
    print('bar-anim-desktop.svg', len(svg) // 1024, 'KB')


def bar_window():
    """Concept 3: floating screen mockup on the wallpaper, bar across its top."""
    style, bar, bw, bh = bar_parts()
    SCALE, MX, MY = 0.82, 150, 120          # screen inset in the card
    W, H = 1440, 760
    sw, sh_ = W - 2 * MX, H - 2 * MY        # screen size
    bg = jpeg_b64(cover_crop(W, H, 0.75))   # lighter part behind
    scr = jpeg_b64(cover_crop(round(sw / SCALE), round(sh_ / SCALE), 0.0))
    svg = (
        f'<svg width="{W//2}" height="{H//2}" viewBox="0 0 {W} {H}" '
        f'xmlns="http://www.w3.org/2000/svg" role="img" '
        f'aria-label="Pelmet on the desktop: hidden icons slide out from the chevron, then tuck away">'
        f'<style>{style}</style>'
        f'<defs>'
        f'<clipPath id="card"><rect width="{W}" height="{H}" rx="{CARD_R}"/></clipPath>'
        f'<clipPath id="scr"><rect width="{round(sw/SCALE)}" height="{round(sh_/SCALE)}" rx="{round(28/SCALE)}"/></clipPath>'
        f'<filter id="sh" x="-20%" y="-20%" width="140%" height="140%">'
        f'<feDropShadow dx="0" dy="16" stdDeviation="30" flood-color="#0a0028" flood-opacity=".6"/>'
        f'</filter></defs>'
        f'<g clip-path="url(#card)">'
        f'<image x="0" y="0" width="{W}" height="{H}" href="data:image/jpeg;base64,{bg}"/>'
        f'<rect x="{MX}" y="{MY}" width="{sw}" height="{sh_}" rx="28" filter="url(#sh)"/>'
        f'<g transform="translate({MX},{MY}) scale({SCALE})" clip-path="url(#scr)">'
        f'<image x="0" y="0" width="{round(sw/SCALE)}" height="{round(sh_/SCALE)}" href="data:image/jpeg;base64,{scr}"/>'
        f'{bar}'
        f'</g></g></svg>')
    (MOCK / 'bar-anim-window.svg').write_text(svg)
    print('bar-anim-window.svg', len(svg) // 1024, 'KB')


# concept 0: rounded corners only, transparent background
for base, out in [('base-general.png', 'renders/settings-rounded.png'),
                  ('editor-anim-base.png', 'renders/editor-rounded.png')]:
    im = rounded(Image.open(MOCK / base).convert('RGB'), WIN_R)
    im.save(MOCK / out)
    print(out, im.size)

window_card('base-general.png', 'renders/settings-ctx.png')
window_card('editor-anim-base.png', 'renders/editor-ctx.png')
editor_ctx()
bar_desktop()
bar_window()

# static previews of the animated concepts for quick eyeballing
for name in ['editor-anim-ctx', 'bar-anim-desktop', 'bar-anim-window']:
    subprocess.run(['rsvg-convert', str(MOCK / f'{name}.svg'),
                    '-o', str(OUT / f'{name}-preview.png')], check=True)
    print(f'renders/{name}-preview.png')
