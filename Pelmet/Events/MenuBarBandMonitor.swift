// MenuBarBandMonitor.swift
// Watches the menubar band on every display: hover dwell + empty-area clicks
// reveal; leaving the band / clicking elsewhere feeds the rehide machine.
// Also implements per-display behavior: the display the pointer is on wins.

import AppKit
import PelmetCore
import PelmetEngine

final class MenuBarBandMonitor {
    private weak var appState: AppState?
    private var mouseMonitor: Any?
    private var clickMonitor: Any?
    private var dragMonitor: Any?
    private var hoverTimer: Timer?
    private var pointerInBand = false
    private var cmdDragActive = false
    /// A ⌘-drag happened since the last adoption pass. Band-exit adoption is
    /// a catch-all for missed mouse-ups — but unconditionally snapshotting the
    /// AX tree on EVERY top-edge graze was the tax; only drags change layout.
    private var dragSinceAdoption = false
    private var lastDisplayUUID: String?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Passive global monitors: enough for hover + click detection, no
        // event swallowing (empty-area clicks fall through harmlessly).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.pointerMoved()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.clicked(event)
        }
        // ⌘-drag tracking: rehide must never fire mid-drag, and adoption runs
        // the moment the drag ends — before the next conceal can act on a
        // stale model (which hid everything except the freshly dragged item).
        dragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.dragEvent(event)
        }
    }

    private func dragEvent(_ event: NSEvent) {
        guard let appState else { return }
        switch event.type {
        case .leftMouseDragged:
            guard event.modifierFlags.contains(.command) else { return }
            // Pelmet's own synthetic drags reach this global monitor too —
            // adopting them is circular (model → drag → adopt → model), and
            // adopting a BOUNCED one would cement the failure into the model.
            guard !appState.syntheticDragInFlight else { return }
            let location = NSEvent.mouseLocation
            let screen = NSScreen.containing(location)
            guard let screen, isInMenuBarBand(location, of: screen) else { return }
            if !cmdDragActive {
                cmdDragActive = true
                dragSinceAdoption = true
                appState.pointerReturnedToBand()  // cancels any rehide countdown
                PelmetLog.log("band: ⌘-drag started")
            }
        case .leftMouseUp:
            guard cmdDragActive else { return }
            cmdDragActive = false
            // The drop x identifies WHICH item was dragged (it lands under
            // the cursor) — chevron-less zone adoption needs that identity.
            let dropX = NSEvent.mouseLocation.x
            PelmetLog.log("band: ⌘-drag ended → adopting (dropX=\(Int(dropX)))")
            // Give MenuBarAgent a beat to finalize the new position, then
            // adopt before rehide can run a stale conceal.
            DispatchQueue.main.asyncAfter(deadline: .now() + AppTiming.dragAdoptDelay) { [weak self] in
                guard let self, let appState = self.appState else { return }
                self.dragSinceAdoption = false
                appState.adoptSectionsFromBar(dragEndX: dropX)
                if appState.isRevealed {
                    appState.pointerLeftBand()  // re-arm the countdown
                }
            }
        default:
            break
        }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        mouseMonitor = nil
        clickMonitor = nil
        dragMonitor = nil
        hoverTimer?.invalidate()
    }

    // MARK: - Pointer

    private func pointerMoved() {
        guard let appState else { return }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.containing(location)
        let inBand = screen.map { isInMenuBarBand(location, of: $0) } ?? false
        let displayUUID = screen?.displayUUIDString

        // Per-display behavior: crossing onto an "always show all" display
        // reveals; crossing back to a "collapse" display arms the countdown.
        // (An instant conceal here flashed the bar open-shut when the pointer
        // crossed displays right after a hover reveal — rehide, don't snap.)
        if displayUUID != lastDisplayUUID {
            // First sighting (nil at launch) is a baseline, not a crossing —
            // treating it as one concealed the bar on the first mouse move
            // after a reveal.
            let crossed = lastDisplayUUID != nil
            lastDisplayUUID = displayUUID
            if crossed {
                switch appState.settings.behavior(forDisplayUUID: displayUUID) {
                case .alwaysShowAll:
                    // Not .hover: a display-policy reveal must not inherit the
                    // hover fast-rehide path, and the rehide timer defers
                    // while the pointer stays on this display.
                    appState.reveal([.hidden], reason: .displayPolicy)
                case .collapse:
                    if appState.isRevealed {
                        appState.pointerLeftBand()
                    }
                }
            }
        }

        guard appState.settings.behavior(forDisplayUUID: displayUUID) == .collapse else { return }

        if inBand, !pointerInBand {
            pointerInBand = true
            appState.pointerReturnedToBand()
            // A synthetic placement warps the pointer through the band — a
            // hover reveal mid-drag injects a reveal/conceal cycle under the
            // running drag (frames shift mid-measurement; seen live during
            // the first overflow rescue). Not a hover.
            scheduleHoverReveal()
        } else if !inBand, pointerInBand {
            pointerInBand = false
            hoverTimer?.invalidate()
            // Leaving the band arms the countdown (never an instant conceal),
            // and catches a ⌘-drag whose mouse-up the monitor missed.
            appState.pointerLeftBand()
            if dragSinceAdoption {
                dragSinceAdoption = false
                appState.adoptSectionsFromBar()
            }
        }
    }

    /// True while rehide should hold off: pointer in the band, over a
    /// menubar-anchored menu/popover, or interacting with Pelmet's own windows.
    func shouldDeferRehide() -> Bool {
        if pointerInBand { return true }
        // Pelmet frontmost only holds the bar for the layout editor and the
        // onboarding demo — the General tab is not a reason to stay revealed.
        if NSApp.isActive, appState?.editorHoldsBar == true || OnboardingController.shared.isPresented { return true }
        return pointerIsOverElevatedWindow()
    }

    /// Diagnostic twin of `shouldDeferRehide` — which gate held.
    func deferReason() -> String {
        "band=\(pointerInBand) active=\(NSApp.isActive) elevated=\(pointerIsOverElevatedWindow())"
    }

    /// Deliberately narrow: only visible, menu/popover-sized windows at
    /// elevated levels count. `layer > 0` alone matches the invisible
    /// always-on-top helper windows half the utilities on a Mac keep around
    /// (PopClip, Unclutter, Raycast…) — that overreach made rehide never fire.
    private func pointerIsOverElevatedWindow() -> Bool {
        let location = NSEvent.mouseLocation
        guard
            let primary = NSScreen.screens.first,
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return false }
        // CG window bounds are top-left-origin global coordinates.
        let cgPoint = CGPoint(x: location.x, y: primary.frame.maxY - location.y)
        // Menus and popovers hang BELOW the bar. Anything whose top edge sits
        // in or above the band is a host/overlay window, not something the
        // user opened: Control Center keeps a 656×973 layer-101 window at
        // y=0 and Sconce a 640×538 layer-25 overlay at y=-40 — both passed
        // the size filter and pinned every hover-out reveal open (2026-09-02).
        let bandHeight = primary.frame.maxY - primary.visibleFrame.maxY
        for window in windows {
            guard
                let layer = window[kCGWindowLayer as String] as? Int,
                // Status-item popovers and menus live in this level range;
                // floating utility panels (level 3) and the Dock (20) don't count.
                layer >= 24, layer <= 102,
                let alpha = window[kCGWindowAlpha as String] as? CGFloat, alpha > 0.05,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"],
                // Menu/popover-sized, not screen-covering overlays.
                width < 900, height < 1200, width > 4, height > 4,
                y >= bandHeight - 1
            else { continue }
            if CGRect(x: x, y: y, width: width, height: height).contains(cgPoint) {
                return true
            }
        }
        return false
    }

    /// Pointer state for the settle catch-up: a reveal that outlives its hover
    /// re-arms on the short clock.
    var pointerCurrentlyInBand: Bool { pointerInBand }

    private func scheduleHoverReveal() {
        guard let appState,
              appState.settings.revealTriggers.hoverEnabled, !appState.isRevealed,
              !appState.syntheticDragInFlight else { return }
        // Floor: otherwise the bar flaps open on the way to a hot corner.
        let delay = max(appState.settings.revealTriggers.hoverDelay, AppTiming.hoverDelayFloor)
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState, self.pointerInBand else { return }
                // Re-verify against the LIVE pointer, not just the
                // tracked flag — the flag lags by one event-delivery
                // latency, which is exactly a fast swipe-through. A
                // graze must not open the bar.
                let location = NSEvent.mouseLocation
                guard let screen = NSScreen.containing(location),
                      self.isInMenuBarBand(location, of: screen),
                      !appState.syntheticDragInFlight else { return }
                appState.reveal([.hidden], reason: .hover)
            }
        }
    }

    /// Conceal-settle self-heal (mirror of the reveal-side one): a rapid
    /// hover out-in can put the pointer back in the band while a conceal is
    /// mid-flight — the entry edge is already spent, so without this the bar
    /// stays shut under a hovering pointer until it leaves and re-enters.
    func rearmHoverAfterConceal() {
        guard pointerInBand,
              let appState,
              appState.settings.behavior(
                forDisplayUUID: NSScreen.containing(NSEvent.mouseLocation)?.displayUUIDString
              ) == .collapse
        else { return }
        scheduleHoverReveal()
    }

    private func clicked(_ event: NSEvent) {
        guard let appState else { return }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.containing(location)
        let inBand = screen.map { isInMenuBarBand(location, of: $0) } ?? false

        if inBand {
            // Synthetic placement drags post real ⌘-mouse-downs in the band —
            // the hit-test can read one as an empty-area click (a trapped
            // item's phantom position has no element under it) and toggle a
            // reveal under the running drag (seen live during rescue).
            guard !appState.syntheticDragInFlight else { return }
            guard isEmptyMenuBarArea(location, on: screen) else { return }
            if event.type == .rightMouseDown {
                // Right-click on empty bar: always-available settings entry.
                let menu = PelmetStatusItem.contextMenu(appState: appState)
                menu.popUp(positioning: nil, at: location, in: nil)
                return
            }
            guard appState.settings.revealTriggers.clickEnabled else { return }
            PelmetLog.log("band: empty-area click count=\(event.clickCount)")
            if event.clickCount >= 2 {
                // Second click of a double. With the feature off, ignore it —
                // acting again reads as an open-shut flash.
                if appState.settings.revealTriggers.doubleClickForAlwaysHidden {
                    appState.reveal([.hidden, .alwaysHidden], reason: .doubleClick)
                }
            } else {
                // Single click acts IMMEDIATELY — the old 300ms double-click
                // defer made every plain click feel dead. A double's second
                // click widens the reveal on top (revealRequested unions), so
                // no defer is needed to keep double-click working.
                appState.toggle(reason: .click)
            }
        } else if appState.isRevealed {
            // Clicks inside Pelmet's own UI or a status-item menu/popover are
            // part of using the revealed items — and while the settings window
            // is open nothing collapses, period. Clicks on an "always show"
            // display never collapse either: the display's policy wins.
            if !appState.editorHoldsBar, !NSApp.isActive, !pointerIsOverElevatedWindow(),
               appState.settings.behavior(forDisplayUUID: screen?.displayUUIDString) == .collapse {
                appState.rehideTriggered(.clickedElsewhere)
            }
        }
    }

    // MARK: - Geometry

    private func isInMenuBarBand(_ point: NSPoint, of screen: NSScreen) -> Bool {
        let bandHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard bandHeight > 0 else { return false }
        let band = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - bandHeight,
            width: screen.frame.width,
            height: bandHeight
        )
        return NSMouseInRect(point, band, false)
    }

    /// Empty = the AX element under the pointer belongs to the menubar host
    /// but is not an item/menu. A systemwide hit-test works on every display
    /// (the snapshot's frames are main-display-only, which silently broke
    /// empty-click detection on external screens).
    private func isEmptyMenuBarArea(_ point: NSPoint, on screen: NSScreen?) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        // Convert bottom-left mouse coords → top-left AX coords.
        let axPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              let element else {
            // Nothing under the pointer at all — treat as empty bar.
            return true
        }
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        // Items, buttons, and app menus are NOT empty; the agent's bare
        // window/group backdrop is.
        let itemRoles: Set<String> = ["AXMenuBarItem", "AXButton", "AXMenuButton", "AXImage"]
        // The frontmost app's bare AXMenuBar element is the backdrop that
        // spans the whole bar — hitting it (not an AXMenuBarItem title) means
        // empty space. The agent's own window/group backdrop counts too.
        let empty = !itemRoles.contains(role)
            && (role == "AXMenuBar"
                || owner == PelmetBundle.agentID
                || role == "AXWindow" || role == "AXGroup")
        PelmetLog.log("band: hit-test role=\(role) owner=\(owner) → empty=\(empty)")
        return empty
    }

}
