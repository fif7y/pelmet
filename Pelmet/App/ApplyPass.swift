// ApplyPass.swift
// M1 of the sets core (docs/CORE-SETS.md): the one door through which
// Pelmet moves a bar item. Reads the bar, asks `MovePlan` for the fewest
// drags, waits for the pointer to be idle, then performs each `Move` as one
// shielded ⌘-drag (cursor hidden, physical input swallowed — `ItemMover`)
// and verifies the landing by order. Reports per item; failed moves stay
// pending so the button can offer Retry.

import AppKit
import PelmetCore
import PelmetEngine

struct ApplyReport: Equatable {
    struct Skipped: Equatable {
        let item: ItemID
        let why: MovePlan.Skip
    }
    var applied: [ItemID] = []
    var failed: [ItemID] = []
    var skipped: [Skipped] = []
    var planned = 0
}

@MainActor
enum ApplyPass {
    /// A host the agent pins to the trailing cluster, or a system module.
    /// The input menu is movable; it must not become the trailing clamp
    /// when the agent re-registers it to the left of the chevron.
    static func isProtectedSystemItem(_ id: ItemID) -> Bool {
        if id.bundleID == PelmetBundle.textInputAgentID { return false }
        return MenuBarPolicy.isPositionPinnedAppleBundle(id.bundleID) || id.isSystemModule
    }

    /// Primary-band frames by canonical key, leftmost representative per
    /// key (title-variant twins collapse the same way the editor does).
    static func primaryFrames(_ snap: EngineSnapshot) -> [ItemID: CGRect] {
        let maxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        var frames: [ItemID: CGRect] = [:]
        for item in snap.items {
            guard let f = item.frame, PlacementGeometry.isPrimary(f, screenMaxX: maxX) else { continue }
            let key = item.id.sectionKey
            if let existing = frames[key], existing.minX <= f.minX { continue }
            frames[key] = f
        }
        // Items the native « holds report overlapping phantom frames (one
        // shared minX, or staggered a few points apart; see
        // `PlacementGeometry.overflowTrapped`). They are not on screen:
        // dragging them "bounced" and marked Velja immovable (20:43,
        // 2026-09-20); staggered ones slipped through and every Apply
        // aimed into the « (13:36, 2026-09-21). Drop them here so no
        // plan, count or verify sees them.
        for key in trappedKeys(in: frames) { frames.removeValue(forKey: key) }
        return frames
    }

    /// Keys whose primary-band frame overlaps another's: the «'s phantom,
    /// on the bar but not on screen.
    private static func trappedKeys(in frames: [ItemID: CGRect]) -> Set<ItemID> {
        let entries = Array(frames)
        return Set(PlacementGeometry.overflowTrapped(entries.map(\.value)).map { entries[$0].key })
    }

    /// Items behind the « right now, by canonical key.
    static func trapped(_ snap: EngineSnapshot) -> Set<ItemID> {
        let maxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        var frames: [ItemID: CGRect] = [:]
        for item in snap.items {
            guard let f = item.frame, PlacementGeometry.isPrimary(f, screenMaxX: maxX) else { continue }
            let key = item.id.sectionKey
            if let existing = frames[key], existing.minX <= f.minX { continue }
            frames[key] = f
        }
        return trappedKeys(in: frames)
    }

    /// Drawn entries the plan skipped as notOnScreen that are not on the bar
    /// at all (the app quit, the icon left): nothing to wait for, so they
    /// leave the report — or Apply stays lit on "1 not moved" forever
    /// (Sconce, 13:46 2026-09-21). Icons behind the « stay: they are on the
    /// bar and a later pass reaches them.
    static func dropAbsentSkips(_ report: inout ApplyReport, snap: EngineSnapshot) {
        let onBar = Set(snap.items.map { $0.id.sectionKey })
        let absent = report.skipped.filter { $0.why == .notOnScreen && !onBar.contains($0.item.sectionKey) }
        guard !absent.isEmpty else { return }
        for skip in absent { PelmetLog.log("apply: \(skip.item.rawValue) is not on the bar — edit dropped") }
        report.skipped.removeAll { skip in absent.contains { $0.item == skip.item } }
    }

