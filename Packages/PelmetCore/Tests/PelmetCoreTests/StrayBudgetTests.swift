import Testing
@testable import PelmetCore

@Suite struct StrayBudgetTests {
    let a = ItemID.bundleKey("com.a"), b = ItemID.bundleKey("com.b")
    var hidden: Roster { Roster(members: [a: .hidden, b: .hidden]) }

    @Test func twoAttemptsThenItGivesUpOnceAndStaysQuiet() {
        var budget = StrayBudget()
        var verdict = budget.check([a], roster: hidden)
        #expect(verdict.ready == [a])
        budget.spend([a], roster: hidden)
        #expect(budget.check([a], roster: hidden).ready == [a])
        budget.spend([a], roster: hidden)
        verdict = budget.check([a], roster: hidden)
        #expect(verdict.ready.isEmpty && verdict.exhausted == [a] && verdict.newlyExhausted == [a])
        #expect(budget.check([a], roster: hidden).newlyExhausted.isEmpty)
    }

    @Test func eachItemHasItsOwnBudget() {
        var budget = StrayBudget()
        budget.spend([a], roster: hidden)
        budget.spend([a], roster: hidden)
        let verdict = budget.check([a, b], roster: hidden)
        #expect(verdict.ready == [b] && verdict.exhausted == [a])
    }

    @Test func aChangedSectionClearsOnlyThatItem() {
        var budget = StrayBudget()
        budget.spend([a, b], roster: hidden)
        budget.spend([a, b], roster: hidden)
        var moved = hidden
        moved.assign(a, to: .alwaysHidden)
        let verdict = budget.check([a, b], roster: moved)
        #expect(verdict.ready == [a] && verdict.exhausted == [b])
    }

    @Test func nothingElseResets() {
        // A clear bar, a check with other strays, the item missing for a
        // while: none of it wipes what a used.
        var budget = StrayBudget()
        budget.spend([a], roster: hidden)
        budget.spend([a], roster: hidden)
        #expect(budget.check([], roster: hidden).ready.isEmpty)
        #expect(budget.check([b], roster: hidden).ready == [b])
        let verdict = budget.check([a], roster: hidden)
        #expect(verdict.exhausted == [a] && verdict.ready.isEmpty)
    }

    @Test func aSectionGoingThereAndBackStartsFresh() {
        var budget = StrayBudget()
        budget.spend([a], roster: hidden)
        budget.spend([a], roster: hidden)
        var away = hidden
        away.assign(a, to: .visible)
        #expect(budget.check([a], roster: away).ready == [a])
        #expect(budget.check([a], roster: hidden).ready == [a])
    }
}
