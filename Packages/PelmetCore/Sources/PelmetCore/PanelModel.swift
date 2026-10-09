// PanelModel.swift
// What the panel shows, as data (docs/PANEL-PLAN.md §2). Membership comes from
// the Roster; the bar's order is read, never stored (docs/CORE-SETS.md), so the
// order here is whatever the last walk that drew a section saw. The view lays
// the tiles out with `PanelGrid` and draws them; nothing in here knows a pixel.

import Foundation

/// One cell of the panel. A new kind of tile is a new case.
public enum PanelTile: Hashable, Sendable {
    /// A menu bar item, by `sectionKey`.
    case item(ItemID)
    /// An app that is in a section but not running, so it has no icon in the
    /// bar: the bundle ID. A click opens the app.
    case launcher(String)
    /// A separator that starts a new row. Not drawn, only a break.
    case rowBreak

    /// The id the search ranker knows this tile by: the command bar's
    /// candidates use the same strings. Nil for a break.
    public var searchID: String? {
        switch self {
        case .item(let key): key.rawValue
        case .launcher(let bundle): "launcher:\(bundle)"
        case .rowBreak: nil
        }
    }
}

public struct PanelSection: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Visible icons macOS had no room for.
        case didntFit
        case hidden
        case alwaysHidden
    }

    public let kind: Kind
    public var tiles: [PanelTile]
    /// Always Hidden only: closed behind its fold row. The tiles stay here so
    /// the row can say how many are behind it.
    public var isFolded: Bool

    public init(kind: Kind, tiles: [PanelTile], isFolded: Bool) {
        self.kind = kind
        self.tiles = tiles
        self.isFolded = isFolded
    }

    /// Tiles you can click; breaks are not counted.
    public var count: Int { tiles.filter { $0 != .rowBreak }.count }
}

public struct PanelModel: Equatable, Sendable {
    /// In the order the panel stacks them, top down. A section with nothing
    /// to show is left out, except Hidden at rest: the panel says so when
    /// nothing is hidden.
    public var sections: [PanelSection]
    /// While filtering, the tile Return would open: the best match across
    /// every section.
    public var bestMatch: PanelTile?

    public func section(_ kind: PanelSection.Kind) -> PanelSection? {
        sections.first { $0.kind == kind }
    }

    public var isEmpty: Bool { sections.allSatisfy { $0.count == 0 } }

