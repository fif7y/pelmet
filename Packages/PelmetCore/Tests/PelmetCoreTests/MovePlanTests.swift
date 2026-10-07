import Testing
@testable import PelmetCore

@Suite struct MovePlanTests {
    let chevron = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.StatusItem")
    let a = ItemID.bundleKey("com.a"), b = ItemID.bundleKey("com.b"), c = ItemID.bundleKey("com.c")
    let d = ItemID.bundleKey("com.d"), v1 = ItemID.bundleKey("com.v1"), v2 = ItemID.bundleKey("com.v2")

    var roster: Roster {
        Roster(members: [a: .hidden, b: .hidden, c: .hidden, d: .alwaysHidden])
    }

    @Test func alreadyInOrderPlansNothing() {
        let plan = MovePlan.compute(
            bar: [d, a, b, c, chevron, v1, v2],
            edits: OrderEdits(order: [.hidden: [a, b, c]]),
            roster: roster, chevron: chevron
        )
        #expect(plan.moves.isEmpty)
        #expect(plan.skipped.isEmpty)
    }

    @Test func oneItemOutOfPlaceIsOneMove() {
        // c drawn first: moving c alone beats moving a and b.
        let plan = MovePlan.compute(
            bar: [a, b, c, chevron, v1],
            edits: OrderEdits(order: [.hidden: [c, a, b]]),
            roster: roster, chevron: chevron
        )
        #expect(plan.moves == [Move(item: c, after: nil, before: a)])
    }

    @Test func reversalMovesAllButOne() {
        let plan = MovePlan.compute(
            bar: [a, b, c, chevron],
            edits: OrderEdits(order: [.hidden: [c, b, a]]),
            roster: roster, chevron: chevron
        )
        #expect(plan.moves.count == 2)
        #expect(plan.moves.map(\.item).contains(a) == false || plan.moves.map(\.item).contains(c) == false)
    }

    @Test func interleavedVisibleItemCrossesTheChevron() {
        // Interleaved bar: v1 sits inside the hidden run. The plan is the
        // whole bar, so v1 is a move to its side even with no edit for
        // Visible; the hidden edit orders a and b with section-mate bounds.
        let plan = MovePlan.compute(
            bar: [b, v1, a, chevron, v2],
            edits: OrderEdits(order: [.hidden: [a, b]]),
            roster: roster, chevron: chevron
        )
        #expect(plan.moves.contains(Move(item: v1, after: chevron, before: v2)))
        let hiddenMoves = plan.moves.filter { $0.item != v1 }
        #expect(hiddenMoves.map(\.item) == [a] || hiddenMoves.map(\.item) == [b])
        #expect(hiddenMoves.first?.after == nil || hiddenMoves.first?.before == chevron)
    }

    @Test func groupingAloneIsAMoveWithNoEdit() {
        // No drawing at all: an icon on the wrong side of the chevron still
        // counts (Apply lights up), a grouped bar plans nothing.
        let misplaced = MovePlan.compute(bar: [a, v1, b, chevron, v2], edits: OrderEdits(), roster: roster, chevron: chevron)
        #expect(misplaced.moves == [Move(item: v1, after: chevron, before: v2)])
        let grouped = MovePlan.compute(bar: [d, a, b, chevron, v1, v2], edits: OrderEdits(), roster: roster, chevron: chevron)
        #expect(grouped.moves.isEmpty)
    }

    @Test func unlistedMembersFollowTheDrawnOnes() {
        // Editor listed only b before a; c (unlisted) keeps its place after.
        let plan = MovePlan.compute(
            bar: [a, b, c, chevron],
            edits: OrderEdits(order: [.hidden: [b, a]]),
            roster: roster, chevron: chevron
        )
        #expect(plan.moves == [Move(item: b, after: nil, before: a)])
    }

    @Test func offScreenAndPinnedAndOwnAreSkippedNotPlanned() {
        let siri = ItemID.bundleKey("com.apple.systemuiserver")
        let sep = ItemID.status(bundle: "app.fif7y.Pelmet", title: "Pelmet.Separator.X")
        var members = roster.members
        members[siri] = .hidden; members[sep] = .hidden
        let plan = MovePlan.compute(
            bar: [siri, sep, b, a, chevron],          // c is behind « (no frame)
            edits: OrderEdits(order: [.hidden: [c, a, b, siri, sep]]),
            roster: Roster(members: members), chevron: chevron,
            pinned: [siri], ownItems: [sep]
        )
        #expect(plan.skipped.contains { $0.0 == c && $0.1 == .notOnScreen })
        #expect(plan.skipped.contains { $0.0 == siri && $0.1 == .pinned })
        #expect(plan.skipped.contains { $0.0 == sep && $0.1 == .ownItem })
        #expect(plan.moves.allSatisfy { ![c, siri, sep].contains($0.item) })
    }

