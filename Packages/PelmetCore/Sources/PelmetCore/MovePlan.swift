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
    /// Each edited section's order before its first edit, so Discard puts
    /// every icon back at the slot it had: reading the bar can't do that
    /// for a concealed section, and never knew the old index anyway.
    public var previousOrder: [Section: [ItemID]]
    /// Own items (separators) created by this edit set: drawn, not yet in
    /// the bar's order. Apply places them; Discard removes them again.
    public var created: Set<ItemID>

    public init(
        order: [Section: [ItemID]] = [:],
        previousSection: [ItemID: Section] = [:],
        previousOrder: [Section: [ItemID]] = [:],
        created: Set<ItemID> = []
    ) {
        self.order = order
        self.previousSection = previousSection
        self.previousOrder = previousOrder
        self.created = created
    }

    public var isEmpty: Bool { order.isEmpty && previousSection.isEmpty }

    private enum CodingKeys: String, CodingKey { case order, previousSection, previousOrder, created }

    /// `previousSection` arrived after `order` shipped on the branch: an
    /// edit set saved without it still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([Section: [ItemID]].self, forKey: .order) ?? [:]
        previousSection = try c.decodeIfPresent([ItemID: Section].self, forKey: .previousSection) ?? [:]
        previousOrder = try c.decodeIfPresent([Section: [ItemID]].self, forKey: .previousOrder) ?? [:]
        created = try c.decodeIfPresent(Set<ItemID>.self, forKey: .created) ?? []
    }

    /// The edit for `section` is done with (applied, or the bar matches):
    /// its drawing and its baseline go together.
    public mutating func clearOrder(for section: Section) {
        // A created item drawn in this section is placed now: no longer
        // Discard's to remove.
        if let drawn = order[section] { created.subtract(drawn) }
        order.removeValue(forKey: section)
        previousOrder.removeValue(forKey: section)
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

    /// Where a grouping-pass stray lands (`strayPlan`).
    public enum Placement: Equatable, Sendable {
        /// The slot the editor drew for it.
        case drawn
        /// Nothing drawn for it (a fresh registration, a relaunch, boot): the
        /// chevron end of its section.
        case chevronEdge
        /// Drawn, but no drawn neighbour is on screen and movable: the
        /// chevron end of its section instead.
        case drawnUnavailable
    }

    public struct Plan: Equatable, Sendable {
        public var moves: [Move]
        public var skipped: [(ItemID, Skip)]
        /// Strays only: how each move was placed.
        public var placements: [ItemID: Placement] = [:]
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
                if let why = anchor(id) { skipped.append((id, why)) }
                else if !live.contains(id) { skipped.append((id, .notOnScreen)) }
            }
        }
        // A pinned item right of the chevron that the editor put in a
        // concealable section (the clock, Control Center: macOS's end of the
        // bar, hidden through the allowlist) is neither a mover nor a
        // bound. Kept as an anchor it sat right of every visible icon and
        // the run asked Media to land right of the clock — "1 not moved"
        // on every pass (2026-09-22).
        let chevronIndex = chevron.flatMap { bar.firstIndex(of: $0) }
        let bar = bar.enumerated().filter { i, id in
            !(pinned.contains(id) && roster.section(of: id) != .visible && chevronIndex.map { i > $0 } == true)
        }.map(\.element)

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
        // The pinned run at the bar's right end (Control Center, the clock)
        // takes no icon right of it. The editor inserted One Thing before an
        // own item the order kept after the clock, and Apply aimed the drag
        // past the clock: "1 not moved" on every pass (2026-09-25).
        let trailingPinned = Set(bar.reversed().prefix { pinned.contains($0) })
        let visible = desired(.visible)
        run += visible.filter { !trailingPinned.contains($0) } + visible.filter(trailingPinned.contains)
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

    /// Icons whose physical side of the chevron disagrees with their
    /// section: a Hidden / Always Hidden icon right of it, a Visible one left
    /// of it. Collapsed they look fine (membership hides them), on reveal
    /// they reappear on the wrong side and the visible icons shift (#80).
    /// `bar` is the observed primary-band order, left to right. No chevron
    /// on the bar means no boundary to disagree with. `pinned` hosts cannot
    /// be moved and `exempt` items are not this policy's to move (Pelmet's
    /// own), so neither is ever a stray.
    public static func strays(
        bar: [ItemID],
        roster: Roster,
        chevron: ItemID?,
        pinned: Set<ItemID> = [],
        exempt: Set<ItemID> = []
    ) -> [ItemID] {
        guard let chevron, let split = bar.firstIndex(of: chevron) else { return [] }
        return bar.enumerated().compactMap { i, id in
            guard i != split, !pinned.contains(id), !exempt.contains(id) else { return nil }
            let concealable = roster.section(of: id) != .visible
            return (i < split) == concealable ? nil : id
        }
    }

    /// The "keep sections grouped" plan (docs/CORE-SETS.md, #80): move the
    /// strays across the chevron and nothing else. Every other icon is an
    /// anchor, so the run never re-sorts a section, and the pending drawing
    /// is read for the strays alone.
    ///
    /// A stray the editor drew (a drop between sections) lands in the exact
    /// slot it was dropped in: before its nearest drawn successor that is on
    /// the bar and stays (not itself a stray, not pinned, not behind the «),
    /// else after its nearest such predecessor, so Apply has nothing left to
    /// do for it. With no such neighbour it takes the chevron end of its
    /// section like a stray that was never drawn (a fresh registration, a
    /// relaunch: Always Hidden before Hidden, as the whole-bar run orders
    /// them); `placements` says which. Two strays drawn into one gap chain in
    /// their drawn order.
    ///
    /// Discard after an auto relocation puts the membership back and the icon
    /// then strays again and crosses to the chevron end, not to the slot it
    /// first sat in (left as is, #80).
    public static func strayPlan(
        bar: [ItemID],
        roster: Roster,
        chevron: ItemID?,
        pinned: Set<ItemID> = [],
        exempt: Set<ItemID> = [],
        edits: OrderEdits = OrderEdits()
    ) -> Plan {
        let movable = Set(strays(bar: bar, roster: roster, chevron: chevron, pinned: pinned, exempt: exempt))
        guard !movable.isEmpty else { return Plan(moves: [], skipped: []) }
        // Wrong-side icons the policy leaves alone are still no neighbour to
        // land beside: their spot is the one thing that is not settled.
        let misplaced = Set(strays(bar: bar, roster: roster, chevron: chevron, pinned: pinned))
        let live = Set(bar)

        struct Slot { let item: ItemID; let anchor: ItemID; let isBefore: Bool; let index: Int }
        var slots: [Slot] = []
        var drawnButUnplaceable: Set<ItemID> = []
        for stray in bar where movable.contains(stray) {
            let section = roster.section(of: stray)
            guard let drawn = edits.order[section], let at = drawn.firstIndex(of: stray) else { continue }
            func usable(_ id: ItemID) -> Bool {
                id != stray && id != chevron && live.contains(id) && !misplaced.contains(id)
                    && !pinned.contains(id) && roster.section(of: id) == section
            }
            if let next = drawn[(at + 1)...].first(where: usable) {
                slots.append(Slot(item: stray, anchor: next, isBefore: true, index: at))
            } else if let previous = drawn[..<at].last(where: usable) {
                slots.append(Slot(item: stray, anchor: previous, isBefore: false, index: at))
            } else {
                drawnButUnplaceable.insert(stray)
            }
        }

        // The rest take the chevron end; the drawn ones are planned apart,
        // so they are out of this run (they would only be its bounds).
        let placedApart = Set(slots.map(\.item))
        let rest = bar.filter { !placedApart.contains($0) }
        let anchors = pinned.union(rest.filter { !movable.contains($0) })
        var plan = compute(bar: rest, edits: OrderEdits(), roster: roster, chevron: chevron, pinned: anchors)
        plan.moves = plan.moves.filter { movable.contains($0.item) }
        plan.skipped = []
        for move in plan.moves {
            plan.placements[move.item] = drawnButUnplaceable.contains(move.item) ? .drawnUnavailable : .chevronEdge
        }

        // A mover leaves its spot, so a bound is the nearest neighbour that stays.
        func staying(from item: ItemID, step: Int) -> ItemID? {
            guard var i = bar.firstIndex(of: item) else { return nil }
            i += step
            while bar.indices.contains(i) {
                if !movable.contains(bar[i]) { return bar[i] }
                i += step
            }
            return nil
        }
        struct Gap: Hashable { let anchor: ItemID; let isBefore: Bool }
        var tail: [Gap: ItemID] = [:]
        for slot in slots.sorted(by: { $0.index < $1.index }) {
            let gap = Gap(anchor: slot.anchor, isBefore: slot.isBefore)
            let after: ItemID?, before: ItemID?
            if slot.isBefore {
                after = tail[gap] ?? staying(from: slot.anchor, step: -1)
                before = slot.anchor
            } else {
                after = tail[gap] ?? slot.anchor
                before = staying(from: slot.anchor, step: 1)
            }
            tail[gap] = slot.item
            plan.moves.append(Move(item: slot.item, after: after, before: before))
            plan.placements[slot.item] = .drawn
        }
        return plan
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
