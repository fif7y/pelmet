# Core plan: sets, not positions

Status: the sets core is the only core since 2026-09-20 (branch `roster`; M3 deleted the placement paths and the `core.setsOnly` switch with them — there is no way back to walks). Decision: option 1 (revealed items reappear in place) with Tidy folded into Apply; "Keep sections grouped" ON by default so the shipped look is unchanged.

Naming rule for this work: every type, file, log prefix and UI string is Pelmet's own. Nothing seen in any other product's binaries, logs or UI is reused, including release codenames. `AgentBarEngine.swift` becomes `AgentBarEngine.swift` as part of this plan.

## Why

Most bug classes since 0.2.20 trace to one design choice: sections are kept **physically grouped** in the bar, so every hide, reveal, new item, relaunch and overflow event may start a synthetic ⌘-drag walk. Walks fight the native «, fight other managers, land under the user's own clicks (#42), and need screen-capture covers plus a finished-picture lifecycle to stay invisible (#35, #39, #40).

The assertion Pelmet already ships hides by **membership**. Position never mattered for hiding. It only mattered for the grouped-reveal look. This plan drops that look and keeps grouping as an explicit user action.

What we verified before choosing this (2026-09-20, live, instrumented):
- The agent's stored position table is dead for live items. Written values are ignored on hide/re-allow, in range or out, whatever the allowlist order.
- Only a real HID ⌘-drag starts the agent's drag session. Events posted to a pid, or at session/annotated-session level, are delivered but never reorder.
- Screen Recording cannot be avoided by a better capture mechanism. It can only be made optional by degrading features that need item images.

## Principles

1. **Membership is the product.** Shown, hidden, always hidden. Changing membership never moves an item.
2. **The bar's physical order is the truth.** Pelmet reads it, never stores it. Stored state is membership plus pending edits.
3. **Synthetic drags happen in exactly one place**, on explicit user intent (Apply), never in the background, never on hover, reveal, conceal, boot, relaunch or new-item arrival.
4. **Own items move through the same door.** Extras, replicas, launchers and separators are dragged by Apply like any icon; only the chevron anchors. Registration does not place: a fresh registration under the same tag lands at the slot MenuBarAgent remembers in RAM, and the plist (`TrailingItemPreferredPositions`) is read only at an agent restart (probed 2026-09-20 — rank and trailing-inset values both ignored). `writeOrderHint` still seeds a Pelmet relaunch.
5. **No covers for walks.** There are no walks. A cover survives only if we choose to mask the system's reveal animation.

## Model (PelmetCore, pure, tested)

- `Roster` — the three membership sets keyed by canonical `sectionKey`. Replaces the positional half of `SectionModel`. Canonicalization rules (bundle keys for Apple hosts, unmanaged agents, host strays) carry over unchanged.
- `RosterRule` — default membership for items Pelmet hasn't met: new apps hidden by default, system hosts unmanaged, replica collateral rules, extras show rules. Absorbs `MenuBarPolicy`'s membership half. `MenuBarPolicy` keeps only classification (what is an Apple host, what lives in CoreServices).
- `OrderEdits` — pending order changes from the editor: per section, the order the user drew, plus a `tidy` flag. Cleared by Apply or Discard. Persisted so a quit doesn't lose them.
- `MovePlan` — pure function `(bar order read from AX, OrderEdits) -> [Move]`. A `Move` is one item and one target neighbour. Minimal move count, neighbour math reused from `PlacementGeometry`. Fixture-tested against today's known bar shapes (overflow, notch, multi-display, pinned Apple hosts).

## Behaviours

**Reveal / conceal.** Assertion off / assertion on. Nothing else. A revealed item reappears where it lives, animated by the system. No drift correction, no rescues, no adoption windows, no « clicks, no zone-only rules.

**Editor.** Shows the real bar order (AX read) per section. Dragging an item **between sections** changes membership and takes effect immediately; the icon keeps its physical spot and is marked "not in place" until Apply or the grouped option relocates it. Dragging **within a section** records an `OrderEdit` and lights the Apply button. Nothing in the bar moves until Apply.

**Apply.** One visible button, replaces Tidy bar order. Shows the pending count. Runs one `ApplyPass`:
1. Reads the bar, builds the `MovePlan`.
2. Waits for the pointer to be idle (public `CGEventSource.secondsSinceLastEventType`), configurable, default 1.5 s.
3. Hides the cursor, suppresses local input for the pass (public `CGEventSource` suppression interval), performs each `Move` as a real ⌘-drag, verifies each by AX, restores the cursor.
4. Reports per item: applied, skipped (behind «, pinned host, item vanished), failed (user moved). Failed moves stay pending; the button offers Retry.
Grouping is part of the same pass (the Tidy checkbox was folded in, Gab 2026-09-20: on a grouped bar it did nothing visible, and an editor drop across sections already crossed the chevron through the drawn order): the plan is the whole bar as one run, so any icon sitting on the wrong side of the chevron is a move even with no edit, and the button counts it.

