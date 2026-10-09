# Panel plan: hidden icons in a panel, plus Search in Settings

Status: 2026-10-09. Decisions D1–D5 (section 9). Phases 0–2 done, Phase 3 v1 live on `panel` (results under Phase 3).
Issue #26. The design is the mock in
`~/Projects/pelmet-site/marketing/panel-mock/` (`index.html` = the panel,
`settings.html` = the Settings Panel and Search tabs, private) and decisions
1–13 in the vault note `Ideas/2026-09-17 - Brainstorm - Pelmet floating bar.md`.
This plan turns that into Swift without a second mechanism.

Naming rule from CORE-SETS applies: every type, file, log prefix and string is
Pelmet's own. Log prefix for this work: `panel:`.

## 1. Audit (2026-10-09, read-only)

Three parallel code reads of `roster` and `floating-bar`, then a second pass
re-checked nine key claims against the source (four held, five corrected below).
Nothing was built, run or tested live, so section 8 lists the spikes that settle
what reading can't.

**Fits as is**

- One reveal entry: the `.reveal` effect in `AppState.dispatch`
  (`AppState.swift:2334`) calls `TransitionCoordinator.performReveal`
  (`TransitionCoordinator.swift:306`). Every trigger (chevron, ⌥/double-click,
  hover, ⌥⌘, empty-bar click) lands there. The panel branches at this one spot,
  as the tray did (`floating-bar` `AppState.swift:~1713`). Not every reveal may
  go to the panel: Apply (`.settingsPreview`, `ApplyPass.swift:370`), ⌘-drag
  (`.barDrag`, `MenuBarBandMonitor.swift:168`), the always-show policy
  (`.displayPolicy`, `:240`) and Pelmet's own extras shown in the bar
  (`pressOwn` → `showItemInBar`, `ItemPress.swift:285`, `AppState.swift:712`)
  need the real bar. Routing is by reason, as the tray's `tray.takes(sections,
  reason:)` did.
- The click relay exists and is already covered: `AppState.openItemMenu`
  (`:688`) → `ItemPress.open` (`ItemPress.swift:93`) reveals the item alone
  under a bar cover, « expands if needed, shielded click, conceals under a second
  cover. ⌥⌘K uses it today. A tile click is the same call.
- Overflow is already detected: `ApplyPass.trapped` (`ApplyPass.swift:61`),
  `overflowNoticeCount` (`AppState.swift:2587`). "Didn't fit" reads it.
- Launchers exist: `ExtraKind.appLauncher` (`SettingsStore.swift:161,241`),
  click at `MediaControls.swift:~1136`. Not-running icons come from
  `NSWorkspace.icon(forFile:)` (`CommandBarCorpus.swift:181`).
- Picture capture and per-item cut-outs exist on roster:
  one-frame SCStream per display (`ConcealGhostOverlay.swift:389`), strip →
  item crops (`cropColumns` `:576`, `cutOut` `:617`). Only the per-item store
  is missing, and the tray has one (`TrayPictures.swift`).
- Alias and shortcut rules already live on AppState: `setItemAlias` (`:815`,
  40-char cap) and `setItemHotkey` (`:778`, returns the refusal). The check
  itself, `itemHotkeyRefusal` (`:799`, Pelmet / other item / macOS / other
  app), is `private`; Settings needs it to warn while recording, so it opens up
  in Phase 1.
- Adding a Settings tab is mechanical: `SettingsTab` (`SettingsView.swift:28`,
  `title` `:36`, `symbol` `:51`, pane switch `:128`) and
  `SettingsIndex.tabName` (`SettingsIndex.swift:70`, falls back to raw English).

**Changes the mock implies (decide before Phase 3, see section 9)**

- **Pictures in Panel mode.** In Panel mode hidden icons are never drawn on the
  bar, so the reveal and conceal pictures that feed tiles today stop coming.
  The tray solved it with a picture pass: a covered reveal + capture when the
  panel opens with tiles missing pictures, and a refresh after every relay.
  App icons stand in meanwhile. Without Screen Recording there is no pass:
  tiles are app icons (color, not menu bar glyphs) plus names.
- **Reorder inside the panel.** The bar's order is read, never stored
  (CORE-SETS principle 2), and moving an icon is a real ⌘-drag that only Apply
  does (principle 3). Moving between sections is membership and costs nothing.
  Reordering inside a section is an Apply pass.
- **Bar order for hidden icons.** Concealed items have IDs, no frames
  (`MenuBarEngine.swift:32`). The panel uses the order read on the last walk
  that saw them (kept in memory, never stored), falling back to Roster order.
- **"Didn't fit" tiles** have identity and an overlapping frame, no picture
  (open Q9: items past the notch can't be pictured). They show as icon + name.
- **The Search tab's demo.** The mock embeds a working command bar. In Swift,
  a second CommandBarController in Settings would be a second mechanism. Plan:
  "Try" buttons open the real ⌥⌘K bar with the query typed.

**Gaps found in today's code**

- `ItemPress` drives the engine directly (`ItemPress.swift:187,241`), outside
  `RehideStateMachine`. Fine for ⌥⌘K; with a panel, panel state and the rehide
  timer can drift. Phase 3 routes it through one gate.
- A lone trapped icon may go undetected: `PlacementGeometry` needs two
  overlapping frames (`PlacementGeometry.swift:40`). Code reading only.
- Settings `ShortcutRecorder` writes straight to a binding with no refusal
  hook (`ShortcutRecorder.swift:154`). The bare-key guard is duplicated
  (`CommandBarController.swift:812`, `ShortcutRecorder.swift:141`) and the
  refusal copy is private to the controller (`:835`).
- Nothing prunes `itemAliases` / `itemHotkeys` for items that are gone. The
  Search list will show them; it needs a "not on the bar" state.
- Pictures of hidden icons come from reveal settle (TC `:431` → `:1014`),
  conceal start when that picture is missing (`:454`, `:468`) and boot
  (`takeBootPicture` `:1113`). All need the icons drawn on the bar.
- The Panel tab preview renders from stored data and never holds the bar
  (`editorHoldsBar`, `AppState.swift:42`, holds it only during an Apply pass).
- Strings: `gen-xcstrings.py` asserts all 9 translations per key (351 keys
  today). Panel + Search add roughly 70–90.

**Don't port, don't duplicate**

- `floating-bar` is 34 ahead, 116 behind `roster`, with 14 files changed on
  both sides (AppState, TransitionCoordinator, ConcealGhostOverlay, engine,
  xcstrings). Never merge it. Port by hand: `TrayPanel.swift` (glass NSPanel),
  `TrayPictures.swift` (per-item store, `harvest`), `harvestTrayPictures`
  (TC `:192`), the cell fallback chain (`TrayController.swift:166`).
  `TrayPress.swift` is superseded by `ItemPress`.
- Single sources to reuse: band geometry cache (`MenuBarBandMonitor.swift:51`),
  overflow detection, `ItemPress`, `ItemNaming`, `ItemImageCache.icon(for:)`
  (`ItemImageCache.swift:36`), Roster membership, `SearchRanker`.

## 2. Architecture

One mechanism, three ways to show it.

```
triggers ─▶ AppState.dispatch(.reveal) ─▶ RevealRouting(reason, hiddenIconsIn)
                                            ├─ BarPresenter    (today: performReveal)
                                            └─ PanelPresenter  (layout .panel | .row)
