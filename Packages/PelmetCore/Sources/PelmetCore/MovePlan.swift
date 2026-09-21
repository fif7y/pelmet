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
    /// Where each icon lived before the editor moved it between sections,
    /// so Discard can put it back. An entry leaves when the icon is drawn
    /// back where it was, when the user moves it by hand in the bar, and
    /// with every other edit at Apply.
    public var previousSection: [ItemID: Section]

    public init(order: [Section: [ItemID]] = [:], previousSection: [ItemID: Section] = [:]) {
        self.order = order
        self.previousSection = previousSection
    }

    public var isEmpty: Bool { order.isEmpty && previousSection.isEmpty }

    private enum CodingKeys: String, CodingKey { case order, previousSection }

    /// `previousSection` arrived after `order` shipped on the branch: an
    /// edit set saved without it still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([Section: [ItemID]].self, forKey: .order) ?? [:]
        previousSection = try c.decodeIfPresent([ItemID: Section].self, forKey: .previousSection) ?? [:]
    }
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
    /// refuses to move. The plan is always the whole bar as one run:
    /// always-hidden, hidden, chevron, visible — edited sections in their
    /// drawn order, the others as they sit. So an icon on the wrong side of
    /// the chevron is a move even with no edit (folded in from the Tidy
    /// checkbox, Gab 2026-09-20: Apply means "make the bar match the editor").
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

        // Desired sequence: concealable sections left of the chevron in
        // editor order (drawn or current), visible right of it.
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
        var run = desired(.alwaysHidden) + desired(.hidden)
        if let chevron, live.contains(chevron) { run.append(chevron) }
        run += desired(.visible)
        let runs = [run]

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
            // Bounds must already be where the run says when the drag
            // happens: a kept item, or a mover placed earlier in this list
            // (the list runs left to right). Aiming between two run
            // neighbours that were both still out of place put Snib left of
            // a Siri that had not moved yet — verify false, no retry
            // (2026-09-20 18:42, three passes to settle two moves).
            var placed = staying
            for (i, id) in run.enumerated() where !staying.contains(id) && anchor(id) == nil {
                let after = run[..<i].last(where: placed.contains)
                let before = run[(i + 1)...].first(where: staying.contains)
                moves.append(Move(item: id, after: after, before: before))
                placed.insert(id)
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