    // The clock drawn into Hidden still ends the bar: the visible icons left
    // of it are in place, not "after the clock".
    @Test func endPinnedItemInHiddenIsNoBound() {
        let clock = ItemID.status(bundle: "com.apple.MenuBarAgent", title: "com.apple.menuextra.clock")
        var members = roster.members
        members[clock] = .hidden
        let plan = MovePlan.compute(
            bar: [c, chevron, v1, v2, clock],
            edits: OrderEdits(order: [.hidden: [c, clock]]),
            roster: Roster(members: members), chevron: chevron,
            pinned: [clock]
        )
        #expect(plan.moves.isEmpty)
        #expect(plan.skipped.contains { $0.0 == clock && $0.1 == .pinned })
    }

    @Test func tidyGroupsAroundTheChevronWithoutMovingIt() {
        // v1 parked in the hidden run, a and d parked right of the chevron.
        // Tidy is two runs around the chevron anchor: concealable [d, b, c, a]
        // (always-hidden first, then Hidden in bar order) and visible [v1, v2].
        let plan = MovePlan.compute(
            bar: [b, v1, c, chevron, a, v2, d],
            edits: OrderEdits(),
            roster: roster, chevron: chevron
        )
        let moved = Set(plan.moves.map(\.item))
        #expect(!moved.contains(chevron))
        // b, c, the chevron and v2 already read in order; d, a and v1 move
        // (v1 sits inside the hidden run and must cross the chevron).
        #expect(moved == [d, a, v1])
        #expect(plan.moves.contains(Move(item: v1, after: chevron, before: v2)))
        #expect(plan.moves.contains(Move(item: d, after: nil, before: b)))
        #expect(plan.moves.contains(Move(item: a, after: c, before: chevron)))
    }

    @Test func tidyUsesTheDrawnOrderForEditedSections() {
        let plan = MovePlan.compute(
            bar: [a, b, chevron, v1],
            edits: OrderEdits(order: [.hidden: [b, a]]),
            roster: roster, chevron: chevron
        )
        #expect(plan.moves == [Move(item: b, after: nil, before: a)] || plan.moves == [Move(item: a, after: b, before: chevron)])
    }

    @Test func heaviestIncreasingPicksTheLongestRunAndKeepsHeavyMembers() {
        #expect(MovePlan.heaviestIncreasing([2, 0, 1, 3]) == [1, 2, 3])
        #expect(MovePlan.heaviestIncreasing([0, 1, 2]) == [0, 1, 2])
        #expect(MovePlan.heaviestIncreasing([2, 1, 0]).count == 1)
        // A heavy member out of place wins over the longer light run around it.
        #expect(MovePlan.heaviestIncreasing([1, 2, 0], weights: [1, 1, 10]) == [2])
    }

    @Test func nothingIsAimedPastThePinnedEnd() {
        // Gab's bar, 2026-09-25: the order kept Camera after the clock, and a
        // drop before Camera drew One Thing there too. Both land left of CC.
        let cc = ItemID.status(bundle: "com.apple.MenuBarAgent", title: "com.apple.menuextra.controlcenter")
        let clock = ItemID.status(bundle: "com.apple.MenuBarAgent", title: "com.apple.menuextra.clock")
        var members = roster.members
        for id in [v1, v2, cc, clock] { members[id] = .visible }
        let plan = MovePlan.compute(
            bar: [c, chevron, v2, v1, cc, clock],
            edits: OrderEdits(order: [.visible: [v2, cc, clock, v1]]),
            roster: Roster(members: members), chevron: chevron,
            pinned: [cc, clock]
        )
        #expect(plan.moves.isEmpty)
        let drop = MovePlan.compute(
            bar: [c, chevron, a, v2, v1, cc, clock],
            edits: OrderEdits(order: [.visible: [v2, cc, clock, a, v1]]),
            roster: Roster(members: members.merging([a: .visible]) { $1 }), chevron: chevron,
            pinned: [cc, clock]
        )
        // One swap of a and v2 (either may move), never a slot past CC.
        #expect(drop.moves.count == 1)
        #expect(drop.moves.allSatisfy { $0.after != clock && $0.after != cc && $0.before != nil })
    }

    @Test func pinnedHostMidBarIsOrderedAround() {
        // Pinned host sits between b and a; editor wants a, host, b.
        // The host never moves: a and b each cross it.
        let host = ItemID.bundleKey("com.apple.systemuiserver")
        var members = roster.members; members[host] = .hidden
        let plan = MovePlan.compute(
            bar: [b, host, a, chevron],
            edits: OrderEdits(order: [.hidden: [a, host, b]]),
            roster: Roster(members: members), chevron: chevron, pinned: [host]
        )
        #expect(Set(plan.moves.map(\.item)) == [a, b])
        #expect(plan.moves.contains(Move(item: a, after: nil, before: host)))
        #expect(plan.moves.contains(Move(item: b, after: host, before: chevron)))
        #expect(plan.skipped.contains { $0.0 == host && $0.1 == .pinned })
    }

