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
            anchorX: appState.transitions.sectionAnchorX,
            pointerX: NSEvent.mouseLocation.x
        )
        panel.show(cells: cells, placement: placement)
        let missing = pictures.missing(among: cells.map(\.key))
        PelmetLog.log("tray: cells " + cells.map { "\($0.key.rawValue.split(separator: ":").last ?? "?")=\(Int($0.size.width))×\(Int($0.size.height))\($0.isPicture ? "" : " icon")" }.joined(separator: " "))
        PelmetLog.log("tray: open \(sections.map(\.rawValue).sorted()) — \(cells.count) cell(s), \(cells.count - missing.count) picture(s), \(placement.position.rawValue) on display \(screen.directDisplayID ?? 0)")
        onOpened?()
        if !missing.isEmpty, ScreenRecordingAccess.isGranted {
            picturePass(reason: "\(missing.count) missing")
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
        for section in [PelmetCore.Section.hidden, .alwaysHidden] where sections.contains(section) {
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
        guard relayTask == nil else {
            PelmetLog.log("tray: press \(key.rawValue) ignored, a relay is running")
            return
        }
        panel.setPressed(key)
        relayTask = Task { @MainActor in
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
        let stale = pictures.picture(for: key).map { Date().timeIntervalSince($0.takenAt) > AppTiming.trayPictureFreshness } ?? true
        let background = stale ? await appState.transitions.trayBackground() : []
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
        var got = 0
        if stale {
            let mine = snap.items.filter { $0.id.sectionKey == key }
            got = await appState.transitions.harvestTrayPictures(into: pictures, items: mine, background: background)
        }
        let item = snap.items.first { $0.id.sectionKey == key && $0.frame != nil }
        var shown = false
        if let item {
            // AX first (no pointer involved), a shielded HID click when
            // nothing shows: Apple's hosts and Control Center's modules
            // take the press and do nothing with it.
            let before = TrayPress.elevatedWindowCount()
            // Apple's hosts and the system modules take the AX press and do
            // nothing with it (Passwords, Weather, Sound): straight to the
            // click for them.
            let apple = item.id.isSystemModule || (item.id.bundleID?.hasPrefix("com.apple.") ?? true)
            let pressed = !apple && item.pid > 0 && TrayPress.press(item)
            if pressed { shown = await Self.somethingShown(over: before) }
            var clicked = false
            if !shown {
                clicked = true
                await TrayPress.click(item)
                shown = await Self.somethingShown(over: before)
            }
            PelmetLog.log("tray: press \(key.rawValue) → \(pressed ? "pressed" : "AX skipped")\(clicked ? ", clicked" : ""), \(shown ? "showed something" : "showed nothing")\(toggle == nil ? "" : " (« expanded)"), \(got) picture(s), \(Int(-started.timeIntervalSinceNow * 1000))ms")
            if shown {
                // Whatever showed keeps the item revealed; the conceal
                // follows its dismissal.
                let cap = Date().addingTimeInterval(AppTiming.trayRelayMenuCap)
                while Date() < cap, TrayPress.elevatedWindowCount() > before {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                PelmetLog.log("tray: \(key.rawValue) gone at \(Int(-started.timeIntervalSinceNow * 1000))ms")
            }
        } else {
            PelmetLog.log("tray: press \(key.rawValue) → not on screen, \(Int(-started.timeIntervalSinceNow * 1000))ms")
        }
        panel.setPressed(nil)
        if let toggle { await OverflowToggle.collapseAfterPass(toggle) }
        await appState.engine.conceal()
        appState.updateSnapshot(await appState.engine.snapshot())
        if let cover { appState.transitions.endBarCover(cover, label: "tray") }
        frozen = false
        if got > 0 { refresh() }
    }

    /// Polls for an elevated window beyond `before` within the menu wait.
    private static func somethingShown(over before: Int) async -> Bool {
        let showBy = Date().addingTimeInterval(AppTiming.trayRelayMenuWait)
        while Date() < showBy {
            try? await Task.sleep(for: .milliseconds(30))
            if TrayPress.elevatedWindowCount() > before { return true }
        }
        return false
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
            // The section's items, not the section: no section changes, so
            // Pelmet's own extras stay put and nothing else reflows.
            await appState.engine.reveal(items: Set(cellSections.keys))
            appState.updateSnapshot(await appState.engine.snapshot())
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            try? await Task.sleep(for: AppTiming.trayRelaySettle)
            let snap = await appState.engine.freshSnapshot()
            let inSection = snap.items.filter { sections.contains(appState.settings.sectionModel.section(of: $0.id)) }
            let got = Task.isCancelled ? 0 : await appState.transitions.harvestTrayPictures(into: pictures, items: inSection, background: background)
            await appState.engine.conceal()
            appState.updateSnapshot(await appState.engine.snapshot())
            if let cover { appState.transitions.endBarCover(cover, label: "tray") }
            PelmetLog.log("tray: picture pass (\(reason)) → \(got) picture(s) in \(Int(-started.timeIntervalSinceNow * 1000))ms")
            frozen = false
            if got > 0 { refresh() }
        }
    }

    // MARK: - Reorder

    /// A drop: the new order is an editor drawing per section, applied at
    /// once. The pass needs the items in the bar, so the tray closes first.
    private func reordered(_ order: [ItemID]) {
        guard let appState else { return }
        for section in [PelmetCore.Section.hidden, .alwaysHidden] where sections.contains(section) {
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
