// ItemPress.swift
// Opens a menu bar item's menu in place, hidden or not. An item on the bar is
// clicked where it sits. A concealed one is brought back on its own beneath
// a cover (its section stays concealed, nothing else reflows), clicked with
// a shielded HID click at its centre, kept revealed until what the click
// showed is gone, and put back under a cover of its own through the
// engine's conceal. An item behind the native « is reached by expanding it
// for the press.
//
// The cover hides the reveal and the click, then lifts: the real icon shows
// highlighted with its menu dropping from it (`pressCoverLiftsAfterClick`).
//
// Always a click, never an AX press: a press left a SwiftUI menu bar extra's
// button stuck highlighted (a capsule behind the glyph that survived
// relaunches, 2026-09-21), and the system's hosts and modules took it and
// did nothing. The cover above the bar ignores mouse events, so the click
// reaches the item beneath it.
//
// Pelmet's own extras are not clicked at all: their action runs directly
// (`pressOwn`), the one their button runs on a click. A click on our own
// status item put the main thread in our own menu tracking, so the relay's
// log and oracles stalled until the menu closed, and a cover, a shield and
// a pointer warp had nothing to hide.
//
// One relay at a time: a press that arrives while an earlier one still waits
// on its menu makes that one yield, then runs. A yield is a flag, never a
// task cancellation: a cancelled task's sleeps return at once, which cut a
// click short between its down and up, and a relay that has started always
// puts back what it brought.

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class ItemPress {
    enum Button {
        case primary
        /// The right click: the menu an item keeps for it.
        case secondary
    }

    /// How a press showed something, for the log and for the wait for it to
    /// be gone: the way it showed is the way it is checked undone.
    private enum Sign: String {
        case window = "a window"
        case ownWindow = "its own window"
        case appInFront = "its app in front"
    }

    /// One relay. `yielded` is set by the press that supersedes it.
    private final class Run {
        private(set) var yieldedAt: Date?
        var task: Task<Void, Never>?
        var yielded: Bool { yieldedAt != nil }

        func yield() {
            if yieldedAt == nil { yieldedAt = Date() }
        }

        /// A wait's deadline, cut short once the relay has yielded: the
        /// next press is waiting on it.
        func capped(_ deadline: Date) -> Date {
            yieldedAt.map { min(deadline, $0.addingTimeInterval(AppTiming.pressYieldWait)) } ?? deadline
        }
    }

    /// What the window oracles need from the screens, read on the main
    /// actor so the window list can be walked off it.
    private nonisolated struct Geometry: Sendable {
        let barBottom: CGFloat
        let screenWidth: CGFloat
    }

    private nonisolated struct WindowCounts: Sendable {
        /// Elevated windows that are not Pelmet's (a menu, a popover).
        var elevated = 0
        /// Windows of the item's own app.
        var own = 0
    }

    private weak var appState: AppState?
    private var current: Run?
    /// A relay is on the bar (locating, revealing, clicking, putting back).
    var isRunning: Bool { current != nil }

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Entry

    func open(_ id: ItemID, button: Button) {
        let requested = Date()
        let previous = current
        if let previous {
            PelmetLog.log("press: \(id.sectionKey.rawValue) — the running relay yields")
            previous.yield()
        }
        let run = Run()
        current = run
        let after = previous?.task
        run.task = Task { @MainActor [weak self] in
            await after?.value
            await self?.relay(id.sectionKey, button: button, requested: requested, run: run)
            if self?.current === run { self?.current = nil }
        }
    }

    // MARK: - Relay

    /// Locate the item, reveal it alone if it is concealed, click it, wait
    /// its menu out, put it back.
    private func relay(_ key: ItemID, button: Button, requested: Date, run: Run) async {
        guard let appState else { return }
        func ms() -> Int { Int(-requested.timeIntervalSinceNow * 1000) }
        // A relay superseded before it started leaves the bar alone: a
        // cover, a reveal and a conceal for nothing would only flash.
        guard !run.yielded else {
            PelmetLog.log("press: \(key.rawValue) — superseded before it started")
            return
        }
        if key.bundleID == PelmetBundle.mainID,
           let need = appState.ownPressNeed(key, secondary: button == .secondary) {
            await pressOwn(key, need: need, button: button, requested: requested, run: run)
            return
        }
        guard !appState.applying else {
            PelmetLog.log("press: \(key.rawValue) refused — an Apply pass has the bar")
            return
        }
        // A reveal or conceal in flight gives false frames and a bar that is
        // about to change under the click.
        let settleBy = Date().addingTimeInterval(AppTiming.pressTransitionWait)
        while appState.isTransitioning, Date() < settleBy, !run.yielded {
            try? await Task.sleep(for: .milliseconds(30))
        }

        // A walk of its own, never the mirror: it can be 30s old, and a
        // width change since (a growing meter, the camera pill) puts the
        // frames where the click would land on a neighbour.
        var snap = await appState.engine.freshSnapshot()
        var onBar = Self.onBar(key, in: snap)
        if onBar == nil, key.bundleID == PelmetBundle.mainID {
            // Pelmet's own items hide by their own visibility, not the
            // assertion: out of the AX tree and out of the concealed set
            // while their section is concealed, and an item-only reveal
            // brings nothing back. Their section opens as the hotkey would
            // open it, and the item is clicked where it lands.
            appState.showItemInBar(key)
            let by = Date().addingTimeInterval(AppTiming.pressTransitionWait)
            while appState.isTransitioning, Date() < by, !run.yielded {
                try? await Task.sleep(for: .milliseconds(30))
            }
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            if let found = await settledItem(key, run: run) { snap = found.snap; onBar = found.item }
        }
        let concealed = snap.concealed.contains { $0.sectionKey == key }
        guard onBar != nil || concealed else {
            PelmetLog.log("press: \(key.rawValue) — not on the bar, \(ms())ms")
            return
        }
        guard !run.yielded else {
            PelmetLog.log("press: \(key.rawValue) — superseded before it started")
            return
        }
        let revealsItem = onBar == nil
        var trapped = onBar != nil && ApplyPass.trapped(snap).contains(key)
        PelmetLog.log("press: \(key.rawValue) (\(button == .secondary ? "secondary" : "primary")) — \(revealsItem ? "concealed, revealed alone" : trapped ? "behind the «" : "on the bar")")

        // Only a bar that is about to change needs hiding: an item at rest
        // on the bar is clicked as it is. The transitions are told the bar
        // is held, so no idle picture is taken of it meanwhile.
        let transitions = appState.transitions
        let changesBar = revealsItem || trapped
        var cover: TransitionCoordinator.BlinkCover?
        if changesBar {
            transitions.pressBegan()
            cover = await transitions.beginBarCover(label: "press")
        }
        var target = onBar
        var revealed = false
        var toggle: OverflowToggle.Toggle?
        // Unhighlighted, with nothing of its own open: the item can be
        // pictured as the bar draws it.
        var atRest = false
        if changesBar, !run.yielded {
            if revealsItem {
                revealed = true
                await appState.engine.reveal(items: [key])
                appState.updateSnapshot(await appState.engine.snapshot())
                let found = await settledItem(key, run: run)
                target = found?.item
                if let found {
                    snap = found.snap
                    trapped = ApplyPass.trapped(snap).contains(key)
                }
                PelmetLog.log("press: \(key.rawValue) revealed at \(ms())ms (\(found?.walks ?? 0) walk(s)\(found?.settled == false ? ", frame still moving" : ""))")
            }
            if trapped {
                toggle = await OverflowToggle.expandForPass()
                if toggle != nil, let found = await settledItem(key, run: run) { target = found.item }
            }
        }

        if run.yielded {
            PelmetLog.log("press: \(key.rawValue) — superseded before the click, \(ms())ms")
        } else if trapped, toggle == nil {
            // The frame is the « 's phantom: a click there lands on a neighbour.
            PelmetLog.log("press: \(key.rawValue) — behind the « and it would not expand, not clicked, \(ms())ms")
        } else if let target, let frame = target.frame {
            let geometry = Self.geometry()
            let before = await Self.counts(pid: target.pid, geometry: geometry)
            let wasFront = Self.isFrontmost(target.pid)
            await ItemMover.shieldedClick(
                at: CGPoint(x: frame.midX, y: frame.midY),
                button: button == .secondary ? .right : .left
            )
            PelmetLog.log("press: \(key.rawValue) clicked at \(ms())ms\(toggle == nil ? "" : " (« expanded)")")
            // The reveal and the click are behind the cover; from here the
            // real icon shows, highlighted, with its menu dropping from it.
            if AppTiming.pressCoverLiftsAfterClick, toggle == nil, let lifting = cover {
                lifting.dismiss()
                cover = nil
                PelmetLog.log("press: \(key.rawValue) cover lifted at \(ms())ms")
            }
            let sign = await waitForSign(over: before, pid: target.pid, geometry: geometry, frontCounts: !wasFront, run: run)
            PelmetLog.log("press: \(key.rawValue) \(sign.map { "showed \($0.rawValue)" } ?? "showed nothing") at \(ms())ms")
            // An item that was never put away has nothing to wait for.
            if let sign, revealed || toggle != nil {
                atRest = await waitUntilGone(key, sign: sign, pid: target.pid, before: before, geometry: geometry, run: run, elapsed: ms)
            } else {
                atRest = sign == nil
            }
        } else {
            PelmetLog.log("press: \(key.rawValue) — not on screen, \(ms())ms")
        }

        if revealed || toggle != nil {
            // Put back under a cover of its own: the one from the reveal was
            // lifted for the menu, or has run out its safety by now.
            cover?.dismiss()
            cover = await transitions.beginBarCover(label: "press")
            // The panel's picture of it, as it looks now its menu is gone,
            // filmed under the cover. Not at the cap: still open, the item
            // is drawn highlighted.
            if revealed, toggle == nil, atRest, !run.yielded, let frame = target?.frame, appState.revealTarget.panelLayout != nil {
                await appState.panelPresenter.repicture(key, frame: frame)
            }
            if let toggle { await OverflowToggle.collapseAfterPass(toggle) }
            if revealed {
                await appState.engine.conceal(items: [key])
                appState.updateSnapshot(await appState.engine.snapshot())
            }
            if let cover {
                transitions.endBarCover(cover, label: "press") { transitions.pressEnded() }
            } else {
                transitions.pressEnded()
            }
        } else {
            cover?.dismiss()
            if changesBar { transitions.pressEnded() }
        }
        PelmetLog.log("press: \(key.rawValue) done at \(ms())ms")
    }

    // MARK: - Own items

    /// One of Pelmet's own extras: its action runs here, as its button would
    /// run it. No cover, no shield, no window oracles. A menu needs the item
    /// on the bar to anchor, so its section opens first (the item then stays
    /// out for the rehide machine, as after a hotkey); the camera's pill
    /// needs the camera live, which no reveal changes. The log line comes
    /// before the call: a menu holds the main thread in its tracking until
    /// it closes.
    private func pressOwn(
        _ key: ItemID, need: ExtrasManager.PressNeed, button: Button, requested: Date, run: Run
    ) async {
        guard let appState else { return }
        func ms() -> Int { Int(-requested.timeIntervalSinceNow * 1000) }
        let secondary = button == .secondary
        switch need {
        case .nothing:
            break
        case .live:
            guard appState.isOwnExtraShowing(key) else {
                PelmetLog.log("press: \(key.rawValue) — not live, nothing to open, \(ms())ms")
                return
            }
        case .onBar:
            if !appState.isOwnExtraShowing(key) {
                guard !appState.applying else {
                    PelmetLog.log("press: \(key.rawValue) refused — an Apply pass has the bar")
                    return
                }
                appState.showItemInBar(key)
                let by = Date().addingTimeInterval(AppTiming.pressTransitionWait)
                while appState.isTransitioning, Date() < by, !run.yielded {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                guard !run.yielded else {
                    PelmetLog.log("press: \(key.rawValue) — superseded before it started, \(ms())ms")
                    return
                }
            }
        }
        // An item that stayed out of the bar (its rule keeps it hidden) pops
        // its menu at the pointer.
        let anchored = need != .onBar || appState.isOwnExtraShowing(key)
        PelmetLog.log("press: \(key.rawValue) (\(secondary ? "secondary" : "primary")) own action at \(ms())ms\(anchored ? "" : ", not on the bar: menu at the pointer")")
        let ran = appState.activateExtra(key, secondary: secondary)
        PelmetLog.log("press: \(key.rawValue) own action \(ran ? "returned" : "not found") at \(ms())ms")
    }

    /// Hold the item revealed until what the click showed is undone: the
    /// windows are back to the count before, or the app is no longer in
    /// front. Concealing under an open popover orphans it (the item's button
    /// stays highlighted in the bar until the app is clicked again). "In
    /// front" alone is a weak sign — an app can stay in front after its
    /// popover closed — so it is capped short. A yielded relay waits
    /// `pressYieldWait` at most, the press behind it is waiting.
    /// True when it went: false at the cap or when a later press took over.
    @discardableResult
    private func waitUntilGone(
        _ key: ItemID, sign: Sign, pid: pid_t, before: WindowCounts, geometry: Geometry,
        run: Run, elapsed ms: () -> Int
    ) async -> Bool {
        let cap = Date().addingTimeInterval(sign == .appInFront ? AppTiming.pressFrontCap : AppTiming.pressMenuCap)
        while Date() < run.capped(cap) {
            let still: Bool
            switch sign {
            case .window: still = await Self.counts(pid: pid, geometry: geometry).elevated > before.elevated
            case .ownWindow: still = await Self.counts(pid: pid, geometry: geometry).own > before.own
            case .appInFront: still = Self.isFrontmost(pid)
            }
            if !still {
                PelmetLog.log("press: \(key.rawValue) gone at \(ms())ms")
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        PelmetLog.log("press: \(key.rawValue) given up at \(ms())ms\(run.yielded ? " (yielded)" : " (cap)")")
        return false
    }

    // MARK: - Locating

    /// The item's copy on the primary bar when the walk carries several
    /// (another display's bar has its own), with a frame.
    private static func onBar(_ key: ItemID, in snap: EngineSnapshot) -> ObservedItem? {
        let maxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        let copies = snap.items.filter { $0.id.sectionKey == key && $0.frame != nil }
        return copies.first { $0.frame.map { PlacementGeometry.isPrimary($0, screenMaxX: maxX) } ?? false }
            ?? copies.first
    }

    /// The item once its frame has stopped moving: the agent slides a
    /// revealed icon in, and a click aimed at a frame read mid-slide lands
    /// beside it. Walks until two in a row agree, bounded by
    /// `pressFrameCap`; the last frame read stands if it never settles.
    private func settledItem(_ key: ItemID, run: Run) async -> (item: ObservedItem, snap: EngineSnapshot, walks: Int, settled: Bool)? {
        guard let appState else { return nil }
        let by = Date().addingTimeInterval(AppTiming.pressFrameCap)
        let tolerance = AppTiming.pressFrameTolerance
        var last: (item: ObservedItem, snap: EngineSnapshot)?
        var walks = 0
        while !run.yielded {
            let snap = await appState.engine.freshSnapshot()
            walks += 1
            if let item = Self.onBar(key, in: snap), let frame = item.frame {
                if let before = last?.item.frame,
                   abs(before.midX - frame.midX) <= tolerance, abs(before.midY - frame.midY) <= tolerance {
                    return (item, snap, walks, true)
                }
                last = (item, snap)
            } else {
                last = nil
            }
            guard Date() < by else { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return last.map { ($0.item, $0.snap, walks, false) }
    }

    // MARK: - Oracles

    /// Polls for an elevated window beyond `before`, a new window of the
    /// item's own app, or that app coming to the front (a popover activates
    /// it), within the menu wait. A yielded relay stops waiting after
    /// `pressYieldWait`: the click is already out and the item must not be
    /// put back under a menu that is still opening.
    private func waitForSign(over before: WindowCounts, pid: pid_t, geometry: Geometry, frontCounts: Bool, run: Run) async -> Sign? {
        let showBy = Date().addingTimeInterval(AppTiming.pressMenuWait)
        while Date() < run.capped(showBy) {
            try? await Task.sleep(for: .milliseconds(30))
            let now = await Self.counts(pid: pid, geometry: geometry)
            if now.elevated > before.elevated { return .window }
            if now.own > before.own { return .ownWindow }
            if frontCounts, Self.isFrontmost(pid) { return .appInFront }
        }
        return nil
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        pid > 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func geometry() -> Geometry {
        Geometry(
            barBottom: NSScreen.screens.first.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24,
            screenWidth: NSScreen.screens.first?.frame.width ?? 1440
        )
    }

    /// One walk of the window list, off the main actor, for both oracles.
    ///
    /// Elevated: windows on screen that are not Pelmet's — a menu, a
    /// popover, a panel the press opened — counted so the relay knows when
    /// the press has shown something and when that something is gone. Not
    /// keyed on the owner: a system extra's panel belongs to another
    /// process. Ordinary document windows (layer 0) and the bar's own
    /// layer are not it.
    ///
    /// Own: every on-screen window of `pid` but a bar row, whatever its
    /// level or shape. A status item has no window of its own on macOS 27:
    /// anything taller than a bar row is a popover or panel, whatever level
    /// it sits at, and a press that opens one raises the count by one.
    @concurrent
    private static func counts(pid: pid_t, geometry: Geometry) async -> WindowCounts {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return WindowCounts() }
        let me = ProcessInfo.processInfo.processIdentifier
        var counts = WindowCounts()
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
            else { continue }
            if pid > 0, owner == pid, height > 40 { counts.own += 1 }
            guard owner != me else { continue }
            // A system popover can sit at the bar's own level (layer 25,
            // 1131pt tall): the bar's level is excluded only at the bar's
            // height.
            if layer > 0, layer != 25 || height > 60 {
                counts.elevated += 1
            } else if layer == 0, height > 40, width < geometry.screenWidth * 0.6, y >= 0, y <= geometry.barBottom + 60 {
                // A popover at the normal level: its top sits between the
                // bar and 60pt below it (its bounds carry a margin), and it
                // is nowhere near a document window's width.
                counts.elevated += 1
            }
        }
        return counts
    }
}
