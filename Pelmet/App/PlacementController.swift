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
    private let engine: EngineGoldenGate

    init(appState: AppState, engine: EngineGoldenGate) {
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
        return MenuBarPolicy.isUnmanagedAppleBundle(id.bundleID) || id.isSystemModule
    }

    // MARK: - Physical placement (synthetic ⌘-drag)

    /// Returns true when the icon was dragged into place (or verified already
    /// there) — false when placement had to be skipped (no frame, nothing to
    /// measure against), so callers can keep it queued for a retry.
    @discardableResult
    func physicallyPlace(_ id: ItemID, in section: PelmetCore.Section) async -> Bool {
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

    /// Routed-but-not-yet-placed newcomers. A new icon spawns at the far left
    /// of the VISIBLE-at-that-moment items — but concealed cluster members
    /// rematerialize around it on reveal, stranding it mid-cluster (Figma
    /// landed between always-hidden icons). Placement into a concealed
    /// section can't be measured, so it waits here until a reveal gives the
    /// section live frames.
    var pendingPlacements: Set<ItemID> = []

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
            while let id = pendingPlacements.subtracting(attempted).sorted(by: { $0.rawValue < $1.rawValue }).first {
                attempted.insert(id)
                pendingPlacements.remove(id)
                guard let appState else { return }
                let section = appState.settings.sectionModel.section(of: id)
                // Held for the hidden cluster to materialize (see the
                // hidden-zone rule in physicallyPlaceNow): don't burn a
                // lookup wait on it until a reveal makes the drag safe.
                if deferredForReveal.contains(id),
                   !appState.currentRevealedSections.contains(.hidden) {
                    pendingPlacements.insert(id)
                    continue
                }
                if let after = framelessRetryAfter[id], after > .now {
                    pendingPlacements.insert(id)
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
                guard section == .visible
                    || appState.revealedSectionsForExtras.contains(section) else {
                    pendingPlacements.insert(id)
                    continue
                }
                PelmetLog.log("place: attempting \(id.rawValue) (section \(section))")
                let placed = await physicallyPlace(id, in: section)
                if placed {
                    // A verified reveal-time placement ends any rescue
                    // ping-pong — the item is truly in its slot.
                    rescueAttempts.removeValue(forKey: id)
                    frameless.removeValue(forKey: id)
                    framelessRetryAfter.removeValue(forKey: id)
                } else if let since = frameless[id] {
                    // No frame at all. If its section is on screen right now
                    // the registration is parked — ask for an adoption
                    // window (rate-limited per bundle), and retry slowly.
                    framelessRetryAfter[id] = .now.addingTimeInterval(Self.framelessRetryInterval)
                    let onScreen = section == .visible || appState.currentRevealedSections.contains(section)
                    if onScreen, let bundle = id.bundleID, bundle != PelmetBundle.mainID,
                       Date.now.timeIntervalSince(since) > 2,
                       (readoptRequested[bundle].map { Date.now.timeIntervalSince($0) > Self.readoptInterval } ?? true) {
                        readoptRequested[bundle] = .now
                        PelmetLog.log("place: \(id.rawValue) has had no frame for \(Int(Date.now.timeIntervalSince(since)))s while its section is on screen — asking for an adoption window")
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
                if !placed, !pendingRescues.contains(id) {
                    if deferredForReveal.contains(id) {
                        pendingPlacements.insert(id)
                    } else if MenuBarPolicy.isPelmetExtraID(id), !id.isPelmetSeparator {
                        PelmetLog.log("place: \(id.rawValue) not hosted — dropped from the queue")
                    } else {
                        pendingPlacements.insert(id)
                    }
                }
            }
        }
    }

    /// Items whose last attempt found no frame at all, with the time of the
    /// first such miss. Retried on a slow clock, and once the item should be
    /// visible (its section revealed) the app is asked to re-adopt it.
    private var frameless: [ItemID: Date] = [:]
    private var framelessRetryAfter: [ItemID: Date] = [:]
    private var readoptRequested: [String: Date] = [:]
    private static let framelessRetryInterval: TimeInterval = 30
    private static let readoptInterval: TimeInterval = 120

    /// Placements held until the hidden cluster is materialized: their drag
    /// would touch the hidden zone while its items are absent. Stay queued
    /// (extras included) and try again at the next reveal settle.
    private var deferredForReveal: Set<ItemID> = []

    // MARK: - Order supervisor (wrong side of the chevron)

    /// Per-item correction budget. A correction is a drag under a reveal;
    /// an item that will not stay put after a few of them is left alone for
    /// a while rather than dragged on every hover.
    private var driftAttempts: [ItemID: Int] = [:]
    private var driftCoolOffUntil: [ItemID: Date] = [:]
    private static let maxDriftAttempts = 3
    private static let driftCoolOff: TimeInterval = 8 * 60

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
                  !MenuBarPolicy.isUnmanagedAppleBundle(bundle),
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
        let ownOutOfOrder = OrderDrift.ownItemsOutOfOrder(
            items: measured, model: model, pelmetBundleID: PelmetBundle.mainID
        ).filter { !misplaced.contains($0) }
        return DriftReading(
            chevronMinX: chevron.minX,
            misplaced: misplaced + ownOutOfOrder,
            measuredCount: measured.filter { $0.minX != nil }.count
        )
    }

    /// A verdict needs two agreeing reads: a reveal that follows a conceal
    /// within the same reflow measured the chevron at 1329 and, a second
    /// later, at 1421 (2026-09-09). One read mid-reflow would drag items
    /// that are only passing through.
    private static let driftConfirmDelay: Duration = .milliseconds(400)

    func correctDrift() async {
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
            for id in driftAttempts.keys { driftAttempts.removeValue(forKey: id) }
            PelmetLog.log("drift: none (chevron@\(a.chevronMinX), \(a.measuredCount) measured)")
            return
        }
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
        let misplaced = b.misplaced
        let chevron = CGRect(x: b.chevronMinX, y: 0, width: 0, height: 0)
        // Anything now on its side has earned its budget back.
        for id in driftAttempts.keys where !misplaced.contains(id) {
            driftAttempts.removeValue(forKey: id)
        }
        var queued: [String] = []
        for id in misplaced {
            if let until = driftCoolOffUntil[id], until > .now { continue }
            driftCoolOffUntil.removeValue(forKey: id)
            let attempts = driftAttempts[id, default: 0] + 1
            driftAttempts[id] = attempts
            if attempts > Self.maxDriftAttempts {
                driftCoolOffUntil[id] = .now.addingTimeInterval(Self.driftCoolOff)
                driftAttempts.removeValue(forKey: id)
                PelmetLog.log("drift: \(id.rawValue) would not stay on its side after \(Self.maxDriftAttempts) corrections — leaving it for \(Int(Self.driftCoolOff / 60)) min")
                continue
            }
            pendingPlacements.insert(id)
            queued.append("\(id.rawValue)#\(attempts)")
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
    private(set) var pendingRescues: Set<ItemID> = []
    private var rescueAttempts: [ItemID: Int] = [:]
    private var rescuing = false
    private static let maxRescueAttempts = 3

    private func queueRescue(_ id: ItemID) {
        guard pendingRescues.insert(id).inserted else { return }
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
        pendingRescues.removeAll()
        Task { [weak self] in
            guard let self else { return }
            defer { self.rescuing = false }
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
                pendingRescues.remove(id)
                if placed {
                    // Zone placement only: the section's neighbors are
                    // concealed here, so the target was the chevron fallback
                    // and the in-slot check is vacuous. Queue the EXACT slot
                    // for the next reveal settle, when neighbors have real
                    // frames. Attempts reset there, not here — a reveal that
                    // re-traps the item ping-pongs back to rescue, and the
                    // cap must span the whole cycle.
                    pendingPlacements.insert(id)
                    PelmetLog.log("rescue: \(id.rawValue) zone-placed — exact slot at next reveal settle")
                } else {
                    let attempts = rescueAttempts[id, default: 0] + 1
                    rescueAttempts[id] = attempts
                    if attempts < Self.maxRescueAttempts {
                        pendingRescues.insert(id)
                        PelmetLog.log("rescue: \(id.rawValue) failed (attempt \(attempts)) — requeued")
                    } else {
                        rescueAttempts.removeValue(forKey: id)
                        PelmetLog.log("rescue: \(id.rawValue) gave up after \(attempts) attempts")
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
            MenuBarGeometry.isInBand(f) && f.midX > 0 && f.midX < primaryMaxX
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
        let pelmetBundle = PelmetBundle.mainID
        guard
            let item = liveItem(in: snap),
            let frame = item.frame
        else {
            PelmetLog.log("place: no frame for \(id.rawValue) — skipping physical move (concealed?)")
            if frameless[id] == nil { frameless[id] = .now }
            return false
        }
        frameless.removeValue(forKey: id)
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
        // Trapped-in-overflow check: a trapped registration reports a phantom
        // frame sharing its minX with another item in the same band — real
        // items never share an x (verified 2026-08-21: 8 trapped separators
        // at exactly one x). Dragging from a phantom would grab whatever
        // REALLY sits there — skip and defer to the conceal-settle rescue.
        let phantom = snap.items.contains {
            $0.id != item.id && $0.frame.map {
                abs($0.minX - frame.minX) < 0.5 && abs($0.midY - frame.midY) < 30
            } == true
        }
        if phantom {
            PelmetLog.log("place: \(id.rawValue) frame is a phantom (duplicate minX \(frame.minX)) — trapped in overflow")
            // Expand the native « inline: the trapped item materializes with
            // a real frame and the normal drag proceeds. Only resolvable
            // while Pelmet is frontmost (editor flows) — background placements
            // fall through to the conceal-settle rescue.
            if allowExpansion, await OverflowChevron.expandForPlacement() {
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
        // the "lifted" coordinate space: once the drag picks the item up, the
        // gap it leaves closes, shifting everything right of its origin left
        // by one item width. Targets computed in pre-lift coordinates land one
        // slot off (verified: consistent ±itemWidth misses in the logs).
        // EXCEPT for Pelmet's own items (separators, extras): dragging an
        // own-process item keeps the bar frozen — the gap does NOT close, so
        // lifted targets land one width short and the drop bounces back
        // (verified: raw-frame drop swaps, lifted-frame drop reverts).
        let dragIsPelmetOwned = item.id.bundleID == pelmetBundle
        func lifted(_ neighborFrame: CGRect) -> CGRect {
            guard !dragIsPelmetOwned else { return neighborFrame }
            return neighborFrame.minX > frame.midX
                ? neighborFrame.offsetBy(dx: -frame.width, dy: 0)
                : neighborFrame
        }
        // Neighbors from the GLOBAL desired order, not just the item's own
        // section: at a section boundary the adjacent item belongs to the
        // NEXT cluster, and a one-sided "right.minX - 14" target overshoots
        // into that item's footprint (bar spacing is tighter than 14pt) — the
        // agent then slots the drop one place too far left. Verified: Figma,
        // first-of-Hidden, kept landing left of Always-Hidden's Bitwarden.
        let globalOrder = appState.editorItems(in: .alwaysHidden)
            + appState.editorItems(in: .hidden)
            + appState.editorItems(in: .visible)
        // Canonical comparison: the editor's representative for this bundle
        // may be a different title-variant of the same item.
        let index = isChevron
            ? appState.editorItems(in: .alwaysHidden).count + appState.editorItems(in: .hidden).count
            : globalOrder.firstIndex(where: { $0.id.sectionKey == id.sectionKey }) ?? globalOrder.count
        // Only frames in the SAME menu-bar band as the dragged item are
        // trustworthy: an AX walk can carry another display's bar (its own
        // coordinate origin), and one foreign neighbor frame aimed a drop at
        // x=268 on a status area that starts around x=1050.
        func inBand(_ f: CGRect) -> Bool {
            MenuBarGeometry.isInBand(f)
                && abs(f.midY - frame.midY) < 30
                && f.midX > 0 && f.midX < screen.frame.maxX
        }
        let chevronFrame = rawChevronFrame.flatMap { inBand($0) ? $0 : nil }
        // Keep the neighbor ITEMS, not just their frames — after the drag the
        // landing is verified against them (x-order), because the lifted-gap
        // assumption is not reliable at cluster boundaries (verified: a
        // one-slot boundary drag bounced back — target fell inside the raw
        // footprint of the left neighbor).
        let leftIdx = globalOrder[..<index].lastIndex(where: { primaryFrame(of: $0.id, in: snap).map(inBand) == true })
        let rightIdx = globalOrder[(min(index + 1, globalOrder.count))...].firstIndex(where: { primaryFrame(of: $0.id, in: snap).map(inBand) == true })
        let leftPair = leftIdx.map { globalOrder[$0] }
        let rightPair = rightIdx.map { globalOrder[$0] }
        let leftNeighbor = leftPair?.frame.map(lifted)
        let rightNeighbor = rightPair?.frame.map(lifted)
        // The desired order has no chevron in it, so a LAST-of-Hidden item's
        // right neighbor is the first Visible one — and "between Snib and
        // Sound" holds on BOTH sides of the chevron. The raw retry then aimed
        // at their midpoint (1479, chevron at 1459) and verified true on the
        // wrong side (Figma, 2026-09-09). At the hidden/visible boundary the
        // live chevron caps the slot instead. Mirror for first-of-Visible.
        let alwaysHiddenEnd = appState.editorItems(in: .alwaysHidden).count
        let hiddenEnd = alwaysHiddenEnd + appState.editorItems(in: .hidden).count
        let chevronCapsRight = !isChevron && chevronFrame != nil
            && index >= alwaysHiddenEnd && index < hiddenEnd
            && (rightIdx.map { $0 >= hiddenEnd } ?? true)
        let chevronCapsLeft = !isChevron && chevronFrame != nil
            && index >= hiddenEnd
            && (leftIdx.map { $0 < hiddenEnd } ?? true)
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
        let systemMinX = snap.items
            .filter { Self.isProtectedSystemItem($0.id) }
            .compactMap(\.frame)
            .filter(inBand)
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

        // Skip only when the item is genuinely at its slot already — a full
        // icon-width tolerance silently swallowed every one-slot move. With
        // NO live neighbors the target is a zone-approximate chevron
        // fallback, and chasing it exactly just bounces (rescue drags at
        // conceal hopped 30pt into the chevron and reverted every time).
        let fallbackTarget = leftNeighbor == nil && rightNeighbor == nil
        // With both bounds live the slot is an ORDER: strictly between the
        // bound centers is placed, whatever the x estimate says. Strict, with
        // a margin — a freshly hosted own item can report the very x of its
        // neighbor (Media controls at Sound's 1554, 2026-09-09), and that one
        // must still be dragged. Without both bounds fall back to x proximity.
        let alreadyPlaced: Bool = {
            if let l = leftBound(in: snap), let r = rightBound(in: snap), l.midX < r.midX {
                return l.midX + 2 < frame.midX && frame.midX < r.midX - 2
            }
            return abs(frame.midX - targetX) < (fallbackTarget ? 40 : 10)
        }()
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
           frame.midX < chevron.midX || targetX < chevron.midX {
            PelmetLog.log("place: \(id.rawValue) touches the hidden zone while it is concealed (x=\(frame.midX) → \(targetX), chevron@\(chevron.midX)) — waiting for a reveal")
            deferredForReveal.insert(id)
            return false
        }
        deferredForReveal.remove(id)
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
            if allowExpansion, await OverflowChevron.expandForPlacement() {
                try? await Task.sleep(for: AppTiming.overflowExpandSettle)
                return await physicallyPlaceNow(id, in: section, allowExpansion: false)
            }
            queueRescue(id)
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
