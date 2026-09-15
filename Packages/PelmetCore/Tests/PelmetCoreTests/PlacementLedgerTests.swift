import Foundation
import Testing
@testable import PelmetCore

@Suite struct PlacementLedgerTests {
    let a = ItemID(rawValue: "status:com.example.a::A")
    let b = ItemID(rawValue: "status:com.example.b::B")
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func blankRecordLeavesTheLedger() {
        var ledger = PlacementLedger()
        ledger.queue(a)
        #expect(ledger.pending == [a])
        #expect(ledger.trackedIDs == [a])
        ledger.dequeue(a)
        #expect(ledger.trackedIDs.isEmpty)
    }

    @Test func driftBudgetThenCoolOffThenReset() {
        var ledger = PlacementLedger()
        let v1 = ledger.spendDriftAttempt(a, now: t0)
        #expect(v1 == .correct(attempt: 1))
        let v2 = ledger.spendDriftAttempt(a, now: t0)
        #expect(v2 == .correct(attempt: 2))
        let v3 = ledger.spendDriftAttempt(a, now: t0)
        #expect(v3 == .correct(attempt: 3))
        let v4 = ledger.spendDriftAttempt(a, now: t0)
        #expect(v4 == .coolOff)
        let v5 = ledger.spendDriftAttempt(a, now: t0 + 60)
        #expect(v5 == .skip)
        // Cool-off over: budget starts fresh.
        let v6 = ledger.spendDriftAttempt(a, now: t0 + PlacementLedger.driftCoolOff + 1)
        #expect(v6 == .correct(attempt: 1))
    }

    @Test func driftResetSparesTheMisplaced() {
        var ledger = PlacementLedger()
        _ = ledger.spendDriftAttempt(a, now: t0)
        _ = ledger.spendDriftAttempt(b, now: t0)
        ledger.resetDriftBudget(except: [b])
        #expect(ledger[a].driftAttempts == 0)
        #expect(ledger[b].driftAttempts == 1)
    }

    @Test func rescueBudgetGivesUpOnTheLastAttempt() {
        var ledger = PlacementLedger()
        let q1 = ledger.queueRescue(a)
        #expect(q1)
        let q2 = ledger.queueRescue(a)
        #expect(!q2)
        let v7 = ledger.spendRescueAttempt(a)
        #expect(v7 == (1, true))
        let v8 = ledger.spendRescueAttempt(a)
        #expect(v8 == (2, true))
        let v9 = ledger.spendRescueAttempt(a)
        #expect(v9 == (3, false))
        #expect(ledger[a].rescueAttempts == 0)
    }

    @Test func framelessRetryRidesTheSlowClock() {
        var ledger = PlacementLedger()
        let v10 = ledger.scheduleFramelessRetry(a, now: t0)
        #expect(v10 == nil)
        ledger.noteFrameless(a, now: t0)
        ledger.noteFrameless(a, now: t0 + 5)  // first miss wins
        let v11 = ledger.scheduleFramelessRetry(a, now: t0 + 10)
        #expect(v11 == 10)
        #expect(ledger.framelessRetryPending(a, now: t0 + 11))
        #expect(!ledger.framelessRetryPending(a, now: t0 + 10 + PlacementLedger.framelessRetryInterval))
        ledger.notePlaced(a)
        #expect(ledger[a] == PlacementRecord())
    }
}
