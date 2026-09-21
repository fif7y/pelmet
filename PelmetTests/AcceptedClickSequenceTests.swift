// AcceptedClickSequenceTests.swift

import Testing
@testable import Pelmet

struct AcceptedClickSequenceTests {
    @Test func rapidTripleClickDoesNotBecomeAnotherSingleClick() {
        var sequence = AcceptedClickSequence()
        let counts = (1...3).map {
            sequence.accept(rawCount: $0, timestamp: 10 + Double($0) * 0.1, doubleClickInterval: 0.5)
        }
        #expect(counts == [1, 2, 2])
    }

    @Test func continuedClicksUseThePreviousClickTime() {
        var sequence = AcceptedClickSequence()
        #expect(sequence.accept(rawCount: 1, timestamp: 10, doubleClickInterval: 0.5) == 1)
        #expect(sequence.accept(rawCount: 2, timestamp: 10.4, doubleClickInterval: 0.5) == 2)
        #expect(sequence.accept(rawCount: 3, timestamp: 10.8, doubleClickInterval: 0.5) == 2)
        sequence.reset()
        #expect(sequence.accept(rawCount: 4, timestamp: 10.9, doubleClickInterval: 0.5) == 1)
    }
    @Test func acceptedPairBecomesDoubleClick() {
        var sequence = AcceptedClickSequence()
        #expect(sequence.accept(rawCount: 1, timestamp: 10, doubleClickInterval: 0.5) == 1)
        #expect(sequence.accept(rawCount: 2, timestamp: 10.2, doubleClickInterval: 0.5) == 2)
    }

    @Test func rejectedFirstClickCannotPromoteRawSecondClick() {
        var sequence = AcceptedClickSequence()
        sequence.reset()
        #expect(sequence.accept(rawCount: 2, timestamp: 10.2, doubleClickInterval: 0.5) == 1)
    }

    @Test func rejectionBreaksAnAcceptedSequence() {
        var sequence = AcceptedClickSequence()
        #expect(sequence.accept(rawCount: 1, timestamp: 10, doubleClickInterval: 0.5) == 1)
        sequence.reset()
        #expect(sequence.accept(rawCount: 2, timestamp: 10.2, doubleClickInterval: 0.5) == 1)
    }

    @Test func expiredRawSecondClickStartsANewSequence() {
        var sequence = AcceptedClickSequence()
        #expect(sequence.accept(rawCount: 1, timestamp: 10, doubleClickInterval: 0.5) == 1)
        #expect(sequence.accept(rawCount: 2, timestamp: 10.6, doubleClickInterval: 0.5) == 1)
        #expect(sequence.accept(rawCount: 3, timestamp: 10.8, doubleClickInterval: 0.5) == 2)
    }
}
