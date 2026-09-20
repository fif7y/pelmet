// PlacementController.swift
// Physical placement + order-apply orchestration, extracted from AppState:
// the synthetic ⌘-drag pipeline (Pelmet-owned items), the deterministic plist
// rebuild with re-mint recovery (third-party items), the newcomer placement
// queue, and the order-apply cover choreography.

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class PlacementController {
    private weak var appState: AppState?
    private let engine: AgentBarEngine

    init(appState: AppState, engine: AgentBarEngine) {
        self.appState = appState
        self.engine = engine
    }

    // Input-source titles and agent registrations can change during a drag.
    // Use the same identity for initial lookup, verification, and retries.
    static func liveItem(
        for id: ItemID, in items: [ObservedItem], matchingFrame: (CGRect) -> Bool = { _ in true }
    ) -> ObservedItem? {
        let variants = items.filter { $0.id.sectionKey == id.sectionKey }
        return variants.first { $0.id == id && $0.frame.map(matchingFrame) == true }
            ?? variants.first { $0.frame.map(matchingFrame) == true }
    }

    static func isProtectedSystemItem(_ id: ItemID) -> Bool {
        // The input menu is movable; it must not become the trailing clamp
        // when the agent re-registers it to the left of the chevron.
        if id.bundleID == PelmetBundle.textInputAgentID { return false }
        return MenuBarPolicy.isPositionPinnedAppleBundle(id.bundleID) || id.isSystemModule
    }

    // MARK: - Physical placement (synthetic ⌘-drag)

    /// Returns true when the icon was dragged into place (or verified already
    /// there) — false when placement had to be skipped (no frame, nothing to
    /// measure against), so callers can keep it queued for a retry.
    @discardableResult
    func physicallyPlace(_ id: ItemID, in section: PelmetCore.Section) async -> Bool {
        guard !CoreMode.setsOnly else { return false }
        // Synthetic drags post raw CGEvents with sleeps between them — two
        // interleaved sequences corrupt each other (second mouse-down while
        // the first drag's button is logically down, targets ping-ponging).
        // Serialize every placement through one chain; callers spawn Tasks
        // freely (editor drops, extras toggles, tidy) and each waits its turn.
        let prior = placementChain
        var placed = false
        let task = Task { [weak self] in
            await prior?.value
            placed = await self?.physicallyPlaceNow(id, in: section) ?? false
        }
        placementChain = task
        await task.value
        return placed
    }

    private var placementChain: Task<Void, Never>?

    /// True while a synthetic ⌘-drag sequence is executing. The band monitor
    /// consults this to skip its drag-end adoption for OUR drags: the model
    /// is authoritative in that flow (the editor drop already wrote it), and
    /// adopting a BOUNCED drag would cement the failed order back into the
    /// model, silently reverting the user's arrangement.
    private(set) var activePlacements = 0
    var syntheticDragInFlight: Bool { activePlacements > 0 }

    /// One record per item: the newcomer queue, the reveal hold, the
    /// rescue queue, the frameless clock and the correction budgets. The
    /// rules live in PelmetCore; this controller only decides when to read
    /// them.
    private var ledger = PlacementLedger()

    /// Routed-but-not-yet-placed newcomers. A new icon spawns at the far left
    /// of the VISIBLE-at-that-moment items — but concealed cluster members
    /// rematerialize around it on reveal, stranding it mid-cluster (Figma
    /// landed between always-hidden icons). Placement into a concealed
    /// section can't be measured, so it waits here until a reveal gives the
    /// section live frames.
    var pendingPlacements: Set<ItemID> { ledger.pending }
    /// Queued items that only need to be on the right SIDE of the chevron:
    /// the camera/mic indicator re-enters layout on every hardware edge and
    /// its walk back to the exact slot rode the next hover reveal as a
    /// synthetic drag — the "laggy" reveal and the icon "moving itself" in
    /// #39. A live indicator anywhere in its zone is right where it belongs.
    private var zoneOnlyPlacements: Set<ItemID> = []
    func queuePlacement(_ id: ItemID, zoneOnly: Bool = false) {
        guard !CoreMode.setsOnly else { return }
        ledger.queue(id)
        if zoneOnly { zoneOnlyPlacements.insert(id) } else { zoneOnlyPlacements.remove(id) }
    }
    func queuePlacements(_ ids: some Sequence<ItemID>) {
        guard !CoreMode.setsOnly else { return }
        ledger.queue(ids)
    }
    func dropPlacement(_ id: ItemID) {
        ledger.dequeue(id)
        zoneOnlyPlacements.remove(id)
    }

    /// True when `id` sits on its section's side of the chevron on the
    /// primary band (nil frames read as "not in zone").
    private func isInZone(_ id: ItemID, section: PelmetCore.Section, in snap: EngineSnapshot) -> Bool {
        guard let appState,
              let chevron = appState.pelmetChevronItem(in: snap)?.frame,
              MenuBarGeometry.isInBand(chevron)
        else { return false }
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        guard let frame = Self.liveItem(for: id, in: snap.items, matchingFrame: {
            PlacementGeometry.isPrimary($0, screenMaxX: primaryMaxX)
        })?.frame else { return false }
        return section == .visible ? frame.minX > chevron.midX : frame.maxX < chevron.midX
    }

    /// Called on every reveal settle: place pending newcomers whose section
    /// is now measurable. Items meanwhile moved by the user (editor drop
    /// places immediately) just drop out of the queue.
    private var flushingPlacements = false

    func flushPendingPlacements() {
        guard !pendingPlacements.isEmpty, !flushingPlacements else { return }
        flushingPlacements = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.flushingPlacements = false }
            // Drain: items queued WHILE this flush runs (a drift correction
            // found at the same settle) are taken in the same pass. Each id
            // gets one attempt per flush — a requeued id waits for the next.
            var attempted = Set<ItemID>()
            var overflowLogged = false
            while let id = pendingPlacements.subtracting(attempted).sorted(by: { $0.rawValue < $1.rawValue }).first {
                attempted.insert(id)
                ledger.dequeue(id)
                guard let appState else { return }
                // A full bar: the drag would land on whatever the « shows
                // there and the next reflow would undo it. Editor drops
                // don't ride this queue, so nothing the user is doing waits.
                if overflowing {
                    if !overflowLogged {
                        overflowLogged = true
                        PelmetLog.log("place: bar overflows — \(pendingPlacements.count + 1) placement(s) wait for room")
                    }
                    ledger.queue(id)
                    continue
                }
                let section = appState.settings.sectionModel.section(of: id)
                // Held for the hidden cluster to materialize (see the
                // hidden-zone rule in physicallyPlaceNow): don't burn a
                // lookup wait on it until a reveal makes the drag safe.
                if ledger[id].deferredForReveal,
                   !appState.currentRevealedSections.contains(.hidden) {
                    ledger.queue(id)
                    continue
                }
                if ledger.framelessRetryPending(id, now: .now) {
                    ledger.queue(id)
                    continue
                }
                // Logged per attempt, not per flush: a concealed section's
                // items ride every flush until their reveal, silently.
                // itemsChanged fires this flush mid-conceal too (a rescue's
                // restore is itself an itemsChanged) — placing a concealed
                // section's item there measures fading frames. Hold until
                // ITS section is actually revealed. The chevron never rides
                // this queue: its walk runs at boot and on toggle-on, under
                // a deliberate reveal — a reveal-settle walk grabbed the
                // cursor mid-hover (2026-09-06).
                if id == AppState.chevronItemID { continue }
                if zoneOnlyPlacements.remove(id) != nil,
                   isInZone(id, section: section, in: await engine.snapshot()) {
                    PelmetLog.log("place: \(id.rawValue) in its zone — not dragged (indicator)")
                    continue
                }
                guard section == .visible
                    || appState.revealedSectionsForExtras.contains(section) else {
                    ledger.queue(id)
                    continue
                }
                PelmetLog.log("place: attempting \(id.rawValue) (section \(section))")
                let placed = await physicallyPlace(id, in: section)
                if placed {
                    // A verified reveal-time placement ends any rescue
                    // ping-pong — the item is truly in its slot.
                    ledger.notePlaced(id)
                } else if let framelessFor = ledger.scheduleFramelessRetry(id, now: .now) {
                    // No frame at all. If its section is on screen right now
                    // the registration is parked — ask for an adoption
                    // window (rate-limited per bundle), and retry slowly.
                    let onScreen = section == .visible || appState.currentRevealedSections.contains(section)
                    if onScreen, !overflowing, let bundle = id.bundleID, bundle != PelmetBundle.mainID,
                       framelessFor > 2,
                       (readoptRequested[bundle].map { Date.now.timeIntervalSince($0) > Self.readoptInterval } ?? true) {
                        readoptRequested[bundle] = .now
                        PelmetLog.log("place: \(id.rawValue) has had no frame for \(Int(framelessFor))s while its section is on screen — asking for an adoption window")
                        let state = appState
                        Task { await state.reopenAdoption(for: bundle) }
                    }
                }
                // Still unmeasurable (section concealed again, no frame) —
                // requeue for the next reveal settle. Trapped items moved to
                // the rescue queue instead; conceal is what frees them. A
                // Pelmet extra with no frame is simply not hosted (media
                // controls with nothing playing) — it attaches leftmost in
                // its section when it next shows, so a standing placement
                // would only re-run the lookup wait at every flush.
                if !placed, !ledger[id].rescueQueued {
                    if ledger[id].deferredForReveal {
                        ledger.queue(id)
                    } else if MenuBarPolicy.isPelmetExtraID(id), !id.isPelmetSeparator {
                        PelmetLog.log("place: \(id.rawValue) not hosted — dropped from the queue")
                    } else {
                        ledger.queue(id)
                    }
                }
            }
        }
    }

    /// Adoption windows asked for on behalf of frameless items whose section
    /// is on screen (their registration is parked), rate-limited per bundle.
    private var readoptRequested: [String: Date] = [:]
    private static let readoptInterval: TimeInterval = 120

    // MARK: - Order supervisor (wrong side of the chevron)

    /// Reveal-settle check: every live item on the wrong side of the
    /// chevron for its model section is queued for a corrective placement
    /// under this reveal. The judgement is `OrderDrift.misplaced`; this
    /// adds the budget and the moments to stay out of the way (a synthetic
    /// drag in flight, a transition, a user ⌘-drag adoption still landing).
    // MARK: - Parked registrations (in the model, absent from the bar)

    /// Bundles already given an adoption window in their current process
    /// lifetime. One window per launch: an app that legitimately drops its
    /// icon while running must not have the assertion dropped every reveal.
    private var readoptedPIDs: [String: pid_t] = [:]
    /// Bundles seen missing at the previous reveal settle. A reveal's
    /// "settled" callback runs while the agent is still materializing the
    /// cluster (Snib and OpenClip read missing 23ms after a settle,
    /// 2026-09-09), so one sighting is not evidence.
    private var missingAtLastSettle: Set<String> = []

    /// A model item whose app is running but which is neither live nor
    /// concealed while its section is on screen has re-registered under the
    /// assertion and parked (ChatGPT Classic re-creates its status item at
    /// runtime, 2026-09-09). Same remedy as a relaunch: an adoption window.
    func readoptMissing(in snap: EngineSnapshot) {
        guard let appState else { return }
        let revealed = appState.currentRevealedSections
        let present = Set(snap.items.map(\.id.sectionKey)).union(snap.concealed.map(\.sectionKey))
        var running: [String: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let b = app.bundleIdentifier { running[b] = app.processIdentifier }
        }
        var missingNow: Set<String> = []
        for (key, section) in appState.settings.sectionModel.assignments {
            guard section == .visible || revealed.contains(section),
                  let bundle = key.bundleID, bundle != PelmetBundle.mainID,
                  !MenuBarPolicy.isPositionPinnedAppleBundle(bundle),
                  let pid = running[bundle],
                  !present.contains(key.sectionKey)
            else { continue }
            missingNow.insert(bundle)
            guard missingAtLastSettle.contains(bundle), readoptedPIDs[bundle] != pid else { continue }
            readoptedPIDs[bundle] = pid
            PelmetLog.log("readopt: \(bundle) is running and assigned \(section) but had no registration at two reveals — opening an adoption window")
            let state = appState
            Task { await state.reopenAdoption(for: bundle) }
        }
        missingAtLastSettle = missingNow
    }

    /// One measurement: the chevron's x and the wrong-side ids, or nil when
    /// the chevron has no in-band frame.
    private struct DriftReading: Equatable {
        let chevronMinX: CGFloat
        let misplaced: [ItemID]
        let measuredCount: Int
        /// Items the native « holds (`PlacementGeometry.overflowTrappedCount`).
        let trappedCount: Int
    }

    private func readDrift(_ snap: EngineSnapshot) -> DriftReading? {
        guard let appState,
              let chevron = appState.pelmetChevronItem(in: snap)?.frame,
              MenuBarGeometry.isInBand(chevron)
        else { return nil }
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        let measured: [(id: ItemID, minX: CGFloat?)] = snap.items.map { item in
            guard let f = item.frame, MenuBarGeometry.isInBand(f),
                  abs(f.midY - chevron.midY) < 30, f.midX > 0, f.midX < primaryMaxX
            else { return (item.id, nil) }
            return (item.id, f.minX)
        }
        let model = appState.settings.sectionModel
        // Zone drift for everyone, plus within-section drift for Pelmet's
        // own items (they re-enter at the agent's remembered position and
        // adoption holds their model slot — the bar must follow the model).
        let misplaced = OrderDrift.misplaced(
            items: measured, chevronMinX: chevron.minX,
            model: model, pelmetBundleID: PelmetBundle.mainID
        )
        // The camera/mic indicator is zone-only (see `zoneOnlyPlacements`):
        // its slot within the section is never worth a drag.
        let ownOutOfOrder = OrderDrift.ownItemsOutOfOrder(
            items: measured, model: model, pelmetBundleID: PelmetBundle.mainID
        ).filter { !misplaced.contains($0) && !$0.rawValue.hasSuffix("::Pelmet.CameraMic") }
        return DriftReading(
            chevronMinX: chevron.minX,
            misplaced: misplaced + ownOutOfOrder,
            measuredCount: measured.filter { $0.minX != nil }.count,
            trappedCount: PlacementGeometry.overflowTrappedCount(measured.compactMap(\.minX))
        )
    }

    /// Logged once per overflow episode, not per pass.
    private var overflowPauseLogged = false
    /// The bar is full (`AppState.barOverflows`): nothing dragged stays put.
    private var overflowing: Bool { appState?.barOverflows ?? false }

    /// A verdict needs two agreeing reads: a reveal that follows a conceal
    /// within the same reflow measured the chevron at 1329 and, a second
    /// later, at 1421 (2026-09-09). One read mid-reflow would drag items
    /// that are only passing through.
    private static let driftConfirmDelay: Duration = .milliseconds(400)

    func correctDrift() async {
        guard !CoreMode.setsOnly else { return }
        guard let appState, !syntheticDragInFlight, !appState.isTransitioning,
              appState.currentRevealedSections.contains(.hidden)
        else { return }
        if let ended = appState.lastUserDragEndedAt, Date.now.timeIntervalSince(ended) < 8 {
            PelmetLog.log("drift: skipped — user ⌘-drag landed \(Int(Date.now.timeIntervalSince(ended)))s ago")
            return
        }
        let first = await engine.snapshot()
        appState.updateSnapshot(first)
        guard let a = readDrift(first) else { return }
        defer {
            // Absence is judged on a later read than presence: the settle
            // callback leads the agent's materialization by a few hundred ms.
            Task { [weak self] in
                try? await Task.sleep(for: Self.driftConfirmDelay)
                guard let self, let appState = self.appState,
                      !appState.isTransitioning, appState.currentRevealedSections.contains(.hidden) else { return }
                self.readoptMissing(in: await self.engine.snapshot())
            }
        }
        if a.misplaced.isEmpty {
            ledger.resetDriftBudget(except: [])
            overflowPauseLogged = false
            PelmetLog.log("drift: none (chevron@\(a.chevronMinX), \(a.measuredCount) measured\(a.trappedCount > 0 ? ", \(a.trappedCount) trapped in «" : ""))")
            return
        }
        // The bar overflows: the « decides who is on screen, and every
        // correction we drag is undone by the next reflow (#42: 23 drags
        // in 25 minutes, the icons visibly shuffling). Pause until it
        // de-crowds; the conceal-settle rescue keeps its own budget.
        if a.trappedCount > 0 || overflowing {
            if !overflowPauseLogged {
                overflowPauseLogged = true
                PelmetLog.log("drift: bar overflows (\(a.trappedCount) item(s) trapped in «) — corrections paused until it de-crowds")
            }
            return
        }
        overflowPauseLogged = false
        try? await Task.sleep(for: Self.driftConfirmDelay)
        guard !syntheticDragInFlight, !appState.isTransitioning,
              appState.currentRevealedSections.contains(.hidden) else { return }
        let second = await engine.snapshot()
        appState.updateSnapshot(second)
        guard let b = readDrift(second) else { return }
        guard abs(a.chevronMinX - b.chevronMinX) <= 3, a.misplaced == b.misplaced else {
            PelmetLog.log("drift: unsettled — \(a.misplaced.map(\.rawValue)) at chevron@\(a.chevronMinX), then \(b.misplaced.map(\.rawValue)) at chevron@\(b.chevronMinX) — skipped")
            return
        }
        let misplaced = b.misplaced.filter { !appState.isImmovable($0) }
        let chevron = CGRect(x: b.chevronMinX, y: 0, width: 0, height: 0)
        // Anything now on its side has earned its budget back.
        ledger.resetDriftBudget(except: misplaced)
        var queued: [String] = []
        for id in misplaced {
            switch ledger.spendDriftAttempt(id, now: .now) {
            case .skip:
                continue
            case .coolOff:
                PelmetLog.log("drift: \(id.rawValue) would not stay on its side after \(PlacementLedger.maxDriftAttempts) corrections — leaving it for \(Int(PlacementLedger.driftCoolOff / 60)) min")
            case .correct(let attempt):
                ledger.queue(id)
                queued.append("\(id.rawValue)#\(attempt)")
            }
        }
        PelmetLog.log("drift: \(misplaced.map(\.rawValue)) misplaced (chevron@\(chevron.minX)) — queued \(queued)")
    }

    // MARK: - Overflow rescue (items trapped in the native « overflow)

    /// Items whose placement failed because their registration is trapped in
    /// the native overflow notch: still present in AX, but reporting a
    /// phantom frame at the trailing area's left edge — a drag from there
    /// would grab whatever REALLY sits at that point. De-crowding
    /// materializes trapped items with real in-band frames (verified live
    /// 2026-08-21), so placement defers to the next conceal settle.
    var pendingRescues: Set<ItemID> { ledger.rescueQueued }
    private var rescuing = false

    private func queueRescue(_ id: ItemID) {
        guard ledger.queueRescue(id) else { return }
        PelmetLog.log("rescue: \(id.rawValue) queued for next conceal settle")
    }

    /// Called on every conceal settle: the bar just de-crowded, so trapped
    /// registrations now have real frames. A hidden-section separator is
    /// width-collapsed here — force-expand just IT, drag it to its zone,
    /// then restore its model visibility. Adoption stays suppressed for the
    /// whole window (activePlacements): a force-shown separator mid-conceal
    /// reads as a zone change, and the order fold-in would re-sort the very
    /// order the drag is placing toward.
    func flushPendingRescues() {
        guard !pendingRescues.isEmpty, !rescuing else { return }
        rescuing = true
        let queued = pendingRescues
        for id in queued { ledger[id].rescueQueued = false }
        Task { [weak self] in
            guard let self else { return }
            defer { self.rescuing = false }
            // The conceal just de-crowded the bar — or didn't. Read it
            // before dragging: with the « still holding items the rescue
            // burns attempts and warps the pointer for nothing (#42).
            if let appState {
                appState.updateSnapshot(await engine.snapshot())
                if overflowing {
                    PelmetLog.log("rescue: bar still overflows — \(queued.count) trapped item(s) wait for room")
                    for id in queued { ledger[id].rescueQueued = true }
                    return
                }
            }
            PelmetLog.log("rescue: attempting \(queued.count) trapped item(s)")
            for id in queued {
                guard let appState else { return }
                activePlacements += 1
                let forced = appState.forceShowSeparator(id)
                // Let the attach + reflow finish — measuring a mid-attach
                // frame reads as a phantom and burns the attempt.
                if forced { try? await Task.sleep(for: AppTiming.rescueForceShowSettle) }
                let placed = await physicallyPlace(
                    id, in: appState.settings.sectionModel.section(of: id)
                )
                if forced { appState.restoreSeparatorVisibility() }
                activePlacements -= 1
                // The attempt may have re-queued itself (still phantom) —
                // this loop is the single requeue authority.
                ledger[id].rescueQueued = false
                if placed {
                    // Zone placement only: the section's neighbors are
                    // concealed here, so the target was the chevron fallback
                    // and the in-slot check is vacuous. Queue the EXACT slot
                    // for the next reveal settle, when neighbors have real
                    // frames. Attempts reset there, not here — a reveal that
                    // re-traps the item ping-pongs back to rescue, and the
                    // cap must span the whole cycle.
                    ledger.queue(id)
                    PelmetLog.log("rescue: \(id.rawValue) zone-placed — exact slot at next reveal settle")
                } else {
                    let (attempt, requeue) = ledger.spendRescueAttempt(id)
                    if requeue {
                        ledger[id].rescueQueued = true
                        PelmetLog.log("rescue: \(id.rawValue) failed (attempt \(attempt)) — requeued")
                    } else {
                        PelmetLog.log("rescue: \(id.rawValue) gave up after \(attempt) attempts")
                    }
                }
            }
        }
    }

    /// The main-display frame of an item under any of its id variants.
    static func primaryBandFrame(of key: ItemID, in snap: EngineSnapshot) -> CGRect? {
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        return snap.items.lazy
            .filter { $0.id.sectionKey == key.sectionKey }
            .compactMap(\.frame)
            .first { MenuBarGeometry.isInBand($0) && $0.midX > 0 && $0.midX < primaryMaxX }
    }

    /// Post-drag read that waits for the dragged item to stop moving: floor
    /// wait, then re-read until its frame repeats, bounded by the cap. A
    /// single fixed-delay read judged mid-animation frames as misses.
    private func quiescedSnapshot(watching id: ItemID) async -> EngineSnapshot {
        try? await Task.sleep(for: AppTiming.postDragSettleFloor)
        let started = ContinuousClock.now
        var snap = await engine.snapshot()
        var matches = 0
        var reads = 1
        while matches < AppTiming.postDragQuiesceMatches,
              started.duration(to: .now) < AppTiming.postDragQuiesceCap {
            try? await Task.sleep(for: AppTiming.postDragQuiescePoll)
            let next = await engine.snapshot()
            reads += 1
            let before = Self.primaryBandFrame(of: id, in: snap)
            let now = Self.primaryBandFrame(of: id, in: next)
            matches = (before == now) ? matches + 1 : 0
            snap = next
        }
        let ms = Int(started.duration(to: .now) / .milliseconds(1))
        PelmetLog.log("place: quiesced \(id.rawValue) after \(reads) read(s), \(ms)ms\(matches < AppTiming.postDragQuiesceMatches ? " (cap)" : "")")
        return snap
    }

    /// `allowExpansion` bounds the retry-after-«-expansion to depth one.
    private func physicallyPlaceNow(
        _ id: ItemID, in section: PelmetCore.Section, allowExpansion: Bool = true
    ) async -> Bool {
        guard let appState else { return false }
        try? await Task.sleep(for: AppTiming.placementPreSettle)
        // The payload can be a canonical `bundle:` id (stored/concealed
        // editor tile) or any title-variant — resolve to the live
        // representative by section key, exact id first.
        // An item can appear under several ids (title variants) and, per
        // id, with another display's frame when the main copy is missing
        // from the walk (Sconce: `::Item-0` at x=-614/y=-119 on the left
        // display while `::Sconce` sat on the main bar, 2026-09-09 — every
        // editor drop of Sconce skipped, and Bitwarden aimed past it). Only
        // a primary-band frame is a frame we can drag or aim at.
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        func isPrimary(_ f: CGRect) -> Bool {
            PlacementGeometry.isPrimary(f, screenMaxX: primaryMaxX)
        }
        func primaryFrame(of key: ItemID, in snap: EngineSnapshot) -> CGRect? {
            Self.liveItem(for: key, in: snap.items, matchingFrame: isPrimary)?.frame
        }
        func liveItem(in snap: EngineSnapshot) -> ObservedItem? {
            Self.liveItem(for: id, in: snap.items, matchingFrame: isPrimary)
        }
        // Freshly-shown extras take a beat to be hosted — retry the lookup
        // briefly instead of giving up on the first stale snapshot.
        var snap = await engine.snapshot()
        appState.updateSnapshot(snap)
        for _ in 0..<AppTiming.placementLookupRetries where liveItem(in: snap) == nil {
            try? await Task.sleep(for: AppTiming.placementLookupRetryDelay)
            snap = await engine.snapshot()
            appState.updateSnapshot(snap)
        }
        guard
            let item = liveItem(in: snap),
            let frame = item.frame
        else {
            PelmetLog.log("place: no frame for \(id.rawValue) — skipping physical move (concealed?)")
            ledger.noteFrameless(id, now: .now)
            return false
        }
        ledger.noteFrame(id)
        // In flight from HERE: the pre-settle and the frame lookup above are
        // ~2s of waiting with no synthetic events, and counting them held
        // the rehide (3s deferral) and swallowed hover reveals after every
        // reveal settle and Settings close (2026-09-08, a queued extra that
        // was never hosted re-ran that wait at every flush).
        activePlacements += 1
        defer { activePlacements -= 1 }
        // Post-drag verification looks the item up by its LIVE id.
        let liveID = item.id
        // Primary display by design: the engine's canonical frames are the
        // primary band and every bar mirrors the one order — drags here move
        // all displays.
        guard let screen = NSScreen.screens.first else { return false }
        // Trapped-in-overflow check (`PlacementGeometry.isPhantom`): dragging
        // from a phantom would grab whatever REALLY sits there — skip and
        // defer to the conceal-settle rescue.
        let phantom = PlacementGeometry.isPhantom(
            frame, amongOthers: snap.items.filter { $0.id != item.id }.compactMap(\.frame)
        )
        if phantom {
            PelmetLog.log("place: \(id.rawValue) frame is a phantom (duplicate minX \(frame.minX)) — trapped in overflow")
            // Expand the native « inline: the trapped item materializes with
            // a real frame and the normal drag proceeds. Only resolvable
            // while Pelmet is frontmost (editor flows) — background placements
            // fall through to the conceal-settle rescue.
            // The « click warps the user's pointer: only inside the editor,
            // where the drop already committed it to synthetic motion. A
            // background rescue clicked it three times in 25 seconds under
            // someone's own clicks (#42).
            if allowExpansion, appState.editorHoldsBar, await OverflowChevron.expandForPlacement() {
                try? await Task.sleep(for: AppTiming.overflowExpandSettle)
                return await physicallyPlaceNow(id, in: section, allowExpansion: false)
            }
            queueRescue(id)
            return false
        }
        // Chevron is OPTIONAL: with the Pelmet icon hidden, live neighbor
        // frames alone anchor the target — only the no-neighbor fallbacks
        // and the final side clamp need the chevron.
        // Placing the chevron ITSELF: it is not an editor item, so it has
        // no index in the desired order — its slot is the hidden/visible
        // boundary (right of every hidden item, left of the first visible
        // one), and it can't be its own anchor.
        let isChevron = appState.pelmetChevronItem(in: snap)?.id == item.id
        let rawChevronFrame = isChevron ? nil : appState.pelmetChevronItem(in: snap)?.frame

        // Neighbors in the DESIRED order that have live frames — adjusted into
        // the "lifted" coordinate space (`PlacementGeometry.lifted`): targets
        // computed in pre-lift coordinates land one slot off (verified:
        // consistent ±itemWidth misses in the logs).
        // Own = any Pelmet host, helpers included: a helper-hosted separator
        // is Pelmet's item under the main-bundle key (sectionKey folding),
        // and it must never run the third-party bounce budget — the
        // immovable mark refuses own bundles, so that path claimed "placed"
        // and re-dragged it at every settle.
        let dragIsPelmetOwned = item.id.bundleID.map(PelmetBundle.ownIDs.contains) ?? false
        func lifted(_ neighborFrame: CGRect) -> CGRect {
            PlacementGeometry.lifted(neighborFrame, dragged: frame, ownItem: dragIsPelmetOwned)
        }
        // Neighbors from the GLOBAL desired order, not just the item's own
        // section: at a section boundary the adjacent item belongs to the
        // NEXT cluster, and a one-sided "right.minX - 14" target overshoots
        // into that item's footprint (bar spacing is tighter than 14pt) — the
        // agent then slots the drop one place too far left. Verified: Figma,
        // first-of-Hidden, kept landing left of Always-Hidden's Bitwarden.
        // Pinned items (SystemUIServer, a tray that swallows drags) sit
        // wherever their host put them, not where the order says: as a
        // neighbor, Siri live at the far right made a hidden item's slot
        // land right of the chevron (2026-09-15). They bound nothing.
        func placeable(_ section: PelmetCore.Section) -> [ObservedItem] {
            appState.editorItems(in: section).filter { !appState.isImmovable($0.id) }
        }
        let globalOrder = placeable(.alwaysHidden) + placeable(.hidden) + placeable(.visible)
        // Canonical comparison: the editor's representative for this bundle
        // may be a different title-variant of the same item.
        let index = isChevron
            ? placeable(.alwaysHidden).count + placeable(.hidden).count
            : globalOrder.firstIndex(where: { $0.id.sectionKey == id.sectionKey }) ?? globalOrder.count
        // Only frames in the SAME menu-bar band as the dragged item are
        // trustworthy (`PlacementGeometry.inBand`).
        func inBand(_ f: CGRect) -> Bool {
            PlacementGeometry.inBand(f, of: frame, screenMaxX: screen.frame.maxX)
        }
        let chevronFrame = rawChevronFrame.flatMap { inBand($0) ? $0 : nil }
        // Keep the neighbor ITEMS, not just their frames — after the drag the
        // landing is verified against them (x-order), because the lifted-gap
        // assumption is not reliable at cluster boundaries (verified: a
        // one-slot boundary drag bounced back — target fell inside the raw
        // footprint of the left neighbor).
        func isLive(_ item: ObservedItem) -> Bool {
            primaryFrame(of: item.id, in: snap).map(inBand) == true
        }
        let alwaysHiddenEnd = placeable(.alwaysHidden).count
        let hiddenEnd = alwaysHiddenEnd + placeable(.hidden).count
        // The trailing system cluster never moves and nothing drops right of
        // it, so a system member is no LEFT bound: an own item ordered
        // "after the clock" (Media controls on a bar whose Visible section
        // is battery/wifi/clock, #13) aimed at clock.maxX, verified against
        // the clock's x, failed, and re-dragged at every conceal settle.
        // Left of one is a real slot, so it still bounds on the right. A
        // system item the user HIDES is not that cluster — it moves like any
        // other icon, and skipping it aimed the Focus item one slot left of
        // the Sound icon and called it placed (2026-09-16).
        let leftIdx = globalOrder.indices[..<index].last(where: { i in
            isLive(globalOrder[i]) && (!Self.isProtectedSystemItem(globalOrder[i].id) || i < hiddenEnd)
        })
        let rightIdx = globalOrder[(min(index + 1, globalOrder.count))...].firstIndex(where: isLive)
        let leftPair = leftIdx.map { globalOrder[$0] }
        let rightPair = rightIdx.map { globalOrder[$0] }
        let leftNeighbor = leftPair?.frame.map(lifted)
        let rightNeighbor = rightPair?.frame.map(lifted)
        // At the hidden/visible boundary the live chevron caps the slot
        // instead of the neighbor from the desired order (the raw retry once
        // aimed at a midpoint straddling the chevron and verified true on the
        // wrong side — Figma, 2026-09-09). `PlacementGeometry.chevronCaps`.
        let caps = PlacementGeometry.chevronCaps(
            index: index, leftIdx: leftIdx, rightIdx: rightIdx,
            alwaysHiddenEnd: alwaysHiddenEnd, hiddenEnd: hiddenEnd
        )
        let chevronCapsRight = !isChevron && chevronFrame != nil && caps.right
        let chevronCapsLeft = !isChevron && chevronFrame != nil && caps.left
        func liveChevron(_ snap: EngineSnapshot) -> CGRect? {
            appState.pelmetChevronItem(in: snap)?.frame.flatMap { inBand($0) ? $0 : nil }
        }
        // The slot's live bounds in a given snapshot: the neighbor from the
        // desired order, or the chevron where it caps the section boundary.
        func leftBound(in snap: EngineSnapshot) -> CGRect? {
            chevronCapsLeft
                ? liveChevron(snap)
                : leftPair.flatMap { primaryFrame(of: $0.id, in: snap) }.flatMap { inBand($0) ? $0 : nil }
        }
        func rightBound(in snap: EngineSnapshot) -> CGRect? {
            chevronCapsRight
                ? liveChevron(snap)
                : rightPair.flatMap { primaryFrame(of: $0.id, in: snap) }.flatMap { inBand($0) ? $0 : nil }
        }

        let managedMinX = snap.items
            .filter { !Self.isProtectedSystemItem($0.id) }
            .compactMap(\.frame?.minX)
            .min()
        // Only members right of the chevron are the trailing cluster: Now
        // Playing hosted LEFT of it clamped a Visible target into the hidden
        // zone (1158 with the chevron at 1233, #13's log).
        let systemMinX = snap.items
            .filter { Self.isProtectedSystemItem($0.id) }
            .compactMap(\.frame)
            .filter { f in inBand(f) && (chevronFrame.map { f.minX > $0.midX } ?? true) }
            .map(\.minX)
            .min()
        // Two ways to aim. Between-centers from raw bound frames is the
        // primary whenever both bounds are live (it is what the retry used
        // to do, and it is the one that lands). The anchored estimate —
        // lifted frames, one-sided offsets, zone fallbacks, cluster clamps —
        // covers one-sided and no-neighbor cases and serves as the retry.
        let anchoredX = PlacementGeometry.targetX(
            leftNeighbor: leftNeighbor,
            rightNeighbor: rightNeighbor,
            chevron: chevronFrame,
            section: section,
            managedMinX: managedMinX,
            systemMinX: systemMinX,
            screenMaxX: screen.frame.maxX
        )
        let betweenX: CGFloat? = {
            guard let l = leftBound(in: snap), let r = rightBound(in: snap), l.midX < r.midX else { return nil }
            return PlacementGeometry.betweenCentersX(left: l, right: r, screenMaxX: screen.frame.maxX)
        }()
        let aimedBetween = betweenX != nil
        guard let targetX = betweenX ?? anchoredX else {
            let rawLeft = globalOrder[..<index].reversed().first(where: { $0.frame != nil })
            let rawRight = globalOrder[(min(index + 1, globalOrder.count))...].first(where: { $0.frame != nil })
            PelmetLog.log("place: no live neighbors and no chevron for \(id.rawValue) — skipping (frame=\(frame) index=\(index)/\(globalOrder.count) rawLeft=\(rawLeft?.id.rawValue ?? "nil") \(rawLeft?.frame.map(String.init(describing:)) ?? "") rawRight=\(rawRight?.id.rawValue ?? "nil") \(rawRight?.frame.map(String.init(describing:)) ?? ""))")
            return false
        }

        // Skip only when the item is genuinely at its slot already
        // (`PlacementGeometry.alreadyAtSlot`: an order with both bounds live,
        // x proximity otherwise; rescue drags at conceal once hopped 30pt
        // into the chevron and reverted every time, hence the wide fallback
        // tolerance).
        let fallbackTarget = leftNeighbor == nil && rightNeighbor == nil
        let alreadyPlaced = PlacementGeometry.alreadyAtSlot(
            x: frame.midX,
            leftMidX: leftBound(in: snap)?.midX, rightMidX: rightBound(in: snap)?.midX,
            targetX: targetX, fallbackTarget: fallbackTarget
        )
        guard !alreadyPlaced else {
            PelmetLog.log("place: \(id.rawValue) already at slot (x=\(frame.midX), target=\(targetX))")
            return true
        }

        // The drag must start inside the main display's menu bar band — a
        // stale or foreign-display frame here would post a ⌘-click into
        // whatever sits at that point on screen.
        guard MenuBarGeometry.isInBand(frame),
              frame.midX > 0, frame.midX < screen.frame.maxX else {
            PelmetLog.log("place: source frame outside menu bar band (\(frame)) — skipping drag")
            return false
        }
        // The landing is verified by ORDER against the intended neighbors —
        // landing coordinates legitimately shift with the post-drop reflow,
        // but the item must sit right of its left neighbor and left of its
        // right one. A failed first attempt retries once with RAW (unlifted)
        // neighbor frames: whether the gap closes during the drag differs by
        // context, and whichever assumption was wrong the first time, the
        // other target is the correct one.
        func landedInSlot(_ snap: EngineSnapshot) -> Bool {
            guard let x = primaryFrame(of: liveID, in: snap)?.midX else { return false }
            let leftMid = leftBound(in: snap)?.midX
            let rightMid = rightBound(in: snap)?.midX
            let ok = PlacementGeometry.inSlot(x: x, leftMidX: leftMid, rightMidX: rightMid)
            if !ok {
                // A verification miss costs a whole second drag — say why.
                PelmetLog.log("place: verify x=\(x) left=\(chevronCapsLeft ? "chevron" : leftPair?.id.rawValue ?? "nil")@\(leftMid.map { "\($0)" } ?? "-") right=\(chevronCapsRight ? "chevron" : rightPair?.id.rawValue ?? "nil")@\(rightMid.map { "\($0)" } ?? "-")")
            }
            return ok
        }
        // The hidden zone is untouchable while its items are absent. The
        // agent keeps a concealed item's place as a remembered position; a
        // drag that starts or ends left of the chevron then shifts the
        // chevron (or a neighbor) past that position, and the item comes
        // back on the visible side at the next reveal (Snib, 2026-09-09,
        // after an own-item drag across the chevron). Hold such placements
        // for a reveal, where every item is present and the drag reflows
        // real frames. The chevron's own walk already runs under one.
        if !isChevron, let chevron = chevronFrame,
           !appState.currentRevealedSections.contains(.hidden),
           PlacementGeometry.touchesHiddenZone(x: frame.midX, targetX: targetX, chevronMidX: chevron.midX) {
            PelmetLog.log("place: \(id.rawValue) touches the hidden zone while it is concealed (x=\(frame.midX) → \(targetX), chevron@\(chevron.midX)) — waiting for a reveal")
            ledger[id].deferredForReveal = true
            return false
        }
        ledger[id].deferredForReveal = false
        // The chevron's slot is an ORDER, not an x: with both boundary
        // neighbors live, sitting between them is the whole job. The x
        // target is a 13pt-off estimate that dragged it every launch and
        // bounced it straight back (2026-09-06). Concealed left neighbor
        // (no frame) → fall through: the drag is what fixes a chevron that
        // landed inside the collapsed cluster.
        if isChevron,
           let l = leftPair?.frame, let r = rightPair?.frame,
           l.midX < frame.midX, frame.midX < r.midX {
            PelmetLog.log("place: chevron already between its neighbors (x=\(frame.midX)) — no drag")
            return true
        }
        // No live hidden neighbor = the cluster is concealed; a drop now
        // lands before every concealed item. Stay queued for a reveal.
        if isChevron, leftPair == nil {
            PelmetLog.log("place: chevron has no live hidden neighbor — waiting for a reveal")
            return false
        }
        // Marked after `PlacementLedger.maxBounces` placements whose drags
        // all landed back at the start: dragging it again is the glitch the
        // user sees (#15), not a fix. Treated as placed so nothing requeues.
        if appState.isImmovable(id) {
            PelmetLog.log("place: \(id.rawValue) is marked immovable — left where its app put it")
            return true
        }
        PelmetLog.log("place: dragging \(id.rawValue) x=\(frame.midX) → \(targetX) (section \(section), \(aimedBetween ? "between" : "anchored"))")
        // Keep the settings window above the dragged icon's app for the
        // span of the drag; released after the refocus ladder below.
        let holdsSettings = appState.settingsWindowVisible
        if holdsSettings { SettingsWindowController.shared.holdAboveDrag() }
        defer { if holdsSettings { scheduleSettingsRelease() } }
        await ItemMover.cmdDrag(
            from: CGPoint(x: frame.midX, y: 12),
            to: CGPoint(x: targetX, y: 12),
            ownItem: dragIsPelmetOwned
        )
        var after = await quiescedSnapshot(watching: liveID)
        appState.updateSnapshot(after)
        if let newFrame = primaryFrame(of: liveID, in: after) {
            PelmetLog.log("place: landed at x=\(newFrame.midX)")
        } else {
            PelmetLog.log("place: item not observable after drag")
        }
        var placed = landedInSlot(after)
        // The chevron's order check is only meaningful with the hidden
        // neighbor still live — with it gone, "between" is vacuous and the
        // drop most likely landed in the concealed gap. Unverified: requeue
        // for the next reveal rather than trust it.
        if isChevron, placed,
           leftPair.flatMap({ primaryFrame(of: $0.id, in: after) }).map(inBand) != true {
            PelmetLog.log("place: chevron's hidden neighbor vanished mid-drag — unverified, requeued")
            return false
        }
        // One retry with the OTHER aim. A between-centers miss re-aims
        // between the bounds as they sit after the reflow; an anchored miss
        // (one-sided or fallback first drag) tries between-centers if both
        // bounds have appeared since, else the anchored estimate again.
        if !placed,
           let retryFrame = primaryFrame(of: liveID, in: after) {
            let retryX: CGFloat?
            let aim: String
            if let l = leftBound(in: after), let r = rightBound(in: after), l.midX < r.midX {
                retryX = PlacementGeometry.betweenCentersX(left: l, right: r, screenMaxX: screen.frame.maxX)
                aim = "between"
            } else if !aimedBetween, let anchoredX {
                retryX = anchoredX
                aim = "anchored"
            } else {
                retryX = nil
                aim = "none"
            }
            if let retryX, abs(retryX - retryFrame.midX) > 4 {
                PelmetLog.log("place: retry (\(aim)) \(id.rawValue) x=\(retryFrame.midX) → \(retryX)")
                await ItemMover.cmdDrag(
                    from: CGPoint(x: retryFrame.midX, y: 12),
                    to: CGPoint(x: retryX, y: 12),
                    ownItem: dragIsPelmetOwned
                )
                after = await quiescedSnapshot(watching: liveID)
                appState.updateSnapshot(after)
                placed = landedInSlot(after)
                PelmetLog.log("place: retry landed at x=\(primaryFrame(of: liveID, in: after)?.midX ?? -1) verified=\(placed)")
            } else {
                PelmetLog.log("place: no retry aim for \(id.rawValue) (\(aim))")
            }
        }
        // A SINGLE trapped item can evade the duplicate-minX check (nothing
        // else at its phantom x). Fallback signature for own items: both
        // drags left the frame byte-identical. That also matches a genuine
        // bounce — either way a retry on the de-crowded settled bar is the
        // right recovery, so hand it to the conceal-settle rescue.
        if !placed, dragIsPelmetOwned,
           let finalX = primaryFrame(of: liveID, in: after)?.minX,
           abs(finalX - frame.minX) < 0.5 {
            PelmetLog.log("place: \(id.rawValue) never moved (x=\(finalX)) — trapped or bounced")
            // Same inline «-expansion as the phantom path — a SINGLE trapped
            // item often has no duplicate to trip the pre-check on.
            if allowExpansion, appState.editorHoldsBar, await OverflowChevron.expandForPlacement() {
                try? await Task.sleep(for: AppTiming.overflowExpandSettle)
                return await physicallyPlaceNow(id, in: section, allowExpansion: false)
            }
            queueRescue(id)
        }
        // A third-party item that never moved across both drags swallowed
        // them (an Electron tray, #15). Count it; after the budget, stop
        // dragging it for good and let the editor say why.
        if !placed, !dragIsPelmetOwned, let bundle = id.bundleID,
           let finalX = primaryFrame(of: liveID, in: after)?.minX,
           abs(finalX - frame.minX) < 0.5 {
            let bounce = ledger.noteBounce(id)
            PelmetLog.log("place: \(id.rawValue) bounced both drags (x=\(finalX)) — \(bounce.count)/\(PlacementLedger.maxBounces)")
            if bounce.immovable {
                appState.setImmovable(bundle, true)
                return true
            }
        }
        return placed
    }

    /// The drag clicked outside Pelmet — hand focus back to the settings
    /// window. Retried: the dragged icon's app can win an activation race
    /// hundreds of ms later and steal focus back from a single attempt.
    /// The window floats for the whole ladder, then returns to normal level.
    private func scheduleSettingsRelease() {
        SettingsWindowController.shared.refocus()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            SettingsWindowController.shared.refocus()
            try? await Task.sleep(for: .milliseconds(500))
            SettingsWindowController.shared.refocus()
            SettingsWindowController.shared.releaseAfterDrag()
        }
    }
}
