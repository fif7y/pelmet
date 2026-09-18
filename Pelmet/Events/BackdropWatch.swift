// BackdropWatch.swift
// Fires when a window may have moved under the menu bar. The bar is glass:
// a window edge or shadow parked just below it tints the bar's pixels, so
// any picture of the bar goes stale the moment that window moves (#33).
// No API announces "a window moved" across apps; these are the moments
// one can: a mouse-up ends a drag or resize, a modifier key-up ends a
// tiling shortcut, an activation or a Space switch brings windows forward.

import AppKit

@MainActor
final class BackdropWatch {
    private let onChange: () -> Void
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        // A drag ends where the mouse-up lands and the hand goes straight
        // to the bar (330ms measured, Gab 2026-09-17): check at once.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.schedule(after: 0)
        } as Any)
        // Tiling shortcuts animate the window into place.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return }
            self?.schedule(after: AppTiming.backdropSettle)
        } as Any)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedule(after: AppTiming.backdropSettle) }
            })
        }
    }

    /// One look after the last signal in a burst.
    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        guard delay > 0 else {
            pending = nil
            onChange()
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
