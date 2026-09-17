// PeriscopeProbe — can an un-hosted status item's off-screen window be captured,
// and does it keep updating? Shows whatever it captures in a glass panel under
// the menu bar for ~40 s, then quits. Log + PNGs land in argv[1].
import AppKit
import ScreenCaptureKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let logURL = outDir.appendingPathComponent("probe.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try! FileHandle(forWritingTo: logURL)
let t0 = Date()
func log(_ s: String) {
    let line = String(format: "%7.2f  %@\n", Date().timeIntervalSince(t0), s)
    logHandle.write(line.data(using: .utf8)!)
}

func cpuSeconds() -> Double {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
         + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

func rgba(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard w > 0, h > 0,
          let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return data }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return data
}
/// Fraction of pixels with alpha > 16 (is there anything drawn at all?).
func coverage(_ img: CGImage) -> Double {
    let d = rgba(img); guard !d.isEmpty else { return 0 }
    var n = 0; var i = 3
    while i < d.count { if d[i] > 16 { n += 1 }; i += 4 }
    return Double(n) / Double(d.count / 4)
}
/// Fraction of pixels that changed between two captures (liveness).
func diff(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return 1 }
    let da = rgba(a), db = rgba(b); guard !da.isEmpty else { return 0 }
    var n = 0; var i = 0
    while i < da.count {
        if abs(Int(da[i]) - Int(db[i])) > 8 || abs(Int(da[i+1]) - Int(db[i+1])) > 8 || abs(Int(da[i+2]) - Int(db[i+2])) > 8 { n += 1 }
        i += 4
    }
    return Double(n) / Double(da.count / 4)
}
func savePNG(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: outDir.appendingPathComponent(name)) }
}

struct Target {
    let window: SCWindow
    let app: String
    var label: String { "\(app)#\(window.windowID)" }
}

func capture(_ w: SCWindow, scale: CGFloat) async -> CGImage? {
    let cfg = SCStreamConfiguration()
    cfg.width = max(1, Int(w.frame.width * scale))
    cfg.height = max(1, Int(w.frame.height * scale))
    cfg.showsCursor = false
    cfg.ignoreShadowsSingleWindow = true
    cfg.captureResolution = .best
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    let filter = SCContentFilter(desktopIndependentWindow: w)
    do {
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    } catch {
        log("capture FAILED \(w.owningApplication?.applicationName ?? "?")#\(w.windowID): \(error)")
        return nil
    }
}

