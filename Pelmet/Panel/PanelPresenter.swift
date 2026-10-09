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
        if !wasOpen { foldOpen = false }
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
            if event.keyCode == 53 {  // Esc
                MainActor.assumeIsolated { self.appState?.concealNow() }
                return nil
            }
            return event
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
            onFold: { [weak self] in self?.toggleFold() })
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
        let model = PanelModel.build(
            roster: appState.settings.sectionModel.roster,
            items: items.map(\.id),
            drawnOrder: appState.lastDrawnOrder,
            didntFit: appState.overflowTrappedItems,
            options: options,
            alwaysHiddenRequested: sections.contains(.alwaysHidden))

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
        var content = PanelContent(layout: layout)
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
                        image: .icon(icon), name: ItemNaming.appName(forBundle: bundle) ?? bundle)
                case .rowBreak:
                    break
                }
            }
        }
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

    private func toggleFold() {
        foldOpen.toggle()
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
        let frame = window.frame.insetBy(dx: -40, dy: -40)
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
