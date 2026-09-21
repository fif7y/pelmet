// OverflowProbe.swift — the « under-bar's first question (2026-09-20):
// can the native overflow toggle be found and expanded from a background
// app, what does the expanded bar look like (which items gain frames, where),
// and does the expanded state HOLD under an opaque cover window while the
// pointer leaves, another app is clicked, and time passes?
// Run with the bar overflowing (Pelmet quit: the full bar overflows on a 14").
// Log: out/overflow.log, pictures out/overflow-*.png (screencapture, no dot).
// Build: ./build.sh OverflowProbe

import AppKit
import ApplicationServices

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let logURL = URL(fileURLWithPath: outDir).appendingPathComponent("overflow.log")
try? "".write(to: logURL, atomically: true, encoding: .utf8)
let t0 = Date()
func log(_ s: String) {
    let line = String(format: "%6.2f %@\n", Date().timeIntervalSince(t0), s)
    print(line, terminator: "")
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
}

// MARK: - AX helpers

struct Item: CustomStringConvertible {
    let element: AXUIElement
    let pid: pid_t
    let bundle: String
    let role: String
    let desc: String
    let title: String
    let frame: CGRect
    var description: String {
        "\(bundle)[\(pid)] \(role) \"\(desc.isEmpty ? title : desc)\" x=\(Int(frame.minX))..\(Int(frame.maxX)) w=\(Int(frame.width))"
    }
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func frame(of el: AXUIElement) -> CGRect {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return .zero }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func item(from el: AXUIElement) -> Item {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
    return Item(element: el, pid: pid, bundle: bundle,
                role: attr(el, kAXRoleAttribute) as? String ?? "?",
                desc: attr(el, kAXDescriptionAttribute) as? String ?? "",
                title: attr(el, kAXTitleAttribute) as? String ?? "",
                frame: frame(of: el))
}

let agentPID: pid_t = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first?.processIdentifier ?? 0

/// Hit-test sweep across the primary band: every distinct element at y=12.
/// `scope` = the agent's own app element (no frontmost menu bar in the way)
/// or systemwide.
func sweep(from x0: CGFloat, to x1: CGFloat, step: CGFloat = 3, agentScoped: Bool = false) -> [Item] {
    let sys = agentScoped ? AXUIElementCreateApplication(agentPID) : AXUIElementCreateSystemWide()
    var seen: [String: Item] = [:]
    var order: [String] = []
    var x = x0
    while x < x1 {
        defer { x += step }
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(x), 12, &el) == .success, let el else { continue }
        let it = item(from: el)
        let key = "\(it.pid)|\(it.role)|\(Int(it.frame.minX))|\(Int(it.frame.width))|\(it.desc)|\(it.title)"
        if seen[key] == nil { seen[key] = it; order.append(key) }
    }
    return order.compactMap { seen[$0] }
}

// The « labels, every language MenuBarAgent ships.
let loctable = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")
var showLabels: Set<String> = ["Show Hidden Menu Bar Items"]
var hideLabels: Set<String> = ["Hide Menu Bar Items"]
if let data = try? Data(contentsOf: loctable),
   let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
    for (_, v) in root {
        guard let strings = v as? [String: Any] else { continue }
        if let s = strings["menuBar.showOverflowItemsAccessibilityLabel"] as? String { showLabels.insert(s) }
        if let h = strings["menuBar.hideOverflowItemsAccessibilityLabel"] as? String { hideLabels.insert(h) }
    }
}
func expandedState(_ desc: String) -> Bool? {
    let d = desc.trimmingCharacters(in: .whitespacesAndNewlines)
    if hideLabels.contains(d) { return true }
    if showLabels.contains(d) { return false }
    return nil
}
func toggleState(_ el: AXUIElement) -> Bool? {
    expandedState(attr(el, kAXDescriptionAttribute) as? String ?? "")
}

func hidClick(at point: CGPoint, restoreCursor: Bool = true) {
    let before = CGEvent(source: nil)?.location
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
    down.post(tap: .cghidEventTap)
    usleep(60_000)
    up.post(tap: .cghidEventTap)
    usleep(20_000)
    if restoreCursor, let before {
        CGWarpMouseCursorPosition(before)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

func snap(_ name: String, _ r: CGRect) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))",
                   URL(fileURLWithPath: outDir).appendingPathComponent("overflow-\(name).png").path]
    try? p.run(); p.waitUntilExit()
}