    /// Trapped icons a drawn edit names — the only reason a pass expands
    /// the « (Gab, 2026-09-21: never for moves that do not need it).
    static func trappedEdited(_ snap: EngineSnapshot, edits: OrderEdits) -> Set<ItemID> {
        let drawn = Set(edits.order.values.flatMap { $0 })
        return trapped(snap).intersection(drawn)
    }

    /// `primaryFrames` plus the last frame remembered for each item that is
    /// concealed right now — the collapsed-bar view of the whole bar, for
    /// the Apply count (a wrong-side icon lights the button without a
    /// reveal). The pass itself measures live.
    static func rememberedFrames(_ snap: EngineSnapshot, appState: AppState) -> [ItemID: CGRect] {
        var frames = primaryFrames(snap)
        let live = Set(snap.items.map(\.id.sectionKey))
        let chevronNow = appState.pelmetChevronItem(in: snap).flatMap { frames[$0.id.sectionKey]?.midX }
        for id in snap.concealed where !live.contains(id.sectionKey) {
            let key = id.sectionKey
            guard var f = appState.rememberedFrames[key] else { continue }
            // Concealed icons slide with the chevron: re-anchor the frame
            // to where the chevron is now (AppState.rememberedChevronMidX).
            if let now = chevronNow, let then = appState.rememberedChevronMidX[key] {
                f = f.offsetBy(dx: now - then, dy: 0)
            }
            frames[key] = f
        }
        return frames
    }

    /// The bar as `MovePlan` wants it: canonical keys, left to right, only
    /// items with a primary-band frame.
    static func barOrder(_ frames: [ItemID: CGRect]) -> [ItemID] {
        frames.sorted { $0.value.minX < $1.value.minX }.map(\.key)
    }

    static func plan(
        for appState: AppState, snapshot snap: EngineSnapshot, edits: OrderEdits? = nil,
        remembered: Bool = false
    ) -> MovePlan.Plan {
        let frames = remembered ? rememberedFrames(snap, appState: appState) : primaryFrames(snap)
        let bar = barOrder(frames)
        let chevron = appState.pelmetChevronItem(in: snap)?.id.sectionKey
        // The trailing system cluster only pins while it IS the cluster:
        // right of the chevron. A system item the user parked left of it
        // (hidden, or just dropped into Visible in the editor) moves like
        // any icon (Sound, 2026-09-20 16:56 and 17:00).
        let roster = appState.settings.sectionModel.roster
        let chevronMidX = chevron.flatMap { frames[$0]?.midX }
        func inTrailingCluster(_ id: ItemID) -> Bool {
            guard let chevronMidX, let x = frames[id]?.midX else { return roster.section(of: id) == .visible }
            return x > chevronMidX
        }
        // …and only while the roster still wants it there: Sound drawn into
        // Hidden while sitting right of the chevron was skipped as pinned on
        // every pass, "Moved 0" with Apply (1) coming back (2026-09-20 21:03).
        let pinned = Set(bar.filter {
            appState.isImmovable($0)
                || (isProtectedSystemItem($0) && inTrailingCluster($0)
                    && roster.section(of: $0) == .visible)
        })
        // The one anchor is the chevron (passed separately). Every other own
        // item — extras, replicas, launchers, separators — drags like any
        // icon: registration never places an own item (a separator moved to
        // the end of Hidden in the editor re-hosted at the far right and
        // Apply skipped it as an anchor, 2026-09-20 20:19).
        let own = Set<ItemID>()
        return MovePlan.compute(
            bar: bar,
            edits: edits ?? appState.settings.orderEdits,
            roster: roster,
            chevron: chevron,
            pinned: pinned,
            ownItems: own
        )
    }

