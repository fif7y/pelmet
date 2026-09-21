// ConcealGhostOverlay.swift
// Snapshot covers floated over the bar. The agent animates every swap on
// its own (a slide-in on reveal, a fade in place on conceal — frame-burst
// 2026-09-08, 27.0 b8) and offers no way to turn that off, so Pelmet's
// styles are pictures animated OVER it: an empty-bar capture hides the
// agent's motion, and a picture of the icons (opaque, or cut out against
// the empty bar so it can move without smearing the wallpaper) performs the
// style's own move — see `AnimationRecipe` in TransitionCoordinator. Without
// a usable capture a style falls back to the agent's animation.

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
        func fadeOut(duration: CFTimeInterval = ConcealGhostOverlay.dismissDuration, slide: Bool = false) {
            for overlay in overlays { overlay.fadeOut(duration: duration, slide: slide) }
        }
        /// Perform a recipe move: `entering` runs it from the offset/faded
        /// state to rest, otherwise from rest away. A `.pop` is a no-op
        /// (the picture is simply there, or simply lifted by the caller).
        func animate(_ move: AnimationRecipe.Move, entering: Bool) {
            for overlay in overlays { overlay.animate(move, entering: entering) }
        }
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

    /// Other processes' surfaces drawn IN the bar over `rect` (CG global,
    /// top-left origin): at or above the bar's own level, taller than the
    /// band, reaching its top half. Never a status item (band-height), never
    /// the bar itself, never the Dock's layer-20 full-screen backstop
    /// (below the bar), never a panel whose top edge merely grazes the
    /// band's last rows.
    static func foreignBandWindows(
        intersecting rect: CGRect, bandHeight: CGFloat,
        in list: [[String: Any]]? = nil
    ) -> [(id: CGWindowID, owner: String)] {
        guard let list = list ?? onScreenWindows() else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= barLevel,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  CGRect(x: x, y: y, width: width, height: height).intersects(rect)
            else { return nil }
            // Pelmet's own windows are the covers, except a menu: the
            // status item's context menu hangs into the band's last rows
            // while it fades out, and a picture taken at that conceal
            // replayed its top edge on the next hover reveal (#40).
            if pid == me {
                return layer >= menuLevel ? (id, "Pelmet menu") : nil
            }
            guard height > bandHeight + 1, y < rect.minY + bandHeight / 2 else { return nil }
            return (id, w[kCGWindowOwnerName as String] as? String ?? "pid \(pid)")
        }
    }

    /// The window server's on-screen list, fetched once per capture set:
    /// every display's band is filtered from the same list.
    static func onScreenWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
    }

    /// What shows through the glass behind `rect` (CG global, top-left):
    /// every other process's window below the bar's level whose bounds
    /// come within `backdropReach` of the band, on any display, as
    /// `[id, x, y, w, h]` runs sorted by id. Two equal signatures = the
    /// same backdrop; a moved, resized, raised or closed window changes
    /// it, and a picture of the bar taken under the old one is stale (#33:
    /// a Finder window's top edge slid in with the bar).
    static func backdropSignature(of rect: CGRect?, in list: [[String: Any]]? = nil) -> [Int] {
        guard let rect, rect.width > 8, let list = list ?? onScreenWindows(),
              let primary = NSScreen.screens.first else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let zones: [CGRect] = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.directDisplayID else { return nil }
            let bounds = CGDisplayBounds(displayID)
            let shift = screen.frame.maxX - primary.frame.maxX
            let band = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY, rect.maxY)
            return CGRect(
                x: rect.minX + shift - backdropReach, y: bounds.minY,
                width: rect.width + 2 * backdropReach, height: band + backdropReach)
        }
        var runs: [(CGWindowID, [Int])] = []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let layer = w[kCGWindowLayer as String] as? Int, layer < barLevel,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
            else { continue }
            let frame = CGRect(x: x, y: y, width: width, height: height)
            guard zones.contains(where: { $0.intersects(frame) }) else { continue }
            runs.append((id, [Int(id), Int(x), Int(y), Int(width), Int(height)]))
        }
        return runs.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }
    /// How far below the band a window still tints it: the glass blur
    /// and a window's shadow both reach a few dozen points.
    static let backdropReach: CGFloat = 48

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
    /// Points the capture extends past the requested rect on each side so
    /// the picture's background is continuous with the bar around it.
    static let capturePadding: CGFloat = 6

    /// When Pelmet last took a picture. Every capture lights the system's
    /// screen-capture indicator at the bar's right end, which shifts the
    /// whole cluster left ~3pt and stays ~3s past the last capture
    /// (measured 3.0–3.2s, `screencapture` and a one-frame SCStream alike,
    /// 2026-09-16). While it is lit the bar is already in its shifted
    /// place, so a picture taken now needs no retake.
    private(set) static var lastCaptureAt: Date?
    static var captureIndicatorLit: Bool {
        lastCaptureAt.map { Date().timeIntervalSince($0) < AppTiming.captureIndicatorHold } ?? false
    }

    /// When the status item's context menu last closed. NSMenu fades out
    /// for a beat after the click that dismisses it, still on screen for
    /// the window list, and a picture taken inside that beat carried the
    /// menu's top rows into the next hover reveal (#40). Captures wait it
    /// out; `foreignBandWindows` leaves the menu out should one overlap.
    static var menuClosedAt: Date?
    static let menuFadeHold: TimeInterval = 0.5

    static func snapshotSet(of rect: CGRect?) async -> [BarSnapshot] {
        guard let rect, rect.width > 8 else { return [] }
        if let closed = menuClosedAt {
            let remaining = menuFadeHold - Date().timeIntervalSince(closed)
            if remaining > 0 {
                PelmetLog.log("ghost: capture waits \(Int(remaining * 1000))ms for the menu to fade")
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
            }
        }
        guard ScreenRecordingAccess.isGranted else {
            ScreenRecordingAccess.promptOnce()
            return []
        }
        guard let primary = NSScreen.screens.first else { return [] }

        var shots: [BarSnapshot] = []
        let windowList = onScreenWindows()
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
            var globalX = max(bounds.minX, translatedX - capturePadding)
            // Never picture the notch: nothing Pelmet manages lives in the
            // cutout, and a notch overlay app's surface hugs it inside the
            // band (Sconce's rest halo baked into the empty-bar picture and
            // floated over every hover reveal for 15 minutes, 2026-09-12).
            if let cutoutRight = screen.auxiliaryTopRightArea?.minX {
                globalX = max(globalX, cutoutRight + 2)
            }
            let width = min(rect.maxX + (screen.frame.maxX - primary.frame.maxX) + capturePadding - globalX, bounds.maxX - globalX)
            guard width > 8, bandHeight > 0 else { continue }
            // sourceRect is display-local top-left; the bar spans the top band.
            let capture = CGRect(x: globalX - bounds.minX, y: 0, width: width, height: bandHeight)
            // Another app's surface over the band (a notch panel wider than
            // the cutout, a HUD) is not the bar — leave it out of the picture.
            // The SCWindow lookup is the slow call, so only pay it on a hit.
            let foreign = foreignBandWindows(
                intersecting: CGRect(x: globalX, y: bounds.minY, width: width, height: bandHeight),
                bandHeight: bandHeight, in: windowList
            )
            var excluded: [SCWindow] = []
            if !foreign.isEmpty {
                let ids = Set(foreign.map(\.id))
                if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                    excluded = content.windows.filter { ids.contains($0.windowID) }
                }
                PelmetLog.log("ghost: capture leaves out \(foreign.map(\.owner).joined(separator: ", ")) (\(excluded.count) window(s))")
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()
            config.sourceRect = capture
            // The display's own scale — a hardcoded ×2 half-sized the strip
            // on 1× externals.
            let scale = screen.backingScaleFactor
            config.width = Int(capture.width * scale)
            config.height = Int(capture.height * scale)
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            // Flattened like the still: composited with alpha, the stream's
            // band came back ~0.5 luma brighter across the board (rounding
            // through the transparent bar); opaque it matches byte for byte.
            config.shouldBeOpaque = true
            guard let shot = await captureFrame(filter: filter, configuration: config) else {
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
        if !shots.isEmpty { lastCaptureAt = Date() }
        return shots
    }

    /// One frame from an SCStream, the display as it is shown. A
    /// `SCScreenshotManager` still composites the band WITHOUT the shadow
    /// the key window casts up into the bar's bottom rows (nor the window's
    /// top edge under the bar's last row), in every configuration tried,
    /// so its picture floated over the live bar read lighter or darker
    /// across the strip's bottom 12pt for the cover's whole hold (#25,
    /// measured 2026-09-15: +4 luma, +40 on the edge row; a stream frame
    /// matched a `screencapture` still to the pixel). ~90ms end to end
    /// against ~45ms for the still; the reveal's picture is precaptured, so
    /// none of it lands on the hover path.
    private static let captureQueue = DispatchQueue(label: "app.fif7y.Pelmet.ghost.capture")

    private static func captureFrame(filter: SCContentFilter, configuration: SCStreamConfiguration) async -> CGImage? {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let sink = FirstFrameSink()
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
        } catch {
            PelmetLog.log("ghost: stream capture failed to start — \(error.localizedDescription)")
            return nil
        }
        let image = await sink.firstImage(timeout: .milliseconds(600))
        // The stop is ~20ms the caller never needs to wait for.
        Task { try? await stream.stopCapture() }
        return image
    }

    /// The Smooth exit slides the icons alone. SCK cannot hand them over
    /// (excluding the wallpaper window drops the bar's items too — they are
    /// drawn inside the WindowServer-owned Menubar window, probed
    /// 2026-09-08), so the glyphs are cut out by difference against the
    /// empty-bar capture taken at the last conceal settle: a pixel that
    /// matches the background is background. `punch` lists x-ranges
    /// cleared regardless —
    /// the chevron flips glyph between the two captures (absolute x, points,
    /// same origin as the strip frames). Where the captures don't overlap
    /// the strip stays opaque; a strip that differs almost everywhere
    /// (animated wallpaper) returns nil and the caller falls back to the
    /// agent's animation.
    static func iconsOnly(
        _ strips: [BarSnapshot], background: [BarSnapshot],
        punch: [ClosedRange<CGFloat>] = [], keep: ClosedRange<CGFloat>? = nil
    ) -> [BarSnapshot]? {
        var out: [BarSnapshot] = []
        for strip in strips {
            guard let bg = background.first(where: {
                abs($0.windowFrame.minY - strip.windowFrame.minY) < 1
                    && $0.windowFrame.intersects(strip.windowFrame)
            }) else {
                PelmetLog.log("ghost: cut-out skipped — no background under the strip @x=\(Int(strip.windowFrame.minX))")
                return nil
            }
            guard var cut = cutOut(strip: strip, background: bg, punch: punch) else { return nil }
            var frame = strip.windowFrame
            // Only the strip's own columns: a system icon at the picture's
            // edge that changed between the captures (AirPods state,
            // battery %) must not ride the slide — and a window that ends
            // at the strip's edge CLIPS the slide, so the icons emerge from
            // behind the chevron instead of crossing over it.
            if let keep {
                let dx = strip.windowFrame.minX - primaryOffset(of: strip, in: strips)
                let scale = CGFloat(cut.width) / strip.windowFrame.width
                let x0 = max(0, (keep.lowerBound + dx - strip.windowFrame.minX) * scale)
                let x1 = min(CGFloat(cut.width), (keep.upperBound + dx - strip.windowFrame.minX) * scale)
                guard x1 - x0 > 4 * scale,
                      let cropped = cut.cropping(to: CGRect(x: x0.rounded(), y: 0, width: (x1 - x0).rounded(), height: CGFloat(cut.height)))
                else {
                    PelmetLog.log("ghost: cut-out skipped — keep \(Int(keep.lowerBound))..\(Int(keep.upperBound)) maps to \(Int(x0))..\(Int(x1)) px on the strip @x=\(Int(strip.windowFrame.minX))")
                    return nil
                }
                cut = cropped
                frame = NSRect(
                    x: strip.windowFrame.minX + x0.rounded() / scale, y: frame.minY,
                    width: (x1 - x0).rounded() / scale, height: frame.height
                )
            }
            out.append(BarSnapshot(image: cut, windowFrame: frame, takenAt: strip.takenAt))
        }
        return out.isEmpty ? nil : out
    }

    /// The same pictures with `columns` (absolute x, points) made
    /// transparent — the empty-bar cover with the chevron cut out, so the
    /// real chevron (which flips at the swap) shows through instead of the
    /// picture's stale glyph.
    static func clearing(_ snaps: [BarSnapshot], columns: [ClosedRange<CGFloat>]) -> [BarSnapshot] {
        guard !columns.isEmpty else { return snaps }
        return snaps.map { snap in
            let w = snap.image.width, h = snap.image.height
            guard let px = rgba(snap.image, width: w, height: h) else { return snap }
            let scale = CGFloat(w) / snap.windowFrame.width
            for range in columns {
                let x0 = max(0, Int(((range.lowerBound - snap.windowFrame.minX) * scale).rounded()))
                let x1 = min(w, Int(((range.upperBound - snap.windowFrame.minX) * scale).rounded()))
                guard x1 > x0 else { continue }
                for y in 0..<h {
                    let row = px.pointer + y * px.stride
                    for x in x0..<x1 { (row + x * 4).update(repeating: 0, count: 4) }
                }
            }
            guard let image = px.context.makeImage() else { return snap }
            return BarSnapshot(image: image, windowFrame: snap.windowFrame, takenAt: snap.takenAt)
        }
    }

    /// Snapshots on other displays are the primary strip translated
    /// right-anchored (snapshotSet); `keep` is given in primary coordinates.
    /// The primary strip is the one on the primary display — not the one
    /// nearest x=0: a display parked left of the primary put its strip at
    /// x=-864 against the primary's 1012, and `keep` mapped off the picture
    /// (2026-09-18, three displays).
    private static func primaryOffset(of strip: BarSnapshot, in strips: [BarSnapshot]) -> CGFloat {
        let primaryFrame = NSScreen.screens.first?.frame ?? .zero
        let primary = strips.first { primaryFrame.contains(CGPoint(x: $0.windowFrame.midX, y: primaryFrame.midY)) }
            ?? strips.min(by: { abs($0.windowFrame.minX) < abs($1.windowFrame.minX) })
        return primary?.windowFrame.minX ?? 0
    }

    private static func cutOut(
        strip: BarSnapshot, background bg: BarSnapshot, punch: [ClosedRange<CGFloat>]
    ) -> CGImage? {
        let overlap = strip.windowFrame.intersection(bg.windowFrame)
        guard overlap.width > 4 else {
            PelmetLog.log("ghost: cut-out skipped — strip and background don't overlap")
            return nil
        }
        let scale = CGFloat(strip.image.width) / strip.windowFrame.width
        guard abs(CGFloat(bg.image.width) / bg.windowFrame.width - scale) < 0.01 else {
            PelmetLog.log("ghost: cut-out skipped — strip and background scales differ")
            return nil
        }
        let w = strip.image.width, h = min(strip.image.height, bg.image.height)
        guard let a = rgba(strip.image, width: w, height: h),
              let b = rgba(bg.image, width: bg.image.width, height: h) else { return nil }
        let ax0 = Int(((overlap.minX - strip.windowFrame.minX) * scale).rounded())
        let bx0 = Int(((overlap.minX - bg.windowFrame.minX) * scale).rounded())
        let span = min(Int((overlap.width * scale).rounded()), w - ax0, bg.image.width - bx0)
        guard span > 0 else { return nil }
        var changed = 0
        for y in 0..<h {
            let arow = a.pointer + y * a.stride
            let brow = b.pointer + y * b.stride
            for i in 0..<span {
                let ap = arow + (ax0 + i) * 4
                let bp = brow + (bx0 + i) * 4
                let d = max(
                    abs(Int(ap[0]) - Int(bp[0])),
                    abs(Int(ap[1]) - Int(bp[1])),
                    abs(Int(ap[2]) - Int(bp[2]))
                )
                // Soft key: identical → gone, 26+ levels off → kept whole.
                let alpha = d <= 6 ? 0 : d >= 26 ? 255 : (d - 6) * 255 / 20
                if alpha == 255 { changed += 1 }
                if alpha < 255 {
                    ap[0] = UInt8(Int(ap[0]) * alpha / 255)
                    ap[1] = UInt8(Int(ap[1]) * alpha / 255)
                    ap[2] = UInt8(Int(ap[2]) * alpha / 255)
                    ap[3] = UInt8(alpha)
                }
            }
        }
        for range in punch {
            let x0 = max(0, Int(((range.lowerBound - strip.windowFrame.minX) * scale).rounded()))
            let x1 = min(w, Int(((range.upperBound - strip.windowFrame.minX) * scale).rounded()))
            guard x1 > x0 else { continue }
            for y in 0..<h {
                let row = a.pointer + y * a.stride
                for x in x0..<x1 { (row + x * 4).update(repeating: 0, count: 4) }
            }
        }
        let ratio = Double(changed) / Double(span * h)
        guard ratio < 0.6 else {
            PelmetLog.log("ghost: cut-out skipped — \(Int(ratio * 100))% of the strip differs from the background")
            return nil
        }
        return a.context.makeImage()
    }

    private struct Pixels {
        let context: CGContext
        let pointer: UnsafeMutablePointer<UInt8>
        let stride: Int
    }

    /// Premultiplied BGRA8 copy of `image`, `width`×`height` from its top-left.
    private static func rgba(_ image: CGImage, width: Int, height: Int) -> Pixels? {
        let stride = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let data = context.data else { return nil }
        // Anchor the top rows: both captures share the bar's top edge.
        context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        return Pixels(context: context, pointer: data.assumingMemoryBound(to: UInt8.self), stride: stride)
    }

    /// Capture now and float immediately. Call `fadeOut()`/`dismiss()` once
    /// the swap beneath has been issued; a safety timeout fades regardless.
    static func begin(over rect: CGRect?, safety: TimeInterval = 0.5) async -> GhostSet? {
        begin(from: await snapshotSet(of: rect), safety: safety)
    }

    /// Float pre-captured snapshots — synchronous, zero capture latency.
    static func begin(from snaps: [BarSnapshot], safety: TimeInterval = 0.5, startHidden: Bool = false) -> GhostSet? {
        guard !snaps.isEmpty else { return nil }
        // A cover orders in above every window at the bar's level, another
        // app's surface included: Sconce's notch glass lost its top 39pt
        // behind Pelmet's picture of the bar while it opened (2026-09-12).
        // With a foreign surface over the strip the cover slips in BELOW it
        // — the bar's own animation is still hidden, the surface still
        // draws on top. Per display: a notchless external carries Sconce's
        // rest bar at top center, permanently.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return GhostSet(overlays: snaps.map { snap in
            let f = snap.windowFrame
            let cg = CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
            let foreign = foreignBandWindows(intersecting: cg, bandHeight: f.height)
            if !foreign.isEmpty {
                PelmetLog.log("ghost: cover under \(foreign.map(\.owner).joined(separator: ", ")) @x=\(Int(f.minX))")
            }
            return ConcealGhostOverlay(snapshot: snap, safety: safety, startHidden: startHidden, beneath: foreign.first?.id)
        })
    }

    private init(snapshot: BarSnapshot, safety: TimeInterval, startHidden: Bool = false, beneath: CGWindowID? = nil) {
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
        if startHidden { imageView.layer?.opacity = 0 }
        window.contentView = imageView
        if let beneath {
            window.order(.below, relativeTo: Int(beneath))
        } else {
            window.orderFrontRegardless()
        }
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

    /// Ease-out into rest, ease-in away — the agent's own curves.
    func animate(_ move: AnimationRecipe.Move, entering: Bool) {
        guard !finished, let layer = imageView.layer else { return }
        // Slides keep the agent's own curves (ease-out in, ease-in away);
        // fades run symmetric so the whole duration reads as a crossfade.
        let slideCurve: (Float, Float, Float, Float) = entering ? (0.16, 1, 0.3, 1) : (0.55, 0, 0.8, 0.4)
        let fadeCurve: (Float, Float, Float, Float) = (0.42, 0, 0.58, 1)
        let curve = { if case .slide = move { return slideCurve } else { return fadeCurve } }()
        // The start state must be ON the layer before the animation reads
        // its "from" — a picture floated with startHidden may not have had
        // a layer yet when its opacity was zeroed.
        if entering, case .pop = move {} else if entering { layer.opacity = 0 }
        switch move {
        case .pop:
            return
        case .fade(let duration):
            if entering {
                AlphaFade.run(imageView, to: 1, duration: duration, controlPoints: curve)
            } else {
                fadeOut(duration: duration, controlPoints: curve)
            }
        case .slide(let dx, let duration):
            let rest = layer.position.x
            let away = rest + dx
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = entering ? away : rest
            slide.toValue = entering ? rest : away
            slide.duration = duration
            slide.timingFunction = CAMediaTimingFunction(controlPoints: curve.0, curve.1, curve.2, curve.3)
            layer.add(slide, forKey: "pelmetSlide")
            layer.position.x = entering ? rest : away
            if entering {
                // Opaque early so the travel itself reads, not just a fade.
                AlphaFade.run(imageView, to: 1, duration: min(duration, 0.14), controlPoints: curve)
            } else {
                fadeOut(duration: duration)
            }
        }
    }

    /// Fade the cover out — ease-in (holds visibility, then accelerates away),
    /// the mirror of the show fade's ease-out. Idempotent. `slide` adds a
    /// drift toward the chevron (the Smooth exit's tuck-away).
    static let dismissDuration: CFTimeInterval = 0.16

    func fadeOut(
        duration: CFTimeInterval = ConcealGhostOverlay.dismissDuration, slide: Bool = false,
        controlPoints: (Float, Float, Float, Float) = (0.55, 0, 0.8, 0.4)
    ) {
        guard !finished else { return }
        finished = true
        if slide, let layer = imageView.layer {
            let shift = min(imageView.bounds.width * 0.5, 80)
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = layer.position.x
            anim.toValue = layer.position.x + shift
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.4)
            layer.add(anim, forKey: "pelmetSlideOut")
            layer.position.x += shift
        }
        // Strong self: the completion is the count's decrement — a weak
        // capture could leak activeStripCount high and suppress per-item
        // ghosts forever.
        AlphaFade.run(imageView, to: 0, duration: duration, controlPoints: controlPoints) { [window, self] in
            window.orderOut(nil)
            self.standDown()
        }
    }
}

