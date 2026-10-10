// PanelPresenter.swift
// The hidden icons as tiles in a glass panel under the chevron, instead of
// on the bar (docs/PANEL-PLAN.md §5 Phase 3). The bar stays concealed the
// whole time: the rehide machine says revealed, this draws it. A tile click
// closes the panel through the machine and opens the item's menu the way
// ⌥⌘K does (ItemPress: alone, under a cover).
//
// Pictures: hidden icons are never drawn on the bar in this mode, so the
// first open with tiles missing one runs the picture pass (decision D2);
// app icons stand in until it lands.

import AppKit
import PelmetCore
import PelmetEngine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class PanelPresenter: RevealPresenter {
    static let cornerRadius: CGFloat = 20
    /// The mock hangs the panel 6pt under the bar and 6pt past the
    /// chevron's right edge.
    static let gapBelowBar: CGFloat = 6
    static let pastChevron: CGFloat = 6

    private weak var appState: AppState?
    let pictures = ItemPictures()
    private var window: KeyableGlassPanel?
    private var hosting: PanelHostingView?
    /// The tracking area's owner, which it does not keep.
    private var pointerWatch: PointerWatch?
    private var gripHost: GripHostingView?
    /// The grip shows faintly while the pointer is on the panel.
    private var pointerOnPanel = false
    /// The columns are being dragged: the pointer runs ahead of the edge,
    /// off the panel, and that must not close it.
    private var draggingColumns = false
    /// A tile is in the air (`TileDrag`): the pointer runs over the bar and
    /// off the panel, and that must not close it.
    private var tileDrag: TileDrag?
    private var dragTimer: Timer?
    private var springTask: Task<Void, Never>?
    /// Esc during a drag: global (a panel a hover opened isn't key and hears
    /// no keys) and local, so a quick tap is not missed between two polls.
    private var escMonitors: [Any] = []
    /// What the drag shows, shared with the view.
    private let dragState = PanelDragState()
    /// Where SwiftUI laid out the sections, grids and fold, in the hosting
    /// view's space; read when the pointer needs a target.
    private var frames: [PanelFrameKey: CGRect] = [:]
    /// The button under a tile fires on the mouse-up that ends a drag too:
    /// no press until this passes (it starts at the release, not at the
    /// cancel).
    private var pressGuardUntil: CFTimeInterval = 0
    /// A drag was cancelled, or refused, with the button still down: the rest
    /// of that press is neither a drag nor a click. Ends at the release (or
    /// the next press).
    private var ignoresDragUntilRelease = false
    /// Mouse down and up, watched from a drag until its button comes up, so a
    /// release SwiftUI never reports (it drops a gesture on a key press) still
    /// ends it.
    private var mouseMonitors: [Any] = []
    /// The Esc that cancelled a drag, or its repeats, still reaches the
    /// panel's own key handler; that must not close the panel.
    private var escSwallowUntil: CFTimeInterval = 0
    private(set) var isOpen = false
    private var openedByHover = false
    /// Opened from the bar under the pointer (hover, a click on the bar):
    /// the pointer's display, not the chevron's.
    private var opensUnderPointer = false
    /// The display it opened on, kept until it closes: a refresh (a key, a
    /// fold, a picture pass) never moves it to another one.
    private var openScreen: CGDirectDisplayID?
    /// Held like a menu until the pointer is on the panel: opened from the
    /// keyboard, or reshaped by its column grip (a drag let go past the
    /// edge, or a reset that shrinks the panel from under the pointer,
    /// would otherwise close it).
    private var awaitsPointer = false
    /// When `place` last changed the window's frame.
    private var resizedAt: CFTimeInterval = 0
    private var sections: Set<PelmetCore.Section> = []
    /// Always Hidden's fold, for this open.
    private var foldOpen = false
    /// The keyboard's filter and selection, for this open.
    private var query = ""
    private var selected: PanelTile?
    /// Set when the query changed: the best match becomes the selection.
    private var selectBest = false
    /// The command bar's candidates, read once per open: the filter ranks
    /// with them (aliases, synonyms), and they name the launchers.
    private var corpus: [CommandBarEntry] = []
    private var history = SearchHistory()
    /// What the last refresh drew, for Return and the arrows.
    private var lastModel: PanelModel?
    private var lastContent: PanelContent?
    /// Whether the panel last scrolled or wrapped, as logged.
    private var loggedFit: String?
    /// Each open from closed: a scrolled panel opens at the top again.
    private var opens = 0
    /// The grip's tip, and the wait before it goes.
    private var columnsTip: String?
    private var tipTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var launcherIcons: [String: NSImage] = [:]
    /// Waiting on the pass under way, the preview's redraw among them.
    private var passWaiters: [@MainActor () -> Void] = []
    private var motion: Motion?
    private var motionTimer: Timer?
    /// Set by a fold: the next `place` moves the glass in this style.
    private var foldMotion: RevealAnimation?
    private var glassTimer: Timer?
    /// Where `place` last put the window, before any motion.
    private var placed: NSRect?
    private var passTask: Task<Void, Never>?
    /// Keys a pass looked for and could not picture (an item that draws
    /// nothing, one the notch hides): not asked for again until a picture
    /// would have gone stale anyway.
    private var unpicturable: [ItemID: Date] = [:]
    /// Bumped per open and close, so a fade that ends late leaves alone a
    /// panel that opened again.
    private var generation = 0
    /// What measures the panel, kept for an open: a refresh gives it a new
    /// root view instead of building a controller per pass.
    private var measurer: NSHostingController<PanelView>?
    /// The measuring pass has no drag to show, and must not watch the live one.
    private let idleDrag = PanelDragState()

    init(appState: AppState) {
        self.appState = appState
    }

    /// Whether an armed rehide should wait. The panel closes as the bar
    /// does, once the pointer leaves (Gab, 2026-10-09: a clicked one held
    /// like a menu and read as stuck), so it holds while the pointer is on
    /// it or between it and the bar: the gap under the bar is crossed on
    /// the way in, and with no rehide delay the countdown ran out right
    /// there. A shortcut's panel holds until the pointer has been on it,
    /// as the bar does for a shortcut's reveal.
    ///
    /// The menu bar counts by its rectangle, not by what the band monitor
    /// saw: a picture pass covers the bar with a window of its own, the
    /// monitor read the pointer as gone and a clicked panel closed 0.3s in
    /// (2026-10-09).
    var holdsReveal: Bool {
        guard isOpen, let window else { return false }
        if awaitsPointer || draggingColumns || tileDrag != nil { return true }
        let pointer = NSEvent.mouseLocation
        var reach = window.frame
        if let screen = window.screen ?? NSScreen.main {
            reach.size.height = screen.frame.maxY - reach.minY
            let bar = GlassPanel.barHeight(of: screen)
            // NSMouseInRect: a pointer pushed to the top row sits at maxY,
            // which `contains` leaves out.
            if NSMouseInRect(pointer, NSRect(x: screen.frame.minX, y: screen.frame.maxY - bar,
                                             width: screen.frame.width, height: bar), false) { return true }
        }
        if NSMouseInRect(pointer, reach, false) { return true }
        PelmetLog.log("panel: let go — pointer at \(Int(pointer.x)),\(Int(pointer.y)), panel \(Int(reach.minX))…\(Int(reach.maxX))")
        return false
    }

    private var showsGrip = false

    private func updateGrip() {
        gripHost?.rootView = PanelEdgeGrip(
            shows: showsGrip, panelHovered: pointerOnPanel,
            onDrag: { [weak self] _, ended in self?.dragColumns(ended: ended) },
            onReset: { [weak self] in self?.resetColumns() })
    }

    /// Off the panel is off the bar: the countdown starts at the rehide
    /// delay, not at the next re-arm a second and a half on. Not when the
    /// panel shrank out from under a pointer that stayed put: a filter
    /// typed with the pointer resting on it would close it mid-word.
    private func pointerLeftPanel() {
        guard isOpen, !awaitsPointer, !draggingColumns, tileDrag == nil, CACurrentMediaTime() - resizedAt > 0.1 else { return }
        PelmetLog.log("panel: pointer left")
        appState?.pointerLeftBand()
    }

    // MARK: - RevealPresenter

    func reveal(_ sections: Set<PelmetCore.Section>, reason: RevealReason?, trace: PerfTrace) {
        let wasOpen = isOpen
        // A click on a hover-opened panel makes it deliberate; a hover never
        // turns a deliberate one back.
        openedByHover = reason == .hover && (!wasOpen || openedByHover)
        self.sections = sections
        if !wasOpen {
            awaitsPointer = reason == .hotkey
            opensUnderPointer = reason == .hover || reason == .click || reason == .doubleClick
            openScreen = nil
            foldOpen = false
            query = ""
            selected = nil
            opens += 1
            if let appState {
                corpus = CommandBarCorpus.build(appState: appState)
                history = CommandBarController.loadHistory()
            }
        }
        isOpen = true
        generation += 1
        let shown = refresh()
        trace.mark("built", detail: "\(shown.tiles) tiles")
        show(takeKey: !openedByHover, fadeIn: !wasOpen)
        // On screen from the next pass of the run loop: the `perf` line's
        // open → first frame.
        DispatchQueue.main.async { trace.finish("shown") }
        PelmetLog.log("panel: \(wasOpen ? "widened" : "open") (\(reason.map { "\($0)" } ?? "no reason")) — \(shown.tiles) tile(s), \(shown.missing.count) without a picture, key=\(window?.isKeyWindow == true)")
        // Settled on the next turn, as the bar's reveal settles after its
        // effect returns: the machine is still in this dispatch.
        DispatchQueue.main.async { [weak self] in self?.appState?.panelDidSettle() }
        picturePassIfNeeded(shown.missing)
    }

    func conceal(trace: PerfTrace) {
        close()
        trace.finish("closed")
        DispatchQueue.main.async { [weak self] in self?.appState?.panelDidSettle() }
    }

    /// Off screen with no settle of its own: the bar is taking over the
    /// reveal that is under way.
    func dismiss() {
        close()
    }

    /// A click or a key on a panel a hover opened, asking for what is
    /// already out: the machine has nothing to reveal, but the panel is the
    /// click's now, taking keys.
    func makeDeliberate() {
        guard isOpen, openedByHover else { return }
        openedByHover = false
        window?.makeKey()
        installKeyMonitor()
        PelmetLog.log("panel: made deliberate, key=\(window?.isKeyWindow == true)")
    }

    // MARK: - Window

    private func ensureWindow() -> (KeyableGlassPanel, PanelHostingView) {
        if let window, let hosting { return (window, hosting) }
        let hosting = PanelHostingView(rootView: Self.blank())
        // The window's frame is ours; the content must not resize it.
        hosting.sizingOptions = []
        let window = KeyableGlassPanel(content: hosting, cornerRadius: Self.cornerRadius)
        window.alphaValue = 0
        // A display unplugged, the lid closed, a scale changed: place it
        // again (on another display if its own is gone).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                PelmetLog.log("panel: screens changed, placing again")
                self.refresh()
            }
        }
        // The column grip sits half past the glass's left edge, in a clear
        // margin of the window (`show` sets the window to take clicks on
        // its clear parts too).
        window.leadingMargin = ColumnGrip.reach / 2
        let grip = GripHostingView(rootView: PanelEdgeGrip())
        grip.sizingOptions = []
        window.edgeAccessory = grip
        gripHost = grip
        let watch = PointerWatch(
            entered: { [weak self] in
                self?.awaitsPointer = false
                self?.pointerOnPanel = true
                self?.updateGrip()
            },
            exited: { [weak self] in
                guard let self else { return }
                // Leaving counts as having been on it, unless the panel
                // just reshaped away from the pointer.
                if CACurrentMediaTime() - self.resizedAt > 0.1 { self.awaitsPointer = false }
                self.pointerOnPanel = false
                self.updateGrip()
                self.pointerLeftPanel()
            })
        window.contentView?.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: watch, userInfo: nil))
        pointerWatch = watch
        self.window = window
        self.hosting = hosting
        return (window, hosting)
    }

    private func show(takeKey: Bool, fadeIn: Bool) {
        guard let window else { return }
        window.ignoresMouseEvents = false
        // Dev: `pelmet.debug.panelAppearance` light or dark checks the other
        // mode without changing the Mac's. Read at each open.
        window.appearance = switch UserDefaults.standard.string(forKey: "pelmet.debug.panelAppearance") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        if fadeIn {
            window.alphaValue = 0
            move(Self.reduceMotion ? nil : Motion(
                duration: AppTiming.panelEntrance, from: AppTiming.panelEntranceDrop, to: 0, curve: Self.enterCurve))
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AppTiming.panelEntrance
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
        // Keys only for a panel opened on purpose: a hover passing by must
        // not take the typing from the app in front.
        if takeKey {
            window.makeKey()
            installKeyMonitor()
        }
    }

    private func close() {
        guard isOpen else { return }
        if tileDrag != nil { finishDrag(cancel: true, closing: true) }
        isOpen = false
        pointerOnPanel = false
        draggingColumns = false
        generation += 1
        let mine = generation
        removeKeyMonitor()
        PelmetLog.log("panel: closed")
        guard let window else { return }
        // Up for the length of its fade: a click on it must not land, and a
        // click beneath it must.
        window.ignoresMouseEvents = true
        move(Self.reduceMotion ? nil : Motion(
            duration: AppTiming.panelExit, from: 0, to: AppTiming.panelExitRise, curve: Self.exitCurve))
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AppTiming.panelExit
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.4)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls this on the main thread but does not say so.
            Task { @MainActor in
                guard let self, self.generation == mine, !self.isOpen else { return }
                self.window?.orderOut(nil)
                // Hidden, not gone: a search row left in the window would
                // keep its caret blinking on a timer of its own.
                self.query = ""
                self.hosting?.rootView = Self.blank()
                self.measurer = nil
            }
        })
    }

    /// A panel with nothing in it: what the window holds before the first
    /// open and after each close.
    private static func blank() -> PanelHost {
        PanelHost(panel: PanelView(content: PanelContent(), onPress: { _ in }, onFold: {}))
    }

    // MARK: - Motion

    /// Reduce Motion: Smooth's slide becomes a fade.
    private static func foldStyle(_ style: RevealAnimation) -> RevealAnimation {
        style == .smooth && reduceMotion ? .fade : style
    }

    /// Always Hidden's fold, in the Animation style: the window takes the
    /// taller height for the length of it, its top where it is, and the
    /// glass inside grows or shrinks with the tiles (Smooth), or holds while
    /// they fade out (Fade). A fade in has the glass at its height at once.
    private func resizeGlass(to frame: NSRect, style: RevealAnimation) {
        guard let window else { return }
        stopGlass()
        let from = window.glassHeight
        let to = frame.height
        let growing = to >= from
        let duration: TimeInterval = switch style {
        case .instant: 0
        case .smooth: growing ? AppTiming.smoothRevealDuration : AppTiming.smoothExitDuration
        case .fade: growing ? 0 : AppTiming.fadeExitDuration
        }
        guard duration > 0, from != to else {
            placed = frame
            window.place(frame)
            window.setGlassHeight(to)
            return
        }
        let tall = NSRect(x: frame.minX, y: frame.maxY - max(from, to), width: frame.width, height: max(from, to))
        placed = tall
        window.place(tall)
        window.setGlassHeight(from)
        let curve = growing ? Self.enterCurve : Self.exitCurve
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let t = min((CACurrentMediaTime() - start) / duration, 1)
                guard t < 1 else {
                    self.stopGlass()
                    self.resizedAt = CACurrentMediaTime()
                    self.placed = frame
                    window.place(frame)
                    window.setGlassHeight(to)
                    return
                }
                if style == .smooth { window.setGlassHeight(from + (to - from) * curve.value(at: t)) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        glassTimer = timer
    }

    private func stopGlass() {
        glassTimer?.invalidate()
        glassTimer = nil
    }

    /// The mock's entrance drop or exit rise, stepped by hand over where
    /// `place` last put the window: a refresh mid-motion (a key typed right
    /// after the hotkey) moves that spot, and the motion follows it. An
    /// animator frame animation would put back the frame it started with.
    private struct Motion {
        let start = CACurrentMediaTime()
        let duration: TimeInterval
        let from: CGFloat
        let to: CGFloat
        let curve: UnitCurve

        func offset(at now: CFTimeInterval) -> CGFloat {
            let t = min(max((now - start) / duration, 0), 1)
            return from + (to - from) * curve.value(at: t)
        }
    }

    private static let enterCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))
    private static let exitCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.55, y: 0), endControlPoint: UnitPoint(x: 0.8, y: 0.4))
    /// Reduce Motion keeps the fades and drops the travel.
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func move(_ motion: Motion?) {
        motionTimer?.invalidate()
        motionTimer = nil
        self.motion = motion
        stepMotion()
        guard motion != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepMotion() }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stepMotion() {
        guard let window, let placed else { return }
        let now = CACurrentMediaTime()
        window.setFrameOrigin(NSPoint(x: placed.minX, y: placed.minY + (motion?.offset(at: now) ?? 0)))
        if let motion, now - motion.start >= motion.duration {
            motionTimer?.invalidate()
            motionTimer = nil
            self.motion = nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.window === self.window else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    /// The mock's keys: type to filter, arrows and Return, Esc clears the
    /// filter and then closes. True when the key was the panel's.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let key = PanelKey(event) else { return false }
        switch key {
        case .escape:
            if tileDrag != nil {
                cancelDrag()
            } else if CACurrentMediaTime() < escSwallowUntil {
                // The Esc that just cancelled a drag, or a repeat of it.
                escSwallowUntil = CACurrentMediaTime() + 0.3
            } else if query.isEmpty {
                appState?.concealNow()
            } else {
                setQuery("")
            }
        case .enter:
            if let tile = selected ?? lastModel?.bestMatch { press(tile) }
        case .move(let direction):
            guard let content = lastContent else { break }
            switch content.step(from: selected, toward: direction) {
            case .select(let tile):
                selected = tile
                refresh()
            case .unfold: toggleFold()
            case .stay: break
            }
        case .delete:
            if !query.isEmpty { setQuery(String(query.dropLast())) }
        case .type(let typed):
            guard let new = PanelKey.query(query, typing: typed) else { return false }
            setQuery(new)
        }
        return true
    }

    private func setQuery(_ new: String) {
        query = new
        selectBest = true
        refresh()
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Right-aligned under the bar, its right edge just past the chevron
    /// (the display's edge less a margin when the icon is off). A hover
    /// opens it on the display under the pointer; the chevron's distance
    /// from its display's right edge carries over, as the bar lays out the
    /// same on every display.
    private func place(_ size: CGSize) {
        guard let window, let target = targetScreen() else { return }
        let margin = GlassPanel.edgeMargin
        var right = target.frame.maxX - margin
        if let chevron = drawnChevron() {
            right = min(right, target.frame.maxX - (chevron.screen.frame.maxX - chevron.frame.maxX) + Self.pastChevron)
        }
        let width = min(size.width, target.frame.width - 2 * margin)
        let top = Self.top(on: target)
        // The glass's frame, then the window's: wider by the grip's margin.
        let glassX = max(right - width, target.frame.minX + margin).rounded()
        let frame = NSRect(
            x: glassX - window.leadingMargin,
            y: (top - size.height).rounded(),
            width: width.rounded() + window.leadingMargin, height: size.height.rounded())
        if frame.size != placed?.size { resizedAt = CACurrentMediaTime() }
        if let style = foldMotion {
            foldMotion = nil
            resizeGlass(to: frame, style: style)
            return
        }
        stopGlass()
        placed = frame
        window.place(frame.offsetBy(dx: 0, dy: motion?.offset(at: CACurrentMediaTime()) ?? 0))
        window.setGlassHeight(frame.height)
    }

    /// The display the panel opens on, and keeps until it closes.
    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let pointerScreen = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let kept = openScreen.flatMap { id in screens.first { $0.displayID == id } }
        let target = kept ?? (opensUnderPointer ? pointerScreen : nil) ?? drawnChevron()?.screen ?? pointerScreen
            ?? NSScreen.main ?? screens.first
        openScreen = target?.displayID
        return target
    }

    /// The chevron and its display, nil when it isn't in a bar's band (icon
    /// off, behind Apple's «, not placed yet), as the band monitor reads it:
    /// a parked frame would place the panel by nothing on screen.
    private func drawnChevron() -> (frame: NSRect, screen: NSScreen)? {
        guard let frame = appState?.chevronWindowFrame else { return nil }
        let mid = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mid, $0.frame, false) }) else { return nil }
        let bar = GlassPanel.barHeight(of: screen)
        let band = NSRect(x: screen.frame.minX, y: screen.frame.maxY - bar, width: screen.frame.width, height: bar)
        return band.intersects(frame) ? (frame, screen) : nil
    }

    private static func top(on screen: NSScreen) -> CGFloat {
        screen.frame.maxY - GlassPanel.barHeight(of: screen) - gapBelowBar
    }

    /// As tall as the panel can be on `screen`: down to the Dock, or the
    /// display's bottom, less the edge margin.
    private static func heightCap(on screen: NSScreen) -> CGFloat {
        min(top(on: screen) - screen.visibleFrame.minY - GlassPanel.edgeMargin, debugCap)
    }

    /// Debug: `open -a Pelmet --args -pelmet.debug.panelCap 300` caps the
    /// height and the row's width as a short, narrow display would.
    private static var debugCap: CGFloat {
        let cap = UserDefaults.standard.double(forKey: "pelmet.debug.panelCap")
        return cap > 0 ? cap : .greatestFiniteMagnitude
    }

    // MARK: - Content

    /// Rebuilds the tiles and fits the window to them. Returns how many
    /// tiles it drew and which items have no picture yet.
    @discardableResult
    private func refresh() -> (tiles: Int, missing: [ItemID]) {
        guard let appState else { return (0, []) }
        let (_, hosting) = ensureWindow()
        let screen = targetScreen()
        // The row wraps where `place` would cut it: the display less its
        // margins and the row's padding.
        let rowWidth = screen.map {
            min($0.frame.width - 2 * GlassPanel.edgeMargin, Self.debugCap) - 2 * PanelMetrics.row.padding
        }
        let (built, missing, model) = buildContent(
            appState, layout: appState.revealTarget.panelLayout ?? .panel, query: query, selected: selected,
            foldOpen: foldOpen, alwaysRequested: sections.contains(.alwaysHidden), maxRowWidth: rowWidth)
        var content = built
        lastModel = model
        if selectBest {
            selectBest = false
            selected = query.isEmpty ? nil : model.bestMatch
            content.selected = selected.flatMap { content.art[$0] == nil ? nil : $0 }
        }
        // A filter or a fold can take the selected tile away.
        selected = content.selected
        content.columnsTip = columnsTip
        content.scrollID = opens
        // The hosting view sizes nothing (`sizingOptions = []`), so its
        // fitting size is zero: the view measures itself here. Taller than
        // the display, the tiles scroll in what the search row leaves.
        var size = measure(content)
        if let screen, size.height > Self.heightCap(on: screen) {
            let cap = Self.heightCap(on: screen)
            // With no room for the tiles, what is left is the search row and
            // its padding; the tiles then take the rest of the cap.
            content.scrollHeight = 0
            let rest = measure(content)
            content.scrollHeight = max(cap - rest.height, 0)
            size = CGSize(width: rest.width, height: max(cap, rest.height))
        }
        // The oracle for a short or narrow display: logged when it changes.
        let lines = content.layout == .row ? content.blocks.first?.grid.rows.count ?? 0 : 0
        let fit = "scrolls \(content.scrollHeight.map { "in \(Int($0))" } ?? "no")\(lines > 1 ? ", row wraps to \(lines)" : "")"
        if fit != loggedFit {
            loggedFit = fit
            PelmetLog.log("panel: \(Int(size.width))×\(Int(size.height)), \(fit)")
        }
        lastContent = content
        hosting.rootView = PanelHost(panel: view(content))
        showsGrip = content.layout == .panel && !content.isEmpty
        updateGrip()
        place(size)
        return (content.art.count, missing)
    }

    /// `live` is the panel on screen. The measuring pass has no drag, reports
    /// no frames and needs no menus, which would be built for every tile.
    private func view(_ content: PanelContent, live: Bool = true) -> PanelView {
        guard live else {
            return PanelView(content: content, onPress: { _ in }, onFold: {}, drawsGrip: false, drag: idleDrag)
        }
        return PanelView(
            content: content,
            onPress: { [weak self] tile in
                // The mouse-up that ends a drag is not a click.
                guard let self, self.tileDrag == nil, !self.ignoresDragUntilRelease,
                      CACurrentMediaTime() >= self.pressGuardUntil else { return }
                self.press(tile)
            },
            onFold: { [weak self] in self?.toggleFold() },
            tileMenu: { [weak self] tile in self?.menu(for: tile) ?? [] },
            panelMenu: { [weak self] in
                self?.panelMenu(shown: self?.lastContent) { [weak self] in self?.toggleFold() } ?? []
            },
            // The window moves as it widens: the pointer is read on screen.
            onColumnsDrag: { [weak self] _, ended in self?.dragColumns(ended: ended) },
            onColumnsReset: { [weak self] in self?.resetColumns() },
            drawsGrip: false,
            onTileDrag: { [weak self] tile, phase in self?.tileDragged(tile, phase) },
            drag: dragState,
            onFrame: { [weak self] key, frame in self?.frames[key] = frame })
    }

    private func measure(_ content: PanelContent) -> CGSize {
        let measured = view(content, live: false)
        let controller: NSHostingController<PanelView>
        if let measurer {
            measurer.rootView = measured
            controller = measurer
        } else {
            controller = NSHostingController(rootView: measured)
            measurer = controller
        }
        return controller.sizeThatFits(in: NSSize(width: 4000, height: 4000))
    }

    /// The command bar's candidates afresh, as an open reads them: the
    /// Settings preview shows the apps that are running now.
    func readCorpus() {
        guard let appState, !isOpen else { return }
        corpus = CommandBarCorpus.build(appState: appState)
        history = CommandBarController.loadHistory()
    }

    /// The panel as it would open now, for the Settings preview: its own
    /// filter, selection and fold.
    func previewContent(layout: PanelGrid.Layout, query: String, selected: PanelTile?, foldOpen: Bool)
        -> (content: PanelContent, missing: [ItemID], model: PanelModel)?
    {
        guard let appState else { return nil }
        if corpus.isEmpty { corpus = CommandBarCorpus.build(appState: appState) }
        let built = buildContent(appState, layout: layout, query: query, selected: selected,
                                 foldOpen: foldOpen, alwaysRequested: false)
        return (built.content, built.missing, built.model)
    }

    /// What `refresh` and the preview draw: no state of the presenter's
    /// changes. A selection the filter or fold took away comes back nil.
    private func buildContent(_ appState: AppState, layout: PanelGrid.Layout, query: String, selected: PanelTile?,
                              foldOpen: Bool, alwaysRequested: Bool, maxRowWidth: CGFloat? = nil)
        -> (content: PanelContent, missing: [ItemID], model: PanelModel)
    {
        let options = appState.settings.panel
        // The editor's board, as Search reads it: live items, the concealed
        // ones that left the AX tree (the walk's `concealed` alone misses
        // system items such as Sound) and Pelmet's own extras, less those
        // the bar would not draw either.
        let items = [PelmetCore.Section.hidden, .alwaysHidden, .visible].flatMap(appState.editorItems(in:))
            .filter { appState.ownExtraWouldShow($0.id) }
        let launchers = corpus.compactMap { entry -> String? in
            if case .launcher(let bundle) = entry.action { return bundle }
            return nil
        }
        let model = PanelModel.build(
            roster: appState.settings.sectionModel.roster,
            items: items.map(\.id),
            drawnOrder: appState.lastDrawnOrder,
            didntFit: appState.overflowTrappedItems,
            // Closed apps off: out of the panel at rest, a search still finds them.
            launchers: options.showsClosedApps || !query.isEmpty ? launchers : [],
            options: options,
            alwaysHiddenRequested: alwaysRequested,
            query: query,
            candidates: corpus.map(\.candidate),
            history: history)

        // What is on screen, in stacking order. A folded Always Hidden draws
        // its fold only; the row layout has no fold, so it leaves it out.
        struct Shown { let section: PanelSection; let folded: Bool }
        var shown: [Shown] = model.sections.compactMap { section in
            let folded = section.kind == .alwaysHidden && section.isFolded && !foldOpen
            if section.count == 0 { return nil }
            if layout == .row && folded { return nil }
            return Shown(section: section, folded: folded)
        }
        let alwaysShown = shown.contains { $0.section.kind == .alwaysHidden && !$0.folded }
        // The row merges them: the groups a drop is aimed at.
        var rowGroups: [PanelGroup] = []
        if layout == .row {
            // One row, as the bar draws it: Always Hidden left of Hidden, a
            // divider between groups.
            let order: [PanelSection.Kind] = [.didntFit, .alwaysHidden, .hidden]
            shown.sort { order.firstIndex(of: $0.section.kind)! < order.firstIndex(of: $1.section.kind)! }
            rowGroups = shown.map { PanelGroup(kind: $0.section.kind, tiles: $0.section.tiles.filter { $0 != .rowBreak }) }
            let tiles = shown.map(\.section.tiles).reduce(into: [PanelTile]()) { all, group in
                if !all.isEmpty { all.append(.rowBreak) }
                all += group
            }
            shown = tiles.isEmpty ? [] : [Shown(section: PanelSection(kind: .hidden, tiles: tiles, isFolded: false), folded: false)]
        }

        // The tile fold: a "+10" tile after Hidden's icons, in a Hidden of
        // its own when Hidden has none. A search shows matches, no fold.
        if layout == .panel, options.alwaysHiddenFold == .tile, query.isEmpty,
           let always = shown.firstIndex(where: { $0.section.kind == .alwaysHidden }) {
            if always > 0, shown[always - 1].section.kind == .hidden {
                var hidden = shown[always - 1].section
                hidden.tiles.append(.fold)
                shown[always - 1] = Shown(section: hidden, folded: false)
            } else {
                shown.insert(Shown(section: PanelSection(kind: .hidden, tiles: [.fold], isFolded: false), folded: false),
                             at: always)
            }
        }

        let columns = options.columns
        let minimum = shown.filter { !$0.folded }
            .map { PanelGrid.neededColumns(of: $0.section.tiles, maximum: columns) }.max() ?? 1
        let didntFitShown = shown.contains { $0.section.kind == .didntFit }
        var content = PanelContent(layout: layout, query: query)
        content.hasAlwaysHidden = model.sections.contains { $0.kind == .alwaysHidden && $0.count > 0 }
        content.showsAlwaysHidden = alwaysShown
        content.motion = Self.foldStyle(appState.settings.revealAnimation)
        content.fold = options.alwaysHiddenFold
        content.blocks = shown.map { entry in
            PanelBlock(
                kind: entry.section.kind,
                grid: PanelGrid(tiles: entry.section.tiles, columns: columns, layout: layout,
                                showsNames: options.showsNames, minimumColumns: minimum, maxWidth: maxRowWidth),
                count: entry.section.count,
                showsHeader: layout == .panel && (entry.section.kind == .didntFit || (entry.section.kind == .hidden && didntFitShown)),
                foldable: layout == .panel && entry.section.kind == .alwaysHidden,
                isFolded: entry.folded,
                groups: rowGroups)
        }
        // A folded section sets no width. The search field wants room to
        // type into; otherwise the panel is as wide as its icons.
        content.width = max(content.blocks.filter { !$0.isFolded }.map(\.grid.contentSize.width).max() ?? 0,
                            query.isEmpty ? PanelMetrics.compact.wellSize.width : 150)

        let byKey = Dictionary(items.map { ($0.id.sectionKey, $0) }, uniquingKeysWith: { first, _ in first })
        var missing: [ItemID] = []
        for block in content.blocks where !block.isFolded {
            for tile in block.grid.rows.joined().map(\.tile) {
                switch tile {
                case .item(let key):
                    // The tiles whose menu offers "Move to…".
                    if !appState.isImmovable(key) { content.draggable.insert(tile) }
                    let item = byKey[key]
                    let name = item.map(ItemNaming.displayName(for:)) ?? ItemNaming.displayName(for: key)
                    if let picture = pictures.picture(for: key) {
                        content.art[tile] = PanelTileArt(
                            image: .picture(picture.image, size: picture.size, monochrome: picture.isMonochrome), name: name)
                    } else {
                        content.art[tile] = PanelTileArt(image: .icon(Self.standIn(for: item?.id ?? key)), name: name)
                        // Didn't fit is on the bar, behind «: no pass reaches it.
                        if block.kind != .didntFit { missing.append(key) }
                    }
                case .launcher(let bundle):
                    let icon = launcherIcon(bundle)
                    content.art[tile] = PanelTileArt(
                        image: .icon(icon), name: ItemNaming.appName(forBundle: bundle) ?? bundle, dimmed: true)
                case .rowBreak, .fold:
                    break
                }
            }
        }
        content.selected = selected.flatMap { content.art[$0] == nil && $0 != .fold ? nil : $0 }
        return (content, missing, model)
    }

    /// Read once: the preview rebuilds on every bar read and drag step.
    private func launcherIcon(_ bundle: String) -> NSImage {
        if let icon = launcherIcons[bundle] { return icon }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? Self.placeholder
        launcherIcons[bundle] = icon
        return icon
    }

    private static func standIn(for id: ItemID) -> NSImage {
        ItemImageCache.icon(for: id) ?? placeholder
    }

    private static let placeholder: NSImage = {
        let image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    // MARK: - Actions

    func press(_ tile: PanelTile) {
        guard let appState else { return }
        switch tile {
        case .item(let key):
            PelmetLog.log("panel: press \(key.rawValue)")
            appState.concealNow()
            // Waits out a pass under way (openItemMenu).
            appState.openItemMenu(key)
        case .launcher(let bundle):
            PelmetLog.log("panel: launch \(bundle)")
            appState.concealNow()
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .fold:
            toggleFold()
        case .rowBreak:
            break
        }
    }

    // MARK: - Tile drag

    /// A tile in the air, from the first 4pt of travel until it lands or goes
    /// back (docs/PANEL-PLAN.md D1: between sections only).
    private final class TileDrag {
        let tile: PanelTile
        let key: ItemID
        /// Where it came from, by the model.
        let origin: PelmetCore.Section
        let ghost: PanelDragGhost
        /// The pointer less the ghost's centre, kept from where it was grabbed.
        let grab: CGSize
        /// The tile's well centre in the window (y down): where it goes back to.
        let home: CGPoint
        /// What a drop here would do; `.none` for nothing and for `origin`.
        var hit: PanelDropZones.Hit = .none
        let started = CACurrentMediaTime()

        init(tile: PanelTile, key: ItemID, origin: PelmetCore.Section, ghost: PanelDragGhost, grab: CGSize, home: CGPoint) {
            self.tile = tile
            self.key = key
            self.origin = origin
            self.ghost = ghost
            self.grab = grab
            self.home = home
        }
    }

    /// The fold springs open after this long over it (the mock's 600ms).
    private static let springDelay: Duration = .milliseconds(600)

    /// From a tile's gesture. Only the start and the end come from here; the
    /// pointer is read on screen, on the gesture's moves and on a timer, so a
    /// ghost over the bar keeps up with a pointer SwiftUI no longer reports.
    private func tileDragged(_ tile: PanelTile, _ phase: PanelTileDrag) {
        switch phase {
        case .moved(let pointer, let wellCenter):
            if tileDrag == nil {
                guard !ignoresDragUntilRelease, NSEvent.pressedMouseButtons & 1 != 0 else { return }
                beginDrag(tile, pointer: pointer, wellCenter: wellCenter)
            }
            tickDrag()
        case .ended:
            released()
        }
    }

    /// The button came up (the gesture's end, a mouse-up seen directly, or a
    /// button found up by the timer; whichever is first): the drop, and the
    /// click that ends a drag is not one.
    private func released() {
        ignoresDragUntilRelease = false
        pressGuardUntil = CACurrentMediaTime() + 0.35
        stopWatchingMouse()
        if tileDrag != nil { finishDrag(cancel: false) }
    }

    private func watchMouse() {
        guard mouseMonitors.isEmpty else { return }
        let seen: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                // A new press: whatever was cancelled before it is over.
                if event.type == .leftMouseUp { self?.released() } else { self?.ignoresDragUntilRelease = false }
            }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: seen) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            seen(event)
            return event
        }) { mouseMonitors.append(local) }
    }

    private func stopWatchingMouse() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
    }

    private func beginDrag(_ tile: PanelTile, pointer: CGPoint, wellCenter: CGPoint) {
        guard isOpen, let appState, let window, let content = lastContent, case .item(let key) = tile,
              content.draggable.contains(tile), let art = content.art[tile],
              let block = content.blocks.first(where: { $0.grid.frame(of: tile) != nil })
        else { return }
        // An Apply or grouping pass has the bar, and `moveItem` ignores a drop
        // that lands during one: no drag to begin, and its release is no click.
        guard !appState.applying else {
            PelmetLog.log("panel: drag of \(key.rawValue) refused, a pass has the bar")
            ignoresDragUntilRelease = true
            watchMouse()
            return
        }
        let origin = appState.settings.sectionModel.section(of: key)
        // The tile's well, on screen: where the pointer is, less how far into
        // the tile it was (the tile's y runs down, the screen's up).
        let mouse = NSEvent.mouseLocation
        let center = CGPoint(x: mouse.x - (pointer.x - wellCenter.x), y: mouse.y + (pointer.y - wellCenter.y))
        let ghost = PanelDragGhost(art: art, grid: block.grid, appearance: window.appearance)
        let drag = TileDrag(
            tile: tile, key: key, origin: origin, ghost: ghost,
            grab: CGSize(width: mouse.x - center.x, height: mouse.y - center.y),
            home: CGPoint(x: center.x - window.frame.minX, y: window.frame.maxY - center.y))
        tileDrag = drag
        watchMouse()
        ghost.show(at: center)
        withAnimation(.easeOut(duration: 0.15)) { dragState.tile = tile }
        PelmetLog.log("panel: drag \(key.rawValue) from \(origin.rawValue)")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
        let escape: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 0x35 else { return }
            MainActor.assumeIsolated { self?.cancelDrag() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: escape) { escMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            escape(event)
            return event.keyCode == 0x35 ? nil : event
        }) { escMonitors.append(local) }
    }

    /// The ghost under the pointer, and the target it is over.
    private func tickDrag() {
        guard let drag = tileDrag else { return }
        // Polled too, for a key held down when the monitors' events came late.
        if CGEventSource.keyState(.combinedSessionState, key: 0x35) {
            cancelDrag()
            return
        }
        // A release nothing reported: the drag ends where the button came up.
        if NSEvent.pressedMouseButtons & 1 == 0, CACurrentMediaTime() - drag.started > 0.15 {
            released()
            return
        }
        let pointer = NSEvent.mouseLocation
        drag.ghost.move(toCenter: CGPoint(x: pointer.x - drag.grab.width, y: pointer.y - drag.grab.height))
        let hit = target(at: pointer, for: drag)
        if hit != drag.hit {
            drag.hit = hit
            targetChanged(to: hit)
        }
    }

    /// The drop at `point`, less the tile's own section: that is no move.
    private func target(at point: CGPoint, for drag: TileDrag) -> PanelDropZones.Hit {
        let hit = dropZones()?.hit(at: point) ?? .none
        return hit.section == drag.origin ? .none : hit
    }

    private func targetChanged(to hit: PanelDropZones.Hit) {
        withAnimation(.easeOut(duration: 0.12)) { dragState.target = hit }
        switch hit {
        case .none: PelmetLog.log("panel: drag over nothing")
        case .fold: PelmetLog.log("panel: drag over the fold")
        case .section(let section): PelmetLog.log("panel: drag over \(section.rawValue)")
        }
        springTask?.cancel()
        springTask = nil
        // Held over the closed fold it opens, for this open only: nothing is
        // stored.
        guard hit == .fold, let content = lastContent, content.layout == .panel,
              content.blocks.contains(where: { $0.kind == .alwaysHidden && $0.isFolded })
        else { return }
        springTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.springDelay)
            guard let self, !Task.isCancelled, self.tileDrag?.hit == .fold else { return }
            self.springTask = nil
            self.openFoldForDrag()
        }
    }

    private func openFoldForDrag() {
        guard isOpen, let appState else { return }
        PelmetLog.log("panel: drag opened Always Hidden")
        foldOpen = true
        foldMotion = Self.foldStyle(appState.settings.revealAnimation)
        let shown = refresh()
        picturePassIfNeeded(shown.missing)
    }

    private func cancelDrag() {
        // The key's own event is still on its way to the panel's handler.
        escSwallowUntil = CACurrentMediaTime() + 0.5
        finishDrag(cancel: true)
    }

    /// The drop: a section other than the tile's own takes it; anywhere else
    /// it goes back to where it was. `closing`: the panel is going, the ghost
    /// only fades.
    private func finishDrag(cancel: Bool, closing: Bool = false) {
        guard let drag = tileDrag else { return }
        var section = cancel ? nil : target(at: NSEvent.mouseLocation, for: drag).section
        // `moveItem` ignores a drop during a pass: it goes back, it doesn't land.
        if section != nil, appState?.applying == true {
            PelmetLog.log("panel: drop of \(drag.key.rawValue) refused, a pass has the bar")
            section = nil
        }
        tileDrag = nil
        dragTimer?.invalidate()
        dragTimer = nil
        for monitor in escMonitors { NSEvent.removeMonitor(monitor) }
        escMonitors = []
        springTask?.cancel()
        springTask = nil
        withAnimation(.easeOut(duration: 0.15)) {
            dragState.tile = nil
            dragState.target = .none
        }
        // Cancelled with the button still down: the rest of that press is not a
        // click. The release ends it (`released`).
        if NSEvent.pressedMouseButtons & 1 != 0 {
            ignoresDragUntilRelease = true
        } else {
            ignoresDragUntilRelease = false
            pressGuardUntil = CACurrentMediaTime() + 0.35
            stopWatchingMouse()
        }
        // Let go past the edge, it holds until the pointer comes back (the
        // column grip does the same).
        awaitsPointer = true
        if let section, let appState {
            PelmetLog.log("panel: drop \(drag.key.rawValue) → \(section.rawValue)")
            drag.ghost.release()
            appState.moveItemNow(drag.key, to: section)
            if isOpen { refresh() }
        } else {
            PelmetLog.log("panel: drag cancelled")
            let home = closing ? nil : window.map { CGPoint(x: $0.frame.minX + drag.home.x, y: $0.frame.maxY - drag.home.y) }
            drag.ghost.slideBack(toCenter: home, reduceMotion: Self.reduceMotion)
        }
    }

    /// What the pointer can drop on, in screen points: the glass, the bar's
    /// band, and the parts SwiftUI laid out.
    private func dropZones() -> PanelDropZones? {
        guard let window, let hosting, let content = lastContent, let screen = window.screen ?? NSScreen.main else { return nil }
        let bar = GlassPanel.barHeight(of: screen)
        var zones = PanelDropZones(
            bar: NSRect(x: screen.frame.minX, y: screen.frame.maxY - bar, width: screen.frame.width, height: bar),
            panel: window.glassScreenFrame)
        func onScreen(_ key: PanelFrameKey) -> CGRect? {
            frames[key].map { window.convertToScreen(hosting.convert($0, to: nil)) }
        }
        if content.layout == .row {
            // One grid; its tiles are placed from its corner (y runs down).
            if let block = content.blocks.first, let grid = onScreen(.grid(block.kind)) {
                zones.groups = block.groups.map { group in
                    PanelDropZones.Group(kind: group.kind, tiles: group.tiles.compactMap { block.grid.frame(of: $0) }.map {
                        CGRect(x: grid.minX + $0.minX, y: grid.maxY - $0.maxY, width: $0.width, height: $0.height)
                    })
                }
            }
            return zones
        }
        if content.blocks.contains(where: { $0.kind == .didntFit }) { zones.didntFit = onScreen(.section(.didntFit)) }
        // The fold is a tile of Hidden's grid, placed from the grid's corner
        // (an offset is not a layout frame: SwiftUI reports where the tile was
        // laid out, not where it is drawn), or its own count or handle.
        if let block = content.blocks.first(where: { $0.grid.frame(of: .fold) != nil }),
           let cell = block.grid.frame(of: .fold), let grid = onScreen(.grid(block.kind)) {
            zones.fold = CGRect(x: grid.minX + cell.minX, y: grid.maxY - cell.maxY, width: cell.width, height: cell.height)
        } else if content.query.isEmpty, content.fold != .tile, content.blocks.contains(where: { $0.foldable }) {
            zones.fold = onScreen(.fold)
        }
        if content.blocks.contains(where: { $0.kind == .alwaysHidden && !$0.isFolded }) {
            zones.alwaysHidden = onScreen(.grid(.alwaysHidden))
        }
        return zones
    }

    // MARK: - Columns

    /// Columns from the pointer, `distance` left of the panel's right edge:
    /// that edge stays put, so each tile's width left of it is one more
    /// column. Two at least, no more than the widest section of `model` can
    /// fill, ten at most. Stored for the current names mode; returned for
    /// the tip.
    @discardableResult
    func setColumns(distance: CGFloat, model: PanelModel?) -> Int {
        guard let appState else { return 0 }
        let options = appState.settings.panel
        let metrics = PanelMetrics.standard(layout: .panel, showsNames: options.showsNames)
        let pitch = metrics.tileSize.width + metrics.columnGap
        let want = Int(((distance - metrics.padding + metrics.columnGap) / pitch).rounded())
        let most = max(2, model?.sections.map { PanelGrid.neededColumns(of: $0.tiles, maximum: 10) }.max() ?? 2)
        let columns = min(max(want, 2), most)
        if options.columns != columns {
            appState.settings.panel.columns = columns
            appState.settingsChanged()
            PelmetLog.log("panel: \(columns) column(s)")
        }
        return columns
    }

    func setAutoColumns() {
        guard let appState else { return }
        appState.settings.panel.columns = nil
        appState.settingsChanged()
        PelmetLog.log("panel: columns Auto")
    }

    private func dragColumns(ended: Bool) {
        guard let window else { return }
        draggingColumns = !ended
        if ended { awaitsPointer = true }
        let columns = setColumns(distance: window.frame.maxX - NSEvent.mouseLocation.x, model: lastModel)
        showTip(String(localized: "\(columns) per row"), for: ended ? 0.5 : nil)
    }

    private func resetColumns() {
        awaitsPointer = true
        setAutoColumns()
        showTip(String(localized: "Auto"), for: 0.8)
    }

    /// Up until `seconds` pass, or until the next call when nil.
    private func showTip(_ text: String, for seconds: Double?) {
        tipTask?.cancel()
        columnsTip = text
        refresh()
        guard let seconds else { return }
        tipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.columnsTip = nil
            if self.isOpen { self.refresh() }
        }
    }

    // MARK: - Right-click

    /// The mock's tile menu: the presses, the moves between sections, the
    /// app. The command bar's ⌘K list has the same rows.
    func menu(for tile: PanelTile) -> [PanelMenuRow] {
        guard let appState else { return [] }
        switch tile {
        case .item(let key):
            var rows: [PanelMenuRow] = [
                .action(String(localized: "Open Menu")) { [weak self] in self?.press(tile) },
                .action(String(localized: "Open Right-Click Menu")) { [weak appState] in
                    PelmetLog.log("panel: right-click \(key.rawValue)")
                    appState?.concealNow()
                    appState?.openItemMenu(key, button: .secondary)
                },
                .action(String(localized: "Show in Menu Bar")) { [weak appState] in
                    PelmetLog.log("panel: show \(key.rawValue) in the bar")
                    appState?.showItemInBar(key)
                },
            ]
            // The clock and Control Center stay where macOS pins them.
            if !appState.isImmovable(key) {
                rows.append(.divider)
                let current = appState.settings.sectionModel.section(of: key)
                for (section, title) in [
                    (PelmetCore.Section.visible, String(localized: "Move to Visible")),
                    (.hidden, String(localized: "Move to Hidden")),
                    (.alwaysHidden, String(localized: "Move to Always Hidden")),
                ] where section != current {
                    rows.append(.action(title) { [weak appState] in
                        PelmetLog.log("panel: move \(key.rawValue) to \(section.rawValue)")
                        appState?.concealNow()
                        appState?.moveItemNow(key, to: section)
                    })
                }
            }
            let app = corpus.first { if case .item(let id) = $0.action { id == key } else { false } }?.app
            if let app, !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
                rows.append(.divider)
                rows.append(.action(String(localized: "Quit \(app.name)")) { [weak appState] in
                    PelmetLog.log("panel: quit \(app.bundleID)")
                    appState?.concealNow()
                    for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) { running.terminate() }
                })
            }
            return rows
        case .launcher(let bundle):
            let name = ItemNaming.appName(forBundle: bundle) ?? bundle
            return [.action(String(localized: "Open \(name)")) { [weak self] in self?.press(tile) }]
        case .rowBreak, .fold:
            return []
        }
    }

    /// The mock's panel menu: the layout, names, Always Hidden, Settings.
    /// `shown` is what the panel it opens on draws, `toggleFold` its fold.
    func panelMenu(shown: PanelContent?, toggleFold: @escaping () -> Void) -> [PanelMenuRow] {
        guard let appState else { return [] }
        let layout = appState.revealTarget.panelLayout ?? .panel
        let alwaysShown = shown?.showsAlwaysHidden ?? false
        let hasAlways = shown?.hasAlwaysHidden ?? false
        return [
            .header(String(localized: "Layout")),
            .check(String(localized: "Panel"), layout == .panel) { [weak self] in self?.setTarget(.panel) },
            .check(String(localized: "Row"), layout == .row) { [weak self] in self?.setTarget(.row) },
            .divider,
            .check(String(localized: "Show Names"), appState.settings.panel.showsNames, enabled: layout == .panel) { [weak self] in
                guard let self, let appState = self.appState else { return }
                appState.settings.panel.showsNames.toggle()
                appState.settingsChanged()
                if self.isOpen { self.refresh() }
            },
            .check(String(localized: "Show Closed Apps"), appState.settings.panel.showsClosedApps) { [weak self] in
                guard let self, let appState = self.appState else { return }
                appState.settings.panel.showsClosedApps.toggle()
                appState.settingsChanged()
                if self.isOpen { self.refresh() }
            },
            .check(String(localized: "Always Hidden"), alwaysShown, enabled: hasAlways, toggleFold),
            .divider,
            .action(String(localized: "Pelmet Settings…")) { [weak appState] in
                appState?.concealNow()
                appState?.openSettings(tab: .panel)
            },
        ]
    }

    /// The layout picked from the panel's menu is the setting from then on:
    /// the dev override gives way to it.
    func setTarget(_ target: RevealTarget) {
        guard let appState else { return }
        UserDefaults.standard.removeObject(forKey: "pelmet.debug.panel")
        appState.settings.hiddenIconsIn = target
        appState.settingsChanged()
        PelmetLog.log("panel: layout \(target.rawValue)")
        if isOpen { refresh() }
    }

    /// Always Hidden's fold flipped on a panel that shows it (`shown`) or
    /// not; returns that panel's own fold. As you left it: the setting
    /// carries the fold to the next open, and the panel's own stays shut.
    func flipFold(shown: Bool, foldOpen: Bool) -> Bool {
        guard let appState, appState.settings.panel.alwaysHidden == .asLeft else { return !foldOpen }
        appState.settings.panel.alwaysHiddenOpen = !shown
        appState.settingsChanged()
        return false
    }

    private func toggleFold() {
        foldOpen = flipFold(shown: lastContent?.showsAlwaysHidden ?? false, foldOpen: foldOpen)
        if let appState { foldMotion = Self.foldStyle(appState.settings.revealAnimation) }
        let shown = refresh()
        picturePassIfNeeded(shown.missing)
    }

    // MARK: - Dev

    /// The open panel as it is on screen, glass, desktop and all, written to
    /// ~/Library/Logs/Pelmet/pass/panel.png: for checking it with no one at
    /// the Mac (`app.fif7y.Pelmet.debug.panelShot`).
    func debugShot() async {
        guard isOpen, let window, let primary = NSScreen.screens.first else {
            PelmetLog.log("panel: shot skipped — not open")
            return
        }
        // Room below for a right-click menu.
        var frame = window.frame.insetBy(dx: -40, dy: -40)
        frame = frame.union(frame.offsetBy(dx: 0, dy: -260))
        let rect = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        // The completion form: the async one traps when the capture hands
        // back neither an image nor an error (crashed Pelmet, 2026-10-09).
        guard #available(macOS 15.2, *), let image = await withCheckedContinuation({ (done: CheckedContinuation<CGImage?, Never>) in
            SCScreenshotManager.captureImage(in: rect) { image, _ in done.resume(returning: image) }
        }) else {
            PelmetLog.log("panel: shot failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let dir = URL(fileURLWithPath: NSString(string: "~/Library/Logs/Pelmet/pass").expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wrote = (try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("panel.png"))) != nil
        PelmetLog.log("panel: shot \(wrote ? "written" : "not written") (\(image.width)×\(image.height))")
    }

    // MARK: - Pictures

    /// A relay's fresh picture of the item it pressed, taken once its menu
    /// is gone (ItemPress): whatever the press changed shows next open.
    func repicture(_ key: ItemID, frame: CGRect) async {
        guard let appState, let picture = await appState.transitions.pictureItem(key, frame: frame) else {
            PelmetLog.log("panel: \(key.rawValue) not re-pictured")
            return
        }
        pictures.store([key: picture])
        unpicturable[key] = nil
        PelmetLog.log("panel: \(key.rawValue) re-pictured")
        if isOpen { refresh() }
    }

    /// The pass, once, when the open panel (or the Settings preview) shows
    /// tiles with no picture. `done` runs once pictures were stored.
    func picturePassIfNeeded(_ missing: [ItemID], done: (@MainActor () -> Void)? = nil) {
        guard let appState, appState.screenRecordingGranted else { return }
        if passTask != nil {
            if let done { passWaiters.append(done) }
            return
        }
        let wanted = missing.filter { key in
            unpicturable[key].map { -$0.timeIntervalSinceNow >= ItemPictures.maxAge } ?? true
        }
        guard !wanted.isEmpty else { return }
        if let done { passWaiters.append(done) }
        let roster = appState.settings.sectionModel.roster
        let needsAlways = wanted.contains { roster.section(of: $0) == .alwaysHidden }
        let reveal: Set<PelmetCore.Section> = needsAlways ? [.hidden, .alwaysHidden] : [.hidden]
        passTask = Task { @MainActor [weak self, weak appState] in
            guard let appState else { return }
            let found = await appState.transitions.picturePass(reveal)
            guard let self else { return }
            self.passTask = nil
            let waiters = self.passWaiters
            self.passWaiters = []
            defer { for waiter in waiters { waiter() } }
            // A pass that never saw the icons (the bar out, an idle Mac's
            // empty walk) says nothing about them: the next open tries again.
            guard let found else {
                PelmetLog.log("panel: pass saw no icons, \(wanted.count) wanted")
                return
            }
            self.pictures.store(found)
            let now = Date()
            for key in wanted where found[key] == nil { self.unpicturable[key] = now }
            let lost = wanted.filter { found[$0] == nil }.map(\.rawValue)
            PelmetLog.log("panel: pass pictured \(found.count) of \(wanted.count) wanted\(lost.isEmpty ? "" : " — none for \(lost)")")
            guard self.isOpen else { return }
            // A widen or an unfold while it ran can want more.
            let shown = self.refresh()
            self.picturePassIfNeeded(shown.missing)
        }
    }
}

/// The panel pinned to the window's top right, where the window is
/// anchored: the content changes a moment before the window takes its new
/// size, and centred it jumped by half the difference (the fold row and the
/// row above it, 2026-10-09). The zero minimums matter: without them the
/// frame grows to a taller panel and centres it all the same.
struct PanelHost: View {
    /// The hosting view's own space: what the drag measures the panel in.
    static let space = "panelHost"

    let panel: PanelView

    var body: some View {
        panel.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topTrailing)
            .coordinateSpace(name: Self.space)
    }
}

/// The panel's content. It takes the first click: a hover-opened panel isn't
/// key, and the press that would make it key must still pick a tile up.
private final class PanelHostingView: NSHostingView<PanelHost> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The column grip's host. It takes the first click: a hover-opened panel
/// isn't key, and the press that would make it key never reached the drag.
private final class GripHostingView: NSHostingView<PanelEdgeGrip> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A tracking area's owner: the pointer onto the panel and off it.
private final class PointerWatch: NSResponder {
    private let entered: () -> Void
    private let exited: () -> Void

    init(entered: @escaping () -> Void, exited: @escaping () -> Void) {
        self.entered = entered
        self.exited = exited
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { entered() }
    override func mouseExited(with event: NSEvent) { exited() }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
