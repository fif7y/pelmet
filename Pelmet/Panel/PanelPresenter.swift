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
    private var hosting: NSHostingView<PanelHost>?
    private(set) var isOpen = false
    private var openedByHover = false
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

    init(appState: AppState) {
        self.appState = appState
    }

    /// Whether an armed rehide should wait: a panel opened on purpose holds
    /// like a menu, a hover one only while the pointer is on it.
    var holdsReveal: Bool {
        guard isOpen, let window else { return false }
        return !openedByHover || window.frame.contains(NSEvent.mouseLocation)
    }

    // MARK: - RevealPresenter

    func reveal(_ sections: Set<PelmetCore.Section>, reason: RevealReason?, trace: PerfTrace) {
        let wasOpen = isOpen
        // A click on a hover-opened panel makes it deliberate; a hover never
        // turns a deliberate one back.
        openedByHover = reason == .hover && (!wasOpen || openedByHover)
        self.sections = sections
        if !wasOpen {
            foldOpen = false
            query = ""
            selected = nil
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
    /// click's now, held like a menu and taking keys.
    func makeDeliberate() {
        guard isOpen, openedByHover else { return }
        openedByHover = false
        window?.makeKey()
        installKeyMonitor()
        PelmetLog.log("panel: made deliberate, key=\(window?.isKeyWindow == true)")
    }

    // MARK: - Window

    private func ensureWindow() -> (KeyableGlassPanel, NSHostingView<PanelHost>) {
        if let window, let hosting { return (window, hosting) }
        let hosting = NSHostingView(rootView: PanelHost(panel: PanelView(content: PanelContent(), onPress: { _ in }, onFold: {})))
        // The window's frame is ours; the content must not resize it.
        hosting.sizingOptions = []
        let window = KeyableGlassPanel(content: hosting, cornerRadius: Self.cornerRadius)
        window.alphaValue = 0
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
        isOpen = false
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
            }
        })
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
            if query.isEmpty { appState?.concealNow() } else { setQuery("") }
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
        guard let window, let appState else { return }
        let screens = NSScreen.screens
        func screen(at point: NSPoint) -> NSScreen? { screens.first { $0.frame.contains(point) } }
        let chevron = appState.chevronWindowFrame
        let chevronScreen = chevron.flatMap { screen(at: NSPoint(x: $0.midX, y: $0.midY)) }
        let pointerScreen = screen(at: NSEvent.mouseLocation)
        guard let target = (openedByHover ? pointerScreen : nil) ?? chevronScreen ?? pointerScreen ?? NSScreen.main ?? screens.first
        else { return }
        let margin = GlassPanel.edgeMargin
        var right = target.frame.maxX - margin
        if let chevron, let chevronScreen {
            right = min(right, target.frame.maxX - (chevronScreen.frame.maxX - chevron.maxX) + Self.pastChevron)
        }
        let width = min(size.width, target.frame.width - 2 * margin)
        let top = target.frame.maxY - GlassPanel.barHeight(of: target) - Self.gapBelowBar
        let frame = NSRect(
            x: max(right - width, target.frame.minX + margin).rounded(),
            y: (top - size.height).rounded(),
            width: width.rounded(), height: size.height.rounded())
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

    // MARK: - Content

    /// Rebuilds the tiles and fits the window to them. Returns how many
    /// tiles it drew and which items have no picture yet.
    @discardableResult
    private func refresh() -> (tiles: Int, missing: [ItemID]) {
        guard let appState else { return (0, []) }
        let (_, hosting) = ensureWindow()
        let (built, missing, model) = buildContent(
            appState, layout: appState.revealTarget.panelLayout ?? .panel, query: query, selected: selected,
            foldOpen: foldOpen, alwaysRequested: sections.contains(.alwaysHidden))
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
        lastContent = content
        let view = PanelView(
            content: content,
            onPress: { [weak self] tile in self?.press(tile) },
            onFold: { [weak self] in self?.toggleFold() },
            tileMenu: { [weak self] tile in self?.menu(for: tile) ?? [] },
            panelMenu: { [weak self] in
                self?.panelMenu(shown: self?.lastContent) { [weak self] in self?.toggleFold() } ?? []
            },
            // The window moves as it widens: the pointer is read on screen.
            onColumnsDrag: { [weak self] _, ended in self?.dragColumns(ended: ended) },
            onColumnsReset: { [weak self] in self?.resetColumns() })
        hosting.rootView = PanelHost(panel: view)
        // The hosting view sizes nothing (`sizingOptions = []`), so its
        // fitting size is zero: the view measures itself here.
        place(NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: 4000, height: 4000)))
        return (content.art.count, missing)
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
                              foldOpen: Bool, alwaysRequested: Bool)
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
            launchers: launchers,
            options: options,
            alwaysHiddenRequested: alwaysRequested,
            query: query,
            candidates: corpus.map(\.candidate),
            history: history)

        // What is on screen, in stacking order. A folded Always Hidden draws
        // its fold row only; the row layout has no fold, so it leaves it out.
        struct Shown { let section: PanelSection; let folded: Bool }
        var shown: [Shown] = model.sections.compactMap { section in
            let folded = section.kind == .alwaysHidden && section.isFolded && !foldOpen
            if section.count == 0 { return nil }
            if layout == .row && folded { return nil }
            return Shown(section: section, folded: folded)
        }
        let alwaysShown = shown.contains { $0.section.kind == .alwaysHidden && !$0.folded }
        if layout == .row {
            // One row, as the bar draws it: Always Hidden left of Hidden, a
            // divider between groups.
            let order: [PanelSection.Kind] = [.didntFit, .alwaysHidden, .hidden]
            shown.sort { order.firstIndex(of: $0.section.kind)! < order.firstIndex(of: $1.section.kind)! }
            let tiles = shown.map(\.section.tiles).reduce(into: [PanelTile]()) { all, group in
                if !all.isEmpty { all.append(.rowBreak) }
                all += group
            }
            shown = tiles.isEmpty ? [] : [Shown(section: PanelSection(kind: .hidden, tiles: tiles, isFolded: false), folded: false)]
        }

        let columns = options.columns
        let minimum = shown.filter { !$0.folded }
            .map { PanelGrid.neededColumns(of: $0.section.tiles, maximum: columns) }.max() ?? 1
        let didntFitShown = shown.contains { $0.section.kind == .didntFit }
        var content = PanelContent(layout: layout, query: query)
        content.hasAlwaysHidden = model.sections.contains { $0.kind == .alwaysHidden && $0.count > 0 }
        content.showsAlwaysHidden = alwaysShown
        content.motion = Self.foldStyle(appState.settings.revealAnimation)
        content.blocks = shown.map { entry in
            PanelBlock(
                kind: entry.section.kind,
                grid: PanelGrid(tiles: entry.section.tiles, columns: columns, layout: layout,
                                showsNames: options.showsNames, minimumColumns: minimum),
                count: entry.section.count,
                showsHeader: layout == .panel && (entry.section.kind == .didntFit || (entry.section.kind == .hidden && didntFitShown)),
                foldable: layout == .panel && entry.section.kind == .alwaysHidden,
                isFolded: entry.folded)
        }
        // A folded section draws its fold row only: its grid sets no width.
        content.width = max(content.blocks.filter { !$0.isFolded }.map(\.grid.contentSize.width).max() ?? 0, 150)

        let byKey = Dictionary(items.map { ($0.id.sectionKey, $0) }, uniquingKeysWith: { first, _ in first })
        var missing: [ItemID] = []
        for block in content.blocks where !block.isFolded {
            for tile in block.grid.rows.joined().map(\.tile) {
                switch tile {
                case .item(let key):
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
                case .rowBreak:
                    break
                }
            }
        }
        content.selected = selected.flatMap { content.art[$0] == nil ? nil : $0 }
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
        case .rowBreak:
            break
        }
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
        let columns = setColumns(distance: window.frame.maxX - NSEvent.mouseLocation.x, model: lastModel)
        showTip(String(localized: "\(columns) per row"), for: ended ? 0.5 : nil)
    }

    private func resetColumns() {
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
        case .rowBreak:
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
    let panel: PanelView

    var body: some View {
        panel.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topTrailing)
    }
}