/// Hands the first complete frame to one waiter, copied out of the
/// pixel buffer byte for byte, tagged with the buffer's own colour space
/// (the display profile) so it draws unmanaged, as the still did. Top-level
/// on purpose: nested in the @MainActor overlay it inherited the actor and
/// SCK's callback on the capture queue tripped the isolation check, and
/// the target's MainActor default isolation did the same for a top-level
/// class until `nonisolated`.
nonisolated private final class FirstFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var pending: CGImage?
    private var done = false

    func firstImage(timeout: Duration) async -> CGImage? {
        await withCheckedContinuation { cont in
            lock.lock()
            if let pending {
                lock.unlock()
                cont.resume(returning: pending)
                return
            }
            continuation = cont
            lock.unlock()
            Task { try? await Task.sleep(for: timeout); self.finish(nil) }
        }
    }

    private func finish(_ image: CGImage?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        if let cont = continuation {
            done = true
            continuation = nil
            lock.unlock()
            cont.resume(returning: image)
        } else {
            if pending == nil { pending = image }
            lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete, status != .idle {
            return
        }
        finish(Self.cgImage(from: buffer))
    }

    private static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // The frame is tagged with the display's own profile ("Color LCD");
        // the picture must carry the same tag or AppKit matches it as
        // device/sRGB on the way to the window (+6 red, +4 blue, measured).
        let space = (CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil) as! CGColorSpace?)
            ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
