// ExtraGlyphs.swift — the animated set of Pelmet-item glyphs and the clock
// that drives them. Every glyph is an NSImage drawn per frame, so the items
// keep the plain `button.image` path (template tinting, the bar's own
// highlight, `squareLength`) and never change width: a moving glyph must
// not move the bar. Nothing here ticks unless something is live — the
// animator stops on its own when the glyph settles.

import AppKit
import PelmetEngine

// MARK: - Glyphs

enum ExtraGlyph {
    /// Three bars bobbing while audio plays — Sconce's now-playing tell,
    /// ported verbatim (same floors, peaks, per-bar phase offset). `level`
    /// blends the resting stack (0) into the live wave (1) so play ↔ pause
    /// settles instead of snapping. Reduce Motion: a still mid-height stack.
    static func mediaBars(t: TimeInterval, level: CGFloat, animated: Bool) -> NSImage {
        let period: TimeInterval = 1.2
        let floors: [CGFloat] = [5, 6, 5]
        let peaks: [CGFloat] = [12, 14, 13]
        let stillHeights: [CGFloat] = [8, 12, 9]
        let heights: [CGFloat] = (0..<3).map { index in
            let live: CGFloat
            if animated {
                let phase = (t / period + Double(index) * 0.33) * 2 * .pi
                let wave = CGFloat((sin(phase) + 1) / 2)
                live = floors[index] + (peaks[index] - floors[index]) * wave
            } else {
                live = stillHeights[index]
            }
            return 4 + (live - 4) * level
        }
        return raster(size: NSSize(width: 13, height: 14), template: true) { rect in
            NSColor.black.setFill()
            for (index, height) in heights.enumerated() {
                let x = CGFloat(index) * 5
                let bar = NSRect(x: x, y: (rect.height - height) / 2, width: 3, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    /// The camera glyph breathing: green, alpha easing 0.55 ↔ 1 on the
    /// slow 2.4s cycle Sconce's charging dot uses. The whole glyph carries
    /// the motion — no extra geometry, so it holds the static footprint.
    static func cameraLive(t: TimeInterval, animated: Bool) -> NSImage {
        let phase = animated ? (sin(t * 2 * .pi / 2.4) + 1) / 2 : 1
        let alpha = 0.55 + 0.45 * phase
        return tinted("video.fill", color: .systemGreen, alpha: alpha)
    }

    /// The mic glyph as a level meter: a faint orange body with a full-tone
    /// fill rising and falling inside it (30% ↔ 85%, 1.6s), like the glyph
    /// is picking up sound. Reduce Motion: a still three-quarter fill.
    static func micLive(t: TimeInterval, animated: Bool) -> NSImage {
        let phase = animated ? (sin(t * 2 * .pi / 1.6) + 1) / 2 : 1
        let fill = 0.3 + 0.55 * phase
        return meter("mic.fill", color: .systemOrange, fill: fill)
    }

    /// AirDrop's own mark: concentric rings with the wedge cut out below
    /// and the solid beam inside it. SF Symbols has no `airdrop` glyph on
    /// this OS, so it's drawn here as a template. `radiating` sends the
    /// rings outward from the centre, fading as they go — the transfer.
    static func airdrop(t: TimeInterval, radiating: Bool) -> NSImage {
        let size: CGFloat = 17
        let center = NSPoint(x: size / 2, y: size / 2 + 0.5)
        let innerRadius: CGFloat = 2.6
        let outerRadius: CGFloat = 7.9
        let ringCount = 3
        let period: TimeInterval = 1.6
        return raster(size: NSSize(width: size, height: size), template: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            // Everything below the centre inside ±34° of straight down is
            // the wedge: rings stop there, the beam lives there.
            let wedgeHalfAngle: CGFloat = 34
            let keep = NSBezierPath()
            keep.move(to: center)
            keep.appendArc(
                withCenter: center, radius: size,
                startAngle: -90 + wedgeHalfAngle, endAngle: -90 - wedgeHalfAngle, clockwise: false
            )
            keep.close()
            context.saveGState()
            keep.addClip()
            NSColor.black.setStroke()
            for ring in 0..<ringCount {
                let radius: CGFloat
                let alpha: CGFloat
                if radiating {
                    let progress = CGFloat(((t / period) + Double(ring) / Double(ringCount))
                        .truncatingRemainder(dividingBy: 1))
                    radius = innerRadius + (outerRadius - innerRadius) * progress
                    // In from the centre, out at the edge.
                    alpha = min(1, progress * 4) * (1 - progress * progress)
                } else {
                    radius = innerRadius + (outerRadius - innerRadius) * CGFloat(ring) / CGFloat(ringCount - 1)
                    alpha = 1
                }
                let path = NSBezierPath(
                    ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                )
                path.lineWidth = 1.3
                NSColor.black.withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
            context.restoreGState()
            // The beam: a rounded cone from the centre down the wedge.
            let beam = NSBezierPath()
            let beamHalfAngle: CGFloat = 19
            let beamLength = outerRadius - 0.4
            beam.move(to: NSPoint(x: center.x, y: center.y - 1.2))
            beam.appendArc(
                withCenter: center, radius: beamLength,
                startAngle: -90 - beamHalfAngle, endAngle: -90 + beamHalfAngle, clockwise: false
            )
            beam.close()
            beam.lineJoinStyle = .round
            beam.lineWidth = 1.4
            NSColor.black.setFill()
            NSColor.black.setStroke()
            beam.fill()
            beam.stroke()
        }
    }

    // MARK: Rasterizing

    /// A bitmap-backed image at 2× (every Mac bar Pelmet ships on is
    /// Retina). A drawing-handler NSImage would run its handler straight
    /// into the button's context, where a `.sourceAtop` tint floods the
    /// whole button rect.
    private static func raster(size: NSSize, template: Bool, _ draw: (NSRect) -> Void) -> NSImage {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            draw(NSRect(origin: .zero, size: size))
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = template
        return image
    }

    // MARK: Symbol helpers

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    /// The symbol in one colour at one alpha. Not a template: the colour
    /// IS the state (Pelmet's live camera is green, the mic orange).
    private static func tinted(_ name: String, color: NSColor, alpha: Double) -> NSImage {
        guard let glyph = symbol(name) else { return NSImage() }
        return raster(size: glyph.size, template: false) { rect in
            glyph.draw(in: rect)
            color.withAlphaComponent(alpha).set()
            rect.fill(using: .sourceAtop)
        }
    }

    /// The symbol as a meter: faint body, full-tone fill up to `fill` of
    /// its height.
    private static func meter(_ name: String, color: NSColor, fill: Double) -> NSImage {
        guard let glyph = symbol(name) else { return NSImage() }
        return raster(size: glyph.size, template: false) { rect in
            glyph.draw(in: rect)
            color.withAlphaComponent(0.35).set()
            rect.fill(using: .sourceAtop)
            var level = rect
            level.size.height = rect.height * fill
            NSGraphicsContext.current?.saveGraphicsState()
            level.clip()
            glyph.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }
}

// MARK: - Animator

/// Drives one status button's image from a clock. `level` eases toward
/// `targetLevel` (the play ↔ pause blend); once it has settled and the
/// frame is declared still at that level, the timer stops — a resting
/// media button costs no ticks. Nor does one nobody can see: the clock
/// also holds while the item is hidden (`paused`) and while the button's
/// window is occluded — the bar tucked away by a fullscreen app, the
/// display asleep. Reduce Motion is the caller's call: pass
/// `animated: false` to the glyph and never run the animator.
@MainActor
final class ExtraAnimator {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    // Observed for the animator's lifetime; the item outlives every clock.
    private var occlusionObserver: NSObjectProtocol?
    private var frame: ((TimeInterval, CGFloat) -> NSImage)?
    private let epoch = Date()
    private var lastTick: TimeInterval = 0
    private(set) var level: CGFloat = 1
    /// Where `level` is heading; 0 means "settle and stop ticking".
    var targetLevel: CGFloat = 1 {
        didSet { if targetLevel != oldValue { schedule() } }
    }
    /// A hidden item keeps its frame but stops ticking.
    var paused = false {
        didSet { if paused != oldValue { schedule() } }
    }
    private var fps: Double = 30

    init(button: NSStatusBarButton?) {
        self.button = button
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Identity only crosses to the main actor, never the window.
            let windowID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, let own = self.button?.window, windowID == ObjectIdentifier(own) else { return }
                self.schedule()
            }
        }
    }

    /// The bar is on screen: no window yet counts as visible (the item is
    /// about to attach), an occluded one does not.
    private var onScreen: Bool {
        guard let window = button?.window else { return true }
        return window.occlusionState.contains(.visible)
    }

    private var tag = ""

    /// Idempotent per `tag`: `apply` runs on every converge, and a glyph
    /// already running this frame keeps its clock and phase.
    func run(tag: String, fps: Double = 30, frame: @escaping (TimeInterval, CGFloat) -> NSImage) {
        if self.frame != nil, self.tag == tag { return }
        self.tag = tag
        self.fps = fps
        self.frame = frame
        tick()
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        frame = nil
        tag = ""
    }

    /// Called when the item goes away; the notification observer is the
    /// one thing a deinit can't release under strict concurrency.
    func tearDown() {
        stop()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }

    private var settled: Bool { abs(level - targetLevel) < 0.005 }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard frame != nil, !paused, onScreen else { return }
        // A settled rest level needs no clock; the live level does.
        if settled, targetLevel == 0 { return }
        lastTick = Date().timeIntervalSince(epoch)
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.1 / fps
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let frame, let button else { return }
        let now = Date().timeIntervalSince(epoch)
        let dt = max(0, min(0.1, now - lastTick))
        lastTick = now
        if !settled {
            // Exponential approach, ~0.4s to settle.
            level += (targetLevel - level) * min(1, dt / 0.12)
            if settled { level = targetLevel }
        }
        button.image = frame(now, level)
        if settled, targetLevel == 0 { schedule() }
    }
}

// MARK: - AirDrop activity

/// "A transfer is running": AirDrop moves files over the AWDL interface
/// (`awdl0`), which sits at 0 B/s otherwise (measured idle 2026-09-15). A
/// 1s poll of its byte counters, only while an animated AirDrop item
/// exists; sustained throughput above the gate reads as a transfer, with
/// a short hold so a stall mid-transfer doesn't flicker the glyph.
@MainActor
final class AirDropActivityMonitor {
    private(set) var isTransferring = false
    private var timer: Timer?
    private var last: (bytes: UInt64, at: Date)?
    private var lastAboveGate: Date = .distantPast
    private let onChange: () -> Void
    /// Bytes/s that count as a transfer. Continuity chatter is well under;
    /// tune from the `airdrop: awdl0` log lines during a real transfer.
    static let gate: Double = 150_000
    static let hold: TimeInterval = 2

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let bytes = Self.awdlBytes() else { return }
        let now = Date()
        defer { last = (bytes, now) }
        guard let last, bytes >= last.bytes else { return }
        let rate = Double(bytes - last.bytes) / max(0.5, now.timeIntervalSince(last.at))
        if rate >= Self.gate { lastAboveGate = now }
        if rate > 20_000 {
            PelmetLog.log("airdrop: awdl0 \(Int(rate / 1000)) KB/s")
        }
        let transferring = now.timeIntervalSince(lastAboveGate) < Self.hold
        if transferring != isTransferring {
            isTransferring = transferring
            PelmetLog.log("airdrop: transfer \(transferring ? "started" : "ended")")
            onChange()
        }
    }

    /// awdl0's in + out byte counters, from the link-level ifaddrs entry.
    private static func awdlBytes() -> UInt64? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if String(cString: entry.pointee.ifa_name) == "awdl0",
               entry.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                return UInt64(data.pointee.ifi_ibytes) + UInt64(data.pointee.ifi_obytes)
            }
            cursor = entry.pointee.ifa_next
        }
        return nil
    }
}
