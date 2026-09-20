// MovePlan.swift
// M1 of the sets core (docs/CORE-SETS.md): the editor records order changes
// as `OrderEdits`; `MovePlan` turns the bar's observed order plus those
// edits into the fewest moves that realise them. Pure: no AX, no timing.
// The app's ApplyPass performs each `Move` as one real ⌘-drag and verifies.

import Foundation

/// Pending order changes from the editor. Cleared by Apply or Discard,
/// persisted so a quit doesn't lose them.
public struct OrderEdits: Codable, Equatable, Sendable {
    /// Per section, the left-to-right order the user drew (canonical keys).
    /// Sections absent here have no pending change.
    public var order: [Section: [ItemID]]
    /// Group the bar as well: hidden and always-hidden left of the chevron
    /// in their editor order, visible right of it.
    public var tidy: Bool

    public init(order: [Section: [ItemID]] = [:], tidy: Bool = false) {
        self.order = order
        self.tidy = tidy
    }

    public var isEmpty: Bool { order.isEmpty && !tidy }
}

/// One item to one slot: land it right of `after` (nil = left end of the
/// run) and left of `before` (nil = right end). Both neighbours are live
/// bar items the executor measures at drag time.
public struct Move: Equatable, Sendable {
    public let item: ItemID
    public let after: ItemID?
    public let before: ItemID?
}

public enum MovePlan {
    public enum Skip: Equatable, Sendable {
        /// No frame in the walk: concealed, or behind the native «.
        case notOnScreen
        /// macOS keeps this one where it is; the editor says so too.
        case pinned
        /// Pelmet's own items are placed by registration, never dragged.
        case ownItem
    }

    public struct Plan: Equatable, Sendable {
        public var moves: [Move]
        public var skipped: [(ItemID, Skip)]
        public static func == (a: Plan, b: Plan) -> Bool {
            a.moves == b.moves && a.skipped.map(\.0) == b.skipped.map(\.0) && a.skipped.map(\.1) == b.skipped.map(\.1)
        }
    }

    /// `bar` is the observed primary-band order, left to right, canonical
    /// keys, only items with a frame. `pinned` are the hosts the agent
    /// refuses to move. Within-section edits order an item only relative to
    /// its section-mates; `tidy` orders the whole bar around the chevron.
    public static func compute(
        bar: [ItemID],
        edits: OrderEdits,
        roster: Roster,
        chevron: ItemID?,
        pinned: Set<ItemID> = [],
        ownItems: Set<ItemID> = []
    ) -> Plan {
        var skipped: [(ItemID, Skip)] = []
        let live = Set(bar)
        // Anchors: never dragged. They stay in every run as fixed members
        // (a heavy weight below keeps them in the kept subsequence), so the
        // others order around them and across them. Reported only where the
        // editor drew them.
        func anchor(_ id: ItemID) -> Skip? {
            if pinned.contains(id) { return .pinned }
            if ownItems.contains(id) || id == chevron { return .ownItem }
            return nil
        }
        for (_, order) in edits.order {
            for id in order {
                if !live.contains(id) { skipped.append((id, .notOnScreen)) }
                else if let why = anchor(id) { skipped.append((id, why)) }
            }
        }

        // Desired sequence per run. Without tidy, each edited section is its
        // own run over its live members; other sections are untouched. With
        // tidy the whole bar is one run: concealable sections left of the
        // chevron in editor order (edited or current), visible right of it.
        func desired(_ section: Section) -> [ItemID] {
            let current = bar.filter { roster.section(of: $0) == section && $0 != chevron }
            guard let drawn = edits.order[section] else { return current }
            // A drawn entry that left the section (or was drawn twice)
            // must not survive into the run: it would sit in two runs.
            var seen = Set<ItemID>()
            let drawnLive = drawn.filter {
                live.contains($0) && roster.section(of: $0) == section && $0 != chevron && seen.insert($0).inserted
            }
            // Members the editor didn't list keep their relative bar order, after the drawn ones.
            return drawnLive + current.filter { !drawnLive.contains($0) }
        }
        var runs: [[ItemID]] = []
        if edits.tidy {
            var run = desired(.alwaysHidden) + desired(.hidden)
            if let chevron, live.contains(chevron) { run.append(chevron) }
            run += desired(.visible)
            runs = [run]
        } else {
            runs = edits.order.keys.sorted { $0.rawValue < $1.rawValue }.map(desired)
        }

        var moves: [Move] = []
        for run in runs {
            // The current bar order restricted to this run's members.
            let current = bar.filter(run.contains)
            let index = Dictionary(run.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            // Heaviest subsequence already in desired order stays; anchors
            // outweigh everything else so they are always part of it.
            let keep = heaviestIncreasing(
                current.map { index[$0]! },
                weights: current.map { anchor($0) == nil ? 1 : run.count + 1 }
            )
            let staying = Set(keep.map { current[$0] })
            for (i, id) in run.enumerated() where !staying.contains(id) && anchor(id) == nil {
                moves.append(Move(item: id, after: i > 0 ? run[i - 1] : nil, before: i + 1 < run.count ? run[i + 1] : nil))
            }
        }
        return Plan(moves: moves, skipped: skipped)
    }

    /// Indices of the heaviest strictly increasing subsequence (weights all
    /// 1 = the longest one).
    static func heaviestIncreasing(_ values: [Int], weights: [Int]? = nil) -> [Int] {
        guard !values.isEmpty else { return [] }
        let weights = weights ?? Array(repeating: 1, count: values.count)
        var length = weights
        var previous = Array(repeating: -1, count: values.count)
        for i in values.indices {
            for j in 0..<i where values[j] < values[i] && length[j] + weights[i] > length[i] {
                length[i] = length[j] + weights[i]
                previous[i] = j
            }
        }
        var end = length.indices.max { length[$0] < length[$1] }!
        var result: [Int] = []
        while end >= 0 { result.append(end); end = previous[end] }
        return result.reversed()
    }
}
