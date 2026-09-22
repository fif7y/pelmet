// TrayPress.swift
// The relay's press: the item is hosted in the real bar beneath a cover, and
// AXPress on its own extras-bar element opens whatever it opens, from the
// bar. The engine's snapshot names the item and its frame; the element
// comes from the owning app (one AX round trip per press). A system module
// (no enumerable extras bar) takes whatever the system finds at its centre.

import AppKit
import ApplicationServices
import PelmetEngine

enum TrayPress {
    @discardableResult
    static func press(_ item: ObservedItem) -> Bool {
        guard let frame = item.frame else { return false }
        if item.pid > 0, let element = extrasElement(pid: item.pid, at: frame) {
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
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

    /// Elevated windows on screen that are not Pelmet's — a menu, a
    /// popover, a panel the press opened — counted so the relay knows when
    /// the press has shown something and when that something is gone. Not
    /// keyed on the owner: a system extra's panel belongs to another
    /// process. Ordinary document windows (layer 0) and the bar's own
    /// layer are not it.
    static func elevatedWindowCount() -> Int {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        let barBottom = NSScreen.screens.first.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24
        let screenWidth = NSScreen.screens.first?.frame.width ?? 1440
        return list.filter { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner != me,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"]
            else { return false }
            // Weather's popover is a status-level window (layer 25, the
            // bar's own level) 1131pt tall: the bar's level is excluded
            // only at the bar's height.
            if layer > 0, layer != 25 || height > 60 { return true }
            // A popover at the normal level (Weather's): its top sits
            // between the bar and 60pt below it (its bounds carry a
            // margin), and it is nowhere near a document window's width.
            return layer == 0 && height > 40 && width < screenWidth * 0.6 && y >= 0 && y <= barBottom + 60
        }.count
    }

    /// Every on-screen window of `pid` but the bar's own layer, whatever
    /// its level or shape: a popover the press opened raises it by one.
    static func windowCount(pid: pid_t) -> Int {
        guard pid > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        return list.filter { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let height = bounds["Height"] else { return false }
            // A status item has no window of its own on macOS 27: anything
            // taller than a bar row is a popover or panel, whatever level
            // it sits at (Weather's is at the bar's own level).
            return height > 40
        }.count
    }

    /// The click every host answers: a shielded HID click at the item's
    /// centre (cursor hidden, warped back). The cover above ignores mouse
    /// events, so it reaches the bar.
    static func click(_ item: ObservedItem) async {
        guard let frame = item.frame else { return }
        await ItemMover.shieldedClick(at: CGPoint(x: frame.midX, y: frame.midY))
    }
}
