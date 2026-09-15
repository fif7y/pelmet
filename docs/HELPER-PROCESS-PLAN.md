# Helper process plan — own items hidden by the assertion

Written 2026-09-14 against `7c62fab`. Status: **planned, not started.**

## The problem

macOS hides menu bar items per **bundle** (the visibility-restriction
assertion takes an allowlist of bundle ids). Pelmet's process must stay on
the allowlist for the chevron, so every item Pelmet hosts itself — launchers,
separators, the media/camera/AirDrop/shortcut extras — can never ride the
assertion. They are hidden by hand: `isVisible` flips, a width collapse, an
alpha fade (`StatusItemFader`), and a pre-attach 50 ms before every reveal
swap (`AppState.preattachOwnItems`) so the swap stays layout-neutral.

Measured cost (2026-09-11, 60 fps bursts, memory `pelmet-uncovered-reveal-
measurements`): the assertion swap alone is a ~130 ms in-place fade of every
third-party icon. Any own item joining the layout in the same agent pass turns
it into an animated pass: everything slides in from the chevron (~200 ms) then
drifts ~300 ms. The pre-attach hides most of it; the launcher still lands a
beat late (`fadeInAfterGlide`), and 1,458 lines of own-item choreography exist
only to approximate what the assertion does natively for everyone else.

## The fix in one line

Host each concealable section's own items in a process whose bundle id the
assertion can exclude. Then they hide and reveal exactly like third-party
icons, and the fader, the pre-attach and the glide timing are deleted.

## Design

### Three hosts, one per section

Hiding is per bundle and `hidden` / `alwaysHidden` reveal independently, so
one helper cannot host both. The mapping is one host per section:

| Section | Host | Bundle id |
|---|---|---|
| visible | main app (as today) | `app.fif7y.Pelmet` |
| hidden | helper A | `app.fif7y.Pelmet.items.hidden` |
| alwaysHidden | helper B | `app.fif7y.Pelmet.items.alwaysHidden` |

The chevron stays in the main app. The helpers are two tiny `LSUIElement`
app bundles built from **one** source target, nested at
`Pelmet.app/Contents/Helpers/PelmetItems-Hidden.app` and
`…/PelmetItems-AlwaysHidden.app` (same executable, two Info.plists).

Why this is the cheap version: `SectionModel.mustShowBundles` already pins a
bundle whenever any of its observed items sits in a visible-or-revealed
section. With every item of a helper in the same section, the existing
per-bundle rule produces exactly the right allowlist with **no new policy**.
The engine's `ConvergePlan` does not change.

### What a helper does

Hosts `NSStatusItem`s and nothing else. No Accessibility, no AX walking, no
settings file. It is told what to host over XPC and reports clicks back.

- **Launchers**: image + `removalAllowed` + click → opens the app itself via
  `NSWorkspace` (no round trip). Right-click → asks main for the menu.
- **Separators**: title/opacity/space width, right-click → asks main for
  the menu, `removalAllowed`.
- **Extras (media, camera/mic, AirDrop, shortcut)**: the button only. The
  *state* that decides whether the media button exists (CoreAudio HAL and
  CMIO listeners, `MediaControls.swift:744–770`) stays in main, which tells
  the helper `host(spec)` / `unhost(id)`. Clicks forward to main, which keeps
  the play/pause, AirDrop and Shortcuts actions it has today.
- **Drag-out** (`removalAllowed` + `isVisible` KVO, shipped for launchers in
  0.2.25 and separators/chevron in `7a579cf`): the observer moves into the
  helper, which reports `draggedOff(id)`; main drops the spec.

### XPC protocol (main ⇄ helper)

Main → helper: `sync([HostedItem])` — the full list for that section, idempotent
(helper diffs against what it hosts, creates/updates/removes). `HostedItem` =
`{ id: UUID, itemTitle: String, kind, image: Data?, symbol: String?, length,
alpha, removable }`. Also `writeOrderHint` no longer applies to helpers'
fresh registrations (see Placement below).

Helper → main: `clicked(id, button: left|right, screenPoint)`,
`draggedOff(id)`, `hosted(id, ready: Bool)`.

Transport: `NSXPCConnection` with a Mach service is overkill for a nested
helper we spawn ourselves; use an anonymous listener endpoint passed at
launch, or a `DistributedNotificationCenter` pair for the four messages if
the endpoint handoff proves fussy. Decide at M1 on the first spike.

### Lifecycle

- Main launches both helpers at boot with
  `NSWorkspace.shared.openApplication(at:configuration:)` — that is what
  registers the nested bundle with LaunchServices, and an unregistered bundle
  is invisible to the allowlist (memory `allowlist-misses-running-app`).
  Never `Process()`/`posix_spawn`.
- Helper watches its parent pid and exits when main is gone (dispatch source
  on `SIGTERM`/parent-exit poll every 2 s). Main relaunches a helper that dies.
- **Single instance per helper bundle.** Memory `pelmet-instance-overlap-and-
  ax-driving`: overlapping instances froze the Mac. Before launching, main
  terminates any running app with that bundle id whose executable is not
  inside our own bundle path.
- Boot order: helpers launch first, main waits for both `hosted` reports (or
  1.5 s) before the first converge, so the first swap already sees them.

### Item identity and settings migration

Today's grammar: `status:app.fif7y.Pelmet::Pelmet.App.<uuid>`,
`…::Pelmet.Separator.<uuid>`, `…::Pelmet.MediaControls`. The enumerator files
an item under its host process's bundle (`describeLeaf` → `hostBundle(ofPID:)`),
so a launcher hosted by helper A becomes
`status:app.fif7y.Pelmet.items.hidden::Pelmet.App.<uuid>`.

