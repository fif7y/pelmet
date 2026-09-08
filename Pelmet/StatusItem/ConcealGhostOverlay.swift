// ConcealGhostOverlay.swift
// The reveal cover. The agent animates reveals with a slide-in of its own;
// the Instant and Fade styles hide that slide under a snapshot of the still-
// empty strip, floated over the bar until the swap lands, then dropped
// (Instant) or faded (Fade). Conceals need no cover: the agent fades
// concealed items in place on its own (frame-burst 2026-09-08, 27.0 b8) —
// the manufactured exit strip this file used to float was retired in 0.2.14
// (issue #5: the Smooth slide dragged the wallpaper along).

import AppKit
import PelmetEngine
import QuartzCore
import ScreenCaptureKit

/// Explicit Core Animation alpha fade. On macOS 27, `animator().alphaValue`
/// under NSAnimationContext completes almost immediately for windows AND
/// views (verified with presentation sampling, 2026-08-20) — the fade reads
/// as a pop. Only an explicit CABasicAnimation composites fractional alpha
/// over the full duration.
@MainActor
enum AlphaFade {
    static func run(
        _ view: NSView,
        to target: CGFloat,
        duration: CFTimeInterval,
        controlPoints points: (Float, Float, Float, Float),
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { completion?(); return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        if let completion {
            CATransaction.setCompletionBlock {
                Task { @MainActor in completion() }
            }
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = Float(target)
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(
            controlPoints: points.0, points.1, points.2, points.3
        )
        layer.add(anim, forKey: "pelmetAlphaFade")
        layer.opacity = Float(target)
        CATransaction.commit()
    }
}

@MainActor
final class ConcealGhostOverlay {
    /// True while a reveal cover is up — SeparatorManager and ExtrasManager
    /// skip their per-item ghosts under it (a fading copy showing through
    /// would double-expose). Count-tracked: with back-to-back reveals, an
    /// OLDER cover's fade completion must not clear the flag while a newer
    /// cover is still up.
    static var stripActive: Bool { activeStripCount > 0 }
    private static var activeStripCount = 0

    /// One cover per display: the assertion swaps EVERY display's bar at
    /// once, so each bar gets its own strip. Forwarding wrapper so callers
    /// keep the single-cover call shape.
    struct GhostSet {
        fileprivate let overlays: [ConcealGhostOverlay]
        func dismiss() { for overlay in overlays { overlay.dismiss() } }
        func fadeOut() { for overlay in overlays { overlay.fadeOut() } }
    }

    /// SCShareableContent lookup is the slow part (can be 100ms+) — cache the
    /// display handles so repeat conceals only pay for the captures.
    /// Invalidated on display reconfiguration: a stale SCDisplay makes every
    /// capture fail (no hide animation) or capture wrong geometry.
    private static var cachedDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    private static var reconfigureObserver: NSObjectProtocol?

    static func prewarmDisplay() {
        if reconfigureObserver == nil {
            reconfigureObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    cachedDisplays = [:]
                    _ = await scDisplay(for: CGMainDisplayID())
                }
            }
        }
        Task { _ = await scDisplay(for: CGMainDisplayID()) }
    }

    private static func scDisplay(for id: CGDirectDisplayID) async -> SCDisplay? {
        if let cached = cachedDisplays[id] { return cached }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        for display in content.displays {
            cachedDisplays[display.displayID] = display
        }
        return cachedDisplays[id]
    }

    private let window: NSWindow
    private let imageView: NSImageView
    private var finished = false
    private var stoodDown = false

    /// A captured strip image ready to float — pre-captured at conceal settle
    /// so the reveal path pays zero capture latency.
    struct BarSnapshot: @unchecked Sendable {
        let image: CGImage
        /// Cocoa bottom-left global — where this display's cover floats.
        let windowFrame: NSRect
        let takenAt: Date
    }

