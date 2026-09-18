// FloatingBar.swift
// A hidden section revealed into a glass panel flush under the menu bar
// instead of into the bar. The reveal is still the engine's — the items host
// in the real bar, under an empty-bar picture that stays up for the whole
// reveal — and the panel shows a live stream of that covered strip. A click
// on a picture presses the real item beneath the cover, so its own menu
// opens from the bar, right above the picture. On macOS 27 a status item
// exists nowhere but in the bar (no window of its own to capture or move,
// probed 2026-09-17), so a picture plus a relay is the whole design space.
// TransitionCoordinator drives it; MenuBarBandMonitor counts it as bar.

import AppKit
import ApplicationServices
import PelmetCore
import PelmetEngine
import ScreenCaptureKit

@MainActor
final class FloatingBar {
    private let panel: NSPanel
    private let mirror = MirrorView()
    private var stream: SCStream?
    private var sink: MirrorSink?
    private var cover: ConcealGhostOverlay.GhostSet?
    /// The strip in primary-band coordinates (AX global, top-left origin).
    private(set) var strip: CGRect?
    private var screen: NSScreen?

    /// Cocoa point the cover and panel keep between the picture and the glass.
    private static let pad: CGFloat = 4
    private static let cornerRadius: CGFloat = 10
    private static let captureQueue = DispatchQueue(label: "app.fif7y.Pelmet.floatingBar.capture")
    /// The SCShareableContent lookup is the slow part of starting a stream
    /// (100ms+, an empty pill before the first frame); displays and Pelmet's
    /// own SCRunningApplication are stable until the screens change.
    private static var cachedContent: SCShareableContent?
    private static var reconfigureObserver: NSObjectProtocol?

    private static func shareableContent() async -> SCShareableContent? {
        if reconfigureObserver == nil {
            reconfigureObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { _ in Task { @MainActor in cachedContent = nil } }
        }
        if let cachedContent { return cachedContent }
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        return content
    }

    /// A click on the mirror: the primary-band x under it.
    var onPress: ((CGFloat) -> Void)?

    var isShown: Bool { panel.isVisible }