**User ⌘-drags and boundaries.** The chevron and the always-hidden marker remain boundaries for the user's own ⌘-drags: an item dragged across one changes membership, read from the bar on the next snapshot. Pelmet never moves anything in response; it only records the new membership. Icons a user parks left of the chevron stay there and reveal as a group. This is the surviving half of today's adoption code (boundary crossing); the slotting half goes.

**Keep sections grouped (option, ON by default).** Same `ApplyPass` with `tidy`, triggered automatically whenever the roster and the physical bar disagree (new item, membership change, user drag). It runs only through the one door: pointer idle, cursor hidden, local input suppressed, never during a reveal or conceal, never while a menu is open, never while the bar overflows, bounded retries, then it gives up until the next change. Scope: it relocates only icons whose physical side disagrees with their section (in practice one icon per editor drag between sections; user drags are exact by definition and new icons land on the hidden side), never re-sorts within a section (Apply only), and stops after a bounded number of attempts per change, leaving the "not in place" badge. With it on, the chevron is a true boundary, reveals stay grouped, and 0.3.0 shows no visible change on upgrade. Off = never a synthetic drag outside Apply. The core stays sets; grouping is a policy on top and can be switched either way without migration.

**Live items** (camera/mic indicator, Now Playing, Timer, Focus, recording pill, AirDrop, VPN): appear where the agent puts them, `RosterRule` decides visibility, nothing moves. The collateral tracker stays (which system extras hide with which assertion), the placement side of it goes.

**Own items.** Moved by `ApplyPass`: a whole-bar pass attaches idle extras at alpha 0 so they have a slot, re-hosts separators onto their drawn section's helper first, then drags. An extra entering the bar (camera on, audio starting, a launcher's app starting) runs a one-item pass (`ApplyPass.Scope.ownItem`) among the items on screen, no reveal; entering a concealed section it waits for the next reveal settle. The chevron is the one anchor and moves only by the user's own ⌘-drag.

**New items.** Land where the agent puts them. `RosterRule` assigns a section, assertion applies it. The editor shows them in place with a "new" mark. No placement, no order-front routing.

**Boot and relaunch.** Read bar, apply roster, done. Helper hosts still wait for their items before the first assertion (helper race fix stays). No boot picture, no adoption walk.

**Overflow.** Irrelevant to the roster. Apply reports items behind « as skipped. The editor's overflow note stays as information.

**Multi-display.** Membership is global. Apply runs on the active display only.

**Other managers running.** Nothing to fight over except the assertion. Detect a foreign assertion (restriction monitor is open) and show the existing "another manager" notice; no retries.

**Upgrade.** Existing users keep their physical bar as-is. Stored order becomes a one-time `OrderEdits` seed shown as pending, so the first Apply reproduces their old grouped bar if they want it. Nothing moves on its own.

## Survive / delete map (done 2026-09-20, M3)

