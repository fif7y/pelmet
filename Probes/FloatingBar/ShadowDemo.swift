// Shadow demo 2 — mirror ONLY the hidden strip, sized from Pelmet's own log.
// Tails ~/Library/Logs/Pelmet/pelmet.log: `strip: N items → a..b` gives the
// x-range, `effect reveal [...hidden...]` shows the panel, `effect conceal`
// hides it. Runs 3 min max, click the panel to quit.
// argv[1] = output dir, argv[2] = x shift while the capture dot is lit (default 3).
import AppKit
import ScreenCaptureKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
let dotShift = CGFloat(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 3 : 3)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let logURL = outDir.appendingPathComponent("shadow2.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try! FileHandle(forWritingTo: logURL)
let t0 = Date()
func log(_ s: String) {
    logHandle.write(String(format: "%7.2f  %@\n", Date().timeIntervalSince(t0), s).data(using: .utf8)!)
}
func cpuSeconds() -> Double {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
         + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

/// Incremental reader of Pelmet's log.
final class LogTail {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pelmet/pelmet.log")
    var offset: UInt64 = 0
    var partial = ""
    func readNew() -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }              // rotated
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        offset = size
        partial += String(decoding: data, as: UTF8.self)
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        return lines
    }
    /// Last `strip:` range in the whole file (for the first reveal).
    func lastStrip() -> ClosedRange<CGFloat>? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n").reversed() {
            if let r = parseStrip(line) { return r }
        }
        return nil
    }
}
func parseStrip(_ line: String) -> ClosedRange<CGFloat>? {
    // "strip: 7 items → 1278..1523"   (or "→ nil")
    guard let r = line.range(of: "strip: ") , line.contains("→") else { return nil }
    let tail = line[r.upperBound...]
    guard let arrow = tail.range(of: "→ ") else { return nil }
    let range = tail[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
    let parts = range.components(separatedBy: "..")
    guard parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b > a else { return nil }
    return CGFloat(a)...CGFloat(b)
}

final class ClickImageView: NSImageView {
    var onPress: ((CGFloat) -> Void)?      // local x, points
    var onQuit: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onPress?(convert(event.locationInWindow, from: nil).x) }
    override func rightMouseDown(with event: NSEvent) { onQuit?() }
}

@MainActor
final class Mirror: NSObject {
    let panel: NSPanel
    let imageView = ClickImageView()
    let pad: CGFloat = 4

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let host: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 10
            g.contentView = imageView
            host = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
            v.wantsLayer = true; v.layer?.cornerRadius = 10
            v.addSubview(imageView)
            host = v
        }
        panel.contentView = host
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: pad),
            imageView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -pad),
            imageView.topAnchor.constraint(equalTo: host.topAnchor, constant: pad),
            imageView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -pad),
        ])
    }
    func show(frame: NSRect) {
        panel.setFrame(frame, display: true)
        imageView.image = nil
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; panel.animator().alphaValue = 1 }
    }
    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; panel.animator().alphaValue = 0 },
                                            completionHandler: { self.panel.orderOut(nil) })
    }
}

/// Bar-level cover parked over the real strip so the bar looks untouched.
@MainActor
final class Cover {
    let window: NSWindow
    let imageView = NSImageView()
    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        imageView.imageScaling = .scaleAxesIndependently
        window.contentView = imageView
    }
    func show(frame: NSRect, image: NSImage) {
        imageView.image = image
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }
    func hide() { window.orderOut(nil) }
}

struct AXItem { let frame: CGRect; let element: AXUIElement; let app: String }

func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = axAttr(el, kAXPositionAttribute), let s = axAttr(el, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}
/// Every app's menu-bar extras whose frame lies in `band` (global CG coords, top-left origin).
func extrasItems(in band: CGRect, excluding me: pid_t) -> [AXItem] {
    var out: [AXItem] = []
    for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me && app.processIdentifier > 0 {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        guard let bar = axAttr(ax, "AXExtrasMenuBar"), let kids = axAttr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { continue }
        for kid in kids {
            guard let f = axFrame(kid), f.width > 0, band.intersects(f) else { continue }
            out.append(AXItem(frame: f, element: kid, app: app.localizedName ?? "pid \(app.processIdentifier)"))
        }
    }
    return out.sorted { $0.frame.minX < $1.frame.minX }
}

struct Band {
    let screen: NSScreen
    let display: SCDisplay
    let scale: CGFloat
    let barH: CGFloat
    let source: CGRect          // display-local, top-left origin
    let panelFrame: NSRect      // global AppKit coords
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let tail = LogTail()
    var mirror: Mirror?
    var running = true
    var strip: ClosedRange<CGFloat>?
    var mirroring = false
    var items: [AXItem] = []
    var cover: Cover?

