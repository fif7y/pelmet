# Floating bar probes

Throwaway apps that measured the OS before the floating bar (a glass panel under
the menu bar that shows a hidden section instead of the bar) got designed.
Design and decisions live in the vault: `Ideas/2026-09-17 - Brainstorm - Pelmet floating bar`.

| File | What it answers | Result (2026-09-17, macOS 27.2) |
|---|---|---|
| `PeriscopeProbe.swift` | Can an un-hosted status item's own window be captured off-screen, so the panel needs no reveal at all? | **No.** Status items have no window on the window server; only MenuBarAgent's bar windows (one per display) exist. Items are replicants inside them. |
| `WindowList.swift` | Same question from `CGWindowListCopyWindowInfo(.optionAll)` | Same: layer 25 holds no per-item windows, not even Pelmet's own. |
| `ShadowDemo.swift` | The fallback that works: reveal natively, cover the strip in the real bar, mirror it live into the panel, forward clicks | Works. 10 fps mirror of a 245 pt strip = ~4% CPU, 35 ms per capture, purple dot on while open. |

## ShadowDemo, how it works

- Tails `~/Library/Logs/Pelmet/pelmet.log`: `strip: N items → a..b` gives the hidden strip's
  x-range (logged at every conceal), `effect reveal [...hidden...]` shows the panel,
  `effect conceal` hides it. Width follows the strip.
- On reveal it grabs a pre-swap picture of the strip (Pelmet's ghost cover is still up at that
  moment) and parks a bar-level cover over the strip, excluded from the mirror capture.
- Left-click on a picture: the app's `AXExtrasMenuBar` items inside the strip are read via AX
  and the one under the click gets `AXPress`. Its menu opens from the real bar, above the panel.
  Right-click quits. Three-minute run cap.
- `dotShift` (argv[2], default 3): the capture indicator shifts the bar left while lit, the
  source rect follows.

## Known demo-only artifacts (the real build owns these)

- The panel is a foreign window to Pelmet, so a hover reveal's rehide timer keeps running once
  the pointer leaves the bar. In Pelmet the panel is its own window and `isBarHover` counts it.
- The pre-swap cover capture races the swap by ~60 ms. Pelmet owns the cover, no race.
- `DEVELOPER_DIR` must point at the Xcode beta toolchain (see `build.sh`).
