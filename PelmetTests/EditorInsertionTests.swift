// EditorInsertionTests.swift
// Locks the editor's drop-slot rule: midpoint crossing within a row,
// row-major indexing across wrapped rows, nearest row when the cursor sits
// above/below every row, and ids without a measured frame are skipped.

import CoreGraphics
import Testing
import PelmetCore
@testable import Pelmet

struct EditorInsertionTests {
    private let ids = (0..<5).map { ItemID(rawValue: "item\($0)") }

    /// Two rows: 0 1 2 on the top row (x 0/40/80), 3 4 on the second (x 0/40).
    private var frames: [ItemID: CGRect] {
        [
            ids[0]: CGRect(x: 0, y: 0, width: 34, height: 48),
            ids[1]: CGRect(x: 40, y: 0, width: 34, height: 48),
            ids[2]: CGRect(x: 80, y: 0, width: 34, height: 48),
            ids[3]: CGRect(x: 0, y: 54, width: 34, height: 48),
            ids[4]: CGRect(x: 40, y: 54, width: 34, height: 48),
        ]
    }

    @Test func midpointCrossingWithinARow() {
        #expect(EditorInsertion.index(at: CGPoint(x: 10, y: 20), order: ids, frames: frames) == 0)
        #expect(EditorInsertion.index(at: CGPoint(x: 18, y: 20), order: ids, frames: frames) == 1)
        #expect(EditorInsertion.index(at: CGPoint(x: 56, y: 20), order: ids, frames: frames) == 1)
        #expect(EditorInsertion.index(at: CGPoint(x: 58, y: 20), order: ids, frames: frames) == 2)
        #expect(EditorInsertion.index(at: CGPoint(x: 200, y: 20), order: ids, frames: frames) == 3)
    }

    @Test func secondRowIndexesAfterTheFirst() {
        #expect(EditorInsertion.index(at: CGPoint(x: 10, y: 70), order: ids, frames: frames) == 3)
        #expect(EditorInsertion.index(at: CGPoint(x: 50, y: 70), order: ids, frames: frames) == 4)
        #expect(EditorInsertion.index(at: CGPoint(x: 200, y: 70), order: ids, frames: frames) == 5)
    }

    @Test func outsideEveryRowSnapsToTheNearest() {
        #expect(EditorInsertion.index(at: CGPoint(x: 200, y: -30), order: ids, frames: frames) == 3)
        #expect(EditorInsertion.index(at: CGPoint(x: 200, y: 300), order: ids, frames: frames) == 5)
    }

    @Test func unmeasuredIdsAreSkipped() {
        let partial = frames.filter { $0.key != ids[1] }
        #expect(EditorInsertion.index(at: CGPoint(x: 58, y: 20), order: ids, frames: partial) == 1)
        #expect(EditorInsertion.index(at: .zero, order: ids, frames: [:]) == 0)
    }
}
