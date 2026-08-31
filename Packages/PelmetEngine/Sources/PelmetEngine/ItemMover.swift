// ItemMover.swift
// Physical repositioning WITHOUT restarting MenuBarAgent: synthesize the same
// ⌘-drag a human performs. macOS 27 handles coordinate-based drags natively
// (verified live on this machine) — the agent animates the move and persists
// the position itself. No rebuild, no blink, no relaunch.
//
// The drag is shielded (2026-08-31): physical mouse input during the synthetic
// sequence merges into the same HID stream — a physical move yanks the drag
// off-path (the agent mis-tracks slot crossings and bounces), a physical click
// lands wherever the warped cursor is (the menu bar — it can open a random
// item's menu), and a physical mouse-up cuts the drag short mid-path. So for
// the duration of the sequence: wait for a quiet gap in user input, decouple
// the physical mouse from the cursor, swallow physical mouse events with an
// active tap (our own events pass via a source-userData tag), and hide the
// cursor so the pointer doesn't visibly fly across the bar.

import AppKit
import CoreGraphics
import Foundation

public enum ItemMover {
    /// Performs a ⌘-drag from one menubar point to another (top-left-origin
    /// global coordinates, i.e. the same space as AX frames). Saves and
    /// restores the user's cursor so the pointer doesn't visibly teleport.
    ///
    /// Runs OFF the main actor deliberately: when the dragged item is Pelmet's
    /// OWN, our process runs AppKit's drag tracking — posting from the main
    /// actor interleaved the tracking loop with this function's sleeps and
    /// every own-item drop reverted, while a real ⌘-drag on the same item
    /// worked (verified live 2026-08-21). Third-party items never cared
    /// (their owning app tracks the drag).
    public static func cmdDrag(from: CGPoint, to: CGPoint) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // Tag every event from this source so the shield's tap can tell our
        // synthetic stream from real HID input.
        source.userData = DragShield.syntheticTag
        let originalPosition = CGEvent(source: nil)?.location

        // Don't grab the pointer out of the user's hand mid-motion — bounded
        // wait for a quiet gap (the shield still protects if it never comes).
        await waitForPointerQuiet()

        let shield = DragShield()
        shield.activate()
        defer { shield.deactivate() }

        func post(_ type: CGEventType, at point: CGPoint) {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }

        post(.leftMouseDown, at: from)
        // The ⌘-click hands frontmost to the dragged item's owner, and macOS
        // resets cursor visibility (and mouse association) on that flip — a
        // single pre-drag hide never survived it. Re-assert after every post;
        // SetsCursorInBackground (see DragShield) makes the re-hide stick.
        shield.reassert()
        // Hold briefly so the drag registers as a deliberate grab.
        try? await Task.sleep(for: .milliseconds(180))
        PelmetLog.log("mover: mid-drag cursor \(DragShield.cursorVisible ? "VISIBLE" : "hidden")")
        // Ease toward the target — single-jump drags are sometimes ignored,
        // and LONG drags need finer motion for the agent to track slot
        // crossings (a fixed-6-step 440pt drag = 74pt jumps bounced entirely,
        // verified live 2026-08-21).
        let distance = abs(to.x - from.x) + abs(to.y - from.y)
        let steps = min(24, max(6, Int(distance / 40)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let x = from.x + (to.x - from.x) * t
            let y = from.y + (to.y - from.y) * t
            post(.leftMouseDragged, at: CGPoint(x: x, y: y))
            shield.reassert()
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(120))
        post(.leftMouseUp, at: to)

        // Warp home while the shield still hides the cursor — it reappears
        // where the user left it, never mid-flight.
        if let originalPosition {
            try? await Task.sleep(for: .milliseconds(60))
            CGWarpMouseCursorPosition(originalPosition)
        }
    }

    /// Seconds since the user (or anyone) last produced a mouse event. Our own
    /// synthetic events count too, but callers only reach here ≥450ms after
    /// the previous drag (placementPreSettle), past the quiet gap already.
    private static func secondsSincePointerActivity() -> TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .scrollWheel,
        ]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? .infinity
    }

    private static func waitForPointerQuiet() async {
        let deadline = Date.now.addingTimeInterval(EngineTiming.dragIdleMaxWait)
        while Date.now < deadline {
            if secondsSincePointerActivity() >= EngineTiming.dragIdleQuietGap { return }
            try? await Task.sleep(for: EngineTiming.dragIdlePoll)
        }
        PelmetLog.log("mover: pointer never went quiet — dragging shielded anyway")
    }
}

// MARK: - Shield