    /// - Parameters:
    ///   - roster: where every item lives.
    ///   - items: every item the last walk saw, in the order it saw them.
    ///     Concealed items are in it (they have IDs, no frames); an app that
    ///     quit since is not, so a stale roster entry draws no tile.
    ///   - drawnOrder: per section, the left-to-right order read the last time
    ///     that section was on the bar. Items it doesn't name follow in the
    ///     order of `items`.
    ///   - didntFit: the icons the « notice lists. Not `ApplyPass.trapped`,
    ///     which can disagree by one (S4). Each shows once, here, not also in
    ///     its own section.
    ///   - launchers: bundle IDs of apps in a section that aren't running.
    ///   - alwaysHiddenRequested: the opener asked for Always Hidden (⌥-click,
    ///     double-click, its shortcut): open even when the setting hides it.
    ///   - query: the filter. Rows are the command bar's candidates, matched
    ///     by `PanelTile.searchID`, so aliases and synonyms work here too.
    public static func build(
        roster: Roster,
        items: [ItemID],
        drawnOrder: [Section: [ItemID]] = [:],
        didntFit: [ItemID] = [],
        launchers: [String] = [],
        options: PanelOptions = PanelOptions(),
        alwaysHiddenRequested: Bool = false,
        query: String = "",
        candidates: [SearchCandidate] = [],
        history: SearchHistory = SearchHistory(),
        now: Date = Date()
    ) -> PanelModel {
        let filtering = !FoldedText(query).isEmpty

        let overflowing = unique(didntFit.map(\.sectionKey).filter { isTile($0) && !$0.isPelmetSeparator })
        let overflowSet = Set(overflowing)
        let seen = unique(items.map(\.sectionKey).filter(isTile)).filter { !overflowSet.contains($0) }

        func tiles(in section: Section) -> [PanelTile] {
            let members = seen.filter { roster.section(of: $0) == section }
            // Drawn order first: it is where the icons really sit. Whatever
            // it doesn't name (never drawn since boot) follows in walk order.
            let drawn = unique((drawnOrder[section] ?? []).map(\.sectionKey)).filter(Set(members).contains)
            let named = Set(drawn)
            var out = (drawn + members.filter { !named.contains($0) }).map(PanelTile.item)
            let bundles = Set(members.compactMap(\.bundleID))
            for bundle in unique(launchers)
            where roster.section(of: .bundleKey(bundle)) == section && !bundles.contains(bundle) {
                out.append(.launcher(bundle))
            }
            return out
        }

        // Separators are kept as breaks only for a panel that wants them and
        // an unfiltered grid. Leading, trailing and doubled ones go, as the
        // bar wouldn't draw them either.
        func shaped(_ tiles: [PanelTile]) -> [PanelTile] {
            var out: [PanelTile] = []
            for tile in tiles {
                if case .item(let key) = tile, key.isPelmetSeparator {
                    if options.separatorsBreakRows, !filtering, let last = out.last, last != .rowBreak {
                        out.append(.rowBreak)
                    }
                } else {
                    out.append(tile)
                }
            }
            while out.last == .rowBreak { out.removeLast() }
            return out
        }

        let hidden = shaped(tiles(in: .hidden))
        let always = shaped(tiles(in: .alwaysHidden))
        let over = overflowing.map(PanelTile.item)

        var ranked: [PanelTile: Int] = [:]
        if filtering {
            let wanted = Set((hidden + always + over).compactMap(\.searchID))
            let matches = SearchRanker.rank(
                query: query,
                candidates: candidates.filter { wanted.contains($0.id) },
                history: history, now: now, limit: wanted.count
            )
            let byID = Dictionary(
                (hidden + always + over).compactMap { tile in tile.searchID.map { ($0, tile) } },
                uniquingKeysWith: { first, _ in first })
            for (rank, match) in matches.enumerated() {
                if let tile = byID[match.candidate.id] { ranked[tile] = rank }
            }
        }
        // Rank order, best first, so the first tile of a section is the one
        // Return opens when that section holds the best match.
        func filtered(_ tiles: [PanelTile]) -> [PanelTile] {
            filtering ? tiles.filter { ranked[$0] != nil }.sorted { ranked[$0, default: .max] < ranked[$1, default: .max] } : tiles
        }

        var sections: [PanelSection] = []
        let overTiles = filtered(over)
        if !overTiles.isEmpty {
            sections.append(PanelSection(kind: .didntFit, tiles: overTiles, isFolded: false))
        }
        let hiddenTiles = filtered(hidden)
        if !hiddenTiles.isEmpty || !filtering {
            sections.append(PanelSection(kind: .hidden, tiles: hiddenTiles, isFolded: false))
        }
        let alwaysTiles = filtered(always)
        if !alwaysTiles.isEmpty {
            // A search covers both sections whatever the setting says, and
            // the opener's ask beats it too; only the fold row stays shut.
            let folded: Bool?
            if filtering || alwaysHiddenRequested {
                folded = false
            } else {
                switch options.alwaysHidden {
                case .folded: folded = true
                case .asLeft: folded = !options.alwaysHiddenOpen
                case .hidden: folded = nil
                }
            }
            if let folded {
                sections.append(PanelSection(kind: .alwaysHidden, tiles: alwaysTiles, isFolded: folded))
            }
        }

        let best = ranked.min { $0.value < $1.value }?.key
        return PanelModel(sections: sections, bestMatch: best)
    }

    // MARK: - Helpers

    /// Items that get a tile: not the chevron, which is Pelmet's own anchor.
    private static func isTile(_ key: ItemID) -> Bool {
        !key.isPelmetChevron
    }

    private static func unique<T: Hashable>(_ list: [T]) -> [T] {
        var seen = Set<T>()
        return list.filter { seen.insert($0).inserted }
    }
}