@MainActor
final class PanelController: NSObject {
    let panel: NSPanel
    let stack = NSStackView()
    var views: [CGWindowID: NSImageView] = [:]
    var onClick: (() -> Void)?

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 12
            g.contentView = stack
            host = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
            v.wantsLayer = true; v.layer?.cornerRadius = 12
            v.addSubview(stack)
            host = v
        }
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        host.addGestureRecognizer(click)
    }
    @objc func clicked() { onClick?() }

    func show(targets: [Target], images: [CGWindowID: CGImage], screen: NSScreen) {
        let scale = screen.backingScaleFactor
        for t in targets {
            guard let img = images[t.window.windowID] else { continue }
            let iv = NSImageView()
            iv.imageScaling = .scaleNone
            iv.image = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: CGFloat(img.width) / scale).isActive = true
            iv.heightAnchor.constraint(equalToConstant: CGFloat(img.height) / scale).isActive = true
            iv.toolTip = t.label
            stack.addArrangedSubview(iv)
            views[t.window.windowID] = iv
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let barH = screen.frame.maxY - screen.visibleFrame.maxY
        let origin = NSPoint(x: screen.frame.maxX - size.width - 16, y: screen.frame.maxY - barH - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; panel.animator().alphaValue = 1 }
        log("panel shown \(Int(size.width))x\(Int(size.height)) at \(Int(origin.x)),\(Int(origin.y)) barH=\(barH) glass=\(panel.contentView is NSVisualEffectView ? "fallback" : "NSGlassEffectView")")
    }
    func update(_ id: CGWindowID, _ img: CGImage, scale: CGFloat) {
        views[id]?.image = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
    }
    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; panel.animator().alphaValue = 0 },
                                            completionHandler: { self.panel.orderOut(nil) })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PanelController?
    var running = true

    func applicationDidFinishLaunching(_ note: Notification) {
        log("PeriscopeProbe start, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), out=\(outDir.path)")
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            log("screen capture access not granted; prompt requested, granted=\(granted). Allow PeriscopeProbe in Screen & System Audio Recording, then relaunch.")
            if !granted { NSApp.terminate(nil); return }
        }
        Task { @MainActor in await self.run() }
    }

    @MainActor
    func run() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            log("SCShareableContent FAILED (permission?): \(error)")
            NSApp.terminate(nil); return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        let onScreenIDs = Set(((try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?.windows ?? []).map { $0.windowID })

        // Every window at status-bar level (24..26) not ours.
        var targets: [Target] = []
        for w in content.windows where (24...26).contains(w.windowLayer) && w.owningApplication?.processID != me {
            let app = w.owningApplication?.applicationName ?? "?"
            let bid = w.owningApplication?.bundleIdentifier ?? "?"
            let f = w.frame
            log(String(format: "window L%d %@ (%@) #%d frame=(%.0f,%.0f %.0fx%.0f) onScreen=%@ title=%@",
                       w.windowLayer, app, bid, w.windowID, f.origin.x, f.origin.y, f.width, f.height,
                       onScreenIDs.contains(w.windowID) ? "Y" : "n", w.title ?? ""))
            if w.windowLayer == 25, f.width > 4, f.width < 600, f.height > 4, f.height < 60 {
                targets.append(Target(window: w, app: app))
            }
        }
        log("targets: \(targets.count) status-item windows")

        // Capture 1
        var first: [CGWindowID: CGImage] = [:]
        for t in targets {
            let c0 = Date()
            if let img = await capture(t.window, scale: scale) {
                first[t.window.windowID] = img
                let cov = coverage(img)
                log(String(format: "cap1 %@ %dx%d coverage=%.3f %.0fms", t.label, img.width, img.height, cov, Date().timeIntervalSince(c0) * 1000))
                savePNG(img, "cap1_\(t.app.replacingOccurrences(of: "/", with: "_"))_\(t.window.windowID).png")
            }
        }
        // Capture 2, three seconds later: liveness
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        var live: [CGWindowID: CGImage] = [:]
        for t in targets {
            if let img = await capture(t.window, scale: scale) {
                live[t.window.windowID] = img
                let d = first[t.window.windowID].map { diff($0, img) } ?? -1
                log(String(format: "cap2 %@ changed=%.4f", t.label, d))
                savePNG(img, "cap2_\(t.app.replacingOccurrences(of: "/", with: "_"))_\(t.window.windowID).png")
            }
        }

        // Show them, then refresh at ~10 fps for ~35 s, logging CPU every 5 s.
        let shown = targets.filter { live[$0.window.windowID].map { coverage($0) > 0.002 } ?? false }
        log("showing \(shown.count) of \(targets.count) (coverage > 0.2%)")
        let pc = PanelController()
        controller = pc
        pc.onClick = { [weak self] in log("panel clicked, quitting"); self?.running = false }
        pc.show(targets: shown, images: live, screen: screen)

        let end = Date().addingTimeInterval(35)
        var frames = 0
        var lastCPU = cpuSeconds(), lastT = Date()
        while running && Date() < end {
            let f0 = Date()
            for t in shown {
                if let img = await capture(t.window, scale: scale) { pc.update(t.window.windowID, img, scale: scale) }
            }
            frames += 1
            if Date().timeIntervalSince(lastT) >= 5 {
                let cpu = cpuSeconds(); let dt = Date().timeIntervalSince(lastT)
                log(String(format: "refresh: %.1f fps, cpu %.1f%%", Double(frames) / dt, (cpu - lastCPU) / dt * 100))
                frames = 0; lastCPU = cpu; lastT = Date()
            }
            let spent = Date().timeIntervalSince(f0)
            if spent < 0.1 { try? await Task.sleep(nanoseconds: UInt64((0.1 - spent) * 1e9)) }
        }
        pc.hide()
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