    /// The pointer is on the panel — for the band monitor, that is the bar.
    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        mirror.imageScaling = .scaleProportionallyUpOrDown
        mirror.translatesAutoresizingMaskIntoConstraints = false
        let host: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = mirror
            host = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.addSubview(mirror)
            host = effect
        }
        panel.contentView = host
        NSLayoutConstraint.activate([
            mirror.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Self.pad),
            mirror.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Self.pad),
            mirror.topAnchor.constraint(equalTo: host.topAnchor, constant: Self.pad),
            mirror.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Self.pad),
        ])
        mirror.onPress = { [weak self] localX in
            guard let self, let strip else { return }
            onPress?(strip.minX + localX)
        }
    }

    // MARK: - Geometry

    /// The bar's own height on `screen` (same rule as the cover captures:
    /// the visibleFrame band, falling back to the safe area under a
    /// full-screen app).
    private static func barHeight(of screen: NSScreen) -> CGFloat {
        let safeBand = screen.safeAreaInsets.top
        let visibleBand = screen.frame.maxY - screen.visibleFrame.maxY
        return visibleBand > 0 && (safeBand == 0 || visibleBand <= safeBand + 2) ? visibleBand : safeBand
    }

    /// The strip translated onto `screen` (right-anchored, like every bar
    /// mirrors the primary's items), as a Cocoa rect over that bar.
    private static func stripFrame(_ strip: CGRect, on screen: NSScreen) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let barH = barHeight(of: screen)
        guard barH > 0 else { return nil }
        var minX = strip.minX + (screen.frame.maxX - primary.frame.maxX)
        if let cutoutRight = screen.auxiliaryTopRightArea?.minX { minX = max(minX, cutoutRight + 2) }
        let maxX = min(strip.maxX + (screen.frame.maxX - primary.frame.maxX), screen.frame.maxX)
        guard maxX - minX > 8 else { return nil }
        return NSRect(x: minX, y: screen.frame.maxY - barH, width: maxX - minX, height: barH)
    }

    private static func panelFrame(under bar: NSRect) -> NSRect {
        NSRect(x: bar.minX - pad, y: bar.minY - (bar.height + 2 * pad), width: bar.width + 2 * pad, height: bar.height + 2 * pad)
    }

    // MARK: - Show / hide

    /// Float the panel under `screen`'s bar and start mirroring the strip.
    /// `cover` is the empty-bar picture already over the real strip; it is
    /// held until `dismissCover()`. Call before the engine reveals: the
    /// icons then arrive inside the panel with the agent's own motion.
    func show(strip: CGRect, cover: ConcealGhostOverlay.GhostSet?, on screen: NSScreen, entrance: AnimationRecipe.Move) async {
        self.cover?.dismiss()
        self.cover = cover
        self.strip = strip
        self.screen = screen
        guard let bar = Self.stripFrame(strip, on: screen) else {
            PelmetLog.log("floating: strip \(Int(strip.minX))..\(Int(strip.maxX)) has no footprint on display \(screen.directDisplayID ?? 0)")
            return
        }
        mirror.image = nil
        let frame = Self.panelFrame(under: bar)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animate(entrance, entering: true, rest: frame)
        PelmetLog.log("floating: panel \(Int(frame.width))×\(Int(frame.height)) @x=\(Int(frame.minX)) on display \(screen.directDisplayID ?? 0)")
        await startStream(bar: bar, on: screen)
    }

    /// The strip as it really landed (measured once the bar is at rest):
    /// the panel and the mirror follow the items, not the estimate.
    func update(strip: CGRect) async {
        guard panel.isVisible, let screen, let bar = Self.stripFrame(strip, on: screen),
              abs(bar.width - (self.strip.map { $0.width } ?? 0)) > 2 || abs(strip.minX - (self.strip?.minX ?? 0)) > 2
        else { return }
        self.strip = strip
        let frame = Self.panelFrame(under: bar)
        await NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
        PelmetLog.log("floating: strip settled at \(Int(strip.minX))..\(Int(strip.maxX)), panel \(Int(frame.width))pt")
        await startStream(bar: bar, on: screen)
    }

    /// The panel leaves with the exit move; the cover stays until the
    /// conceal beneath is swap-quiet (`dismissCover`), so the icons never
    /// show in the bar on the way out.
    func hide(exit: AnimationRecipe.Move) {
        stopStream()
        guard panel.isVisible else { return }
        animate(exit, entering: false, rest: panel.frame)
    }

    func dismissCover() {
        cover?.dismiss()
        cover = nil
        strip = nil
    }

    /// The recipe's move on the panel itself: ease-out into rest, ease-in
    /// away — the covers' curves, so both surfaces read as one motion.
    private func animate(_ move: AnimationRecipe.Move, entering: Bool, rest: NSRect) {
        let finish: @MainActor @Sendable () -> Void = { [panel] in if !entering { panel.orderOut(nil) } }
        // AppKit calls the completion on the main thread but does not say so.
        let done: @Sendable () -> Void = { Task { @MainActor in finish() } }
        switch move {
        case .pop:
            panel.alphaValue = entering ? 1 : 0
            finish()
        case .fade(let duration):
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
                panel.animator().alphaValue = entering ? 1 : 0
            }, completionHandler: done)
        case .slide(let dx, let duration):
            let away = rest.offsetBy(dx: dx, dy: 0)
            if entering { panel.setFrame(away, display: false) }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = entering
                    ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    : CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.4)
                panel.animator().setFrame(entering ? rest : away, display: true)
                panel.animator().alphaValue = entering ? 1 : 0
            }, completionHandler: done)
        }
    }

    // MARK: - Mirror stream

    /// One SCStream of the strip's band on the panel's display, Pelmet's own
    /// windows left out so the cover over the strip is not what it sees.
    private func startStream(bar: NSRect, on screen: NSScreen) async {
        stopStream()
        let started = Date()
        guard let displayID = screen.directDisplayID,
              let content = await Self.shareableContent(),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            PelmetLog.log("floating: no SCDisplay for \(screen.directDisplayID ?? 0) — mirror stays blank")
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let bounds = CGDisplayBounds(displayID)
        config.sourceRect = CGRect(x: bar.minX - bounds.minX, y: 0, width: bar.width, height: bar.height)
        let scale = screen.backingScaleFactor
        config.width = Int(bar.width * scale)
        config.height = Int(bar.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: AppTiming.floatingMirrorFPS)
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.shouldBeOpaque = true
        let size = bar.size
        let sink = MirrorSink { [weak self] image in
            Task { @MainActor in self?.mirror.image = NSImage(cgImage: image, size: size) }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: Self.captureQueue)
            try await stream.startCapture()
        } catch {
            PelmetLog.log("floating: mirror stream failed to start — \(error.localizedDescription)")
            return
        }
        self.stream = stream
        self.sink = sink
        PelmetLog.log(String(format: "floating: mirror streaming %dpt @%dfps (%.0fms to start)", Int(bar.width), AppTiming.floatingMirrorFPS, Date().timeIntervalSince(started) * 1000))
    }

    private func stopStream() {
        guard let stream else { return }
        self.stream = nil
        sink = nil
        Task { try? await stream.stopCapture() }
    }
}

/// The mirror: the pictures, and the click that reaches the real item.
private final class MirrorView: NSImageView {
    var onPress: ((CGFloat) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onPress?(convert(event.locationInWindow, from: nil).x)
    }
}

/// Every complete frame → one CGImage, handed to the panel. Top-level and
/// nonisolated for the same reason as FirstFrameSink: SCK calls back on the
/// capture queue.
nonisolated private final class MirrorSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let deliver: @Sendable (CGImage) -> Void
    init(deliver: @escaping @Sendable (CGImage) -> Void) { self.deliver = deliver }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }
        if let image = FirstFrameSink.cgImage(from: buffer) { deliver(image) }
    }
}

/// The click relay: the item under the picture is hosted in the bar beneath
/// the cover, and `AXPress` on its own extras-bar element opens whatever it
/// opens, from there. The engine's snapshot names the item and its frame;
/// the element comes from the owning app (one AX round trip on click).
enum FloatingBarPress {
    @discardableResult
    static func press(_ item: ObservedItem) -> Bool {
        guard let frame = item.frame else { return false }
        if item.pid > 0, let element = extrasElement(pid: item.pid, at: frame) {
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        // Nothing enumerable (a system module, a host with no extras bar):
        // whatever the system finds at the item's centre.
        var hit: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(systemWide, Float(frame.midX), Float(frame.midY), &hit) == .success,
              let hit else { return false }
        return AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success
    }

    private static func extrasElement(pid: pid_t, at frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &barRef) == .success,
              let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return nil }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barRef as! AXUIElement, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return nil }
        return kids.first { kid in
            var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(kid, kAXPositionAttribute as CFString, &positionRef) == .success,
                  AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let positionRef, let sizeRef else { return false }
            var position = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            return abs(position.x + size.width / 2 - frame.midX) < 3
        }
    }
}
