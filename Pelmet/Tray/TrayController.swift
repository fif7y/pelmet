// TrayController.swift
// The floating bar: a routed section opens in a glass tray under the menu
// bar instead of in it. The tray holds pictures of the section's items in
// drawn order; the bar itself stays as it is. A press on a cell reveals the
// section in the bar beneath a cover, presses the real item so its own menu
// opens, and conceals again once that menu is gone. A drag reorders the
// cells and the drop is an editor drawing applied through the Apply pass.
// The rehide machine owns the tray's lifetime exactly as it owns an in-bar
// reveal: AppState routes the reveal effect here and the conceal effect
// closes it, so every trigger, the timer and click-elsewhere work unchanged.

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class TrayController {
    weak var appState: AppState?
    let pictures = TrayPictures()
    private let panel = TrayPanel()
    private(set) var sections: Set<PelmetCore.Section> = []
    private var relayTask: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    /// Section of every cell shown, for a drop.
    private var cellSections: [ItemID: PelmetCore.Section] = [:]
    /// A relay or a picture pass has the bar in flux beneath the cover:
    /// the cells hold still until it is over.
    private var frozen = false
    /// Keys a pass could not picture, and when: not retried on every open.
    private var unpictured: [ItemID: Date] = [:]

    /// Settle re-entry: the tray is up (the reveal's settle) or gone (the
    /// conceal's). Wired by AppState like the coordinator's.
    var onOpened: (() -> Void)?
    var onClosed: (() -> Void)?

    init() {
        panel.onPress = { [weak self] key, event in self?.pressed(key, event: event) }
        panel.onReorder = { [weak self] order in self?.reordered(order) }
        panel.onDismiss = { [weak self] in
            PelmetLog.log("tray: Esc")
            self?.appState?.concealNow()
        }
    }

    var isOpen: Bool { panel.isShown }

    func contains(_ point: NSPoint) -> Bool { panel.contains(point) }

    /// A reveal of `sections` for `reason` opens here when every section is
    /// routed and the reason is a person's (the editor's preview and an
    /// Apply pass need the items in the bar).
    func takes(_ sections: Set<PelmetCore.Section>, reason: RevealReason?) -> Bool {
        guard let appState, !sections.isEmpty, !appState.editorHoldsBar else { return false }
        guard sections.isSubset(of: appState.settings.floatingBarSections) else { return false }
        // Nothing on the bar to show: the in-bar reveal handles the empty
        // case (and the editor's chip) as before.
        guard sections.contains(where: { section in appState.editorItems(in: section).contains { presentKeys.contains($0.id.sectionKey) } })
        else {
            PelmetLog.log("tray: \(sections.map(\.rawValue).sorted()) has nothing on the bar — in-bar reveal")
            return false
        }
        switch reason {
        case .hover, .click, .doubleClick, .hotkey, .statusItem, .none: return true
        case .displayPolicy, .settingsPreview, .barDrag: return false
        }
    }

    // MARK: - Open / close

    func open(_ sections: Set<PelmetCore.Section>) {
        guard let appState else { return }
        self.sections = sections
        let cells = buildCells()
        if panel.isShown {
            // Widened while open (a double-click adds Always Hidden): the
            // same tray, more cells.
            panel.update(cells: cells)
            onOpened?()
            return
        }
        let screen = NSScreen.underPointer ?? NSScreen.main ?? NSScreen.screens[0]
        let placement = TrayPanel.Placement(
            screen: screen,
            position: appState.settings.floatingBarPosition,
            scale: appState.settings.floatingBarSize.scale,
            anchorX: visibleClusterMinX ?? appState.transitions.sectionAnchorX,
            pointerX: NSEvent.mouseLocation.x
        )
        panel.show(cells: cells, placement: placement)
        // Own items draw their glyph, never a picture: not "missing".
        let missing = pictures.missing(among: cells.map(\.key).filter { $0.bundleID != PelmetBundle.mainID })
        PelmetLog.log("tray: cells " + cells.map { "\($0.key.rawValue.split(separator: ":").last ?? "?")=\(Int($0.size.width))×\(Int($0.size.height))\($0.isPicture ? "" : " icon")" }.joined(separator: " "))
        PelmetLog.log("tray: open \(sections.map(\.rawValue).sorted()) — \(cells.count) cell(s), \(cells.count - missing.count) picture(s), \(placement.position.rawValue) on display \(screen.directDisplayID ?? 0)")
        onOpened?()
        let stale = cells.contains { cell in
            cell.key.bundleID != PelmetBundle.mainID
                && (pictures.picture(for: cell.key).map { Date().timeIntervalSince($0.takenAt) > AppTiming.trayPictureFreshness } ?? false)
        }
        let worthAPass = missing.contains { unpictured[$0].map { Date().timeIntervalSince($0) > AppTiming.trayPictureFreshness } ?? true }
        if worthAPass || stale, ScreenRecordingAccess.isGranted {
            picturePass(reason: worthAPass ? "\(missing.count) missing" : "stale")
        }
    }

    func close() {
        guard panel.isShown else { onClosed?(); return }
        PelmetLog.log("tray: close")
        panel.hide()
        sections = []
        cellSections = [:]
        onClosed?()
    }

    /// The bar or the settings changed under an open tray.
    func refresh() {
        guard panel.isShown, !frozen else { return }
        let cells = buildCells()
        PelmetLog.log("tray: cells " + cells.map { "\($0.key.rawValue.split(separator: ":").last ?? "?")=\(Int($0.size.width))×\(Int($0.size.height))\($0.isPicture ? "" : " icon")" }.joined(separator: " "))
        panel.update(cells: cells)
    }

    /// Where the visible cluster starts (its leftmost icon, the chevron
    /// included): the section opens just left of it, so the tray hangs
    /// from there. Steadier than the last measured strip, which an Apply
    /// pass re-measures wider.
    private var visibleClusterMinX: CGFloat? {
        guard let appState, let snap = appState.snapshot, let primary = NSScreen.screens.first else { return nil }
        let model = appState.settings.sectionModel
        return snap.items.compactMap { item -> CGFloat? in
            guard let frame = item.frame, frame.maxX <= primary.frame.maxX + 1, frame.minX >= primary.frame.minX,
                  item.id == AppState.chevronItemID || model.section(of: item.id) == .visible
            else { return nil }
            return frame.minX
        }.min()
    }

    // MARK: - Cells

    /// Items on the bar right now, concealed ones included: a concealed
    /// item drops out of the AX tree, so it is in the snapshot's concealed
    /// set, not its item list.
    private var presentKeys: Set<ItemID> {
        guard let appState, let snap = appState.snapshot else { return [] }
        var keys = Set(snap.items.map(\.id.sectionKey)).union(snap.concealed.map(\.sectionKey))
        // Pelmet's own extras hide by their own visibility, not the
        // assertion: out of the AX tree and out of the concealed set while
        // their section is concealed, yet on the bar the moment it opens.
        for spec in appState.settings.extraItems {
            keys.insert(ExtrasManager.itemID(for: spec).sectionKey)
        }
        return keys
    }

    private func buildCells() -> [TrayPanel.Cell] {
        guard let appState else { return [] }
        let present = presentKeys
        var cells: [TrayPanel.Cell] = []
        cellSections = [:]
        // The bar's own order: Always Hidden sits left of Hidden, which
        // sits left of the visible cluster.
        for section in [PelmetCore.Section.alwaysHidden, .hidden] where sections.contains(section) {
            for item in appState.editorItems(in: section) {
                let key = item.id.sectionKey
                guard present.contains(key) else { continue }
                cellSections[key] = section
                if let picture = pictures.picture(for: key) {
                    let image = NSImage(cgImage: picture.image, size: picture.size)
                    cells.append(.init(key: key, image: image, size: picture.size, isPicture: true))
                } else {
                    let icon = ItemImageCache.icon(for: item.id)
                        ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
                        ?? NSImage()
                    cells.append(.init(key: key, image: icon, size: CGSize(width: 22, height: 22), isPicture: false))
                }
            }
        }
        return cells
    }

    // MARK: - Press

    private func pressed(_ key: ItemID, event: NSEvent) {
        guard let appState else { return }
        PelmetLog.log("tray: pressed \(key.rawValue)")
        if appState.isSeparator(key) {
            // A separator is Pelmet's: either button opens Pelmet's menu.
            let menu = PelmetStatusItem.contextMenu(appState: appState)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        if key.bundleID == PelmetBundle.mainID {
            // One of Pelmet's own: its action runs here, no relay needed.
            let ran = appState.activateExtra(key)
            PelmetLog.log("tray: press \(key.rawValue) → own item \(ran ? "activated" : "not found")")
            return
        }
        // A relay still waiting its popover out yields to the new press:
        // it conceals and this one runs after it.
        let previous = relayTask
        if previous != nil {
            PelmetLog.log("tray: press \(key.rawValue) — the running relay yields")
            previous?.cancel()
        }
        panel.setPressed(key)
        relayTask = Task { @MainActor in
            _ = await previous?.value
            await relay(key)
            relayTask = nil
        }
    }

    /// Reveal the one item beneath a cover (its section stays concealed,
    /// nothing else reflows), press it, wait its menu out, conceal.
    private func relay(_ key: ItemID) async {
        guard let appState else { return }
        passTask?.cancel()
        frozen = true
        defer { frozen = false }
        let started = Date()
        let background = await appState.transitions.trayBackground()
        let cover = await appState.transitions.beginBarCover(label: "tray")
        await appState.engine.reveal(items: [key])
        appState.updateSnapshot(await appState.engine.snapshot())
        await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
        try? await Task.sleep(for: AppTiming.trayRelaySettle)
        var snap = await appState.engine.freshSnapshot()
        var toggle: OverflowToggle.Toggle?
        if ApplyPass.trapped(snap).contains(key) {
            toggle = await OverflowToggle.expandForPass()
            if toggle != nil {
                try? await Task.sleep(for: AppTiming.overflowExpandSettle)
                snap = await appState.engine.freshSnapshot()
            }
        }
        let item = snap.items.first { $0.id.sectionKey == key && $0.frame != nil }
        var shown = false
        if let item {
            // The real click, always: an AX press left a SwiftUI menu bar
            // extra's button stuck highlighted (a capsule behind the glyph
            // in the bar, surviving relaunches — Passwords, Weather and a
            // third-party extra, 2026-09-21), and Apple's hosts and the
            // modules took it and did nothing.
            let before = TrayPress.elevatedWindowCount()
            let beforeOwn = TrayPress.windowCount(pid: item.pid)
            let wasFront = Self.isFrontmost(item.pid)
            await TrayPress.click(item)
            let how = await Self.somethingShown(over: before, own: beforeOwn, pid: item.pid, frontCounts: !wasFront)
            shown = how != nil
            PelmetLog.log("tray: press \(key.rawValue) → clicked, \(how.map { "showed \($0)" } ?? "showed nothing")\(toggle == nil ? "" : " (« expanded)"), \(Int(-started.timeIntervalSinceNow * 1000))ms")
            if let how {
                // Concealing under an open popover orphans it: the item's
                // button stays highlighted in the bar until the app is
                // clicked again (a capsule behind three icons, 2026-09-21).
                // Gone = the way it showed is undone: the windows are back
                // to the count before, or the app is no longer in front.
                // "In front" alone is a weak signal (an app can stay in
                // front after its popover closed): capped short.
                let cap = Date().addingTimeInterval(how == "its app in front" ? AppTiming.trayRelayFrontCap : AppTiming.trayRelayMenuCap)
                while Date() < cap, !Task.isCancelled {
                    let still: Bool
                    switch how {
                    case "a window": still = TrayPress.elevatedWindowCount() > before
                    case "its own window": still = TrayPress.windowCount(pid: item.pid) > beforeOwn
                    default: still = Self.isFrontmost(item.pid)
                    }
                    if !still { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                PelmetLog.log("tray: \(key.rawValue) gone at \(Int(-started.timeIntervalSinceNow * 1000))ms\(Task.isCancelled ? " (yielded)" : "")")
                // The item at rest again, still revealed beneath the cover:
                // its picture refreshed (a badge, a state the click changed).
                // Not after a click that opened nothing — the button is
                // still drawing its pressed look.
                if !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    let fresh = await appState.engine.freshSnapshot().items.filter { $0.id.sectionKey == key }
                    let got = await appState.transitions.harvestTrayPictures(into: pictures, items: fresh, background: background)
                    if got > 0 { frozen = false; refresh(); frozen = true }
                }
            }
        } else {
            PelmetLog.log("tray: press \(key.rawValue) → not on screen, \(Int(-started.timeIntervalSinceNow * 1000))ms")
        }
        panel.setPressed(nil)
        if let toggle { await OverflowToggle.collapseAfterPass(toggle) }
        await appState.engine.conceal()
        appState.updateSnapshot(await appState.engine.snapshot())
        if let cover { appState.transitions.endBarCover(cover, label: "tray") }
    }

    /// Polls for an elevated window beyond `before`, or the item's app
    /// coming to the front (a popover activates it), within the menu wait.
    private static func somethingShown(over before: Int, own beforeOwn: Int, pid: pid_t, frontCounts: Bool) async -> String? {
        let showBy = Date().addingTimeInterval(AppTiming.trayRelayMenuWait)
        while Date() < showBy, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            if TrayPress.elevatedWindowCount() > before { return "a window" }
            if TrayPress.windowCount(pid: pid) > beforeOwn { return "its own window" }
            if frontCounts, isFrontmost(pid) { return "its app in front" }
        }
        return nil
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        pid > 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// The relay without the press: the section's pictures, taken beneath
    /// a cover. Runs when the tray opens with cells that have none.
    private func picturePass(reason: String) {
        passTask?.cancel()
        passTask = Task { @MainActor in
            guard let appState, relayTask == nil else { return }
            frozen = true
            defer { frozen = false }
            let started = Date()
            let sections = self.sections
            let background = await appState.transitions.trayBackground()
            let cover = await appState.transitions.beginBarCover(label: "tray")
            // The whole section, companion muted: Pelmet's own extras stay
            // put. (Item-by-item, SwiftUI's menu bar extras came back with
            // a capsule behind their glyph that baked into the pictures.)
            await appState.engine.reveal(sections, quiet: true)
            appState.updateSnapshot(await appState.engine.snapshot())
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            try? await Task.sleep(for: AppTiming.trayRelaySettle)
            let snap = await appState.engine.freshSnapshot()
            let inSection = snap.items.filter { sections.contains(appState.settings.sectionModel.section(of: $0.id)) }
            let got = Task.isCancelled ? 0 : await appState.transitions.harvestTrayPictures(into: pictures, items: inSection, background: background)
            await appState.engine.conceal(quiet: true)
            appState.updateSnapshot(await appState.engine.snapshot())
            if let cover { appState.transitions.endBarCover(cover, label: "tray") }
            let still = pictures.missing(among: cellSections.keys.filter { $0.bundleID != PelmetBundle.mainID })
            for key in still { unpictured[key] = Date() }
            PelmetLog.log("tray: picture pass (\(reason)) → \(got) picture(s) in \(Int(-started.timeIntervalSinceNow * 1000))ms\(still.isEmpty ? "" : ", still none for \(still.map(\.rawValue))")")
            frozen = false
            if got > 0 { refresh() }
        }
    }

    // MARK: - Reorder

    /// A drop: the new order is an editor drawing per section, applied at
    /// once. The pass needs the items in the bar, so the tray closes first.
    private func reordered(_ order: [ItemID]) {
        guard let appState else { return }
        for section in [PelmetCore.Section.alwaysHidden, .hidden] where sections.contains(section) {
            let keys = order.filter { cellSections[$0] == section }
            let current = appState.currentOrder(in: section)
            guard keys != current.filter({ keys.contains($0) }) else { continue }
            for key in keys { appState.moveItem(key, to: section, before: nil) }
            PelmetLog.log("tray: \(section.rawValue) reordered → \(keys.map(\.rawValue))")
        }
        appState.concealNow()
        appState.applyOrderEdits()
    }
}