// MARK: - Run

final class Delegate: NSObject, NSApplicationDelegate {
    var cover: NSWindow?
    var filler: [NSStatusItem] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        Task { @MainActor in await run(); NSApp.terminate(nil) }
    }

    @MainActor
    func run() async {
        log("trusted=\(AXIsProcessTrusted()) screens=\(NSScreen.screens.count)")
        guard let screen = NSScreen.screens.first else { return }
        let barH = screen.frame.maxY - screen.visibleFrame.maxY
        let band = CGRect(x: 0, y: 0, width: screen.frame.maxX, height: max(barH, 24))
        log("bar height=\(barH) band=\(band) agentPID=\(agentPID)")

        // Force an overflow: N status items of our own (the bar fit tonight
        // with Pelmet quit, 1060..1777 on 1800pt).
        let fillerCount = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 12 : 12
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            NSColor.labelColor.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill(); return true
        }
        img.isTemplate = true
        for i in 0..<fillerCount {
            let it = NSStatusBar.system.statusItem(withLength: 28)
            it.button?.image = img
            it.button?.toolTip = "probe \(i)"
            filler.append(it)
        }
        try? await Task.sleep(for: .seconds(1.5))
        log("added \(fillerCount) filler item(s)")

        // A regular app's full-width AXMenuBar shadows the agent's « from the
        // hit-test (2026-08-22). Become frontmost first, then compare.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(600))
        log("frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")

        let agentSweep = sweep(from: band.minX, to: band.maxX, agentScoped: true)
        log("--- agent-scoped sweep (\(agentSweep.count) elements)")
        for it in agentSweep { log("  \(it)") }
        let before = sweep(from: band.minX, to: band.maxX) + agentSweep.filter { a in true }
        log("--- systemwide sweep before (\(before.count) elements)")
        for it in before { log("  \(it)") }
        let isToggle: (Item) -> Bool = { $0.role == "AXButton" && expandedState($0.desc) != nil }
        guard let toggle = agentSweep.first(where: isToggle) ?? before.first(where: isToggle) else {
            log("RESULT: « not found in either sweep — bar not overflowing, or the toggle is shadowed")
            snap("nochevron", band)
            return
        }
        log("« resolved via \(agentSweep.contains(where: isToggle) ? "agent-scoped" : "systemwide") hit-test")
        log("« found: \(toggle) expanded=\(toggleState(toggle.element) == true)")
        snap("before", CGRect(x: 0, y: 0, width: screen.frame.width, height: max(barH, 24)))

        // Expand. AXPress first (refused on 27 so far), then a HID click with the cursor warped back.
        let axPress = AXUIElementPerformAction(toggle.element, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(600))
        var state = toggleState(toggle.element)
        log("AXPress → \(axPress.rawValue) expanded=\(String(describing: state))")
        if state != true {
            hidClick(at: CGPoint(x: toggle.frame.midX, y: toggle.frame.midY))
            try? await Task.sleep(for: .milliseconds(800))
            state = toggleState(toggle.element)
            log("HID click → expanded=\(String(describing: state))")
        }
        guard state == true else { log("RESULT: could not expand «"); return }
        let full = CGRect(x: 0, y: 0, width: screen.frame.width, height: max(barH, 24))

        // Does it stay expanded on its own? State reads only (an element
        // attribute read, no hit-tests, no windows, no captures until 1s).
        var elapsed = 0
        for ms in [300, 700, 1000, 1500, 2000, 3000, 4500] {
            try? await Task.sleep(for: .milliseconds(ms - elapsed)); elapsed = ms
            log("hands-off \(ms)ms: expanded=\(String(describing: toggleState(toggle.element)))")
            if ms == 1000 { snap("expanded-full-1s", full) }
        }
        if toggleState(toggle.element) != true {
            log("RESULT: « collapses on its own within seconds, hands off — re-expanding for the rest")
            hidClick(at: CGPoint(x: frame(of: toggle.element).midX, y: frame(of: toggle.element).midY))
            try? await Task.sleep(for: .milliseconds(500))
            log("re-expanded=\(String(describing: toggleState(toggle.element)))")
        }
        snap("expanded-full", full)
        let after = sweep(from: band.minX, to: band.maxX, agentScoped: true) + sweep(from: band.minX, to: band.maxX).filter { $0.pid != agentPID }
        log("after sweeps: expanded=\(String(describing: toggleState(toggle.element)))")
        log("--- sweep expanded (\(after.count) elements)")
        for it in after { log("  \(it)") }
        let beforeKeys = Set(before.map { "\($0.pid)|\($0.desc)|\($0.title)" })
        let gained = after.filter { !beforeKeys.contains("\($0.pid)|\($0.desc)|\($0.title)") }
        log("gained \(gained.count): \(gained.map { "\($0.bundle.split(separator: ".").last ?? "?")@\(Int($0.frame.minX))" })")
        // Frames that moved between the two sweeps (same pid+desc+title).
        var beforeX: [String: CGFloat] = [:]
        for it in before { beforeX["\(it.pid)|\(it.desc)|\(it.title)"] = it.frame.minX }
        for it in after where it.role == "AXMenuBarItem" || it.role == "AXButton" {
            if let x0 = beforeX["\(it.pid)|\(it.desc)|\(it.title)"], abs(x0 - it.frame.minX) > 2 {
                log("  moved: \(it.bundle) \(Int(x0)) → \(Int(it.frame.minX))")
            }
        }
        for it in after where it.pid == getpid() { log("  own filler: x=\(Int(it.frame.minX)) w=\(Int(it.frame.width))") }
        let toggleNow = frame(of: toggle.element)
        log("« now at x=\(Int(toggleNow.minX))..\(Int(toggleNow.maxX))")

        // Hold under an opaque cover from the leftmost status item to the clock.
        let clockMinX = after.first(where: { $0.desc.lowercased().contains("clock") || $0.title.contains(":") })?.frame.minX ?? band.maxX - 120
        let leftmost = after.map(\.frame.minX).filter { $0 > band.minX }.min() ?? band.minX
        let coverAX = CGRect(x: leftmost - 8, y: 0, width: clockMinX - leftmost + 8, height: barH)
        let w = NSWindow(contentRect: NSRect(x: coverAX.minX, y: screen.frame.maxY - barH, width: coverAX.width, height: barH),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        w.isOpaque = true
        w.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.18, alpha: 1)
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.orderFrontRegardless()
        cover = w
        log("cover up over x=\(Int(coverAX.minX))..\(Int(coverAX.maxX))")
        try? await Task.sleep(for: .milliseconds(500))
        snap("covered", band)

        func poll(_ label: String) {
            let s = toggleState(toggle.element)
            let vis = gained.filter { frame(of: $0.element).width > 0 && frame(of: $0.element).minX > band.minX }.count
            log("\(label): expanded=\(String(describing: s)) gained-still-framed=\(vis)/\(gained.count)")
        }
        poll("under cover 0.5s")
        try? await Task.sleep(for: .seconds(3))
        poll("under cover 3.5s")

        // Pointer leaves the bar.
        CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        try? await Task.sleep(for: .seconds(2))
        poll("pointer away 2s")

        // Another app takes focus (a click on the desktop → Finder).
        hidClick(at: CGPoint(x: screen.frame.midX, y: screen.frame.midY), restoreCursor: false)
        try? await Task.sleep(for: .seconds(1.5))
        log("frontmost now=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
        poll("after desktop click")

        // Pointer back into the bar band (over the cover), then time.
        CGWarpMouseCursorPosition(CGPoint(x: coverAX.midX, y: 10))
        try? await Task.sleep(for: .seconds(1))
        poll("pointer over cover")
        try? await Task.sleep(for: .seconds(5))
        poll("after 5s more")
        snap("held", band)

        // Can the expanded items be read while covered? (element refs, not hit-tests)
        for it in gained.prefix(4) { log("  covered read: \(it.bundle) frame=\(frame(of: it.element))") }

        // Restore: cover down, collapse if still expanded.
        w.orderOut(nil)
        cover = nil
        try? await Task.sleep(for: .milliseconds(300))
        if toggleState(toggle.element) == true {
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(300))
            let f = frame(of: toggle.element)
            hidClick(at: CGPoint(x: f.midX, y: f.midY))
            try? await Task.sleep(for: .milliseconds(800))
            log("collapse click → expanded=\(String(describing: toggleState(toggle.element)))")
        } else {
            log("already collapsed by the time the cover came down")
        }
        snap("after", band)
        log("RESULT: done")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
