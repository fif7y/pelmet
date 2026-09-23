import AppKit

/// Paints behind the native menu bar. It never owns or rearranges menu items.
@MainActor
final class BlackMenuBarOverlay {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var enabled = false
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    nonisolated(unsafe) private var spaceObserver: NSObjectProtocol?

    init() {
        let center = NotificationCenter.default
        screenObserver = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(rehome: true) }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        guard enabled else {
            for panel in panels.values { panel.close() }
            panels.removeAll()
            return
        }
        refresh()
    }

    private func refresh(rehome: Bool = false) {
        guard enabled else { return }
        let screens = NSScreen.screens
        let ids = Set(screens.compactMap(\.pelmetDisplayID))
        for id in panels.keys where !ids.contains(id) {
            panels.removeValue(forKey: id)?.close()
        }
        for screen in screens {
            guard let id = screen.pelmetDisplayID else { continue }
            let height = max(screen.safeAreaInsets.top,
                             screen.frame.maxY - screen.visibleFrame.maxY)
            guard height > 0 else { continue }
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                               width: screen.frame.width, height: height)
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            if rehome { panel.orderOut(nil) }
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // The native bar owns its background and items in one window. Above it
        // would cover the text and icons, so this must stay immediately below.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) - 1)
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenNone, .stationary, .ignoresCycle]
        return panel
    }
}

private extension NSScreen {
    var pelmetDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