tile click ─▶ AppState.openItemMenu ─▶ ItemPress (covered relay) ─▶ picture refresh
```

**PelmetCore (pure, `swift test`)**

- `RevealTarget` — `.menuBar` (default), `.panel`, `.row`. An unknown raw value
  decodes to `.menuBar`, so a downgrade is safe.
- `RevealRouting` — reason + setting → bar or panel. Apply, ⌘-drag, the
  always-show policy and own extras always get the bar. Tested case by case, so
  a new reason has to pick a side.
- `PanelOptions` — names, columns per names mode, separators break rows,
  Always Hidden fold, fold remembered state. Own `init(from:)` with per-field
  fallback.
- `PanelModel.build(...)` — input: Roster membership, last drawn order,
  separators, the « notice's list (S4), launchers, filter query. Output: sections
  (Hidden, Always Hidden, Didn't fit) of `PanelTile`s.
  `PanelTile` = `.item(key)`, `.launcher(id)`, `.rowBreak`. New tile kinds are
  new cases, nothing else moves.
- `PanelGrid` — tiles + columns (Auto = 5) + layout → rows, frames, panel size,
  arrow-key neighbours. Row is the same grid with one row, no names.

**App target, new `Pelmet/Panel/`**

- `RevealPresenter` protocol (`reveal(sections)`, `conceal()`, `isShowing`,
  `frame` for hover/gates). `BarPresenter` wraps today's path unchanged.
- `PanelPresenter` + `PanelWindow` (ported `TrayPanel`): key-able,
  non-activating NSPanel like the command bar's, hung from the chevron
  (`PelmetStatusItem.windowFrame` `:72`) on the chevron's display.
- `PanelView` (SwiftUI) draws a `PanelModel` through `PanelGrid`. The same
  view is the Settings preview.
- `ItemPictures` (ported `TrayPictures`): per-item, memory only, keyed by item
  key + appearance + scale, filled at reveal/conceal settle, the picture pass
  and after each relay. Dropped on the same signals as today
  (`surfaceSignature`, 900 s cap).
- `TileImage` — picture → `ItemImageCache.icon(for:)` → launcher app icon →
  placeholder. Later the editor and the command bar rows can read it too.
- `ItemShortcutRules` — the bare-key guard and refusal copy, hoisted from the
  controller. Used by the command bar, the Settings list and `ShortcutRecorder`
  (new `validate:` hook).

**Rules**

- `RehideStateMachine` stays the only truth for revealed / concealed. Panel
  open = revealed, panel closed = concealed. No second timer.
- The panel never captures while open (no purple dot at rest).
- The panel filter ranks with `SearchRanker` and aliases, so "pw" finds
  1Password in the panel and in ⌥⌘K alike. ⌥⌘K always opens Search.
- No stored order. Section moves are membership edits through the editor's API.

## 3. Settings schema

Added to the `settings.v1` blob via `CodingKeys` (`SettingsStore.swift:463`)
and the per-field `field()` fallback (`:482`). Tests extend
`SettingsStoreTests` (`:88` pattern): old blob → defaults, unknown enum →
default, round trip.

| Field | Type | Default |
|---|---|---|
| `hiddenIconsIn` | `RevealTarget` | `.menuBar` |
| `panel.showsNames` | Bool | false |
| `panel.columnsWithNames` / `panel.columnsCompact` | Int? (nil = Auto, 5) | nil |
| `panel.separatorsBreakRows` | Bool | false |
| `panel.alwaysHidden` | `.folded` / `.asLeft` / `.hidden` | `.folded` |
| `panel.alwaysHiddenOpen` | Bool (for `.asLeft`) | false |

Dev flag while building: `pelmet.debug.panel` (defaults Bool) shows the Panel
tab and the target picker. Removed when the beta ships.

## 4. Where the work happens

- The Search tab (Phase 2) goes straight on `roster`: it ships in 0.3.2,
  before Product Hunt (D3).
- Everything panel goes on branch `panel` off `roster`, in its own worktree
  (`~/Projects/Pelmet-panel`), so launch work keeps going on `roster`. It
  merges into `roster` for the next beta (D5), once Phases 3–6 are green.
- One Pelmet instance at a time: quit inside the run command, dev builds from
  `/Applications` (DerivedData builds hide regardless).
- Before each install, compare the binary's mtime against `git status` in
  every checkout (another session's work rides along otherwise).

## 5. Phases

Each phase ends green: `swift test` in `Packages/PelmetCore` and
`Packages/PelmetEngine`, an `/Applications` dev build, and the boot log read
(`own items adopted`, `helpers:`, `place:`).

**Phase 0 — Spikes (1–2 sessions).** Live answers before code that depends
on them. See section 8.

**Phase 1 — Foundations, no visible change (1–2 sessions)**

- PelmetCore: `RevealTarget`, `PanelOptions`, `PanelModel`, `PanelGrid` + tests
  (order, row breaks, fold modes, filter, Didn't fit, keyboard neighbours,
  Auto = 5).
- SettingsStore fields + tests.
- `RevealPresenter` seam at `AppState.swift:2334` with `BarPresenter` only, and
  `RevealRouting` + tests. Done when `perf` reveal lines match before and after.
- Last drawn order cache from the reveal walk (memory).

**Phase 2 — Settings › Search tab (2 sessions, on `roster`, ships in 0.3.2)**

- First: `ItemShortcutRules` hoisted (command bar behaviour unchanged) and
  `itemHotkeyRefusal` opened up (`private` today).

- `.search` after `.behavior`; `SettingsIndex` tab name and the moved rows.
  `jump(to:)` only scrolls inside the current pane (`SettingsView.swift:186`),
  so the index must point the search rows at `.search`.
- Rows move from General (`:756` shortcut, `:766` reset). General keeps one
  line: "Search the menu bar moved to Search."
- Cards: shortcut, What it finds (Try buttons → `CommandBarController` opens
  with a query), Keys, Aliases and shortcuts (editable list over AppState,
  Add an icon…, × removes, stale entries marked), History + Reset
  (`resetHistory` `:867`).
- Copy is written from section 1's facts (what search covers: items,
  launchers, commands, Settings rows; not menu contents).
- Strings in `gen-xcstrings.py`, all 9 languages.

**Phase 3 — Panel window v1, behind the flag (2–3 sessions)**

- `PanelPresenter`, `PanelWindow`, `PanelView` with tiles from `TileImage`.
- Open / close: chevron, hover, ⌥⌘, follow the target. Hover-opened closes on
  the rehide delay after the pointer leaves bar + panel; click- or
  shortcut-opened stays until Esc, an outside click or a tile click (like a
  menu).
- Hover band includes the panel frame (`MenuBarBandMonitor.swift:366`). The
  rehide elevated-window gate ignores the panel window (known trap).
- Tile click: panel exits, `openItemMenu`, picture refresh when the menu closes.
- `ItemPress` routed through the presenter so the rehide machine sees it.
- Picture pass (per decision D2).
- Row = same window, `PanelGrid` layout `.row`.

*Phase 3 v1 results (2026-10-09, dev build of `panel`, live on Gab's Mac).*
Files: `Pelmet/Panel/PanelPresenter.swift` (window, anchoring, content,
pass trigger), `PanelView.swift`, `ItemPictures.swift`; `GlassPanel` takes a
corner radius (the panel's is 20). Dev switch: `defaults write
app.fif7y.Pelmet pelmet.debug.panel -string panel` (or `row`) overrides
`hiddenIconsIn` live (`AppState.revealTarget`); set at launch it also arms
two notifications, `app.fif7y.Pelmet.debug.toggle` (object `hover`,
`hotkey`, else a click) and `app.fif7y.Pelmet.debug.panelShot` (writes the
open panel to `~/Library/Logs/Pelmet/pass/panel.png`).

- Wiring: `presenter(for:)` returns `PanelPresenter`; a reveal while the bar
  is out stays on the bar, a bar-only reason while the panel is up dismisses
  it. `currentRevealedSections` is what is out *on the bar*: [] while the
  panel draws the reveal, the pass's sections during a pass
  (`picturePassSections`). `panelDidSettle()` posts `transitionSettled`.
- Holding: click/hotkey opens make the panel key and hold like a menu (rehide
  defer `panel=true`); hover opens never take keys and hold only while the
  pointer is on the panel. Esc (local monitor), the chevron, an empty-bar
  click and a click elsewhere (the band monitor's existing path) close it.
- Measured live: hover open 130ms after the zone entry, close 0.7s after the
  pointer leaves; tile click → Sound's menu shown 268ms (cover from the idle
  picture); pass ~1.0s for Hidden + Always Hidden (11 icons).
- Item list = `editorItems(in:)` (the walk's `concealed` misses system items
  such as Sound). Didn't fit = `overflowTrappedItems` (the notice's list).
- Picture pass: real now (`TransitionCoordinator.picturePass`). Fixes found
  live: wait until the hidden icons have frames (two walks from before they
  arrive agree too); film the strip until two frames agree (AX reports where
  icons land before they are drawn there); Pelmet's own extras follow the
  pass's sections (told "concealed" mid-pass they hid again and the bar
  bounced); crop exactly to each AX frame (`cropped(toPrimaryX:)` pads, so
  neighbours' capsules rode along); trim to ink, drop see-through or narrow
  edge runs; tint only flat one-colour glyphs (a glyph on a capsule is two
  brightnesses and filled in).
- Review fixes (live-checked): a bar-only reveal (`.itemInBar`, Apply)
  while the panel is up closes the panel first and queues behind it, so a
  request for the panel's own sections still reaches the bar (bar out in
  107ms); a click in the hover grace makes the panel deliberate
  (`makeDeliberate`, key=true); a reveal or a press during a pass waits for
  it until its cover lifts (`awaitPicturePass`, bounded 2.5s); the pass
  picks icons by section, not the walk's `concealed`; a pass that saw no
  icons marks nothing unpicturable, and one that did re-runs for anything a
  widen or unfold asked for meanwhile; own extras the bar would not draw
  (media controls with nothing playing) get no tile
  (`ExtrasManager.wouldShow`). Own extras in a hidden section still wait for
  a bar reveal to be placed. Dev toggle object `bar` fires an `.itemInBar`
  reveal.
- Pictures are un-blended, not keyed: the cut-out's soft key keeps each
  antialiased edge whole in the bar's colour (a dark fringe on light glass,
  70–83% of a glyph's solid pixels light, measured). For a glyph whose
  changed pixels are all lighter than the bar (or all darker) with barely
  any colour, alpha = its luma distance from the empty bar over the core's
  (90th percentile), white, tinted by the tile. Edges come out partial, a
  grey capsule (Velja, Herd, OpenClip) a faint fill. Light mode checked
  with `pelmet.debug.panelAppearance` (`light`/`dark`, read at each open).
- Not done yet: picture refresh after a relay, pictures for icons that don't
  fit beside the notch in one go (batches), keyboard (Phase 4), Settings UI. Capsule apps (Velja, Herd, OpenClip) keep the bar's
  capsule, clipped to the frame.
- Testing note: keys for a non-activating panel must be posted to Pelmet's
  pid (`CGEvent.postToPid`); HID-posted keys never reach it. An idle Mac's
  bar reads empty (`agent tree has 2 window(s), no items`) even with
  `caffeinate -d`; `caffeinate -u` brings it back.

**Phase 4 — Interactions (3 sessions)**

- Type to filter, arrows + ↩, Esc.
- Right-click menu built from `contextMenu` (`PelmetStatusItem.swift:196`)
  plus Layout / Names / Columns.
- Edge-drag columns → `panel.columns*` for the current names mode.
- Always Hidden fold (three modes).
- Drag between sections and up onto the bar = membership edits (decision D1).
- Didn't fit section, launcher tiles (dim when not running), separators as row
  breaks.

**Phase 5 — Settings › Panel tab (2 sessions)**

- `.panel` after `.menuBar` with a "New" chip. "Show hidden icons in: Menu bar ·
  Panel · Row" over a live 1:1 `PanelView` preview (same view, same settings,
  so both sides stay in sync for free).
- Menu bar option: the `MockBar` from `AnimationShowcase` (`:1658`) plus
  "Right now N of M fit beside the notch" from the band cache.
- Icons card (Show names, Columns, Separators start a new row, Always Hidden)
  only for Panel or Row. Captions say what each option does.
- Status menu: a "Show hidden icons in" submenu from the Animation submenu
  template (`PelmetStatusItem.swift:225`).
- SettingsIndex entries for every new row.

**Phase 6 — Polish and beta (2 sessions)**

- Motion from the mock: enter 180 ms `(.16, 1, .3, 1)`, exit 140 ms
  `(.55, 0, .8, .4)`, constants in `AppTiming`. Reduce Motion = fade.
- Light / dark, multi-display, Macs without a notch, VoiceOver labels (names
  even when names are off), long German / Russian strings.
- Perf: no capture while open, `perf` lines for open → first frame and click →
  menu.
- Release notes credit #26's reporter (`gh issue view 26 --json author`).
- Beta build only on Gab's "cut".

Rough total: 13–16 sessions.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Tiles without pictures in Panel mode | Picture pass + refresh after relay; app icons + names stand in; Settings suggests names when Screen Recording is off |
| Panel and rehide timer drift (ItemPress outside the machine) | One presenter gate; test: tile click during a hover reveal |
| Apply, ⌘-drag or own extras open the panel instead of the bar | `RevealRouting` by reason, one test per reason |
| Hover or elevated-window gates misread the panel | Panel frame in the band; panel excluded from the gate; day-one tests |
| Lone overflowed icon missed | Spike S4; fix in PelmetCore with a test |
| Typing steals focus from the frontmost app | Non-activating key panel, same as the command bar |
| Orphaned popover after a relay | `ItemPress` already waits for the owner's windows |
| Purple dot from the picture pass | Only when tiles lack pictures, never while open, never periodic |
| Merge conflicts | Port tray files by hand; branch rebased on `roster` weekly |
| Launch risk | Nothing merges into `roster` before 0.3.2 stable ships |

## 7. Built to grow

- A new layout (pages, vertical list) is a `PanelGrid` configuration.
- A new place to show icons (a panel per display, a detached panel) is a
  `RevealPresenter`.
- A new tile kind (Now Playing, a clipboard shelf) is a `PanelTile` case.
- `ItemPictures` and `TileImage` can give the Menu Bar editor and command bar
  rows real pictures later.
- `PanelOptions` grows field by field with per-field fallback; an older build
  reading a newer blob keeps every other setting. One known loss: an older
  build re-saves the blob without the new keys, so downgrade then upgrade
  resets the Panel settings to defaults. Accepted (betas only, defaults are
  sane) to keep one blob and one backup key.
- One set of shortcut rules and one ranker across ⌥⌘K, Settings and the panel.

## 8. Phase 0 spikes

- **S1 Picture pass.** On roster, script a covered reveal + capture of Hidden
  with the bar shown. Measure time, dot duration, any visible shift. Settles D2.
- **S2 Panel over the bar.** The ⌥⌘K bar is already a key-able panel that
  takes typing: read how it does it, how the rehide gates treat Pelmet's own
  windows, and what the hover band does when the pointer leaves the bar.
- **S3 Relay from a panel.** The ⌥⌘K bar already closes then relays. Measure
  click → menu from its `press:` lines across apps (one popover app); check for
  orphaned popovers.
- **S4 Lone overflow.** One icon trapped behind «: does `trapped` see it?

### Results (2026-10-09, dev build of `panel` with the S1 spike, 3 displays)

- **S1 ✅ invisible, ~1.3 s.** Debug trigger `app.fif7y.Pelmet.debug.picturePass`
  (`TransitionCoordinator.debugPicturePass`, `snapshotSet(…excludingOwnWindows:)`).
  Times from trigger: empty bar 190 ms, cover up 310, revealed 550, strip 750,
  pictures 760, concealed 790–830, cover lifted 1270–1370. A 60 fps film
  of the bar shows no motion at all; the reveal and conceal stay under the
  cover. Cut-outs are clean glyphs on transparency. To fix in Phase 3:
  - Crops were offset by up to an icon: the frames were read while the
    icons still slid in. Read frames from a settled walk (as
    `ItemPress.settledItem` does) right before the strip capture.
  - With 3 displays the idle empty-bar picture was refused ("another active
    display"), so the pass took its own (+190 ms).
  - Here every drawable Hidden icon fitted (3 of 3; Passwords draws nothing
    under any assertion). A bigger Hidden section won't fit beside the notch
    in one go: the pass reveals in batches that fit, under one cover.
    Untested.
- **S2 ✅ from code.** `GlassPanel` / `KeyableGlassPanel`
  (`Pelmet/Panels/GlassPanel.swift:61,121`) is the panel's base: non-activating
  key panel, closes on outside click, resign and Esc, then relays
  (`CommandBarController.swift:212,420,466,569`). Must change:
  - Add `panel.isOpen` to the rehide defer list (`AppState.swift:2363`);
    today an open ⌥⌘K bar doesn't hold the bar.
  - Never `NSApp.activate` (it breaks the click-elsewhere guard,
    `MenuBarBandMonitor.swift:525`).
  - Hover: leaving the band arms a ≤1 s rehide
    (`RehideStateMachine.swift:217`) and the elevated-window check only runs
    when it fires, so the panel frame joins the band test (`isBarHover` /
    `isInMenuBarBand`, `MenuBarBandMonitor.swift:544,604`).
- **S3 ✅ ⌥⌘K's relay, measured** (debug `openMenu`, 3 Always Hidden apps):
  revealed alone 470–530 ms, click 620–675 ms, window shown 650–740 ms after
  the trigger; the cover lifts at the click. A popover that ignores Esc
  (OpenClip) stays until the next relay supersedes it (60 s cap), as with
  ⌥⌘K today. The pressed tile shows at once and the panel's 140 ms exit
  overlaps the relay.
- **S4 ⚠️ from 4 days of logs.** 32 « events (mostly 2 icons). Once the notice
  listed 2 icons while `ApplyPass.trapped` flagged 1. "Didn't fit" reads the
  notice's list (`AppState.swift:2612`), not `trapped`.

## 9. Decisions (Gab, 2026-10-09)

- **D1 Reorder in the panel.** v1 moves between sections only (instant).
  Reorder stays in Settings › Menu Bar with Apply.
- **D2 Pictures.** Picture pass when the panel opens with tiles missing
  pictures (needs Screen Recording; the dot shows briefly), app icons until it
  lands.
- **D3 Search tab timing.** Into 0.3.2, before Product Hunt (Gab overrode the
  post-launch recommendation). About 40 strings and a Settings change, so it
  needs a beta before the stable.
- **D4 Search demo.** Gab overrode the Try-links-only call: the tab embeds a
  working command bar, as in the mock. It is a second `CommandBarController`
  (`embedded: true`, `AppState.searchDemo`) on the same view and keys, so there
  is one mechanism with two hosts. Picks are real, Try links type into it, and
  ⌥⌘K focuses it while the tab is in front. Both instances re-read the saved
  history before they rank. The stage is drawn, not the person's wallpaper:
  reading that file raised an iCloud Drive access prompt.
- **D5 Panel timing (2026-10-09 late).** Gab moved the panel into the next
  beta: Phases 3–6 now, not after Product Hunt. Build 65 waits for the panel
  (one beta with the Search tab and the panel), and the panel ships in 0.3.2
  stable for the Oct 21 launch, no beta-only switch.

## Timeline

- Oct 9–13: Phase 0 spikes. Phase 2 (Search tab) on `roster`.
- ~Oct 14: 0.3.2 beta with the Search tab, on Gab's "cut". If build 65 is cut
  before the tab lands, the tab rides the next beta (tight for Oct 19).
- Oct 19: 0.3.2 stable. Oct 21: Product Hunt.
- Superseded by D5 (2026-10-09 late): the panel goes into the next beta, so
  Phases 3–6 run now on `panel`, not after launch. Phase 1 done (`5a3d835`).
  Build 65 = Search tab + panel, cut when Phases 3–6 are green and `panel`
  is merged into `roster`; 0.3.2 stable with the panel by Mon Oct 19.
- (Was) Phase 1 on `panel` whenever launch work leaves room; from Oct 22, merge
  `panel`, Phases 3–6, first Panel beta on "cut".