| File | Fate |
|---|---|
| App/PlacementController.swift (932) | DELETED; `ApplyPass` (324) is the one mover |
| App/OverflowChevron.swift (207) | DELETED (« is never clicked; the editor's overflow note reads `overflowTrappedCount`) |
| Core/PlacementLedger.swift, OrderDrift.swift (251 + tests) | DELETED; the bounce budget is three lines in `AppState.noteBounce` |
| Engine/AgentPrefsWatcher.swift (+ `externalOrderChange`) | DELETED; user drags adopt from the band monitor's drag end |
| App/AppState.swift | lost the placement queues, drift, rescues, tidy, the overflow gate and the flag branches; keeps adoption windows (a relaunched item parks under the assertion until one), roster, hover, editor state |
| Core/PlacementGeometry.swift | trimmed to `inSlot`, `betweenCentersX`, `isPrimary`, `overflowTrappedCount` |
| Core/BarAdoption.swift | KEPT (was "delete"): `reconcile` is the surviving half — membership read from the bar after a user ⌘-drag; `chevronDragged` adopts crossed items |
| App/TransitionCoordinator.swift, StatusItem/ConcealGhostOverlay.swift | KEPT whole (cover decision above; the picture lifecycle feeds the cover) |
| StatusItem/SeparatorManager.swift, HelperHosts.swift | keep; hosts follow the drawn section at Apply (`hostedSection`); overflow force-show gone |
| Settings/MenuBarTab.swift | Apply button (count, Retry, Discard) on the title row; Tidy button and the editor reveal gone; overflow note stays |
| Core/SectionModel.swift, MenuBarPolicy.swift, RehideStateMachine.swift, CollateralTracker.swift | keep |
| Engine/AgentBarEngine.swift, ItemMover.swift, ConvergePlan.swift | keep; `ItemMover` is used only by `ApplyPass` |
| Engine/AgentPositionStore/AgentPositions.swift | keep: the own-item hint writer (`writeOrderHint`) still seeds fresh registrations |

Net for M3 alone: 2,345 lines out, 147 in (20 files). `CoreMode` is gone; nothing reads `core.setsOnly` any more.

## Settings that go

Anything that only existed for walks: settle timers for placement, the forced system-extras hold caption (replicas still force the hold, the caption becomes plain text), zone-only rules. Reveal style, hover, shortcuts, extras, launchers, helpers all stay.

## Risks

- **Interleaved reveal look.** This is the visible product change. The README and the editor copy say it up front: hidden icons come back where they live; Apply with Tidy groups them.
- **Apply can fail mid-pass** if the user moves. It reports and retries when idle. Never silently.
- **Apple hosts that don't move** (pinned SystemUIServer) are skipped with a reason, as today.
- **Own-item moves** were proven on a Developer ID build from /Applications (2026-09-20: Camera on and off, Media, Sound both ways across the chevron, a Dot separator). Registration-based placement was probed and falsified the same day.

## Milestones

- **M0 spike (branch `roster`)**: Roster + RosterRule + reveal/conceal with every placement path disabled behind one flag. Live for a day on Gab's bar. Exit: no `place:`/`drift:`/`rescue:` log lines, hover and hotkey reveal work, live items behave.
- **M1 editor + Apply**: OrderEdits, MovePlan, ApplyPass, Apply/Discard UI, Tidy checkbox. Exit: a five-move edit applies in one pass with the cursor hidden, failures reported.
- **M2 own items through the door** (LANDED 2026-09-20): extras, replicas, launchers and separators dragged by Apply; idle extras attached for the pass; separators re-host at Apply. Exit met: an own item drawn anywhere in the editor lands there after one Apply, on or off screen.
- **M3 deletions + cover decision** (DONE 2026-09-20: cover kept, deletions landed — see the map above): the reveal-animation cover stays. Measured at 60fps under Smooth (uncovered) on Gab's bar: grouped reveal = the hidden group fades in place ~130ms (no stagger, no slide; own extras glide in ~130ms after), grouped conceal = ~450ms native slide toward the chevron. Interleaved (an icon drawn Hidden but sitting in the visible cluster, Apply pending): reveal opens its gap by sliding the chevron and cluster ~60pt over ~400ms; conceal slides out ~200ms then the cluster drifts ~600ms closing the gap, and the strip cover double-draws the cluster for two frames while it moves (open nit). Under Instant every reveal and conceal lands in one frame, stale picture included. The sets core made the reveal side nearly free on a grouped bar; the conceal side is not, and Instant is the baseline, so `ConcealGhostOverlay` and the capture pipeline survive. Delete the remaining "delete" rows.
- **M4 release 0.3.0**: migration seed, release notes, README copy for the reveal change.

## Blind spots to close before M1 (2026-09-20 review)

1. **Measure the in-place reveal.** Several items re-appearing across the bar means neighbours slide in several places at once. M0 exists to look at this on a full bar before committing. If it reads as busy, the answer is a short cross-fade cover, never a walk.
2. **~~Own-item registration is a distance from the right edge~~ — moot.** Registration never places a live-process item (see §Own items); the distance idea is kept here only as history. What still holds: prove own-item moves on a Developer ID build from /Applications with a full bar, and watch that a pass never blinks the media bars or drops the chevron's hover state.
3. **Apply's feel.** Idle wait plus a hidden cursor can mean a few silent seconds. Visible progress and a per-item result, or people press it twice.
4. **Upgrade expectations.** Some users chose Pelmet for the block reveal. Release notes say it up front; first launch of 0.3.0 offers "Tidy now" once, and points at "Keep sections grouped".
5. **Separators stay a feature.** Chevron and always-hidden separator remain Pelmet's own items: drag boundaries for the user's ⌘-drags, right-click menu, hosted on the helpers, placed by registration. What changes is only their *exactness*: "everything left of me is hidden" holds whenever the bar is grouped (user-arranged, Tidy, or "Keep sections grouped"). The one source of disagreement is an editor drag between sections, which hides instantly but leaves the icon physically where it was. New items land at the left end of the bar (to confirm in M0), which is the hidden side, so they are grouped from the start. The editor marks a not-yet-in-place icon and Apply (or the grouped option) relocates it.
6. **Order edits for hidden items can't be verified until a reveal.** Apply with Tidy reveals, drags, verifies, conceals in one pass, under the assertion so nothing else is visible.
7. **Foreign manager detection** stays a notice, not a fight. With no background walks, coexistence is mostly harmless, but the assertion still flips.
8. **Marketing assets** (README GIF, hero SVG, promo video) show the block reveal. Re-render for 0.3.0 or show the grouped option.

## Tests

Core: Roster canonicalization (ports SectionModelTests), RosterRule defaults (ports MenuBarPolicyTests membership cases), MovePlan fixtures (minimal moves, overflow skip, pinned skip, tidy step). Engine: ItemMover idle wait and suppression are injectable clocks. App: ApplyPass reporting states.
