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

    @Test func withinSectionOrderIgnoresOtherSectionsBetween() {
        // Interleaved bar: v1 sits inside the hidden run. Ordering Hidden
        // never plans a move for v1, and neighbours are section-mates.
        let plan = MovePlan.compute(
            bar: [b, v1, a, chevron, v2],
            edits: OrderEdits(order: [.hidden: [a, b]]),
            roster: roster, chevron: chevron
        )
        #expect(plan.moves.map(\.item) == [a] || plan.moves.map(\.item) == [b])
        #expect(plan.moves.allSatisfy { $0.item != v1 })
        #expect(plan.moves.first?.after == nil || plan.moves.first?.before == nil)
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

    @Test func tidyGroupsAroundTheChevronWithoutMovingIt() {
        // v1 parked in the hidden run, a and d parked right of the chevron.
        // Tidy is two runs around the chevron anchor: concealable [d, b, c, a]
        // (always-hidden first, then Hidden in bar order) and visible [v1, v2].
        let plan = MovePlan.compute(
            bar: [b, v1, c, chevron, a, v2, d],
            edits: OrderEdits(tidy: true),
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
            edits: OrderEdits(order: [.hidden: [b, a]], tidy: true),
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
        #expect(plan.moves.contains(Move(item: b, after: host, before: nil)))
        #expect(plan.skipped.contains { $0.0 == host && $0.1 == .pinned })
    }
}
