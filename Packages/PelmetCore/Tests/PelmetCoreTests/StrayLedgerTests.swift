import Testing
@testable import PelmetCore

@Suite struct StrayLedgerTests {
    let a = ItemID.bundleKey("com.a"), b = ItemID.bundleKey("com.b")
    let chevron = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.StatusItem")

    func look(_ id: ItemID, _ side: StrayLedger.Side?, _ section: Section, pid: Int32? = 100) -> StrayLedger.Sighting {
        .init(id: id, side: side, section: section, pid: pid)
    }

    @Test func sideOfReadsTheBarAroundTheChevron() {
        let bar = [a, chevron, b]
        #expect(StrayLedger.side(of: a, in: bar, chevron: chevron) == .left)
        #expect(StrayLedger.side(of: b, in: bar, chevron: chevron) == .right)
        #expect(StrayLedger.side(of: chevron, in: bar, chevron: chevron) == nil)
        #expect(StrayLedger.side(of: a, in: bar, chevron: nil) == nil)
    }

    @Test func aNewlySeenStrayIsActionable() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .right, .hidden)], strays: [a])
        #expect(ledger.actionable([a]) == [a])
    }

    @Test func anIconInPlaceIsSettled() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .left, .hidden)])
        #expect(ledger.standing(of: a) == .settled)
    }

    @Test func aRelaunchIsActionableAgain() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .left, .hidden, pid: 1)])
        ledger.observe([look(a, .left, .hidden, pid: 1)])
        // In place and settled until the app comes back as a new process.
        ledger.observe([look(a, .right, .hidden, pid: 2)], strays: [a])
        #expect(ledger.actionable([a]) == [a])
    }

    @Test func aDropAcrossSectionsIsActionableWhileTheSideStays() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .left, .hidden)])
        ledger.observe([look(a, .left, .visible)], strays: [a])
        #expect(ledger.actionable([a]) == [a])
        // Still a stray at the next look: stays actionable until resolved.
        ledger.observe([look(a, .left, .visible)], strays: [a])
        #expect(ledger.actionable([a]) == [a])
    }

    @Test func aSideFlipByHandIsExemptAndReported() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .left, .hidden)])
        let byHand = ledger.observe([look(a, .right, .hidden)], strays: [a])
        #expect(byHand == [a])
        #expect(ledger.actionable([a]).isEmpty)
        #expect(ledger.standing(of: a) == .byHand)
        // Quiet and exempt on the following looks.
        #expect(ledger.observe([look(a, .right, .hidden)], strays: [a]).isEmpty)
        #expect(ledger.actionable([a]).isEmpty)
    }

    @Test func aFlipOfOurOwnMoveIsOurs() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .right, .hidden)], strays: [a])
        let byHand = ledger.observe([look(a, .left, .hidden)], ownMoves: [a])
        #expect(byHand.isEmpty)
        #expect(ledger.standing(of: a) == .settled)
    }

    @Test func aHandPlacedIconIsActionableAgainWhenItsSectionChanges() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .left, .hidden)])
        ledger.observe([look(a, .right, .hidden)], strays: [a])
        ledger.observe([look(a, .right, .visible)])
        // A drop back to Hidden with the side steady is an editor drop.
        ledger.observe([look(a, .right, .hidden)], strays: [a])
        #expect(ledger.actionable([a]) == [a])
    }

    @Test func aSectionAndSideChangingTogetherIsAdoptionNotAStray() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .left, .hidden)])
        ledger.observe([look(a, .right, .visible)])
        #expect(ledger.standing(of: a) == .settled)
        #expect(ledger.actionable([a]).isEmpty)
    }

    @Test func anIconThatLeftTheBarIsNewlySeenWhenItReturns() {
        var ledger = StrayLedger()
        ledger.observe([look(a, .right, .hidden), look(b, .left, .hidden)])
        ledger.observe([look(b, .left, .hidden)])
        ledger.observe([look(a, .right, .hidden), look(b, .left, .hidden)], strays: [a])
        #expect(ledger.actionable([a]) == [a])
    }

    @Test func aDropFromAnotherDisplayIsLeftWhereItLands() {
        // In place, off to the other display, back on the wrong side with no
        // adoption (nothing identified the drop): not a flip, not new, and
        // nothing explains it, so it stays.
        var ledger = StrayLedger()
        ledger.observe([look(a, .left, .hidden)])
        ledger.observe([look(a, nil, .hidden)])
        ledger.observe([look(a, .right, .hidden)], strays: [a])
        #expect(ledger.actionable([a]).isEmpty)
    }

    @Test func aStrayMetOffTheBarAndFramedLaterIsLeftAlone() {
        var ledger = StrayLedger()
        ledger.observe([look(a, nil, .hidden)])
        ledger.observe([look(a, .right, .hidden)], strays: [a])
        #expect(ledger.actionable([a]).isEmpty)
    }
}