    func applicationDidFinishLaunching(_ note: Notification) {
        log("Shadow demo 2 start, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), dotShift=\(dotShift)")
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            log("no screen capture access, quitting"); NSApp.terminate(nil); return
        }
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        log("accessibility trusted=\(trusted)\(trusted ? "" : " — allow PeriscopeProbe in Accessibility, clicks are inert until then")")
        Task { @MainActor in await self.run() }
    }

    func band(for strip: ClosedRange<CGFloat>, content: SCShareableContent) -> Band? {
        let shifted = (strip.lowerBound - dotShift)...(strip.upperBound - dotShift)
        guard let screen = NSScreen.screens.first(where: { $0.frame.minX <= shifted.lowerBound && shifted.upperBound <= $0.frame.maxX }) else { return nil }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let barH = screen.frame.maxY - screen.visibleFrame.maxY
        let w = shifted.upperBound - shifted.lowerBound
        let source = CGRect(x: shifted.lowerBound - screen.frame.minX, y: 0, width: w, height: barH)
        let pad: CGFloat = 4
        let frame = NSRect(x: shifted.lowerBound - pad, y: screen.frame.maxY - barH - (barH + 2 * pad),
                           width: w + 2 * pad, height: barH + 2 * pad)
        return Band(screen: screen, display: display, scale: screen.backingScaleFactor, barH: barH, source: source, panelFrame: frame)
    }

    @MainActor
    func run() async {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { log("SCShareableContent failed: \(error)"); NSApp.terminate(nil); return }
        strip = tail.lastStrip()
        _ = tail.readNew()   // skip history, tail from now on
        log("initial strip: \(strip.map { "\(Int($0.lowerBound))..\(Int($0.upperBound))" } ?? "none yet")")
        let m = Mirror()
        mirror = m
        var current: Band?
        m.imageView.onQuit = { [weak self] in log("right-click, quitting"); self?.running = false }
        m.imageView.onPress = { [weak self] localX in
            guard let self, let b = current else { return }
            let globalX = b.panelFrame.minX + m.pad + localX
            guard let hit = self.items.first(where: { $0.frame.minX <= globalX && globalX <= $0.frame.maxX }) else {
                log("click x=\(Int(globalX)) — no item under it (\(self.items.count) known)"); return
            }
            let r = AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
            log("click x=\(Int(globalX)) → AXPress \(hit.app) [\(Int(hit.frame.minX))..\(Int(hit.frame.maxX))] result=\(r.rawValue)")
        }

        var filter: SCContentFilter?
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let end = Date().addingTimeInterval(180)
        var frames = 0, lastCPU = cpuSeconds(), lastT = Date(), latency = 0.0
        while running && Date() < end {
            let f0 = Date()
            for line in tail.readNew() {
                if let r = parseStrip(line) { strip = r; log("strip → \(Int(r.lowerBound))..\(Int(r.upperBound))") }
                else if line.contains("effect reveal [") && line.contains("idden") && !mirroring {
                    guard let s = strip, let b = self.band(for: s, content: content) else { log("reveal but no strip/band"); continue }
                    current = b
                    cfg.sourceRect = b.source
                    cfg.width = Int(b.source.width * b.scale)
                    cfg.height = Int(b.barH * b.scale)
                    // Pre-swap picture of the strip = the cover. Pelmet's own ghost cover is still up here.
                    let plain = SCContentFilter(display: b.display, excludingWindows: [])
                    let c0 = Date()
                    if let pre = try? await SCScreenshotManager.captureImage(contentFilter: plain, configuration: cfg) {
                        let cv = cover ?? Cover()
                        cover = cv
                        let coverFrame = NSRect(x: b.source.minX + b.screen.frame.minX, y: b.screen.frame.maxY - b.barH,
                                                width: b.source.width, height: b.barH)
                        cv.show(frame: coverFrame, image: NSImage(cgImage: pre, size: NSSize(width: b.source.width, height: b.barH)))
                        log(String(format: "cover up %.0fms after the reveal line", Date().timeIntervalSince(c0) * 1000))
                    }
                    // The mirror must not see our own cover.
                    let fresh = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) ?? content
                    let mine = fresh.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                    filter = SCContentFilter(display: b.display, excludingWindows: mine)
                    log("mirror excludes \(mine.count) own window(s)")
                    m.show(frame: b.panelFrame)
                    mirroring = true
                    log("SHOW \(Int(b.source.width))pt @x=\(Int(s.lowerBound)) display \(b.display.displayID) barH=\(b.barH)")
                    let me = ProcessInfo.processInfo.processIdentifier
                    // AX frames are global CG coords (top-left origin of the primary display).
                    let cgTop = NSScreen.screens[0].frame.maxY - b.screen.frame.maxY
                    let bandRect = CGRect(x: s.lowerBound - 12, y: cgTop, width: (s.upperBound - s.lowerBound) + 24, height: b.barH)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)   // let the capture dot land first
                        let list = extrasItems(in: bandRect, excluding: me)
                        self.items = list
                        log("items: \(list.map { "\($0.app)@\(Int($0.frame.minX))..\(Int($0.frame.maxX))" }.joined(separator: " "))")
                    }
                } else if line.contains("effect conceal") && mirroring {
                    m.hide(); cover?.hide(); mirroring = false
                    log("HIDE")
                }
            }
            if mirroring, let f = filter, let b = current,
               let img = try? await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg) {
                m.imageView.image = NSImage(cgImage: img, size: NSSize(width: b.source.width, height: b.barH))
                frames += 1
                latency += Date().timeIntervalSince(f0)
                if Date().timeIntervalSince(lastT) >= 5 {
                    let cpu = cpuSeconds(); let dt = Date().timeIntervalSince(lastT)
                    log(String(format: "mirror: %.1f fps, capture %.0f ms avg, cpu %.1f%%", Double(frames) / dt, latency / Double(max(frames, 1)) * 1000, (cpu - lastCPU) / dt * 100))
                    frames = 0; latency = 0; lastCPU = cpu; lastT = Date()
                }
            } else if !mirroring { lastCPU = cpuSeconds(); lastT = Date(); frames = 0; latency = 0 }
            let spent = Date().timeIntervalSince(f0)
            if spent < 0.1 { try? await Task.sleep(nanoseconds: UInt64((0.1 - spent) * 1e9)) }
        }
        if mirroring { m.hide(); cover?.hide() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        log("done")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