    @Test func staleEntryInAnotherSectionDoesNotDuplicateTheRun() {
        // c was drawn in hidden, then moved to visible: the hidden edit still
        // lists it. Tidy must plan one run without c twice (this trapped).
        var roster = roster
        roster.assign(c, to: .visible)
        let plan = MovePlan.compute(
            bar: [d, a, b, c, chevron, v1],
            edits: OrderEdits(order: [.hidden: [c, a, b], .visible: [c, v1]]),
            roster: roster, chevron: chevron
        )
        #expect(plan.moves == [Move(item: c, after: chevron, before: v1)])
    }

    @Test func boundsAreKeptItemsOrEarlierMovers() {
        // Bar: c, a, b, d? — desired a, b, c means c moves; but with two
        // movers each bound must already be in place when its drag runs.
        // bar [b, c, a], desired [a, b, c]: keep one of them (say b or c),
        // the movers' bounds are never a not-yet-moved item.
        let plan = MovePlan.compute(
            bar: [b, c, a, chevron],
            edits: OrderEdits(order: [.hidden: [a, b, c]]),
            roster: roster, chevron: chevron
        )
        let movers = plan.moves.map(\.item)
        var placed = Set([b, c, a, chevron]).subtracting(movers)
        for move in plan.moves {
            if let after = move.after { #expect(placed.contains(after)) }
            if let before = move.before { #expect(placed.contains(before) && !movers.contains(before)) }
            placed.insert(move.item)
        }
    }

    // MARK: - Keep sections grouped (#80)

    @Test func straysAreTheIconsOnTheWrongSide() {
        // a hidden right of the chevron, v1 visible left of it.
        let bar = [b, v1, chevron, a, v2]
        let strays = MovePlan.strays(bar: bar, roster: roster, chevron: chevron)
        #expect(strays == [v1, a])
    }

    @Test func aGroupedBarHasNoStraysAndNoChevronMeansNone() {
        #expect(MovePlan.strays(bar: [d, a, b, chevron, v1, v2], roster: roster, chevron: chevron).isEmpty)
        #expect(MovePlan.strays(bar: [v1, a, v2], roster: roster, chevron: nil).isEmpty)
        // A chevron that is not on the bar is no boundary either.
        #expect(MovePlan.strays(bar: [v1, a, v2], roster: roster, chevron: chevron).isEmpty)
    }

    @Test func pinnedAndExemptItemsAreNeverStrays() {
        let bar = [a, chevron, b, v1]
        #expect(MovePlan.strays(bar: bar, roster: roster, chevron: chevron, pinned: [b]).isEmpty)
        #expect(MovePlan.strays(bar: bar, roster: roster, chevron: chevron, exempt: [b]).isEmpty)
    }

    @Test func aHiddenStrayLandsAtTheChevronEndOfItsSection() {
        // Relaunched hidden icon came back right of the chevron.
        let plan = MovePlan.strayPlan(bar: [a, chevron, v1, b, v2], roster: roster, chevron: chevron)
        #expect(plan.moves == [Move(item: b, after: a, before: chevron)])
        #expect(plan.skipped.isEmpty)
    }

    @Test func anAlwaysHiddenStrayGoesBeforeTheHiddenRun() {
        let plan = MovePlan.strayPlan(bar: [a, b, chevron, v1, d], roster: roster, chevron: chevron)
        #expect(plan.moves == [Move(item: d, after: nil, before: a)])
    }

    @Test func aVisibleStrayLandsRightOfTheChevron() {
        let plan = MovePlan.strayPlan(bar: [a, v1, b, chevron, v2], roster: roster, chevron: chevron)
        #expect(plan.moves == [Move(item: v1, after: chevron, before: v2)])
    }

    @Test func theStrayPlanNeverReSortsASection() {
        // Hidden is a, b left of the chevron but Always Hidden d sits
        // between them (an order the whole-bar run would fix) and c strays:
        // only c moves.
        let plan = MovePlan.strayPlan(bar: [a, d, b, chevron, c, v1], roster: roster, chevron: chevron)
        #expect(plan.moves.map(\.item) == [c])
    }

    @Test func aGroupedBarPlansNothing() {
        let plan = MovePlan.strayPlan(bar: [d, a, b, chevron, v1, v2], roster: roster, chevron: chevron)
        #expect(plan.moves.isEmpty)
    }

    @Test func manyStraysAreEachAMoveAndOnlyStrays() {
        let plan = MovePlan.strayPlan(bar: [v1, a, chevron, b, c, v2], roster: roster, chevron: chevron)
        #expect(Set(plan.moves.map(\.item)) == [v1, b, c])
    }

    // MARK: - Keep sections grouped: drawn slots (#80)

    @Test func anEditorStrayLandsInTheSlotItWasDroppedIn() {
        // c dropped between a and b in the editor: Hidden is drawn [a, c, b].
        let plan = MovePlan.strayPlan(
            bar: [a, b, chevron, c, v1], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.hidden: [a, c, b]])
        )
        #expect(plan.moves == [Move(item: c, after: a, before: b)])
        #expect(plan.placements[c] == .drawn)
    }

