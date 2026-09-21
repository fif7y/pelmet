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
        return frames
    }

    /// The bar as `MovePlan` wants it: canonical keys, left to right, only
    /// items with a primary-band frame.
    static func barOrder(_ frames: [ItemID: CGRect]) -> [ItemID] {
        frames.sorted { $0.value.minX < $1.value.minX }.map(\.key)
    }

    static func plan(for appState: AppState, snapshot snap: EngineSnapshot, edits: OrderEdits? = nil) -> MovePlan.Plan {
        let frames = primaryFrames(snap)
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
        let pinned = Set(bar.filter {
            appState.isImmovable($0)
                || (PlacementController.isProtectedSystemItem($0) && inTrailingCluster($0))
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
        var plan: MovePlan.Plan
        switch scope {
        case .wholeBar:
            plan = self.plan(for: appState, snapshot: snap)
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
            plan = self.plan(for: appState, snapshot: snap, edits: edits)
            plan.moves = plan.moves.filter { $0.item == key }
            plan.skipped = plan.skipped.filter { $0.0 == key }
            if plan.moves.isEmpty, plan.skipped.isEmpty {
                PelmetLog.log("apply: \(key.rawValue) already in its slot (own)")
                report.applied.append(key)
                return report
            }
        }
        report.planned = plan.moves.count
        report.skipped = plan.skipped.map { ApplyReport.Skipped(item: $0.0, why: $0.1) }
        PelmetLog.log("apply: plan \(plan.moves.count) move(s), \(plan.skipped.count) skipped")
        for (id, why) in plan.skipped {
            PelmetLog.log("apply: skip \(id.rawValue) (\(why))")
        }
        guard !plan.moves.isEmpty else { return report }

        await waitForIdlePointer()
        let holdsSettings = appState.settingsWindowVisible
        if holdsSettings { SettingsWindowController.shared.holdAboveDrag() }
        defer {
            if holdsSettings {
                SettingsWindowController.shared.refocus()
                SettingsWindowController.shared.releaseAfterDrag()
            }
        }

        for move in plan.moves {
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
        return report
    }
}
