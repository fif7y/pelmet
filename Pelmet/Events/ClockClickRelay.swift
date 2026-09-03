// ClockClickRelay.swift
// Clicking the clock opens Notification Center — unless a hide assertion is
// held, in which case ControlCenter's clock module silently refuses (any
// visibility restriction, any origin, any allowlist; probe-proven
// 2026-09-03). Pelmet can't reach NC itself (every NC service is behind a
// private entitlement) and can't fake the two-finger swipe (recognized
// in-process from raw multitouch frames). What works: intercept the
// physical click with an event tap, drop the assertion, replay the click,
// re-acquire. Hidden icons flash in and out for ~0.5s — the agent finishes
// its reveal animation before the re-acquire applies, whatever the delay.
//
// The tap callback is pure geometry (no AX, no actor hops): it swallows a
// plain left-click on the clock and hands the point to the main thread,
// which runs the blink and replays the click tagged as synthetic so the
// tap lets it through. The physical mouse-up that follows is swallowed too;
// the replay carries its own up.

import AppKit
import PelmetEngine

// Runs off the main actor: the tap callback fires on the relay thread and
// the app target defaults to MainActor isolation (an inferred @MainActor
// closure trapped there on first event). State is lock-guarded.
nonisolated final class ClockClickRelay: @unchecked Sendable {
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private let lock = NSLock()
    /// Clock geometry, main-display AX frame (top-left origin, same space as
    /// CGEvent locations). Mirrored to every display by right-edge inset:
    /// the bar mirrors, so the clock sits the same distance from the right
    /// edge on each screen.
    private var insetFromRight: CGFloat?
    private var width: CGFloat = 0
    private var bandHeight: CGFloat = 0
    private var enabled = false
    /// A physical mouse-down was swallowed; eat the matching mouse-up.
    private var swallowUp = false
    private let onClick: @MainActor (CGPoint) -> Void

    init(onClick: @escaping @MainActor (CGPoint) -> Void) {
        self.onClick = onClick
    }

    func setEnabled(_ on: Bool) {
        lock.withLock { enabled = on }
        if on, tap == nil { startTap() }
    }

    /// Called with the latest engine snapshot's clock frame (nil when the
    /// clock isn't in the walk — locked screen, empty AX).
    @MainActor func updateClockFrame(_ frame: CGRect?) {
        guard let frame, let main = NSScreen.screens.first else { return }
        lock.withLock {
            insetFromRight = main.frame.width - frame.maxX
            width = frame.width
            bandHeight = max(frame.maxY, main.frame.maxY - main.visibleFrame.maxY)
        }
    }

    func stop() {
        lock.withLock { enabled = false }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapRunLoop, let tapSource {
            CFRunLoopRemoveSource(tapRunLoop, tapSource, .commonModes)
            CFRunLoopStop(tapRunLoop)
        }
        self.tap = nil
        tapSource = nil
        tapRunLoop = nil
    }

    // MARK: - Tap

    private func startTap() {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let relay = Unmanaged<ClockClickRelay>.fromOpaque(userInfo).takeUnretainedValue()
                return relay.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            PelmetLog.log("clock: relay tap unavailable — clock clicks stay native")
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
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "pelmet.clock-relay"
        thread.start()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Auto-disable notifications must re-enable or the tap dies silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Pelmet's own posted events (this relay's replay, placement drags).
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticInput.tag {
            return Unmanaged.passUnretained(event)
        }
        let location = event.location
        let decision: Bool = lock.withLock {
            if type == .leftMouseUp {
                defer { swallowUp = false }
                return swallowUp
            }
            guard enabled, isOnClock(location) else { return false }
            // Modifier clicks keep their native meaning (⌘-drag reorders).
            guard event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty else {
                return false
            }
            swallowUp = true
            return true
        }
        guard decision else { return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown {
            Task { @MainActor [onClick] in onClick(location) }
        }
        return nil
    }

    /// Pure geometry under the lock: the display containing the point, then
    /// the clock's right-edge inset on that display.
    private func isOnClock(_ point: CGPoint) -> Bool {
        guard let insetFromRight, width > 0, bandHeight > 0 else { return false }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else { return false }
        let bounds = CGDisplayBounds(display)
        guard point.y >= bounds.minY, point.y < bounds.minY + bandHeight else { return false }
        let maxX = bounds.maxX - insetFromRight
        return point.x >= maxX - width && point.x < maxX
    }

    // MARK: - Replay

    /// A real HID-source click with click state set — the agent ignores
    /// anything less (verified: a bare CGEvent click never opens NC).
    @MainActor static func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = SyntheticInput.tag
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                             mouseCursorPosition: point, mouseButton: .left)
        else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        usleep(useconds_t(AppTiming.clockReplayHold * 1_000_000))
        up.post(tap: .cghidEventTap)
    }
}