/// Guards one synthetic-drag window. Three layers, each independently
/// crash-safe (the WindowServer resets connection state — association, cursor
/// hide, taps — if the process dies mid-drag):
/// 1. `CGAssociateMouseAndMouseCursorPosition(0)` — physical mouse motion
///    stops moving the cursor, so it can't yank the drag off its path.
/// 2. An active HID event tap on its own thread that swallows physical mouse
///    events (ours carry `syntheticTag` in source userData and pass) — no
///    miss-clicks into the menu bar, no premature physical mouse-up.
/// 3. `CGDisplayHideCursor` — the pointer vanishes for the window instead of
///    visibly flying. (May no-op while Pelmet isn't frontmost — cosmetic
///    layer only; 1+2 are what prevent harm.)
///
/// The tap needs a runloop; a dedicated thread hosts it because the main
/// runloop is busy running AppKit's drag tracking during own-item drags, and
/// a starved tap gets auto-disabled by timeout (passing everything through).
private final class DragShield {
    static let syntheticTag: Int64 = 0x504C_4D54 // "PLMT"

    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapSource: CFRunLoopSource?
    private var active = false
    private let armed = DispatchSemaphore(value: 0)

    /// `CGDisplayHideCursor` is FOREGROUND-gated, and the drag's first posted
    /// ⌘-click hands frontmost to the dragged item's owner — so the hide died
    /// the moment the drag started and the cursor stayed visible for the whole
    /// flight (observed live 2026-08-31). This SPI connection property opts
    /// our WindowServer connection into hiding the cursor from the background
    /// (same private-API disclosure posture as MenuBarClientCore). Connection
    /// state — a crash resets it. Resolved via dlsym like the hiding core.
    private static let backgroundCursorOptIn: Bool = {
        typealias MainCID = @convention(c) () -> UInt32
        typealias SetProp = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard
            let cidSym = dlsym(rtldDefault, "CGSMainConnectionID"),
            let setSym = dlsym(rtldDefault, "CGSSetConnectionProperty")
        else {
            PelmetLog.log("mover: CGS cursor SPI unresolved — cursor stays visible in background")
            return false
        }
        let cid = unsafeBitCast(cidSym, to: MainCID.self)()
        let err = unsafeBitCast(setSym, to: SetProp.self)(
            cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue
        )
        if err != 0 {
            PelmetLog.log("mover: SetsCursorInBackground refused (\(err)) — cursor stays visible in background")
        }
        return err == 0
    }()

    /// `CGDisplayHideCursor` is COUNTED — deactivate balances every hide.
    private var hideCount = 0

    /// Whether the cursor is globally visible right now (deprecated
    /// `CGCursorIsVisible`, resolved via dlsym to dodge the warning) —
    /// mid-drag diagnostic for whether the re-asserted hide actually took.
    static var cursorVisible: Bool {
        typealias IsVisible = @convention(c) () -> UInt32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else {
            return true
        }
        return unsafeBitCast(sym, to: IsVisible.self)() != 0
    }

    func activate() {
        guard !active else { return }
        active = true
        _ = Self.backgroundCursorOptIn
        reassert()
        startTap()
    }

    /// Association and cursor-hide are both reset by macOS whenever frontmost
    /// changes — which the drag itself causes. Cheap; called after every
    /// posted event.
    func reassert() {
        guard active else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    /// Idempotent, and the ONLY exit — every layer must come back up even on
    /// a failed drag; leaving association off or the tap alive would freeze
    /// the user's mouse for good.
    func deactivate() {
        guard active else { return }
        active = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapRunLoop, let tapSource {
            CFRunLoopRemoveSource(tapRunLoop, tapSource, .commonModes)
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        tapSource = nil
        tapRunLoop = nil
        while hideCount > 0 {
            CGDisplayShowCursor(CGMainDisplayID())
            hideCount -= 1
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func startTap() {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // Auto-disable notifications must pass or input wedges open.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == DragShield.syntheticTag {
                    return Unmanaged.passUnretained(event)
                }
                return nil // physical mouse input — swallowed for the window
            },
            userInfo: nil
        ) else {
            // No tap (permission edge) — degrade to association-off + hidden
            // cursor: the drag path stays deterministic, clicks aren't caught.
            PelmetLog.log("mover: shield tap unavailable — degraded shield")
            return
        }
        self.tap = tap
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.tapSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.armed.signal()
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "pelmet.drag-shield"
        thread.start()
        // Post no events until the tap is live — a race here would let the
        // first physical events through (harmless) but, worse, could let
        // deactivate() run before tapRunLoop exists and leak a live tap.
        if armed.wait(timeout: .now() + EngineTiming.dragShieldArmTimeout) == .timedOut {
            PelmetLog.log("mover: shield tap never armed — degraded shield")
        }
    }
}
