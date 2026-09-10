// ItemIDGrammar.swift
// The one home for the tag grammar (`status:<bundle>::<title>`, `module:<Name>`,
// `bundle:<id>`). Tags are minted by the enumerator, persisted in the agent
// plist, and parsed by the model — before this file each site rebuilt the
// grammar with its own string hacking.

import Foundation

public extension ItemID {
    enum Parsed: Equatable, Sendable {
        case status(bundle: String, title: String)
        case module(String)
        case bundleKey(String)
        case opaque(String)
    }

    /// Structured view of the tag. `bundleID`/`isSystemModule`/`sectionKey`
    /// stay direct string accessors (hot paths); tests assert they agree with
    /// this parser over a shared corpus.
    var parsed: Parsed {
        if rawValue.hasPrefix("module:") {
            return .module(String(rawValue.dropFirst("module:".count)))
        }
        if rawValue.hasPrefix("bundle:") {
            return .bundleKey(String(rawValue.dropFirst("bundle:".count)))
        }
        if rawValue.hasPrefix("status:") {
            let stripped = rawValue.dropFirst("status:".count)
            if let separator = stripped.range(of: "::") {
                return .status(
                    bundle: String(stripped[..<separator.lowerBound]),
                    title: String(stripped[separator.upperBound...])
                )
            }
        }
        return .opaque(rawValue)
    }

    static func status(bundle: String, title: String) -> ItemID {
        ItemID(rawValue: "status:\(bundle)::\(title)")
    }

    static func module(_ name: String) -> ItemID {
        ItemID(rawValue: "module:\(name)")
    }

    static func bundleKey(_ bundle: String) -> ItemID {
        ItemID(rawValue: "bundle:\(bundle)")
    }

    /// Prefix matching every title variant of a bundle's status tags — the
    /// agent re-mints titles, so "same bundle, any title" is a real query.
    static func statusTagPrefix(bundle: String) -> String {
        "status:\(bundle)::"
    }
}

// MARK: - Pelmet's own items

public extension ItemID {
    /// Which Pelmet-owned item a tag names, if any. The titles are minted by
    /// `ExtraItemSpec.itemTitle`, `SeparatorSpec.itemTitle` and the chevron's
    /// own status item — this reads them back. Before it, six call sites
    /// hand-matched substrings, and `contains("Separator")` would have
    /// claimed any third-party item whose AX title happened to say so.
    enum PelmetItem: Equatable, Sendable {
        case chevron
        case separator
        case mediaControls
        case cameraMic
        case airdrop
        case shortcut
        case appLauncher
        /// A Pelmet-minted title this build does not name. Still one of ours
        /// (so still a section-managed extra) — the classifier must not
        /// narrow `isPelmetExtraID` to a whitelist that a future or older
        /// title falls out of.
        case other(String)
    }

    /// Non-nil only for items Pelmet itself registers.
    var pelmetItem: PelmetItem? {
        guard case .status(_, let title) = parsed, title.hasPrefix("Pelmet.")
        else { return nil }
        switch title {
        case "Pelmet.StatusItem": return .chevron
        case "Pelmet.MediaControls": return .mediaControls
        case "Pelmet.CameraMic": return .cameraMic
        case "Pelmet.AirDrop": return .airdrop
        default: break
        }
        if title.hasPrefix("Pelmet.Separator.") { return .separator }
        if title.hasPrefix("Pelmet.Shortcut.") { return .shortcut }
        if title.hasPrefix("Pelmet.App.") { return .appLauncher }
        return .other(title)
    }

    /// Pelmet's chevron — the boundary every zone reading measures against.
    var isPelmetChevron: Bool { pelmetItem == .chevron }

    /// A user-added separator. Section-managed like an extra, but never a
    /// placement target when it has no frame (see PlacementController).
    var isPelmetSeparator: Bool { pelmetItem == .separator }

    /// One of Pelmet's app launchers.
    var isPelmetAppLauncher: Bool { pelmetItem == .appLauncher }
}
