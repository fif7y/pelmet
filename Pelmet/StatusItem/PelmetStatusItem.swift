// PelmetStatusItem.swift
// Pelmet's own (optional) menubar icon. Left-click toggles the hidden section;
// right-click opens the menu. AppKit NSStatusItem — MenuBarExtra can't do
// right-click or imperative button control.

import AppKit
import PelmetCore
import PelmetEngine

final class PelmetStatusItem {
    private let item: NSStatusItem
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Pelmet.StatusItem"
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: appState.settings.statusIconStyle.symbol(revealed: false),
                accessibilityDescription: "Pelmet"
            )
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Stable engine identity (chevron-boundary lookups key off this).
            button.setAccessibilityTitle("Pelmet.StatusItem")
        }
        updateAccessibilityWarning(granted: appState.accessibilityGranted)
        showUpdateDot(SparkleController.shared.availableVersion != nil)
    }

    /// An available update earns a 5pt accent dot at the chevron's top
    /// right — the one surface most users ever look at. It lives until the
    /// install relaunches the app.
    private var updateDot: NSView?

    func showUpdateDot(_ show: Bool) {
        guard let button = item.button else { return }
        if show, updateDot == nil {
            let size: CGFloat = 5
            let dot = NSView(frame: NSRect(
                x: button.bounds.width - size - 3, y: button.bounds.height - size - 3,
                width: size, height: size
            ))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = PelmetAccent.nsColor.cgColor
            dot.layer?.cornerRadius = size / 2
            dot.autoresizingMask = [.minXMargin, .minYMargin]
            button.addSubview(dot)
            updateDot = dot
        } else if !show {
            updateDot?.removeFromSuperview()
            updateDot = nil
        }
    }

    /// Without the Accessibility grant Pelmet can't see the bar, so the
    /// chevron itself carries the warning: system orange until it's back.
    func updateAccessibilityWarning(granted: Bool) {
        item.button?.contentTintColor = granted ? nil : .systemOrange
    }

    /// Call before releasing (deinit can't touch main-actor AppKit state under
    /// strict concurrency).
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func updateSymbol(revealed: Bool) {
        guard let style = appState?.settings.statusIconStyle else { return }
        item.button?.image = NSImage(
            systemSymbolName: style.symbol(revealed: revealed),
            accessibilityDescription: "Pelmet"
        )
    }

    @objc private func clicked() {
        guard let appState else { return }
        // currentEvent is nil for synthetic AX presses (VoiceOver etc.) —
        // treat those as a plain left-click toggle instead of bailing.
        let event = NSApp.currentEvent
        PelmetLog.log("statusItem clicked: type=\(event?.type.rawValue ?? 0)")
        if event?.type == .rightMouseUp {
            item.menu = Self.contextMenu(appState: appState)
            item.button?.performClick(nil)
            item.menu = nil
        } else if event?.modifierFlags.contains(.option) == true {
            appState.reveal([.hidden, .alwaysHidden], reason: .statusItem)
        } else {
            appState.toggle(reason: .statusItem)
        }
    }

    static func contextMenu(appState: AppState) -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: appState.isRevealed ? String(localized: "Hide Items") : String(localized: "Show Hidden Items"),
            action: #selector(AppMenuTarget.toggle), keyEquivalent: ""
        )
        let showAll = NSMenuItem(
            title: String(localized: "Show Always-Hidden Too"),
            action: #selector(AppMenuTarget.showAll), keyEquivalent: ""
        )
        let settings = NSMenuItem(
            title: String(localized: "Pelmet Settings…"),
            action: #selector(AppMenuTarget.openSettings), keyEquivalent: ","
        )
        let quit = NSMenuItem(
            title: String(localized: "Quit Pelmet"),
            action: #selector(AppMenuTarget.quit), keyEquivalent: "q"
        )
        let target = AppMenuTarget.shared
        target.appState = appState
        var items: [NSMenuItem] = [toggle, showAll, .separator(), settings, .separator(), quit]
        // Same line in every right-click (chevron, separators, empty bar):
        // the About chip is the only other trace once the banner is gone.
        if let version = SparkleController.shared.availableVersion {
            let update = NSMenuItem(
                title: String(localized: "Update to \(version)…"),
                action: #selector(AppMenuTarget.installUpdate), keyEquivalent: ""
            )
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [PelmetAccent.nsColor]))
            items.insert(contentsOf: [update, .separator()], at: 0)
        }
        if !appState.accessibilityGranted {
            // Lead with the fix: nothing else in this menu works without it.
            let grant = NSMenuItem(
                title: String(localized: "Accessibility access is off. Turn it on…"),
                action: #selector(AppMenuTarget.grantAccessibility), keyEquivalent: ""
            )
            grant.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            items.insert(contentsOf: [grant, .separator()], at: 0)
        }
        for menuItem in items where !menuItem.isSeparatorItem {
            menuItem.target = target
        }
        menu.items = items
        return menu
    }
}

/// Shared menu target so context menus built from separators and the status
/// item reuse one implementation.
final class AppMenuTarget: NSObject {
    static let shared = AppMenuTarget()
    weak var appState: AppState?

    @objc func toggle() { appState?.toggle(reason: .statusItem) }
    @objc func showAll() { appState?.reveal([.hidden, .alwaysHidden], reason: .statusItem) }
    @objc func openSettings() { appState?.openSettings() }
    @objc func grantAccessibility() { AccessibilityAccess.request() }
    /// The About pane is the update hub (chip, notes, toggles) — land there
    /// rather than straight in Sparkle's window.
    @objc func installUpdate() { appState?.openSettings(tab: .about) }
    @objc func quit() { NSApp.terminate(nil) }
}