    @Test func aStrayDrawnLastLandsAfterItsDrawnPredecessor() {
        let plan = MovePlan.strayPlan(
            bar: [a, b, chevron, c], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.hidden: [a, b, c]])
        )
        #expect(plan.moves == [Move(item: c, after: b, before: chevron)])
        #expect(plan.placements[c] == .drawn)
    }

    @Test func aVisibleStrayLandsInItsDrawnSlotNotAtTheChevron() {
        let v3 = ItemID.bundleKey("com.v3")
        let plan = MovePlan.strayPlan(
            bar: [a, v1, chevron, v2, v3], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.visible: [v2, v1, v3]])
        )
        #expect(plan.moves == [Move(item: v1, after: v2, before: v3)])
    }

    @Test func aMissingDrawnNeighbourFallsToTheNearestOneThatIsThere() {
        let ghost = ItemID.bundleKey("com.ghost")
        // Drawn [a, c, ghost, b]: ghost is not on the bar, b is.
        let plan = MovePlan.strayPlan(
            bar: [a, b, chevron, c], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.hidden: [a, c, ghost, b]])
        )
        #expect(plan.moves == [Move(item: c, after: a, before: b)])
        #expect(plan.placements[c] == .drawn)
    }

    @Test func aPinnedOrStrayNeighbourIsNoSlot() {
        // b is pinned and d belongs to another section: neither is a
        // neighbour for c, so it goes before a.
        let plan = MovePlan.strayPlan(
            bar: [a, b, chevron, c, d], roster: roster, chevron: chevron, pinned: [b],
            edits: OrderEdits(order: [.hidden: [c, b, d, a]])
        )
        #expect(plan.moves.first { $0.item == c } == Move(item: c, after: nil, before: a))
    }

    @Test func noUsableDrawnNeighbourFallsBackToTheChevronEnd() {
        let ghost = ItemID.bundleKey("com.ghost")
        let plan = MovePlan.strayPlan(
            bar: [a, b, chevron, c], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.hidden: [ghost, c]])
        )
        #expect(plan.moves == [Move(item: c, after: b, before: chevron)])
        #expect(plan.placements[c] == .drawnUnavailable)
    }

    @Test func aStrayWithNoEditKeepsTheChevronEnd() {
        // The drawing is about a and b only (a pending reorder): c, a fresh
        // registration, is not in it.
        let plan = MovePlan.strayPlan(
            bar: [a, b, chevron, c], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.hidden: [b, a]])
        )
        #expect(plan.moves == [Move(item: c, after: b, before: chevron)])
        #expect(plan.placements[c] == .chevronEdge)
    }

    @Test func pendingReordersOfOthersAreNeverPlanned() {
        // Hidden is drawn [b, a, c] with a and b in the wrong order on the
        // bar: only c moves.
        let plan = MovePlan.strayPlan(
            bar: [a, b, chevron, c], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.hidden: [b, a, c]])
        )
        #expect(plan.moves.map(\.item) == [c])
    }

    @Test func twoStraysDrawnIntoOneGapChainInDrawnOrder() {
        // c, then b, dropped one after the other, both right of the chevron.
        let plan = MovePlan.strayPlan(
            bar: [a, chevron, b, c], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.hidden: [a, c, b]])
        )
        #expect(plan.moves == [
            Move(item: c, after: a, before: chevron),
            Move(item: b, after: c, before: chevron),
        ])
    }

    @Test func aDrawnStrayDoesNotBoundTheOnesWithoutADrawing() {
        // c is drawn into the gap before a; b was never drawn and takes the
        // chevron end, bounded by items that stay, not by c.
        let plan = MovePlan.strayPlan(
            bar: [a, chevron, b, c], roster: roster, chevron: chevron,
            edits: OrderEdits(order: [.hidden: [c, a]])
        )
        #expect(plan.moves.contains(Move(item: c, after: nil, before: a)))
        #expect(plan.moves.contains(Move(item: b, after: a, before: chevron)))
        #expect(plan.placements[b] == .chevronEdge)
    }
}
