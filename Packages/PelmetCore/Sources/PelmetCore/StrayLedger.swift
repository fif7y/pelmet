// StrayLedger.swift
// Which strays "keep sections grouped" (docs/CORE-SETS.md, #80) may move.
// Pelmet only moves a stray it can explain: the bar's physical order is the
// truth, and an icon the user put on a side by hand (a ⌘-drag BarAdoption
// could not read, a drop from another display, a drag during a pass) must
// stay where it is. The ledger remembers, per item, the last physical side
// of the chevron, the last roster section and the process behind it, and
// from the change between two looks decides:
//
//   actionable  a stray that is newly seen, relaunched (new pid), or whose
//               section changed while its side did not (an editor drop:
//               membership moved, nothing else did). Lasts while it stays
//               a stray; an icon that is in place is settled.
//   byHand      its side flipped without being one of Pelmet's own planned
//               moves. Exempt until its section changes again.
//   settled     everything else (nothing to explain, nothing to do).
//
// Pure: the caller supplies sightings and its own moves.

import Foundation

public struct StrayLedger: Equatable, Sendable {
    public enum Side: Equatable, Sendable { case left, right }

    public struct Sighting: Equatable, Sendable {
        public let id: ItemID
        /// Side of the chevron on the primary bar; nil when the item has no
        /// place there right now (another display, parked, never framed).
        public let side: Side?
        public let section: Section
        public let pid: Int32?

        public init(id: ItemID, side: Side?, section: Section, pid: Int32? = nil) {
            self.id = id
            self.side = side
            self.section = section
            self.pid = pid
        }
    }

    public enum Standing: Equatable, Sendable { case actionable, settled, byHand }

    private struct Record: Equatable, Sendable {
        var side: Side?
        var section: Section
        var pid: Int32?
        var standing: Standing
    }

    private var records: [ItemID: Record] = [:]

    public init() {}

    /// Left or right of `chevron` in an observed bar order (nil when either
    /// is not on it).
    public static func side(of id: ItemID, in bar: [ItemID], chevron: ItemID?) -> Side? {
        guard let chevron, let split = bar.firstIndex(of: chevron),
              let index = bar.firstIndex(of: id), index != split else { return nil }
        return index < split ? .left : .right
    }

    public func standing(of id: ItemID) -> Standing? { records[id]?.standing }

    /// The strays Pelmet may move.
    public func actionable(_ strays: [ItemID]) -> [ItemID] {
        strays.filter { records[$0]?.standing == .actionable }
    }

    /// Takes one look at the bar: every item in the snapshot, concealed or
    /// not. Items missing from it are forgotten (back later = newly seen).
    /// `strays` are the items whose side disagrees with their section right
    /// now. `ownMoves` are the items a pass of ours just tried to move: their
    /// side flips are ours. Returns the items that flipped by hand this look.
    @discardableResult
    public mutating func observe(
        _ sightings: [Sighting], strays: Set<ItemID> = [], ownMoves: Set<ItemID> = []
    ) -> [ItemID] {
        var next: [ItemID: Record] = [:]
        var byHand: [ItemID] = []
        for s in sightings {
            guard let prev = records[s.id] else {
                next[s.id] = Record(side: s.side, section: s.section, pid: s.pid, standing: strays.contains(s.id) ? .actionable : .settled)
                continue
            }
            var standing = prev.standing
            let relaunched = prev.pid != nil && s.pid != nil && prev.pid != s.pid
            let sectionChanged = prev.section != s.section
            let sideChanged = prev.side != s.side
            if relaunched {
                standing = .actionable
            } else if sectionChanged {
                standing = sideChanged ? .settled : .actionable
            } else if sideChanged, prev.side != nil, s.side != nil {
                if ownMoves.contains(s.id) {
                    standing = .settled
                } else {
                    standing = .byHand
                    byHand.append(s.id)
                }
            }
            // An explanation is only good while the icon is out of place: one
            // in place is settled, so a later arrival from another display
            // (a drop BarAdoption could not read) is not mistaken for one.
            if standing == .actionable, !strays.contains(s.id) { standing = .settled }
            next[s.id] = Record(side: s.side, section: s.section, pid: s.pid ?? prev.pid, standing: standing)
        }
        records = next
        return byHand
    }
}
