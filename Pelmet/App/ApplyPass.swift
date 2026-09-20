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

    static func plan(for appState: AppState, snapshot snap: EngineSnapshot) -> MovePlan.Plan {
        let frames = primaryFrames(snap)
        let bar = barOrder(frames)
        let chevron = appState.pelmetChevronItem(in: snap)?.id.sectionKey
        let pinned = Set(bar.filter { PlacementController.isProtectedSystemItem($0) || appState.isImmovable($0) })
        // Anchors among Pelmet's own items: the chevron (passed separately)
        // and the separators — they are boundaries. Extras, replicas and
        // launchers drag like any icon until M2 places own items by
        // registration (docs/CORE-SETS.md); a Siri edit planned nothing
        // and logged `skip … (ownItem)` (2026-09-20 16:12).
        let own = Set(bar.filter { $0.isPelmetSeparator })
        return MovePlan.compute(
            bar: bar,
            edits: appState.settings.orderEdits,
            roster: appState.settings.sectionModel.roster,
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

    /// Runs the whole pass. The caller owns `applying` and the report.
    static func run(appState: AppState) async -> ApplyReport {
        let engine = appState.engine
        var report = ApplyReport()
        let edits = appState.settings.orderEdits
        let screenMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude

        // Hidden items have frames only under a reveal; tidy needs every
        // section live. Reveal everything and let the editor hold it.
        let needsReveal = edits.tidy || edits.order.keys.contains { $0 != .visible }
        if needsReveal, !appState.currentRevealedSections.isSuperset(of: [.hidden, .alwaysHidden]) {
            appState.reveal([.hidden, .alwaysHidden], reason: .settingsPreview)
            try? await Task.sleep(for: AppTiming.tidyRevealWait)
        }

        var snap = await engine.snapshot()
        appState.updateSnapshot(snap)
        let plan = plan(for: appState, snapshot: snap)
        report.planned = plan.moves.count
        report.skipped = plan.skipped.map { ApplyReport.Skipped(item: $0.0, why: $0.1) }
        PelmetLog.log("apply: plan \(plan.moves.count) move(s), \(plan.skipped.count) skipped\(edits.tidy ? ", tidy" : "")")
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
            PelmetLog.log("apply: \(move.item.rawValue) landed at x=\(frames[move.item]?.midX ?? -1) verified=\(landed)")
            if landed { report.applied.append(move.item) } else { report.failed.append(move.item) }
        }
        return report
    }
}