Migration in `SettingsStore.init(from:)`, one pass, logged as
`extras: order keys rehomed`: for every own-item key in `sectionModel.order`
and `.assignments`, rewrite the bundle segment to the host of the key's
section. `SectionModel.enroll` mints the right bundle from the section it is
given. Nothing else stores these keys (verified: `settings.v1` only).

**Moving an item between sections is a re-host.** The item is removed from
one process and created in another: a fresh registration the agent parks
where it likes. Same problem as a launcher switched on mid-session today,
same answer: the placement drag under a deliberate reveal
(`PlacementController.physicallyPlace`), with `writeOrderHint` seeding the
slot. Budget one session for this alone.

### Policy sites that assume "own = main bundle"

`PelmetBundle.mainID` is compared at these sites and each becomes
"one of the own bundles" (`PelmetBundle.ownIDs: Set<String>`):

- `MenuBarPolicy.identityExemptBundles`, `isChevronID`, `isZoneAdoptable`,
  `isPelmetExtraID`.
- `SectionModel.swift:48` (registration guard), `OrderDrift.misplaced` /
  `ownItemsOutOfOrder` (`pelmetBundleID:` param → set).
- `BarAdoption` (`pelmetBundleID:` param).
- `PlacementController`: `dragIsPelmetOwned` — **flips meaning**. A helper's
  item is not in the dragging process, so the bar behaves like a third-party
  drag: the gap closes, `PlacementGeometry.lifted` applies, and
  `ItemMover.cmdDrag(ownItem:)` is false. Only main-hosted (visible-section)
  items keep the frozen-bar semantics. Verify live before trusting.
- `AppState.isBundlelessHost` fold-in (`7c62fab`) excludes all own bundles.
- `EditorItemsBuilder`, `ItemImageCache.registerPelmetItem`, `MenuBarTab`
  display names: match on the title grammar (`ItemID.pelmetItem`), which
  already ignores the bundle segment. Check each.

### Deleted when done

`StatusItemFader.swift` (147), `AppState.preattachOwnItems` + the
`TransitionCoordinator` call, `ExtrasManager.preattach/apply/setVisible/
lastVisible/forceShow`, `SeparatorManager` same, `AppTiming.rescueForceShow-
Settle` / `fadeInAfterGlide` timings, the rescue's `forceShowSeparator`
(a concealed helper item has no frame like any concealed icon; the generic
conceal-settle rescue covers it). Roughly 900 of the 1,458 lines.

## Milestones

Each ends with a Developer-ID dev build in `/Applications` (never DerivedData:
memory `pelmet-derived-data-blindspot`) and a `sckburst` 60 fps capture of a
hover reveal, compared against the 2026-09-11 baseline.

1. **Spike (1 session).** Helper target in `project.yml`, nested + signed,
   launched via NSWorkspace, hosting one hard-coded separator. Prove: the
   enumerator files it under the helper bundle; with the helper off the
   allowlist the assertion hides it and the reveal is a clean in-place fade.
   Prove LS registration from `/Applications` and the single-instance kill.
   **Stop here if the assertion does not hide it** — the whole plan rests on
   this.
2. **Transport + separators.** XPC/notification protocol, `sync` diffing,
   right-click menu from a helper item (risk: `NSMenu.popUp` from a
   non-frontmost process; fallback: main activates then pops), drag-out
   report. Separators fully migrated, fader bypassed for them.
3. **Launchers + extras.** Images over the wire (cached per bundle/size, as
   `ItemImageCache` does), HAL/CMIO state stays in main, click forwarding.
4. **Identity + moves.** `PelmetBundle.ownIDs`, the policy sites above, the
   settings migration with a test on a captured blob, the section-move
   re-host through placement. Gab's own blob has ~20 stale
   `Pelmet.App.<uuid>` order keys (2026-09-14 note): the migration prunes
   keys with no spec.
5. **Delete + measure.** Remove the fader/pre-attach code, burst the hover
   reveal in Gab's config (hover on, 0.1 s), confirm no animated pass and no
   late launcher. Update the FAQ's "how do launchers hide" answer.
6. **Release.** Two dev-build days of Gab's normal use first (adoption,
   editor drops, display switches, Sconce). Cut on his word.

## Risks, in order

1. **The assertion may treat a nested helper differently** (child of an
   allowed process, or an LS record that resolves to the outer bundle). M1
   exists to find out in an afternoon.
2. **System Settings › Menu Bar lists apps by bundle.** Two extra rows would
   appear, and a user ⌘-dragging a non-removable item off a helper disallows
   *that helper* (memory `pelmet-drag-out-disallows-app`). Name them so the
   rows read as Pelmet's ("Pelmet Items"); every helper item is
   `removalAllowed`; main detects a helper whose items never adopt and points
   at the pane.
3. **Notarization / Sparkle** with nested apps: inner bundles signed first
   with hardened runtime; `release.sh` `codesign --deep` already walks
   nested code, verify with `spctl` and a delta update from the previous
   build (memory `nook-release-state`: update-UI test recipe).
4. **Section moves** cost a placement drag each. Acceptable, it is what a
   fresh launcher costs today; the editor should not make it feel slower.
5. **Media controls state → button race**: main decides "hosted" from HAL
   callbacks while the helper creates the item asynchronously. `hosted(id,
   ready:)` gates the placement queue, same as today's frameless clock.
6. **Two more processes** (~8 MB each). Fine. Users who never add a
   hidden-section own item never launch helper A, same for B: launch lazily
   on first `sync` with a non-empty list.
