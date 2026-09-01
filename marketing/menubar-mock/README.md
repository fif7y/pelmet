# Menu bar mocks — marketing compositors

Reusable, tweakable recreations of Pelmet's marketing surfaces (README, site,
posts). Real screenshots are the base; only the rows showing apps are
re-rendered from a config, so the result is pixel-faithful and never leaks a
personal setup.

Surfaces:
- `index.html` — Settings → Menu Bar window (the editor)
- `bar.html`   — the menu bar itself, with a fake "revealed" hidden section
  drawn from white brand glyphs over a real collapsed capture (`bar-base.png`)
- `bar-anim.svg` — self-contained animated SVG of the bar in action (glyphs
  tuck away and return, hero.svg's 5.7s cycle/easing); works in a plain
  `<img>` on GitHub and the site. Regenerate with the python snippet in git
  history or tweak positions/delays in-file. Preview: `anim-test.html`.
  NB: Playwright screenshots freeze CSS animations — verify with a
  `document.getAnimations()` scrub, not frame diffs.
- `renders/` — finished, caption-ready shots (see below)

## Renders (message → shot)
- "Calm by default."            → `renders/bar-collapsed.png`
- "Hover, and it's all back."   → `renders/bar-revealed-bignames.png`
- "A real layout editor."       → `renders/editor-bignames.png`
- "Your rules for revealing."   → `renders/settings-general.png`
- the bar in action             → `bar-anim.svg`

## Tweak

Edit the `EDIT ME` block at the top of `index.html`:

```js
{icon:'icons/x.png', label:'X'}   // app icon tile
{sprite:[cx,cy],     label:'X'}   // 64px tile lifted from the base image
{sep:'pipe'} / {sep:'dot'}        // separator tile
```

Rows lay out right-to-left, right-aligned, with the editor's variable tile
widths and label ellipsis.

## Render

```sh
cd marketing/menubar-mock && python3 -m http.server 8438
```

Then screenshot the `#stage` element at 1560×1800 (Playwright:
`page.locator('#stage').screenshot(...)` — `file://` is blocked by the
browser tools, hence the server). Output is @2x; display at 780px wide.

## Icons — automated via `fetch-icon.sh`

```sh
./fetch-icon.sh slack "Slack" slack        # <slug> "<search term>" [simpleicons-slug|-]
```

Tries, in order:
1. **Local extract** — `/Applications/<term>.app` icns → `icons/<slug>.png`
2. **App Store artwork** — iTunes Search API (`entity=macSoftware`, then
   `software`), official 512px icon
3. **Glyph** — `cdn.simpleicons.org/<slug>/white` → `glyphs/<slug>.svg`
   (white monochrome, menubar-style; pass `-` to skip)

For apps with no usable App Store artwork (Docker, Spotify, Raycast were
wrong/missing), **recreate** the app icon from the glyph:

```sh
./make-tile.sh docker 2496ED     # brand-color tile + white glyph → icons/docker.png
```

Library today — icons: gdrive, notion, discord, zoom, soundsource, snib,
claude, velja, popclip, bitwarden, figma, obsidian, signal, whatsapp,
vscode, monitorcontrol, windscribe, 1blocker, arc, purepaste, unclutter,
1password, slack, spotify, dropbox, docker, raycast, rectangle,
fantastical, telegram, tailscale. Glyphs: 1password, spotify, raycast,
dropbox, docker, telegram, tailscale, slack.
Simple Icons drops some trademarked brands over time; if a glyph 404s,
recreate it or pull the vendor press kit.

## Regenerating the base

Resize the Settings window until **every section is fully visible — never
ship a screenshot with cut content** (System Events: set size to
`{780, 900}` fits the Menu Bar tab today), then:

```sh
screencapture -x -R<x>,<y>,780,900 base-menubar.png
```

If the row geometry moves, update `ROWS` / `RIGHT_EDGE` in `index.html`.
`base-general.png` is a spare full-height General-tab capture.
