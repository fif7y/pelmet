// ItemEnumerator.swift
// AX snapshot of MenuBarAgent's item tree. Verified structure (M1 findings):
// AXApplication → AXWindow (one per display) → `?`-role groups, one per item.
// Third-party groups nest the owning app's AXApplication node; system items are
// AXMenuBarItem leaves with a com.apple.menuextra.* identifier.

import AppKit
import ApplicationServices
import Foundation
import PelmetCore

public struct RawItem: Equatable, Sendable {
    public let id: ItemID
    public let frame: CGRect
    public let appName: String?
    /// See `ObservedItem.hostIsBundleless`.
    public let hostIsBundleless: Bool
}

/// Bundle attribution of an item's owning process.
private struct HostBundle {
    let id: String
    /// The process itself has no LS bundle id; `id` came from walking the
    /// executable path up to the enclosing .app.
    let bundleless: Bool
}

/// Runs off the main actor: AX calls into busy apps can block, so snapshots are
/// taken on a background executor with short messaging timeouts.
public actor ItemEnumerator {
    public init() {}
    static let agentBundleID = PelmetBundle.agentID

    private var agentElement: AXUIElement?
    private var agentPID: pid_t = 0

    /// Correlates each observed item group to a stable agent tag. Tags come
    /// from the positions plist domain (`status:<bundle>::<title>`); we build
    /// the same shape from the AX tree so both sources agree.
    public func snapshotItems() -> [RawItem] {
        guard let agent = resolveAgent() else { return [] }
        guard let windows = copyAttribute(agent, kAXChildrenAttribute) as? [AXUIElement] else {
            return []
        }
        var byID: [ItemID: RawItem] = [:]
        var order: [ItemID] = []
        for window in windows {
            guard role(of: window) == "AXWindow" else { continue }
            guard let groups = copyAttribute(window, kAXChildrenAttribute) as? [AXUIElement] else {
                continue
            }
            for group in groups {
                guard let item = describeGroup(group) else { continue }
                if let existing = byID[item.id] {
                    // The same item appears once per display. Prefer the
                    // main-display occurrence (y ≈ 0 in CG top-left coords) so
                    // every frame lives in one coordinate space — boundary
                    // comparisons break across mixed display spaces.
                    if !isMainDisplayFrame(existing.frame), isMainDisplayFrame(item.frame) {
                        byID[item.id] = item
                    }
                } else {
                    byID[item.id] = item
                    order.append(item.id)
                }
            }
        }
        return order.compactMap { byID[$0] }
    }

    private func isMainDisplayFrame(_ frame: CGRect) -> Bool {
        MenuBarGeometry.isInBand(frame)
    }

    // MARK: - Internals

    private func resolveAgent() -> AXUIElement? {
        if let cached = agentElement,
           NSRunningApplication(processIdentifier: agentPID)?.bundleIdentifier == Self.agentBundleID {
            return cached
        }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.agentBundleID
        }) else { return nil }
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        // A stuck app must never wedge a snapshot.
        AXUIElementSetMessagingTimeout(element, EngineTiming.axAgentTimeout)
        agentElement = element
        agentPID = agent.processIdentifier
        return element
    }

    private func describeGroup(_ group: AXUIElement) -> RawItem? {
        guard let frame = frame(of: group) else {
            logDrop("no AXFrame", pid: nil, role: role(of: group))
            return nil
        }
        let kids = children(of: group)
        for child in kids {
            switch role(of: child) {
            case "AXApplication":
                // Third-party item: owning app nested right in the tree.
                let appName = copyAttribute(child, kAXTitleAttribute) as? String
                var appPID: pid_t = 0
                AXUIElementGetPid(child, &appPID)
                guard let host = hostBundle(ofPID: appPID) else {
                    logDrop("no bundle id for AXApplication", pid: appPID, role: "AXApplication")
                    return nil
                }
                let title = statusItemTitle(in: child) ?? "Item-0"
                return RawItem(
                    id: .status(bundle: host.id, title: title),
                    frame: frame,
                    appName: appName,
                    hostIsBundleless: host.bundleless
                )
            case "AXGroup":
                // System item: AXGroup wrapping an AXMenuBarItem.
                for leaf in children(of: child) where role(of: leaf) == "AXMenuBarItem" {
                    guard let identifier = copyAttribute(leaf, kAXIdentifierAttribute) as? String else {
                        continue
                    }
                    return RawItem(
                        id: .status(bundle: Self.agentBundleID, title: identifier),
                        frame: frame,
                        appName: nil,
                        hostIsBundleless: false
                    )
                }
            case "AXButton":
                // Plain NSStatusItem buttons (Pelmet's own chevron/separators,
                // Thaw's dividers) sit in the tree as bare AXButtons — no
                // nested AXApplication. Attribute by the button's owning pid.
                if let item = describeLeaf(child, frame: frame) { return item }
            default:
                continue
            }
        }
        // Nothing matched the known shapes (a custom status view exposed as
        // AXStaticText/AXUnknown, issue #1: Little Snitch's two-line traffic
        // monitor). Any child with an owning pid outside the agent still
        // names its app; attribute by that rather than dropping the item.
        for child in kids {
            var pid: pid_t = 0
            AXUIElementGetPid(child, &pid)
            guard pid > 0, pid != agentPID else { continue }
            if let item = describeLeaf(child, frame: frame) {
                logOnce("enumerate: fallback — role=\(roleLabel(child)) → \(item.id.rawValue)", pid: pid)
                return item
            }
        }
        logDrop("unrecognized children \(kids.map { roleLabel($0) })", pid: nil, role: nil)
        return nil
    }

    /// Item attributed by a leaf element's owning pid, titled by whichever of
    /// title / identifier / description the element exposes.
    private func describeLeaf(_ element: AXUIElement, frame: CGRect) -> RawItem? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0, let host = hostBundle(ofPID: pid) else {
            logDrop("no bundle id for leaf", pid: pid, role: role(of: element))
            return nil
        }
        let candidates = [
            copyAttribute(element, kAXTitleAttribute) as? String,
            copyAttribute(element, kAXIdentifierAttribute) as? String,
            copyAttribute(element, kAXDescriptionAttribute) as? String,
        ]
        let title = candidates.compactMap { $0?.isEmpty == false ? $0 : nil }.first ?? "Item-0"
        return RawItem(
            id: .status(bundle: host.id, title: title),
            frame: frame,
            appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            hostIsBundleless: host.bundleless
        )
    }

    /// `NSRunningApplication.bundleIdentifier` first; when the process is not
    /// registered as an application (helper agents nested in another app's
    /// Components/ folder), read the Info.plist of the nearest enclosing .app
    /// on its executable path — and say so, because such an item is filed
    /// under a bundle the assertion can never hide.
    private func hostBundle(ofPID pid: pid_t) -> HostBundle? {
        guard pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        if let id = app?.bundleIdentifier { return HostBundle(id: id, bundleless: false) }
        var url = app?.executableURL ?? executableURL(ofPID: pid)
        while let current = url, current.path != "/" {
            if current.pathExtension == "app", let id = Bundle(url: current)?.bundleIdentifier {
                logOnce("enumerate: bundle-less host → \(id) (\(app?.executableURL?.lastPathComponent ?? "?"))", pid: pid)
                return HostBundle(id: id, bundleless: true)
            }
            url = current.deletingLastPathComponent()
        }
        return nil
    }

    private func executableURL(ofPID pid: pid_t) -> URL? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        // proc_pidpath returns the byte count it wrote, excluding the
        // terminator — decode exactly that rather than the whole buffer.
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer[..<Int(written)], as: UTF8.self))
    }

    /// Each distinct drop is logged once per process lifetime: the walk runs
    /// on every converge and the same unrecognized group would flood the log.
    private var loggedDrops: Set<String> = []

    private func logDrop(_ reason: String, pid: pid_t?, role: String?) {
        var line = "enumerate: skipped — \(reason)"
        if let role { line += " role=\(role)" }
        logOnce(line, pid: pid)
    }

    private func logOnce(_ message: String, pid: pid_t?) {
        var line = message
        if let pid, pid > 0 {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? executableURL(ofPID: pid)?.lastPathComponent ?? "?"
            line += " pid=\(pid) (\(name))"
        }
        guard loggedDrops.insert(line).inserted else { return }
        PelmetLog.log(line)
    }

    /// Best-effort title of the app's status item button (used in the agent
    /// tag). An app node exposes both its MAIN menu bar (wide: Apple, File,
    /// Edit…) and its status-extras bar (narrow) — pick the narrowest bar so
    /// we never read "Apple" off the main menu. Falls back to Item-0.
    private func statusItemTitle(in appNode: AXUIElement) -> String? {
        let menuBars = children(of: appNode).filter { role(of: $0) == "AXMenuBar" }
        let extrasBar = menuBars.min { lhs, rhs in
            (frame(of: lhs)?.width ?? .greatestFiniteMagnitude)
                < (frame(of: rhs)?.width ?? .greatestFiniteMagnitude)
        }
        guard let extrasBar, let width = frame(of: extrasBar)?.width, width < 500 else {
            return nil
        }
        for item in children(of: extrasBar) {
            if let title = copyAttribute(item, kAXTitleAttribute) as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func role(of element: AXUIElement) -> String {
        copyAttribute(element, kAXRoleAttribute) as? String ?? ""
    }

    /// `role(of:)` reports a missing role as "", so the `?? "?"` the log
    /// sites used was dead and they printed `role=` with nothing after it.
    private func roleLabel(_ element: AXUIElement) -> String {
        let role = role(of: element)
        return role.isEmpty ? "?" : role
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let value = copyAttribute(element, "AXFrame"),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }
}
