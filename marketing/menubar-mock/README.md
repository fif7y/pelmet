# Settings-window mock — marketing compositor

Reusable, tweakable recreation of Pelmet's Settings → Menu Bar window for
marketing (README, site, posts). A real full-window screenshot is the base;
only the two editor rows are re-rendered from a config, so the result is
pixel-faithful everywhere else and never leaks a personal setup.

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

## Icons

`icons/` holds 128px PNGs extracted from locally installed apps:

```sh
sips -s format png -Z 128 "/Applications/X.app/Contents/Resources/<CFBundleIconFile>.icns" --out icons/x.png
```

Library: gdrive, notion, discord, zoom, soundsource, snib, claude, velja,
popclip, bitwarden, figma, obsidian, signal, whatsapp, vscode,
monitorcontrol, windscribe, 1blocker, arc, purepaste, unclutter.
For apps not installed (1Password, Raycast, Slack, Spotify…), drop an icon
PNG in `icons/` from the vendor's press kit and reference it.

## Regenerating the base

Resize the Settings window until **every section is fully visible — never
ship a screenshot with cut content** (System Events: set size to
`{780, 900}` fits the Menu Bar tab today), then:

```sh
screencapture -x -R<x>,<y>,780,900 base-menubar.png
```

If the row geometry moves, update `ROWS` / `RIGHT_EDGE` in `index.html`.
`base-general.png` is a spare full-height General-tab capture.
