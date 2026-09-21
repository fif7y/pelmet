# Architecture review + optimization plan (2026-09-21, branch `roster`)

Scope: reverse-engineered from source on `roster` head `bdc9444` (416 commits since 2026-08-20). No code changed. Companion to `docs/CORE-SETS.md`. Nothing here alters user-visible behaviour; every item is a quality, latency or maintainability move.

## 1. Architecture as it stands

Three layers, dependency direction Core ← Engine ← App, plus two helper processes.

| Layer | Home | Responsibility | Purity |
|---|---|---|---|
| **PelmetCore** (SwiftPM) | `Packages/PelmetCore` | Models and pure rules: `SectionModel` (membership + drawn order), `Roster`/`RosterRule` (sets view of the same data), `OrderEdits`, `MovePlan` (weighted LIS), `RehideStateMachine` (reveal/conceal FSM, timing as data), `MenuBarPolicy` (bundle classification tables), `ItemID` grammar + `ItemIdentityResolver`, `BarAdoption.reconcile`, `SettingsStore` (one JSON blob in `UserDefaults`), `PlacementGeometry`, `HelperProtocol` | Pure, 125 tests |
| **PelmetEngine** (SwiftPM) | `Packages/PelmetEngine` | The macOS 27 seam. `AgentBarEngine` actor = the only writer of hide state (assessment assertion swap, epoch-guarded converge). `ItemEnumerator` actor = the AX walk of MenuBarAgent's tree (the bar's physical truth). `ConvergePlan` (pure allowlist decision). `AssessmentMode` + ObjC shim (dlopen of MenuBarClientCore, `@try`-guarded `objc_msgSend`). `ItemMover` (shielded synthetic ⌘-drag, used only by Apply). `AgentPositionStore` (order hint plist for fresh registrations). | IO, 17 tests on the pure parts |
| **App** | `Pelmet/` | `AppState` (@Observable root, 2,120 lines, 87/416 commits touch it), `TransitionCoordinator` + `ConcealGhostOverlay` (picture covers that mask the agent's own animation), `MenuBarBandMonitor` (global mouse monitors → hover/click intents), `ClockClickRelay` (CGEventTap: clock click relay + active-display observer), `ApplyPass`/`OverflowToggle` (the one mover), `ExtrasManager`/`SeparatorManager`/`HelperHosts` (own items; two helpers hosted over CFMessagePort), Settings UI (SwiftUI, `MenuBarTab` editor), Onboarding, Sparkle. | Mixed |
| **PelmetItems** ×2 | `Contents/Helpers` | Section helper apps hosting hidden / always-hidden separators so each section hides as its own bundle. | — |

### Sources of truth (four, deliberately separate)

1. **Membership + drawn edits**: `SettingsStore` blob (`app.fif7y.Pelmet.settings.v1`).
2. **Physical order**: MenuBarAgent's AX tree, read by `ItemEnumerator`, never stored (CORE-SETS principle 2).
3. **Hide state**: the live `MBAssessmentModeAssertion` allowlist, mirrored as `activeAllowlist`/`activeConcealable` in the engine. Concealed items vanish from AX, so the engine *carries* the concealed set across walks.
4. **Pictures**: `revealCoverSnapshot` (empty bar, taken at conceal settle) and `revealedStripSnapshot` (finished bar, taken at reveal settle / boot), each stamped with active display, backdrop signature, hidden-section signature and chevron x.

### The reveal data flow (hover)

```
mouseMoved (global+local NSEvent monitor, main thread, every event)
 └ MenuBarBandMonitor.pointerMoved
    ├ isBarHover → isInMenuBarBand + foreignOverlay (2 window-server IPCs)
    ├ isHoverZone → revealTriggerMaxX (scans snapshot) 
    └ scheduleHoverReveal → Timer(max(hoverDelay, 0.1s))
       └ fire → Task{@MainActor} → re-verify (2 more IPCs) → AppState.reveal
          └ RehideStateMachine.handle → [.reveal] → dispatch
             └ TransitionCoordinator.performReveal → Task
                ├ freshEmptyBarSnapshots (TTL 900s, active-display match)
                ├ clearing() pixel pass → cover NSWindow(s)              [main]
                ├ iconsOnly() pixel diff (boot/cut-out cases) → finished NSWindow(s)   [main]
                ├ (no cover) preattachOwnItems → 50ms sleep
                └ await engine.reveal                                     [actor hop]
                   └ converge
                      ├ refreshSnapshot  ← AX WALK #1 (~100ms, cross-process)
                      ├ MainActor.run { runningApplications }            [hop]
                      ├ ConvergePlan.compute (pure)
                      ├ AssessmentMode.activate (XPC) + reflowCompanion  [hop to main: extras/separators resize]
                      ├ poll activation every 50ms (≤3s)
                      ├ previous.invalidate()
                      └ refreshSnapshot  ← AX WALK #2 (~100ms) — on the settle path
                └ updateSnapshot → onRevealSettled → rehide arm, settleCatchUp, precapture(finished)
```

Conceal mirrors it with the pictures taken *before* the swap (`concealStripFrames` = a walk, plus live SCStream captures for Fade/Smooth).

## 2. Cold hover/click: where the time goes

"Cold" has three distinct causes in this codebase. They stack.

| # | Phase | Cost | Path | Evidence |
|---|---|---|---|---|
| A | Hover dwell floor | 100ms | always | `AppTiming.hoverDelayFloor`; by design |
| B | Pre-swap AX walk (`converge` → `refreshSnapshot`) | ~100ms (N third-party apps × 4+ AX IPCs each, 250ms timeout per stuck app) | always, before the assertion swap | `AgentBarEngine.converge:231`, `ItemEnumerator.statusItemTitle` |
| C | Activation completion poll | 0–50ms (avg 25) | always, before settle | `performSwap:391` polls `activationPoll` |
| D | Post-swap AX walk | ~100ms | always, before `onRevealSettled` (gates the rehide arm, extras catch-up, own-item placement, finished-picture precapture) | `performSwap:419` |
| E | Live SCStream capture on the hover path | ~90ms/display | when no fresh cover: pictures older than 900s, backdrop changed, active display mismatch, Screen Recording off | `performReveal:181` `begin(over:)` |
| F | Per-reveal pixel passes on main | 1–5ms each | every reveal with a cover: `clearing()` always, `iconsOnly()` for boot/cut-out pictures | `ConcealGhostOverlay.clearing`, `.cutOut` |
| G | NSWindow creation per cover per display | ~1–3ms each | every reveal | `ConcealGhostOverlay.init` |
| H | Pre-first-click display stamp mismatch | whole cover lost → falls to E | every reveal before the session's first click (hover-only users) | `freshEmptyBarSnapshots:431` compares stamp to `lastMouseDownDisplay`, nil until `ClockClickRelay` sees a mouseDown; precapture stamps `lastMouseDownDisplay ?? displayUnderPointer`. Verify in log: `cover: picture from another active display (N → 0)` |
| I | Click hit-test with no AX timeout | up to 6s if the app under the pointer is hung | click path | `isEmptyMenuBarArea` uses `AXUIElementCreateSystemWide()` with no `AXUIElementSetMessagingTimeout`; `axAppTimeout` is defined and never used |
| J | Band-monitor work per mouse move | 2 IPCs + snapshot scan per event at 60–120Hz while in the band | before the hover | `isBarHover`, `revealTriggerMaxX` |
| K | Reflow companion image churn on main | N own items × ~5ms (`button.image` assigned unconditionally in `updateCameraSymbol`, `updateFocusGlyph`, `updateMediaSymbol`, `updateAirDropGlyph`, `updateTimerGlyph`; only `updateTimeMachineGlyph` dedupes) | every swap, concurrently with the cover's first frames | `MediaControls.swift:821,842,890,898,937` vs `:909` |

### Measured 2026-09-21 10:34 (PerfTrace, dev build 47, Gab's bar, warm, Instant)

Reveal (hover, 8 samples): trigger→dispatch 0–6ms · cover up **18–48ms** · engine 219–298ms = walk 14–47 + plan 1–5 + activate **50–55 (the poll floor)** + walk2 **53–161** + ~20–50 unattributed (`invalidate` mark added, not yet in a build) · settled = engine + 5 · lift = settled + ~450 (hold).
Conceal (7 samples): strip walk 5–121ms (cache hit or a full walk) · cover 9–191ms (191/142 = live finished-picture capture after a short reveal) · engine 224–342ms, same shape.
One hover reveal converged `noop` right after a quick in/out conceal (10:34:55) — open.

**After 4.3 (10:50, build with the continuation):** activate 50–55 → **1ms**, invalidate 0ms. Engine total unchanged (232–264ms) because walk2 rose to 166–193ms: started 50ms earlier, it blocks on the agent's reflow. The saving only shows once 4.2 takes walk2 off the settle path (expected settle ≈ 30–40ms after dispatch). ~25ms still unattributed inside `engine` = the actor→main hop landing on a busy main thread (4.5, 4.8).

**After 4.2 (10:57, post-swap walk behind the swap):** reveal settled **83–104ms** (engine = walk 31–36 + ~45 unattributed hop), conceal settled 176–215ms (strip walk 71–132 + walk 37–100 still before the swap). Background walk 66–193ms. One conceal converge `superseded` by the itemsChanged→setModel converge the background walk triggers — gate that handler while transitioning (4.1).

**After 4.1 (11:09, converge and the conceal strip from the rest mirror, pre-swap mirror stamped at swap time, itemsChanged converge gated mid-transition):** reveal settled **22–84ms**, conceal settled **48–63ms**, engine 12–66ms with no walk on the path; rest walk 43–125ms and post-swap walk 85–187ms both behind the swap. Left: cover 8–35ms (4.5), live finished-picture capture after a sub-second reveal (178ms on the conceal path, 4.5), plan ≤10ms = running-apps fetch on main (4.7).

**After 4.5 (11:22, punched cover + cut-out memoized on their inputs, cover windows pooled per display, finished picture taken as soon as the cover lifts):** cover **5–14ms**, reveal settled **15–26ms** warm; the finished picture now lands ~150ms after every lift (sub-second reveals included), so the conceal path no longer captures live. A first pool that re-framed any spare window onto any display cost 0.5–1s per reveal (backing-scale change on the move) — keyed per display it is free. Open, pre-existing: the capture indicator shifts the cluster ~16pt for ~3s after any capture; a finished picture taken lit is dropped (`chevron moved since the picture`) by a reveal that happens unlit — cadence-dependent, first item for 4.4 (stamp the indicator state on the picture, shift instead of drop).

Re-ranked by measured payoff: 4.3 (−50ms/swap, deterministic) → 4.5 (−20–45ms before the picture shows) → 4.2 (−50–160ms to settle) → 4.1 (−15–120ms before the swap).

With a fresh picture the user *sees* the finished picture at A + F + G (≈110–120ms) and B/C/D run under the cover. Without one (E or H) the user sees nothing until A + B + activation + the agent's own ~130ms slide.

## 3. Findings, most severe first

### 3.1 Poor architecture decisions

1. **`AppState` is a god object** (2,120 lines, 87 commits). It owns: boot sequence, rehide FSM driving, hover grace, settings apply/debounce, relaunch adoption (with its own sibling-launch heuristics), Apple twin retire/restore, editor intents (`moveItem`, `addSeparator`, discard), Apply orchestration, own-item placement queues, adoption from bar, bundle-less/immovable/unhideable/collateral trackers, snapshot mirror bookkeeping, overflow note, termination. Every feature lands here first; the CORE-SETS M3 deletion removed 2,345 lines and it is still the largest file. *Fix:* split by lifecycle (see §5, step 2).
2. **The reveal path is synchronous with the AX walk.** The engine treats "converge" as "walk, plan, swap, walk". The walk is the bar's truth, but the *reveal* decision needs only membership + the carried concealed set; freshness is what the post-swap walk and `itemsChanged` already provide. Two walks per transition, both on the latency path.
3. **Freshness by TTL instead of by event.** Pictures expire at 900s "to guard wallpaper/appearance drift", but `BackdropWatch` already models backdrop changes by signature and observes app activation + Space change. Wallpaper and appearance changes are observable (distributed notification `com.apple.desktop`/`BackgroundChanged`, `AppleInterfaceThemeChangedNotification`, `didChangeScreenParameters`). The TTL turns every post-idle hover into a cold one.
4. **Polling where a continuation belongs.** Activation completion (50ms poll), `waitUntilQuiesced` (30–200ms polls), `verifyConcealment` (150ms), adoption window (200ms), `waitForOwnItemAdoption` (500ms), `retireAppleTwin` (250ms ×8). Each is a bounded loop with its own constants; none is testable without real time.
5. **Two models for one concept still both live.** `SectionModel` (assignments + order) and `Roster`/`RosterRule` (sets) coexist; `settings.sectionModel.roster` is derived per call in hot paths (`pruneSettledOrderEdits`). Survey detail in §3.6.
6. **String-typed identity leaks.** `ItemID.rawValue.hasSuffix("::com.apple.menuextra.clock")` appears in `MenuBarBandMonitor`, `TransitionCoordinator`, `AppState.updateSnapshot` although `MenuBarPolicy.systemItem(for:) == .clock` exists.

### 3.2 Duplicate logic

- Primary-band frame filter written five ways: `MenuBarGeometry.isInPrimaryBand`, `PlacementGeometry.isPrimary`, `AppState.pelmetChevronItem` inline (`isInBand && midX > 0 && midX < primaryMaxX`), `AppState.adopt` inline, `ItemEnumerator.isMainDisplayFrame` (CG bounds). Pick one, in Core.
- Chevron lookup: `AppState.pelmetChevronItem`, `TransitionCoordinator.liveChevronMinX` / `chevronPunch` (by `AppState.chevronItemID`), `MenuBarBandMonitor.revealTriggerMaxX` (by `MenuBarPolicy.isChevronID`). Three predicates, two of which ignore the per-display copy rule.
- `NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude` computed inline in six places.
- Strip union over primary frames: `TransitionCoordinator.seedStripAtBoot`, `.takeBootPicture`, `.concealStripFrames` are the same loop with different filters.
- Extras + separators `apply(model:revealed:)` pair is called from four sites (`setReflowCompanion`, `settleCatchUp`, `handle(.itemsChanged)`, and implicitly via `preattach`).
- `hiddenSectionSignature` (TransitionCoordinator) re-derives what `SectionModel`/`Roster` should expose as `orderedMembers(of:)`.

### 3.3 Performance

- **B + D above**: two ~100ms AX walks per transition, both blocking.
- **Per-item LaunchServices lookups inside the walk**: `hostBundle(ofPID:)` and `describeLeaf` call `NSRunningApplication(processIdentifier:)` once or twice per item per walk; `resolveAgent` does it once more. No pid → bundle cache.
- **Per-item cross-process AX title reads**: `statusItemTitle(in:)` is 3–4 IPCs into *each* third-party app on every walk (children, extras bar, children, titles). This is the dominant walk cost and the one that stalls on a busy Electron app.
- **`runningApplications` materialised on every converge** via a `MainActor.run` hop, although `AppState` already observes `runningApplications` by KVO.
- **Pixel passes per reveal** (F): `clearing()` allocates a full CGContext copy of every cover and zeroes the chevron columns every reveal; `cutOut` diffs two full strips. Inputs only change when the pictures or the chevron frame change, which already invalidates the finished picture. Precompute at precapture time.
- **Cover windows are created and destroyed per reveal** (G): `NSWindow` + `NSImageView` + `NSImage` per display per cover, twice (cover + finished).
- **Band monitor per mouse move** (J): `foreignOverlay` = `NSWindow.windowNumber(at:)` + `CGWindowListCopyWindowInfo` on every `mouseMoved` in the band; `revealTriggerMaxX`/`pinnedZoneMinX` rescan the snapshot with allocations per event; `settings.behavior(forDisplayUUID:)` is called twice per event.
- **`pointerIsOverElevatedWindow`** copies the *entire* on-screen window list on every rehide re-arm (1.5s) and on every click outside the band while revealed.
- **`updateSnapshot`** rebuilds `bundleCounts`, `readings`, remembered frames, trackers on every content-changed snapshot; `pendingMoveCount` (read by the Apply button on every SwiftUI evaluation) runs a full `ApplyPass.plan` + `trappedEdited` each time.
- **Status-item image swaps** in the reflow companion land on the main thread mid-swap (≈5ms each per the frame-cost memory); fine today, but the companion runs on *every* converge including no-ops.

### 3.4 Scalability risks

- All walk/plan/adopt code is O(items × sections) with `Array.contains`/`firstIndex` on `[ItemID]` order arrays (`desiredOrderedTags` sorts with `firstIndex` inside the comparator → O(n² log n)). Fine at 20 items, visible at 60.
- Hard-coded bundle tables in `MenuBarPolicy` (`isUnmanagedAppleBundle`, `isPositionPinnedAppleBundle`, `isBundleHideableAppleHost`, system agents) grow with every macOS point release and every issue (#36, #42).
- Per-display work is a `for screen in NSScreen.screens` loop with a separate SCStream per display per capture; three displays = three ~90ms captures serially.
- The engine has no push signal from the agent; item changes are only noticed when something walks. A user with hover off and rehide off can go minutes without a walk.

### 3.5 Maintainability

- `AppTiming` + `EngineTiming` hold ~45 load-bearing constants with prose provenance; no test pins any of them, and two are dead (`axAppTimeout`; `tidyRevealWait` name survives Tidy's deletion).
- Log lines are the de-facto test oracle (`apply: own …`, `overflow«: …`); nothing asserts on them.
- `SESSION_LOG.md` is gitignored, so the *why* behind the constants lives outside the repo.
- App-target tests cannot run without quitting the host Pelmet (memory: xcodebuild test launches a host); they are effectively never run.
- `AppState.start()` order is documented as load-bearing in a comment rather than enforced by types.

### 3.6 Survey findings (UI layer, Core/Engine packages)

Two read-only surveys, findings spot-checked against the source. Severity order within each list.

**Crash / correctness (fix regardless of the plan)**

- `OverflowToggle.swift:92-93,115-116` — `posV as! AXValue` on values checked only for `.success`, not type; a non-`AXValue` reply mid agent restart crashes the app. `pelmet-probe/main.swift:89-92` has the correct `CFGetTypeID` guard.
- `ItemMover.swift:73-99` — every sleep in the synthetic drag is `try? await Task.sleep`; under cancellation all six return at once and a malformed down/24 drags/up is posted with the shield still up. Check `Task.isCancelled` before each post.
- `MovePlan.swift:153,186`, `BarAdoption.swift:101` — force unwraps in pure code.
- `MediaControls.swift:1576` — `CMIOObjectGetPropertyData(…, size, &size, …)` passes the same variable in and out (legal in Swift, a trap; `:1489` does it right).

**Performance (App layer)**

- `MenuBarTab.swift:658` — `isOutOfPlace` per tile body rebuilds `ApplyPass.primaryFrames` (O(n²) `trappedKeys`) per tile per render; `:20,:22` — `applyPending` + `pendingMoveCount` run a full `ApplyPass.plan` twice per Apply-button evaluation; `:325` — `StripDropDelegate.track` rebuilds `editorItems` (LaunchServices lookups) on every `dropUpdated`. Cache one plan + one frame map per snapshot/edit change.
- `MenuBarTab.swift:1510-1535` — separator sliders call `settingsChanged()` per tick → `separators.sync` re-rasterizes every glyph, `extras.sync` wipes the icon cache (`MediaControls.swift:118`), CFMessagePort sync per frame. Debounce on `onEditingChanged`.
- `MediaControls.swift:170-181` — `runningApplications` KVO → `applyCurrent()` for every app launch/quit machine-wide, with a LaunchServices query per launcher.
- `MediaControls.swift:684-703` — `pickableRunningApps` copies + resizes every running app's icon synchronously on main when the picker opens.
- Main-actor timers: two independent 1s permission polls (`SettingsView.swift:740`, `OnboardingFlow.swift:271`), 50ms mouse-button poll for the whole editor drag (`EditorDragSession.swift:48`), 200ms AX poll ×300 while Control Center's Focus panel is up (`FocusStatus.swift:232`), `tmutil` spawn every 2s while a backup runs (`TimeMachineBackup.swift:57`).

**Performance (Core/Engine/Apply)**

- `ApplyPass.swift:55-59` + `PlacementGeometry.swift:37-44` — two O(n²) minX-collision scans re-run on every snapshot; `primaryFrames` rebuilt at seven sites, twice per 45ms `quiesced` poll.
- `OverflowToggle.swift:77-97` — finds the « by ~200 `AXUIElementCopyElementAtPosition` calls in 3pt steps on the main actor per pass. Cache the element per agent pid, re-validate with one read.
- `ItemMover.swift:73-99` — fixed-sleep drag ≈1s per move, serial with retry: a 10-move Apply captures the pointer ~20s. Drive the ease loop off measured movement.
- `AgentPositionStore.swift:38-42` — per-tag linear scan of an unpruned, monotonically growing dict.
- `MovePlan.heaviestIncreasing` is O(n²) with no bound by contract.

**Duplicate logic**

- `MediaControls.swift:403-421/463-489/551-562/491-498` vs `SeparatorManager.swift:186-227/202-227/153-163/176-182` — `preattach`, `setVisible`, `observeRemoval`, `applyCurrent` are near-verbatim copies of the same `preattached`/`lastVisible`/`stillCurrent` machine; `StatusItemFader.swift:3-5` says this was consolidated once already. Extract `OwnItemVisibility`.
- `MediaControls.swift:1512-1624,1459-1473` — five copies of "enumerate audio/CMIO devices, read one property".
- `SectionModel.swift:21-33,49-63` vs `ItemIDGrammar.swift:20-37` — two parsers for the tag grammar (the file admits it); `SettingsStore.swift:257-270` vs `ItemIDGrammar.swift:90-105` — forward and reverse `ExtraKind` tables in different packages, no round-trip test.
- `ApplyPass.swift:152-155` = `ItemMover.swift:135-143` (`secondsSincePointerActivity`, separate constants in separate timing files); `ApplyPass.primaryFrames` = `ApplyPass.trapped` body.
- `SettingsView.swift:750-762` = `:851-863` (`binding` helper) + three more "find index in `extraItems`, mutate, `settingsChanged()`" copies in `MenuBarTab`.
- Four hand-synced `ExtraKind`/`SeparatorStyle` presentation tables (`MenuBarTab.swift:434,958,1564`, `MediaControls.swift:564`).
- Fade/slide control-point quadruples duplicated verbatim in `StatusItemFader.swift:32-35`, `ConcealGhostOverlay.swift:613-614,655`, `SettingsView.swift:1423-1426`.

**Architecture / maintainability**

- `MenuBarPolicy.swift:132-140` — `systemAgentRegistry` is process-global mutable state read by every "pure" predicate (`isUnmanagedAppleBundle` → `isSectionManageable` → `BarAdoption`, `ConvergePlan`, `canonicalize`); hence `resetSystemAgentsForTesting`. Pass a `PolicyContext` value.
- `SettingsStore` — one 25-field blob, one key, **no schema version, no migration chain**; a field that fails to decode silently resets (`:429-431`). 14 explicit `settings.save()` sites in `AppState`; forget one and the mutation is lost. `orderEdits` (transient editor state) and `pelmet.overflowLeftExpanded` (written straight to `UserDefaults` from `OverflowToggle.swift:145`) do not belong in it. This is the M4 migration-seed work; add `schemaVersion` now.
- `ApplyPass.run` (`:197-325`) — 128 lines touching 16 `AppState` members, three `defer`s, two closure-typed strategies; no `ApplyPassTests`/`OverflowToggleTests` exist.
- `ExtrasManager` (`MediaControls.swift`, 1,625 lines) is the second god object: 10 kinds, 8 parallel `last*` edge flags, menus, `Process` spawning, key synthesis, CoreAudio/CMIO monitoring. Split per kind behind an `ExtraBehavior` protocol.
- `Roster` is bypassed more than used: `.roster` reached twice in the app, `.assignments` directly at 22 sites (13 in `AppState`); `RosterRule.landing` is a 3-line wrapper over `MenuBarPolicy.isSectionManageable`. Either finish the extraction or fold it back.
- `DisplaysPane` (`SettingsView.swift:868`) reads `NSScreen.screens` in `body`, keyed on reference identity, no reconfiguration observer.
- Dead: `HelperHosts.activeBundleIDs`, `MessagePortLink.isListening`, `SettingsStore.showMediaControls` (still encoded), `SystemItem.primaryBentoBox`; probe-only but `public`: `AgentPositions.readOrdered`, `AssessmentMode.apiDescription`. Two Engine files import AppKit with no AppKit symbol. No TODO/FIXME anywhere.
- Test gaps: no tests for `AgentBarEngine` (548 lines), `ItemEnumerator`, `ItemMover`, `ApplyPass`, `OverflowToggle`, `ExtrasManager`, `SeparatorManager` visibility, `HelperHosts`, `SparkleController`, `MessagePortLink`.
- Private-API inventory (all soft-failing): `MenuBarClientCore` dlopen + 3 selectors (`MBAssessmentShim.m`), `CGSSetConnectionProperty("SetsCursorInBackground")` + `CGCursorIsVisible` (`ItemMover.swift:198-222`), `com.apple.MenuBarAgent` plist write (`AgentPositions.swift:11`), `MenuBarCore.loctable` parse (`OverflowToggle.swift:33`). Worth one doc page.

## 4. Cold hover/click plan (real latency wins, no behaviour change)

Ordered by payoff ÷ risk. Each step is independently shippable and measurable with the 60fps burst tool in `~/Projects/Pelmet-tools`.

### 4.1 Plan from the cached snapshot, walk after the swap (−~100ms hover→swap)

`converge()` keeps the walk but stops blocking on it when a recent snapshot exists:

```swift
// AgentBarEngine.converge
let snapshot: EngineSnapshot
if let last = lastSnapshot, Date().timeIntervalSince(last.takenAt) < EngineTiming.convergeSnapshotReuse /* 2s */ {
    snapshot = last                       // plan from the mirror
} else {
    snapshot = await refreshSnapshot()    // cold: walk once
}
```

The post-swap walk (already there) refreshes the mirror and yields `.itemsChanged`, which re-converges if a bundle appeared since. A brand-new bundle missing from the allowlist for one swap is the same window the app already has between walks today. Keep the empty-walk guard on the cold branch only. `reveal(_:)` / `conceal()` are the callers that benefit; `setModel` can force a walk.

### 4.2 Move the post-swap walk off the settle path (−~100ms swap→settle)

`performSwap` stamps `lastSnapshot` with `plan.concealed` from the *pre-swap* items immediately, returns, and runs the walk + verify in a detached task keyed on the epoch:

```swift
lastSnapshot = EngineSnapshot(items: snapshot.items, concealed: plan.concealed, takenAt: .now)
Task { await self.refreshAndVerify(concealable: concealable, epoch: epoch) }
```

`onRevealSettled` then fires ~100ms earlier: the rehide countdown, extras catch-up and finished-picture precapture all start sooner. `updateSnapshot` still receives the walked snapshot via the existing `engine.snapshot()` call in `TransitionCoordinator` (it will hit the TTL cache; make it await the background walk with `freshSnapshot()` only where a frame is needed, i.e. `concealStripFrames`).

### 4.3 Activation completion as a continuation (−0–50ms per swap)

Replace `ActivationBox` + 50ms poll with `withCheckedContinuation` raced against a 3s timeout task. Same semantics (first resolve wins, dud completions still time out), no polling.

### 4.4 Event-driven picture freshness (removes the post-idle cold path E)

- Drop `revealCoverFreshness`/`revealedStripFreshness` TTLs; invalidate on: `BackdropWatch` signature change (exists), `NSWorkspace.didChangeScreenParametersNotification`, distributed `com.apple.desktop` (`BackgroundChanged`), `AppleInterfaceThemeChangedNotification`, wake from sleep (`NSWorkspace.didWakeNotification`), display active-state change.
- Keep a *long* safety TTL (1h) with a refresh, not a drop: when it expires and the bar is concealed and quiesced, retake the empty-bar picture in the background (`scheduleRevealCoverPrecapture` already does exactly this after a conceal).
- Fix H: compare against `appState.lastMouseDownDisplay ?? displayUnderPointer` in `freshEmptyBarSnapshots` and `revealedStripProblem` (the stamp side already does), so hover-only sessions get the cover before the first click. Verify first with the `(N → 0)` log line.

### 4.5 Precompute covers at precapture time (−F, −G on every reveal)

At `scheduleRevealCoverPrecapture` / `takeRevealedStripPicture` completion, build once and cache:

- the chevron-punched cover (`clearing`), keyed on chevron frame;
- the cut-out finished picture (`iconsOnly`) for boot/cut-out cases;
- `NSImage`s wrapped in a reusable `CoverWindow` per display (borderless, ordered out). `begin(from:)` becomes `orderFront` + `setImage`.

Invalidate together with the pictures (same triggers as 4.4). The reveal path then does no pixel work and no window allocation.

### 4.6 Band monitor: coalesce and cache (CPU while hovering, faster fire)

- Cache `revealTriggerMaxX` / `pinnedZoneMinX` per snapshot (compute in `updateSnapshot`, store on `AppState` as `revealTriggerBound`).
- Skip `foreignOverlay` when the pointer moved < 1pt or < 8ms since the last check; keep the click path exact.
- Read `settings.behavior(forDisplayUUID:)` once per event.
- Replace `Timer.scheduledTimer` + `Task{@MainActor}` with one cancellable `Task.sleep` on the main actor; add `.common` run-loop mode if the Timer stays (menus and drags run tracking modes).
- Set `AXUIElementSetMessagingTimeout` (0.25s) on the systemwide element and on every `AXUIElementCreateApplication` the app makes (`isEmptyMenuBarArea`, `isOwnExtrasBar`, `ItemEnumerator.describeLeaf`/`statusItemTitle`, `ClockClickRelay.clockElement`). Retire the dead `axAppTimeout` by using it.

### 4.7 Cheaper walks (−30–60% of B/D when they do run)

- `ItemEnumerator`: cache `pid → (bundleID, bundleless, localizedName)`; drop entries whose pid is gone (`kill(pid, 0)` or `NSRunningApplication.isTerminated`). Removes 2–3 LS lookups per item per walk.
- Pass `runningBundles` into the engine from `AppState`'s KVO-maintained set instead of the `MainActor.run` hop per converge.
- Instrument the walk (`signpost` per phase: agent children, per-app title read, LS lookups) before touching the title read. If titles dominate, cache `statusItemTitle` per pid with invalidation on `itemsChanged`, since the title is only identity material and `sectionKey` is bundle-level anyway.

### 4.8 Companion image dedupe (−N×5ms of main-thread contention per swap)

Every `update*Glyph`/`update*Symbol` in `MediaControls.swift` takes the `if item.button?.image !== image` guard that `updateTimeMachineGlyph` already has, and `apply()` skips items whose inputs (`revealed`, `model` section, activity flag) are unchanged since `lastVisible`. Same visible result, no replicant snapshot + scene IPC per item per swap.

### 4.9 Push freshness from the agent (structural; do after 4.1–4.8)

Register an `AXObserver` on the agent element for `kAXLayoutChangedNotification`, `kAXUIElementDestroyedNotification` and `kAXCreatedNotification` on the bar windows. Coalesce into one walk per 100ms off the critical path. This is what makes 4.1 safe under all conditions and turns "the walk is truth" into "the mirror is truth, refreshed on change". Probe first: MenuBarAgent may not post layout notifications for hosted items.

Expected end state: hover with a fresh picture ≈ dwell + ~2ms; hover without one ≈ dwell + activation only; conceal settle ~100ms earlier; no post-idle cliff.

## 5. Refactoring strategy (behaviour-preserving, ordered)

1. **Instrument first.** `os_signpost` intervals around: walk, plan, activation, cover build, cover lift, settle. One `PerfTrace` type, log summary per transition (`reveal: walk 96ms plan 1ms activate 41ms cover 3ms settle 187ms`). This turns every step below into a measured before/after and is the first commit.
2. **Split `AppState` by lifecycle, not by feature** (keep `AppState` as the composition root and the @Observable façade):
   - `BootSequence` (start order as a type: `runOneShotMigrations → policy → onboarding → bar items → monitors → pump → engine`), exposes `engineStarted`.
   - `RelaunchAdoption` (notification + KVO observers, sibling heuristics, `lastSeenPID`, `absentBundles`, adoption windows with cover). Pure heuristics get tests.
   - `SnapshotMirror` (`updateSnapshot`, remembered frames, trackers, `bundleCounts`, overflow note) — a struct with `mutating func ingest(_:)` returning a diff, testable without AppKit.
   - `EditorIntents` (`moveItem`, `addSeparator`, `discardOrderEdits`, `barBasedOrder`, prune helpers) — operates on `SettingsStore` + snapshot, returns the model to converge.
   - `OwnItemPlacement` (`placeOwnItemSoon/Now/AtNextReveal`, retries).
   - `AppleTwin` (retire/restore/slot memory).
   `AppState` keeps intents (`toggle/reveal/concealNow/pointer*`), `dispatch`, the rehide timer, settings apply.
3. **One geometry module in Core**: `BarGeometry.primaryBand(frames:)`, `.chevron(in:)`, `.strip(of:)` replacing the five inline variants.
4. **One "async wait" primitive**: `Waiter.until(_ predicate:, poll:, deadline:)` with an injectable clock so every bounded loop (activation, quiesce, verify, adoption, own-item wait) is one function and testable.
5. **Engine snapshot freshness policy as a type** (`SnapshotPolicy.reuse(within:)`, `.fresh`) instead of the `snapshot()`/`freshSnapshot()`/`refreshSnapshot()` trio.
6. **`ItemID` typed predicates** replacing `rawValue.hasSuffix(...)` at all sites.
7. **Timing constants**: keep the enums, add a `TimingSpec` doc comment format (what it gates, measured value, date) and a test that every constant is referenced.
8. **Localize the string tables** (`MenuBarPolicy` bundle sets) into one data file with a test that reads it, so a new Apple host is a data change.
9. **App-layer consolidation** (after 2): `OwnItemVisibility` shared by `ExtrasManager` and `SeparatorManager`; `ExtraBehavior` per kind out of `MediaControls.swift`; one cached `ApplyPlanCache` (plan + primary frames + trapped set per snapshot/edit change) read by `applyPending`, `pendingMoveCount`, `isOutOfPlace`, `barBasedOrder`; `SettingsStore.schemaVersion` + `mutate { }` that saves, with `orderEdits` and `overflowLeftExpanded` moved to a session store.

Order matters: 1 before anything; 2 after the M4 merge (`roster` → `main`) so the split does not fight the floating-bar rebase; 4.1–4.6 can land on `roster` now because they touch the engine and coordinator only.

## 6. Do not touch

- `RehideStateMachine`, `ConvergePlan`, `MovePlan`, `BarAdoption`: pure, tested, and the parts that work. Refactors route *around* them.
- The cover decision (M3) and the picture lifecycle semantics: keep every invalidation rule, only change *when* the expensive work runs.
- The ObjC shim's `@try` boundary and the assertion swap order (activate new, then invalidate old).
- `hoverDelayFloor` and the click-grace constants: product decisions with live measurements behind them.

## 7. Verification

- Per step: burst recording (`~/Projects/Pelmet-tools`) of 10 hover reveals cold and warm, before/after; the `PerfTrace` summary line in `pelmet.log`; `swift test` in both packages; app target builds.
- Regression oracles that already exist in the log: `effect reveal settled`, `cover: picture from another active display`, `finished: …`, `converge: no-op`.
- Live checks with Gab at the Mac (never scripted while he is there): hover after 20 min idle, hover before the first click of a session, hover with an Electron app busy, three-display hover.