    /// Seconds since the last physical pointer event (public CGEventSource
    /// counters; our own synthetic events count too, which is fine — the
    /// pass only asks before its first drag).
    private static func secondsSincePointerActivity() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    private static func waitForIdlePointer() async {
        let deadline = Date.now.addingTimeInterval(AppTiming.applyIdleMaxWait)
        while Date.now < deadline {
            if secondsSincePointerActivity() >= AppTiming.applyIdleGap { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        PelmetLog.log("apply: pointer never went idle — proceeding shielded")
    }

    /// Post-drag read that waits for the moved item to stop animating.
    private static func quiesced(_ engine: AgentBarEngine, watching key: ItemID) async -> EngineSnapshot {
        try? await Task.sleep(for: AppTiming.postDragSettleFloor)
        let started = ContinuousClock.now
        var snap = await engine.snapshot()
        var matches = 0
        while matches < AppTiming.postDragQuiesceMatches,
              started.duration(to: .now) < AppTiming.postDragQuiesceCap {
            try? await Task.sleep(for: AppTiming.postDragQuiescePoll)
            let next = await engine.snapshot()
            matches = primaryFrames(next)[key] == primaryFrames(snap)[key] ? matches + 1 : 0
            snap = next
        }
        return snap
    }

    /// What a pass covers.
    enum Scope {
        /// The Apply button: the whole bar, revealed for measuring.
        case wholeBar
        /// One own item that just entered the bar (a camera indicator
        /// lighting up, a launcher's app starting): dragged to its roster
        /// slot among the items already on screen, no reveal. Own items
        /// re-enter at the slot the agent remembers, and a re-registration
        /// under the same tag keeps that slot whatever the order hint says
        /// (probed 2026-09-20), so the one door is the only way to move
        /// them — docs/CORE-SETS.md §Own items.
        case ownItem(ItemID)
    }

    /// Runs the whole pass. The caller owns `applying` and the report.
    static func run(appState: AppState, scope: Scope = .wholeBar) async -> ApplyReport {
        let engine = appState.engine
        var report = ApplyReport()
        let screenMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude

        // Hidden items have frames only under a reveal, and the plan is the
        // whole bar. Reveal everything and let the editor hold it. An own
        // item is placed among what is on screen right now.
        var revealedForPass = false
        if case .wholeBar = scope {
            revealedForPass = !appState.currentRevealedSections.isSuperset(of: [.hidden, .alwaysHidden])
        }
        if revealedForPass {
            appState.reveal([.hidden, .alwaysHidden], reason: .settingsPreview)
            try? await Task.sleep(for: AppTiming.tidyRevealWait)
        }
        // What the pass opened, the pass closes (a display set to always
        // show keeps its policy).
        defer { if revealedForPass { appState.applyPointerDisplayPolicyAfterDismissal() } }
        // Separators drawn in another section re-host here, not at the
        // editor drop: a fresh registration on the new helper lands where
        // the agent puts it, and the drag below moves it into its slot.
        if case .wholeBar = scope, appState.rehostSeparatorsForApply() {
            PelmetLog.log("apply: separator host(s) moved to their drawn section")
            try? await Task.sleep(for: AppTiming.applyRehostWait)
        }
        // Idle own extras (camera off, nothing playing) join the layout
        // invisibly so the plan can move them too; they leave with the pass.
        if case .wholeBar = scope {
            let ghosts = appState.attachIdleExtrasForApply()
            if !ghosts.isEmpty {
                PelmetLog.log("apply: \(ghosts.count) idle extra(s) attached for the pass")
                // The agent lays a new item out on its own beat.
                try? await Task.sleep(for: AppTiming.postDragSettleFloor)
            }
        }
        defer { if case .wholeBar = scope { appState.detachIdleExtrasAfterApply() } }

        var snap = await engine.snapshot()
        appState.updateSnapshot(snap)
        // The plan for this scope, re-run on a fresh snapshot after the «
        // expands — the own-item scope must keep its filter there too, or
        // the replan is a whole-bar plan (the new separator behind the «
        // was skipped as notOnScreen for good, 2026-09-21 08:43).
        let planFor: (EngineSnapshot) -> MovePlan.Plan
        // Icons behind the « this pass is about: a whole-bar pass expands
        // for the drawn edits that name one, an own-item pass for its item.
        let trappedFor: (EngineSnapshot) -> Set<ItemID>
        switch scope {
        case .wholeBar:
            planFor = { self.plan(for: appState, snapshot: $0) }
            trappedFor = { trappedEdited($0, edits: appState.settings.orderEdits) }
        case .ownItem(let own):
            // The item's section as the editor draws it counts as the edit,
            // so the plan puts the newcomer between its roster neighbours;
            // only its own move runs, the rest of the bar is not touched.
            let key = own.sectionKey
            let model = appState.settings.sectionModel
            let section = model.section(of: own)
            var edits = appState.settings.orderEdits
            if edits.order[section] == nil {
                edits.order[section] = model.order[section] ?? appState.currentOrder(in: section)
            }
            planFor = { snap in
                var plan = self.plan(for: appState, snapshot: snap, edits: edits)
                plan.moves = plan.moves.filter { $0.item == key }
                plan.skipped = plan.skipped.filter { $0.0 == key }
                return plan
            }
            trappedFor = { trapped($0).contains(key) ? [key] : [] }
        }
        var plan = planFor(snap)
        if case .ownItem(let own) = scope, plan.moves.isEmpty, plan.skipped.isEmpty {
            PelmetLog.log("apply: \(own.sectionKey.rawValue) already in its slot (own)")
            report.applied.append(own.sectionKey)
            return report
        }
        report.planned = plan.moves.count
        report.skipped = plan.skipped.map { ApplyReport.Skipped(item: $0.0, why: $0.1) }
        PelmetLog.log("apply: plan \(plan.moves.count) move(s), \(plan.skipped.count) skipped")
        for (id, why) in plan.skipped {
            PelmetLog.log("apply: skip \(id.rawValue) (\(why))")
        }
        // Icons behind the « that a drawn edit names: the pass expands the
        // « (one shielded click), which gives them frames left of the
        // notch (probed 2026-09-20, drags across the notch land first try),
        // re-plans on the shifted bar, and collapses it after. Never for a
        // pass whose edits stay clear of the «.
        let trappedForPass = trappedFor(snap)
        dropAbsentSkips(&report, snap: snap)
        guard !plan.moves.isEmpty || !trappedForPass.isEmpty else { return report }

        await waitForIdlePointer()
        let holdsSettings = appState.settingsWindowVisible
        if holdsSettings { SettingsWindowController.shared.holdAboveDrag() }
        defer {
            if holdsSettings {
                SettingsWindowController.shared.refocus()
                SettingsWindowController.shared.releaseAfterDrag()
            }
        }

        var expandedToggle: OverflowToggle.Toggle?
        if trappedForPass.isEmpty, case .wholeBar = scope {
            await OverflowToggle.collapseIfLeftExpanded()
        }
        if !trappedForPass.isEmpty {
            PelmetLog.log("apply: \(trappedForPass.count) drawn icon(s) behind the « — expanding it")
            expandedToggle = await OverflowToggle.expandForPass()
            if expandedToggle != nil {
                snap = await engine.snapshot()
                appState.updateSnapshot(snap)
                plan = planFor(snap)
                report.planned = plan.moves.count
                report.skipped = plan.skipped.map { ApplyReport.Skipped(item: $0.0, why: $0.1) }
                dropAbsentSkips(&report, snap: snap)
                let framed = trappedForPass.filter { primaryFrames(snap)[$0] != nil }.count
                PelmetLog.log("apply: « expanded — \(framed)/\(trappedForPass.count) framed, replanned \(plan.moves.count) move(s), \(plan.skipped.count) skipped")
            } else {
                PelmetLog.log("apply: « not expanded — trapped icons stay skipped")
            }
        }
        // Not a defer: the collapse click needs the shielded door, so it
        // runs after the drags, before the report leaves.
        let moves = plan.moves
        await performMoves(moves, appState: appState, engine: engine, screenMaxX: screenMaxX, report: &report)
        if let expandedToggle {
            await OverflowToggle.collapseAfterPass(expandedToggle)
        }
        return report
    }

    private static func performMoves(
        _ moves: [Move], appState: AppState, engine: AgentBarEngine,
        screenMaxX: CGFloat, report: inout ApplyReport
    ) async {
        var snap = await engine.snapshot()
        for move in moves {
            snap = await engine.snapshot()
            appState.updateSnapshot(snap)
            var frames = primaryFrames(snap)
            guard let frame = frames[move.item] else {
                PelmetLog.log("apply: \(move.item.rawValue) has no frame — skipped")
                report.skipped.append(.init(item: move.item, why: .notOnScreen))
                continue
            }
            func bounds(_ frames: [ItemID: CGRect]) -> (left: CGRect?, right: CGRect?) {
                (move.after.flatMap { frames[$0] }, move.before.flatMap { frames[$0] })
            }
            func inSlot(_ frames: [ItemID: CGRect]) -> Bool {
                guard let x = frames[move.item]?.midX else { return false }
                let b = bounds(frames)
                return PlacementGeometry.inSlot(x: x, leftMidX: b.left?.midX, rightMidX: b.right?.midX)
            }
            func aim(_ frames: [ItemID: CGRect]) -> CGFloat? {
                let b = bounds(frames)
                let width = frames[move.item]?.width ?? frame.width
                switch (b.left, b.right) {
                case let (l?, r?): return PlacementGeometry.betweenCentersX(left: l, right: r, screenMaxX: screenMaxX)
                case let (l?, nil): return min(l.maxX + width / 2 + 2, screenMaxX - 60)
                case let (nil, r?): return max(r.minX - width / 2 - 2, 200)
                case (nil, nil): return nil
                }
            }
            // An earlier move's reflow can have settled this one already.
            if inSlot(frames), move.after == nil || frames[move.after!] != nil, move.before == nil || frames[move.before!] != nil {
                PelmetLog.log("apply: \(move.item.rawValue) already in slot")
                report.applied.append(move.item)
                continue
            }
            guard let targetX = aim(frames) else {
                PelmetLog.log("apply: \(move.item.rawValue) has no live neighbour to aim at — failed")
                report.failed.append(move.item)
                continue
            }
            guard MenuBarGeometry.isInBand(frame), frame.midX > 0, frame.midX < screenMaxX else {
                PelmetLog.log("apply: \(move.item.rawValue) frame outside the band (\(frame)) — failed")
                report.failed.append(move.item)
                continue
            }
            PelmetLog.log("apply: drag \(move.item.rawValue) x=\(frame.midX) → \(targetX) (after \(move.after?.rawValue ?? "-"), before \(move.before?.rawValue ?? "-"))")
            let ownItem = move.item.bundleID.map(PelmetBundle.ownIDs.contains) ?? false
            await ItemMover.cmdDrag(from: CGPoint(x: frame.midX, y: 12), to: CGPoint(x: targetX, y: 12), ownItem: ownItem)
            snap = await quiesced(engine, watching: move.item)
            appState.updateSnapshot(snap)
            frames = primaryFrames(snap)
            var landed = inSlot(frames)
            // One retry, re-aimed at the bounds as they sit after the reflow.
            if !landed, let x = frames[move.item]?.midX, let retryX = aim(frames), abs(retryX - x) > 4 {
                PelmetLog.log("apply: retry \(move.item.rawValue) x=\(x) → \(retryX)")
                await ItemMover.cmdDrag(from: CGPoint(x: x, y: 12), to: CGPoint(x: retryX, y: 12), ownItem: ownItem)
                snap = await quiesced(engine, watching: move.item)
                appState.updateSnapshot(snap)
                frames = primaryFrames(snap)
                landed = inSlot(frames)
            }
            let finalX = frames[move.item]?.midX ?? -1
            PelmetLog.log("apply: \(move.item.rawValue) landed at x=\(finalX) verified=\(landed)")
            if landed {
                report.applied.append(move.item)
                continue
            }
            // Both drags landed back at the start: the item swallowed them
            // (OpenClip, 2026-09-20 18:54, two passes). Same bounce budget as
            // placement; once marked immovable it is a bound, not a failure —
            // the edit can clear instead of offering Retry forever.
            if !ownItem, move.item.bundleID != nil, abs(finalX - frame.midX) < 0.5,
               appState.noteBounce(move.item, at: finalX) {
                report.skipped.append(.init(item: move.item, why: .pinned))
            } else {
                report.failed.append(move.item)
            }
        }
    }
}
