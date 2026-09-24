// Roster.swift
// Membership is the product (docs/CORE-SETS.md): which section every menubar
// item belongs to. Keyed by canonical `sectionKey`; absent means visible.
// Position never lives here — the bar's physical order is read, not stored.

import Foundation

public struct Roster: Codable, Equatable, Sendable {
    public var members: [ItemID: Section]

    public init(members: [ItemID: Section] = [:]) {
        self.members = members
    }

    /// Canonical key first; full-ID fallback keeps pre-migration blobs (and
    /// probe tooling) working until `SectionModel.canonicalize()` rewrites them.
    public func section(of item: ItemID) -> Section {
        members[item.sectionKey] ?? members[item] ?? .visible
    }

    /// Visible is the absence of an entry, so the roster never grows with
    /// items that need no hiding.
    public mutating func assign(_ key: ItemID, to section: Section) {
        if section == .visible {
            members.removeValue(forKey: key)
        } else {
            members[key] = section
        }
    }

    /// Bundles pinned on screen for the given reveal state: any observed item
    /// in `.visible` or a revealed section pins its whole bundle (hiding is
    /// per-bundle).
    public func mustShowBundles(
        observedItems: [ItemID],
        revealing revealed: Set<Section>
    ) -> Set<String> {
        var mustShow = Set<String>()
        for item in observedItems {
            guard let bundle = item.bundleID else { continue }
            let section = self.section(of: item)
            if section == .visible || revealed.contains(section) {
                mustShow.insert(bundle)
            }
        }
        return mustShow
    }

    /// Bundle-granularity conflict check against the currently observed items:
    /// a bundle can only be concealed if none of its items must remain visible.
    public func concealableBundleIDs(
        observedItems: [ItemID],
        revealing revealed: Set<Section>
    ) -> Set<String> {
        let mustShow = mustShowBundles(observedItems: observedItems, revealing: revealed)
        var wantHide = Set<String>()
        for item in observedItems {
            guard let bundle = item.bundleID else { continue }
            let section = self.section(of: item)
            if section != .visible, !revealed.contains(section) {
                wantHide.insert(bundle)
            }
        }
        return wantHide.subtracting(mustShow)
    }
}

/// Default membership for items Pelmet hasn't met. Classification (what is an
/// Apple host, what lives in CoreServices) stays in `MenuBarPolicy`; this is
/// the membership half.
public enum RosterRule {
    /// Where an item of a never-seen bundle lands, or nil when it gets no
    /// section at all: system hosts are unmanaged, and a visible destination
    /// is the absence of an entry.
    public static func landing(for item: ItemID, newItemsDestination: Section) -> Section? {
        guard MenuBarPolicy.isSectionManageable(item), newItemsDestination != .visible else { return nil }
        return newItemsDestination
    }
}
