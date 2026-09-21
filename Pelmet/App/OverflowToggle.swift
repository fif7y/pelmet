// OverflowToggle.swift
// The native overflow toggle («): a MenuBarAgent-owned AXButton, described
// "Show Hidden Menu Bar Items" collapsed / "Hide Menu Bar Items" expanded.
// It sits in no AX hierarchy, only a position hit-test finds it — through
// the AGENT's own app element, which works with any app frontmost (the
// systemwide hit-test is shadowed by the frontmost app's menu bar; probed
// 2026-09-20). Expanding it gives the trapped items real frames LEFT OF
// THE NOTCH and shifts the visible run ~38pt; the state holds under a
// cover, with the pointer away and another app clicked. AXPress is refused;
// only a real HID click toggles it (ItemMover.shieldedClick). Apply expands
// it only when a drawn edit names a trapped icon, and collapses it after.

import AppKit
import ApplicationServices
import PelmetCore
import PelmetEngine

/// The «'s description is localized by the agent (the system language, not
/// Pelmet's), so both labels are matched against every translation in
/// MenuBarAgent's own strings table; English is always seeded.
nonisolated enum OverflowToggleLabels {
    static let showKey = "menuBar.showOverflowItemsAccessibilityLabel"
    static let hideKey = "menuBar.hideOverflowItemsAccessibilityLabel"
    static let englishShow = "Show Hidden Menu Bar Items"
    static let englishHide = "Hide Menu Bar Items"

    struct Table: Sendable {
        let show: Set<String>
        let hide: Set<String>
    }

    static let defaultURL = URL(fileURLWithPath:
        "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")

    static let table: Table = load(at: defaultURL) ?? Table(show: [englishShow], hide: [englishHide])

    static func load(at url: URL) -> Table? {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        var show: Set<String> = [englishShow]
        var hide: Set<String> = [englishHide]
        for (_, value) in root {
            guard let strings = value as? [String: Any] else { continue }
            if let s = strings[showKey] as? String { show.insert(s) }
            if let h = strings[hideKey] as? String { hide.insert(h) }
        }
        return Table(show: show, hide: hide)
    }

    /// nil = not the toggle. true = expanded (the label offers to hide).
    static func expandedState(forDescription desc: String) -> Bool? {
        let d = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        if table.hide.contains(d) { return true }
        if table.show.contains(d) { return false }
        return nil
    }
}

@MainActor
enum OverflowToggle {
    // AXUIElement is a thread-safe CF ref — safe to hop actors with.
    nonisolated struct Toggle: @unchecked Sendable {
        let element: AXUIElement
        let frame: CGRect
        let expanded: Bool
    }

    /// Sweep the primary band through the agent's app element. ~3pt steps
    /// cannot skip the ~17pt button; nil when the bar does not overflow.
    nonisolated static func find() -> Toggle? {
        guard let screen = NSScreen.screens.first,
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.agentID).first
        else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        var x = screen.frame.midX
        while x < screen.frame.maxX - 200 {
            defer { x += 3 }
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(x), 12, &el) == .success, let el else { continue }
            var roleV: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleV)
            guard roleV as? String == "AXButton" else { continue }
            guard let expanded = state(of: el) else { continue }
            var frame = CGRect.zero
            var posV: CFTypeRef?
            var sizeV: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
               AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success {
                var p = CGPoint.zero
                var s = CGSize.zero
                AXValueGetValue(posV as! AXValue, .cgPoint, &p)
                AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
                frame = CGRect(origin: p, size: s)
            }
            return Toggle(element: el, frame: frame, expanded: expanded)
        }
        return nil
    }

    nonisolated static func state(of element: AXUIElement) -> Bool? {
        var descV: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descV)
        return (descV as? String).flatMap(OverflowToggleLabels.expandedState(forDescription:))
    }

    nonisolated private static func currentFrame(of element: AXUIElement) -> CGRect? {
        var posV: CFTypeRef?
        var sizeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posV) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeV) == .success
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Click until the toggle reads `expanded` (two tries: the collapse
    /// click missed once in three probe runs). Returns the toggle when the
    /// state was reached, nil when there is no « or it would not flip.
    private static func set(expanded: Bool, _ toggle: Toggle) async -> Bool {
        // Live state, never the one captured at find(): the collapse after
        // the first live pass compared against "collapsed" and returned
        // without a click, leaving the « open (2026-09-21 07:00).
        if state(of: toggle.element) == expanded { return true }
        for attempt in 1...2 {
            let frame = currentFrame(of: toggle.element) ?? toggle.frame
            guard frame != .zero else { return false }
            await ItemMover.shieldedClick(at: CGPoint(x: frame.midX, y: frame.midY))
            try? await Task.sleep(for: AppTiming.overflowExpandSettle)
            let now = state(of: toggle.element)
            PelmetLog.log("overflow«: click \(attempt) → \(now.map { $0 ? "expanded" : "collapsed" } ?? "gone")")
            if now == expanded { return true }
            if now == nil { return !expanded }
        }
        return false
    }

    /// A pass expanded the « and could not collapse it (the bar de-crowded
    /// and took the toggle away first, or the click missed): the next pass
    /// that finds it expanded owns it and collapses it after. Persisted —
    /// the agent keeps the state across Pelmet relaunches.
    private static let leftExpandedKey = "pelmet.overflowLeftExpanded"
    private static var leftExpanded: Bool {
        get { UserDefaults.standard.bool(forKey: leftExpandedKey) }
        set { UserDefaults.standard.set(newValue, forKey: leftExpandedKey) }
    }

    /// Expand for a pass. Returns the toggle to collapse afterwards, nil
    /// when nothing was expanded (no «, expanded by the user, or the click
    /// would not take).
    static func expandForPass() async -> Toggle? {
        guard let toggle = find() else {
            PelmetLog.log("overflow«: no toggle on the bar")
            return nil
        }
        if toggle.expanded {
            if leftExpanded {
                PelmetLog.log("overflow«: already expanded (left by an earlier pass) — collapses after")
                return toggle
            }
            PelmetLog.log("overflow«: already expanded by the user — left as is")
            return nil
        }
        guard await set(expanded: true, toggle) else { return nil }
        leftExpanded = true
        return toggle
    }

    /// Any whole-bar pass that does not need the «: put back what an
    /// earlier pass left open, while the bar is revealed and the toggle
    /// on it.
    static func collapseIfLeftExpanded() async {
        guard leftExpanded, let toggle = find() else { return }
        guard toggle.expanded else { leftExpanded = false; return }
        PelmetLog.log("overflow«: left expanded by an earlier pass — collapsing")
        if await set(expanded: false, toggle) { leftExpanded = false }
    }

    static func collapseAfterPass(_ toggle: Toggle) async {
        // The pass may have de-crowded the bar and taken the « with it; the
        // agent still remembers it expanded, so the flag stays for the next
        // pass that sees the toggle again.
        guard state(of: toggle.element) == true else {
            PelmetLog.log("overflow«: gone after the pass — collapses at the next pass that finds it")
            return
        }
        if await set(expanded: false, toggle) { leftExpanded = false }
    }
}