    /// Capture the strip on every display. `rect` is the primary-band strip
    /// in AX global top-left coordinates (the engine's canonical frames);
    /// other bars mirror the same items against their own trailing edge, so
    /// the rect translates right-anchored (the notch only eats the leading
    /// side). Empty result → callers run uncovered, never blocked.
    /// Without Screen Recording every reveal runs uncovered (the agent's
    /// slide-in shows). Contextual: the system prompt fires the first time a
    /// cover is actually wanted (once per launch, see ScreenRecordingAccess);
    /// the General tab's Permissions card carries the row for anyone who
    /// dismissed it (issue #6).
    static func snapshotSet(of rect: CGRect?) async -> [BarSnapshot] {
        guard let rect, rect.width > 8 else { return [] }
        guard ScreenRecordingAccess.isGranted else {
            ScreenRecordingAccess.request()
            return []
        }
        guard let primary = NSScreen.screens.first else { return [] }

        var shots: [BarSnapshot] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.directDisplayID,
                  let display = await scDisplay(for: displayID) else { continue }
            let bounds = CGDisplayBounds(displayID)  // CG top-left global
            // Bar heights differ per display (39pt notched builtin, 24pt
            // externals) — take each display's own band; visibleFrame can
            // collapse under full-screen apps, so fall back to the safe
            // area, then to the strip's. Cover the bar WINDOW's height
            // (visibleFrame band, 39pt on the notched builtin), not the
            // safe-area inset (38pt): the uncovered bottom row flashed
            // light on a cold reveal — a white line under the icons
            // (2026-09-07). Windows start below the bar window, so its
            // last row is still bar, never a window; a band more than
            // 2pt past the safe area is not the bar and is clamped.
            let safeBand = screen.safeAreaInsets.top
            let visibleBand = screen.frame.maxY - screen.visibleFrame.maxY
            let ownBand = visibleBand > 0 && (safeBand == 0 || visibleBand <= safeBand + 2)
                ? visibleBand : safeBand
            let bandHeight = ownBand > 0 ? ownBand : rect.maxY
            // Right-anchored translation onto this display, padded so the
            // snapshot's background is continuous with the bar around it.
            let translatedX = rect.minX + (screen.frame.maxX - primary.frame.maxX)
            let globalX = max(bounds.minX, translatedX - 6)
            let width = min(rect.width + 12, bounds.maxX - globalX)
            guard width > 8, bandHeight > 0 else { continue }
            // sourceRect is display-local top-left; the bar spans the top band.
            let capture = CGRect(x: globalX - bounds.minX, y: 0, width: width, height: bandHeight)
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = capture
            // The display's own scale — a hardcoded ×2 half-sized the strip
            // on 1× externals.
            let scale = screen.backingScaleFactor
            config.width = Int(capture.width * scale)
            config.height = Int(capture.height * scale)
            config.showsCursor = false
            guard let shot = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            ) else {
                PelmetLog.log("ghost: strip capture failed on display \(displayID) — it runs uncovered")
                continue
            }
            shots.append(BarSnapshot(
                image: shot,
                windowFrame: NSRect(
                    x: globalX, y: screen.frame.maxY - bandHeight,
                    width: width, height: bandHeight
                ),
                takenAt: Date()
            ))
        }
        return shots
    }

    /// Capture now and float immediately. Call `fadeOut()`/`dismiss()` once
    /// the swap beneath has been issued; a safety timeout fades regardless.
    static func begin(over rect: CGRect?, safety: TimeInterval = 0.5) async -> GhostSet? {
        begin(from: await snapshotSet(of: rect), safety: safety)
    }

    /// Float pre-captured snapshots — synchronous, zero capture latency.
    static func begin(from snaps: [BarSnapshot], safety: TimeInterval = 0.5) -> GhostSet? {
        guard !snaps.isEmpty else { return nil }
        return GhostSet(overlays: snaps.map { ConcealGhostOverlay(snapshot: $0, safety: safety) })
    }

    private init(snapshot: BarSnapshot, safety: TimeInterval) {
        let frame = snapshot.windowFrame
        let shot = snapshot.image
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false
        imageView = NSImageView(
            image: NSImage(cgImage: shot, size: frame.size)
        )
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        imageView.wantsLayer = true
        window.contentView = imageView
        window.orderFrontRegardless()
        window.displayIfNeeded()
        Self.activeStripCount += 1
        PelmetLog.log("ghost: strip up \(Int(frame.width))×\(Int(frame.height)) @x=\(Int(frame.minX))")
        // Safety: never leave a stale cover if the caller's task dies.
        DispatchQueue.main.asyncAfter(deadline: .now() + safety) { [weak self] in
            self?.fadeOut()
        }
    }

    /// One decrement per overlay, however it ends.
    private func standDown() {
        guard !stoodDown else { return }
        stoodDown = true
        Self.activeStripCount -= 1
    }

    /// Drop the cover with no animation — the Instant reveal style: whatever
    /// landed beneath simply is, from one frame to the next. Idempotent.
    func dismiss() {
        guard !finished else { return }
        finished = true
        window.orderOut(nil)
        standDown()
    }

    /// Fade the cover out — ease-in (holds visibility, then accelerates away),
    /// the mirror of the show fade's ease-out. Idempotent.
    private static let dismissDuration: CFTimeInterval = 0.16

    func fadeOut() {
        guard !finished else { return }
        finished = true
        // Strong self: the completion is the count's decrement — a weak
        // capture could leak activeStripCount high and suppress per-item
        // ghosts forever.
        AlphaFade.run(imageView, to: 0, duration: Self.dismissDuration, controlPoints: (0.55, 0, 0.8, 0.4)) { [window, self] in
            window.orderOut(nil)
            self.standDown()
        }
    }
}
