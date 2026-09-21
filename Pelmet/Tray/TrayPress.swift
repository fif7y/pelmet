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

    /// Windows the item's owner has up beyond its status item — a menu, a
    /// popover, a panel — counted so the relay knows when the press has
    /// shown something and when that something is gone. Ordinary document
    /// windows (layer 0) and the bar's own layer are not it.
    static func elevatedWindowCount(pid: pid_t) -> Int {
        guard pid > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        return list.filter { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int
            else { return false }
            return layer > 0 && layer != 25
        }.count
    }
}
