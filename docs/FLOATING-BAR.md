# Floating bar

A glass tray under the menu bar that holds a hidden section: pictures of its
items, laid out by Pelmet, clicks and drags forwarded to the real items. It is
a place the section lives in while open, not a reveal animation target.

Status: design, 2026-09-21. Replaces the first port (live strip mirror,
transient), which read as a reveal and not as a bar.

## Why a tray at all

On a notch Mac the native in-bar reveal extends the strip left, under the notch
and into the app menus (#26). The tray gives the section unlimited room and the
visible icons never move. In-bar reveal stays the default; the tray is opt-in
per section.

## What macOS 27 allows (measured)

- A status item exists only as a replicant in MenuBarAgent's per-display bar
  window. No per-item window to capture or re-parent (Periscope probe,
  `Probes/FloatingBar`). The tray can only show pictures and relay input.
- The « overflow expands from a background app with a HID click; trapped items
  land left of the notch, live, and stay while covered (OverflowProbe).
- Synthetic ⌘-drags move any item, own or third-party (ItemMover, Apply).

## Behaviour

| | Rule |
|---|---|
| Open | Any trigger the section already has (click, hover, shortcut, chevron). |
| Content | The section's items as their last pictures (taken at conceal, refreshed after every relay), in drawn order, separators drawn as gaps. No capture while open, so no purple dot at rest. |
| Stay | Open until dismissed: click outside, Esc, the trigger again, or the section's auto-rehide timer (the same setting, no new knob). Hover trigger: hover-out closes it, the tray counts as bar for the band monitor. |
| Click | Cell shows the pressed state; the section reveals in the bar under a cover; the real item is pressed (AX) so its menu opens from the bar; on menu close the section conceals and its pictures refresh. Trapped-in-notch items go through the « expansion. |
| Drag | Plain drag (no ⌘: it is Pelmet's own surface) reorders cells; the drop runs the Apply pass. Dragging a cell onto the menu bar promotes it to Visible (v2). |
| No Screen Recording | Cells show the owning app's icon (launcher tiles), same layout, same relay. |
| Displays | Opens on the display the trigger happened on; one tray at a time. |
| Empty section | Nothing to float: the toggle is disabled, no tray. |

## Layout (dynamic)

- Cell = the item's picture at bar scale, cell height = that display's bar
  height, width = picture width. Cells sit edge to edge like the bar; a
  separator is a fixed gap.
- Tray width = content + inset. Never a slack strip: the width comes from the
  pictures, not from a measured strip.
- Wrap: when content exceeds the room (display width minus the app-menu
  area, capped), cells wrap into rows, right-aligned like the bar.
- Position (setting): under the section's place in the bar (default, the
  tray hangs from where the icons would have opened), under the pointer,
  trailing edge, centred. Always clamped inside the display.
- Size (setting): match the bar, or larger (1.25×, pictures upscaled from the
  2× capture).
- Material: system glass, no tint, corner radius shared with the covers.
  Achromatic at rest; the pressed cell is the only highlight.

## Motion

- Entrance: hangs down from the bar edge, 8 pt travel, alpha 0→1, 180 ms,
  ease-out `(0.16, 1, 0.3, 1)`. Exit: mirrored, 140 ms, ease-in
  `(0.55, 0, 0.8, 0.4)`. Same family as the covers so the bar and the tray
  read as one motion.
- Content change while open (an item joins or leaves): width animates 200 ms,
  cells slide, nothing fades.
- Reduced motion: pop both ways.

## Settings

Menu Bar tab, per section header: `Floating bar` checkbox (exists). One
`Floating bar` group under the section grid: Position, Size. Nothing else in
v1; every knob is a separate ask.

## Not in v1

Right-click relay, drag to the bar, per-display trays, periodic picture
refresh while open, tint.

## Where it lives (code)

- `Pelmet/Tray/TrayController.swift` — open/close, cells from the editor's
  items in drawn order, the press relay, the picture pass, the drop.
- `Pelmet/Tray/TrayPanel.swift` — the glass panel, cell layout and wrapping,
  position rule, entrance/exit, the reorder drag, Esc.
- `Pelmet/Tray/TrayPictures.swift` — per-item pictures cut from a keyed-out
  strip picture, keyed by the model key.
- `Pelmet/Tray/TrayPress.swift` — AXPress on the real item's extras-bar
  element; the owner's elevated-window count the relay waits on.
- `TransitionCoordinator.harvestTrayPictures` — strip picture beneath the
  relay's cover with Pelmet's windows left out, cut out against the last
  empty-bar picture; `sectionAnchorX` — where the section opens in the bar.
- `AppState.dispatch` — the reveal effect goes to the tray for a person's
  triggers when every section is routed; the conceal effect closes it.
  `onOpened`/`onClosed` feed the rehide machine's settle.
- `MenuBarBandMonitor.pointerMoved` — the tray counts as bar.
- `ConcealGhostOverlay.snapshotSet(of:excludingOwnWindows:)`.
- Settings: `floatingBarSections`, `floatingBarPosition`, `floatingBarSize`;
  the checkbox on the section headers and the Floating bar card in
  `MenuBarTab`.

Log prefix: `tray:`.

## Relay, step by step

1. `beginBarCover(label: "tray")` — a live picture of the bar from its
   leftmost item to the clock, floated before anything moves.
2. `engine.reveal(sections)` beneath it; wait for swap-quiet plus a short
   settle; a fresh walk.
3. Trapped behind the «: `OverflowToggle.expandForPass`, settle, walk again.
4. Pictures: the section's frames unioned, captured with Pelmet's windows
   excluded, keyed out against the empty bar, cut per item. Cells refresh.
5. `TrayPress.press(item)`; the owner's elevated windows are counted before
   and polled after: shown within 0.6 s → wait until gone (60 s cap).
6. « collapsed if expanded, `engine.conceal()`, `endBarCover`.

The picture pass is the same without step 5, run when the tray opens with
cells that have no picture (app icons stand in until it lands).
