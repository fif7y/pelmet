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
    private var hosting: NSHostingView<PanelView>?
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
        show(takeKey: !openedByHover, fadeIn: !wasOpen)
        PelmetLog.log("panel: \(wasOpen ? "widened" : "open") (\(reason.map { "\($0)" } ?? "no reason")) — \(shown.tiles) tile(s), \(shown.missing.count) without a picture, key=\(window?.isKeyWindow == true)")
        // Settled on the next turn, as the bar's reveal settles after its
        // effect returns: the machine is still in this dispatch.
        DispatchQueue.main.async { [weak self] in self?.appState?.panelDidSettle() }
        picturePassIfNeeded(shown.missing)
    }

    func conceal(trace: PerfTrace) {
        close()
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

    private func ensureWindow() -> (KeyableGlassPanel, NSHostingView<PanelView>) {
        if let window, let hosting { return (window, hosting) }
        let hosting = NSHostingView(rootView: PanelView(content: PanelContent(), onPress: { _ in }, onFold: {}))
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
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
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
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
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
        let mods = event.modifierFlags.intersection([.command, .control])
        switch event.keyCode {
        case 53:  // Esc
            if query.isEmpty { appState?.concealNow() } else { setQuery("") }
        case 36, 76:  // Return, Enter
            if let tile = selected ?? lastModel?.bestMatch { press(tile) }
        case 123: moveSelection(.left)
        case 124: moveSelection(.right)
        case 125: moveSelection(.down)
        case 126: moveSelection(.up)
        case 51:  // Delete
            if !query.isEmpty { setQuery(String(query.dropLast())) }
        default:
            guard mods.isEmpty, let typed = event.characters, !typed.isEmpty,
                  // Function keys type private-use characters.
                  typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }),
                  !(query.isEmpty && typed == " ")
            else { return false }
            setQuery(query + typed)
        }
        return true
    }

    private func setQuery(_ new: String) {
        query = new
        selectBest = true
        refresh()
    }

    /// Along the section's grid; off its edge into the next section, and
    /// down past the last one opens a folded Always Hidden.
    private func moveSelection(_ direction: PanelGrid.Direction) {
        guard let content = lastContent else { return }
        let grids = content.blocks.filter { !$0.isFolded }.map(\.grid)
        func select(_ tile: PanelTile?) {
            guard let tile else { return }
            selected = tile
            refresh()
        }
        guard let current = selected, let g = grids.firstIndex(where: { $0.placement(of: current) != nil }),
              let here = grids[g].placement(of: current)
        else {
            select(grids.lazy.compactMap(\.firstTile).first)
            return
        }
        if let next = grids[g].neighbour(of: current, toward: direction) {
            select(next)
            return
        }
        func atColumn(_ row: [PanelGrid.Placement]?) -> PanelTile? {
            guard let row, !row.isEmpty else { return nil }
            return row[min(here.column, row.count - 1)].tile
        }
        switch direction {
        case .right where g + 1 < grids.count: select(grids[g + 1].firstTile)
        case .left where g > 0: select(grids[g - 1].rows.last?.last?.tile)
        case .down where g + 1 < grids.count: select(atColumn(grids[g + 1].rows.first))
        case .up where g > 0: select(atColumn(grids[g - 1].rows.last))
        case .down where content.blocks.contains(where: \.isFolded): toggleFold()
        default: break
        }
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
        window.place(frame)
        window.setGlassHeight(frame.height)
    }

    // MARK: - Content

    /// Rebuilds the tiles and fits the window to them. Returns how many
    /// tiles it drew and which items have no picture yet.
    @discardableResult
    private func refresh() -> (tiles: Int, missing: [ItemID]) {
        guard let appState else { return (0, []) }
        let (_, hosting) = ensureWindow()
        let (content, missing) = buildContent(appState)
        let view = PanelView(
            content: content,
            onPress: { [weak self] tile in self?.press(tile) },
            onFold: { [weak self] in self?.toggleFold() },
            tileMenu: { [weak self] tile in self?.menu(for: tile) ?? [] },
            panelMenu: { [weak self] in self?.panelMenu() ?? [] },
            onColumnsDrag: { [weak self] ended in self?.dragColumns(ended: ended) },
            onColumnsReset: { [weak self] in self?.resetColumns() })
        hosting.rootView = view
        // The hosting view sizes nothing (`sizingOptions = []`), so its
        // fitting size is zero: the view measures itself here.
        place(NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: 4000, height: 4000)))
        return (content.art.count, missing)
    }

    private func buildContent(_ appState: AppState) -> (PanelContent, missing: [ItemID]) {
        let options = appState.settings.panel
        let layout = appState.revealTarget.panelLayout ?? .panel
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
            alwaysHiddenRequested: sections.contains(.alwaysHidden),
            query: query,
            candidates: corpus.map(\.candidate),
            history: history)
        lastModel = model
        if selectBest {
            selected = query.isEmpty ? nil : model.bestMatch
            selectBest = false
        }

        // What is on screen, in stacking order. A folded Always Hidden draws
        // its fold row only; the row layout has no fold, so it leaves it out.
        struct Shown { let section: PanelSection; let folded: Bool }
        var shown: [Shown] = model.sections.compactMap { section in
            let folded = section.kind == .alwaysHidden && section.isFolded && !foldOpen
            if section.count == 0 { return nil }
            if layout == .row && folded { return nil }
            return Shown(section: section, folded: folded)
        }
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
        content.columnsTip = columnsTip
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
                    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                        .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? Self.placeholder
                    content.art[tile] = PanelTileArt(
                        image: .icon(icon), name: ItemNaming.appName(forBundle: bundle) ?? bundle, dimmed: true)
                case .rowBreak:
                    break
                }
            }
        }
        // A filter or a fold can take the selected tile away.
        if let selected, content.art[selected] == nil { self.selected = nil }
        content.selected = self.selected
        lastContent = content
        return (content, missing)
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

    private func press(_ tile: PanelTile) {
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

    /// Columns from where the pointer is: the panel's right edge stays put,
    /// so each tile's width left of it is one more column. Two at least, no
    /// more than the widest section can fill, ten at most. Stored for the
    /// current names mode.
    private func dragColumns(ended: Bool) {
        guard let appState, let window else { return }
        let options = appState.settings.panel
        let metrics = PanelMetrics.standard(layout: .panel, showsNames: options.showsNames)
        let pitch = metrics.tileSize.width + metrics.columnGap
        let want = Int(((window.frame.maxX - metrics.padding - NSEvent.mouseLocation.x + metrics.columnGap) / pitch).rounded())
        let most = max(2, lastModel?.sections.map { PanelGrid.neededColumns(of: $0.tiles, maximum: 10) }.max() ?? 2)
        let columns = min(max(want, 2), most)
        if options.columns != columns {
            appState.settings.panel.columns = columns
            appState.settingsChanged()
            PelmetLog.log("panel: \(columns) column(s)")
        }
        showTip(String(localized: "\(columns) per row"), for: ended ? 0.5 : nil)
    }

    private func resetColumns() {
        guard let appState else { return }
        appState.settings.panel.columns = nil
        appState.settingsChanged()
        PelmetLog.log("panel: columns Auto")
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
    private func menu(for tile: PanelTile) -> [PanelMenuRow] {
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
    private func panelMenu() -> [PanelMenuRow] {
        guard let appState else { return [] }
        let layout = appState.revealTarget.panelLayout ?? .panel
        let alwaysShown = lastContent?.blocks.contains { $0.kind == .alwaysHidden && !$0.isFolded } ?? false
        let hasAlways = lastContent?.blocks.contains { $0.kind == .alwaysHidden } ?? false
        return [
            .header(String(localized: "Layout")),
            .check(String(localized: "Panel"), layout == .panel) { [weak self] in self?.setTarget(.panel) },
            .check(String(localized: "Row"), layout == .row) { [weak self] in self?.setTarget(.row) },
            .divider,
            .check(String(localized: "Show Names"), appState.settings.panel.showsNames, enabled: layout == .panel) { [weak self] in
                guard let self, let appState = self.appState else { return }
                appState.settings.panel.showsNames.toggle()
                appState.settingsChanged()
                self.refresh()
            },
            .check(String(localized: "Always Hidden"), alwaysShown, enabled: hasAlways) { [weak self] in self?.toggleFold() },
            .divider,
            .action(String(localized: "Pelmet Settings…")) { [weak appState] in
                appState?.concealNow()
                appState?.openSettings(tab: .menuBar)
            },
        ]
    }

    /// The layout picked from the panel's menu is the setting from then on:
    /// the dev override gives way to it.
    private func setTarget(_ target: RevealTarget) {
        guard let appState else { return }
        UserDefaults.standard.removeObject(forKey: "pelmet.debug.panel")
        appState.settings.hiddenIconsIn = target
        appState.settingsChanged()
        PelmetLog.log("panel: layout \(target.rawValue)")
        refresh()
    }

    private func toggleFold() {
        if let appState, appState.settings.panel.alwaysHidden == .asLeft {
            // Left as it was: the next open finds it the same way.
            let shown = lastContent?.blocks.contains { $0.kind == .alwaysHidden && !$0.isFolded } ?? false
            appState.settings.panel.alwaysHiddenOpen = !shown
            appState.settingsChanged()
            foldOpen = false
        } else {
            foldOpen.toggle()
        }
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

    /// The pass, once, when the open panel shows tiles with no picture.
    private func picturePassIfNeeded(_ missing: [ItemID]) {
        guard passTask == nil, let appState, appState.screenRecordingGranted else { return }
        let wanted = missing.filter { key in
            unpicturable[key].map { -$0.timeIntervalSinceNow >= ItemPictures.maxAge } ?? true
        }
        guard !wanted.isEmpty else { return }
        let roster = appState.settings.sectionModel.roster
        let needsAlways = wanted.contains { roster.section(of: $0) == .alwaysHidden }
        let reveal: Set<PelmetCore.Section> = needsAlways ? [.hidden, .alwaysHidden] : [.hidden]
        passTask = Task { @MainActor [weak self, weak appState] in
            guard let appState else { return }
            let found = await appState.transitions.picturePass(reveal)
            guard let self else { return }
            self.passTask = nil
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
