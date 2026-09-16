// ExtraGlyphs.swift — Pelmet's drawn glyphs (the media bars, the AirDrop
// mark) and the clock that drives the one that moves. Every glyph is an
// NSImage, so the items keep the plain `button.image` path (template
// tinting, the bar's own highlight, `squareLength`) and never change
// width: a moving glyph must not move the bar. Nothing here ticks unless
// audio is playing — the animator stops on its own when the bars settle.

import AppKit
import PelmetEngine

// MARK: - Glyphs

enum ExtraGlyph {
    // MARK: Frame budget
    //
    // Each frame is a `button.image` swap, and on macOS 27 every swap
    // costs the main thread ~5ms of AppKit work (layout, replicant
    // snapshot, scene IPC), whatever the glyph draws. So swaps per second,
    // not the drawing, is the CPU budget (30 + 20 fps read as ~26% CPU on
    // an M4, measured 2026-09-15). Two levers keep the bars cheap: the
    // steady clock below, and frame dedupe — heights are quantized to one
    // device pixel and a frame identical to the last one is never assigned.

    /// Bars: a 1.2s wave, ~14 frames per cycle at this rate (≤1.8px of
    /// travel per frame at the wave's steepest, one pixel near the turns,
    /// where dedupe drops frames for free).
    static let barsFPS: Double = 12

    /// Three bars bobbing while audio plays — Sconce's now-playing tell,
    /// ported verbatim (same floors, peaks, per-bar phase offset). `level`
    /// blends the resting stack (0) into the live wave (1) so play ↔ pause
    /// settles instead of snapping. Reduce Motion: a still mid-height stack.
    static func mediaBars(t: TimeInterval, level: CGFloat, animated: Bool) -> NSImage {
        let period: TimeInterval = 1.2
        let floors: [CGFloat] = [5, 6, 5]
        let peaks: [CGFloat] = [12, 14, 13]
        let stillHeights: [CGFloat] = [8, 12, 9]
        // Heights in device pixels (2×): the cache key, and the reason two
        // near-identical frames become the same NSImage.
        let heights: [Int] = (0..<3).map { index in
            let live: CGFloat
            if animated {
                let phase = (t / period + Double(index) * 0.33) * 2 * .pi
                let wave = CGFloat((sin(phase) + 1) / 2)
                live = floors[index] + (peaks[index] - floors[index]) * wave
            } else {
                live = stillHeights[index]
            }
            return Int(((4 + (live - 4) * level) * 2).rounded())
        }
        if let cached = barsCache[heights] { return cached }
        // The blend sweeps through many heights once; the steady wave
        // revisits ~14. Keep the cache small rather than clever.
        if barsCache.count > 64 { barsCache.removeAll(keepingCapacity: true) }
        let image = raster(size: NSSize(width: 13, height: 14), template: true) { rect in
            NSColor.black.setFill()
            for (index, pixels) in heights.enumerated() {
                let height = CGFloat(pixels) / 2
                let x = CGFloat(index) * 5
                let bar = NSRect(x: x, y: (rect.height - height) / 2, width: 3, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        barsCache[heights] = image
        return image
    }

    @MainActor private static var barsCache: [[Int]: NSImage] = [:]

    /// Time Machine's idle mark: the SF Symbol Apple's own extra draws, with
    /// the older name as the fallback.
    static let timeMachineSymbol: String = {
        NSImage(systemSymbolName: "clock.arrow.trianglehead.counterclockwise.rotate.90", accessibilityDescription: nil) != nil
            ? "clock.arrow.trianglehead.counterclockwise.rotate.90"
            : "clock.arrow.circlepath"
    }()

    /// One idle image for the lifetime of the item, so a re-apply that
    /// changes nothing swaps nothing.
    static let timeMachineIdle: NSImage = {
        let image = NSImage(systemSymbolName: timeMachineSymbol, accessibilityDescription: "Time Machine")!
        image.isTemplate = true
        return image
    }()

    /// Apple's mark for a failed backup: the arrow around an exclamation.
    static let timeMachineFailed: NSImage = {
        let image = NSImage(systemSymbolName: "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90", accessibilityDescription: "Time Machine")
            ?? NSImage(systemSymbolName: "exclamationmark.arrow.circlepath", accessibilityDescription: "Time Machine")!
        image.isTemplate = true
        return image
    }()

    /// Time Machine's "backing up" mark, the very image Apple's extra shows
    /// during a backup, read from its bundle at runtime (nothing of Apple's
    /// ships in Pelmet). Falls back to the two-arrow symbol.
    static let timeMachineBackingUp: NSImage = {
        let bundle = Bundle(path: "/System/Library/CoreServices/Menu Extras/TimeMachine.menu")
        if let image = bundle?.image(forResource: "time_machine_backingup") {
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "clock.arrow.2.circlepath", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)!
        fallback.isTemplate = true
        return fallback
    }()

    /// AirDrop's own mark: concentric rings with the wedge cut out below
    /// and the solid beam inside it. SF Symbols has no `airdrop` glyph on
    /// this OS, so it's drawn here as a template, once.
    static let airdrop: NSImage = {
        let size: CGFloat = 17
        let center = NSPoint(x: size / 2, y: size / 2 + 0.5)
        let innerRadius: CGFloat = 2.6
        let outerRadius: CGFloat = 7.9
        let ringCount = 3
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
                let radius = innerRadius + (outerRadius - innerRadius) * CGFloat(ring) / CGFloat(ringCount - 1)
                let path = NSBezierPath(
                    ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                )
                path.lineWidth = 1.3
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
    }()

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
    /// The steady rate the glyph asked for. Every frame costs the bar a
    /// relayout, a replicant snapshot and a scene round trip to the agent
    /// (~5ms of main thread on an M-series Mac, measured 2026-09-15), so
    /// the steady rate is the CPU dial: 50 swaps/s read as 26% CPU.
    private var fps: Double = 30
    /// The play ↔ pause blend is the one motion fast enough to want a full
    /// clock; it lasts ~0.4s, then the steady rate takes over.
    static let blendFPS: Double = 30

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
    private weak var lastImage: NSImage?

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
        lastImage = nil
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
        // The blend runs on the full clock, the steady wave on the glyph's own.
        let rate = settled ? fps : max(fps, Self.blendFPS)
        // The timer already fires on the main run loop: tick in place rather
        // than hopping through a Task, which lands the frame a run-loop pass
        // later and buys a second display flush per frame.
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1 / rate
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let frame, let button else { return }
        let now = Date().timeIntervalSince(epoch)
        let dt = max(0, min(0.1, now - lastTick))
        lastTick = now
        let wasSettled = settled
        if !settled {
            // Exponential approach, ~0.4s to settle.
            level += (targetLevel - level) * min(1, dt / 0.12)
            if settled { level = targetLevel }
        }
        // The glyph hands back the SAME image for a frame that would draw
        // identically (see `mediaBars`); assigning it again would still
        // cost the full AppKit swap, so skip it.
        let image = frame(now, level)
        if image !== lastImage {
            lastImage = image
            button.image = image
        }
        // Just settled: drop from the blend clock to the steady one (or stop).
        if settled, !wasSettled { schedule() }
    }
}
