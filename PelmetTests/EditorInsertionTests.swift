// EditorInsertionTests.swift
// Locks the editor's drop-slot rule: midpoint crossing within a row, and
// indexing across wrapped rows — strips pack from the end, so the TOP row
// carries the LAST indices — nearest row when the cursor sits above/below
// every row, and ids without a measured frame are skipped.

import CoreGraphics
import Testing
import PelmetCore
@testable import Pelmet

struct EditorInsertionTests {
    private let ids = (0..<5).map { ItemID(rawValue: "item\($0)") }

    /// How the strip actually wraps: the last three (2 3 4) hold the top row
    /// at x 0/40/80, and the first two (0 1) fall to the second row, which is
    /// right-anchored like the bar — so they sit at x 40/80.
    private var frames: [ItemID: CGRect] {
        [
            ids[2]: CGRect(x: 0, y: 0, width: 34, height: 48),
            ids[3]: CGRect(x: 40, y: 0, width: 34, height: 48),
            ids[4]: CGRect(x: 80, y: 0, width: 34, height: 48),
            ids[0]: CGRect(x: 40, y: 54, width: 34, height: 48),
            ids[1]: CGRect(x: 80, y: 54, width: 34, height: 48),
        ]
    }

    @Test func midpointCrossingWithinARow() {
        // Second row, so the two tiles below it count for nothing: this row
        // starts the order.
        #expect(EditorInsertion.index(at: CGPoint(x: 50, y: 70), order: ids, frames: frames) == 0)
        #expect(EditorInsertion.index(at: CGPoint(x: 58, y: 70), order: ids, frames: frames) == 1)
        #expect(EditorInsertion.index(at: CGPoint(x: 96, y: 70), order: ids, frames: frames) == 1)
        #expect(EditorInsertion.index(at: CGPoint(x: 98, y: 70), order: ids, frames: frames) == 2)
    }

    @Test func theTopRowIndexesAfterTheRowsBelowIt() {
        #expect(EditorInsertion.index(at: CGPoint(x: 10, y: 20), order: ids, frames: frames) == 2)
        #expect(EditorInsertion.index(at: CGPoint(x: 18, y: 20), order: ids, frames: frames) == 3)
        #expect(EditorInsertion.index(at: CGPoint(x: 58, y: 20), order: ids, frames: frames) == 4)
        #expect(EditorInsertion.index(at: CGPoint(x: 200, y: 20), order: ids, frames: frames) == 5)
    }

    @Test func outsideEveryRowSnapsToTheNearest() {
        // Above everything is the top row's trailing edge — the very end.
        #expect(EditorInsertion.index(at: CGPoint(x: 200, y: -30), order: ids, frames: frames) == 5)
        // Below everything is the bottom row's trailing edge.
        #expect(EditorInsertion.index(at: CGPoint(x: 200, y: 300), order: ids, frames: frames) == 2)
    }

    @Test func unmeasuredIdsAreSkipped() {
        // Drop the top row's middle tile: that row is 2 and 4, so a cursor
        // past 2's midpoint lands before 4.
        let partial = frames.filter { $0.key != ids[3] }
        #expect(EditorInsertion.index(at: CGPoint(x: 18, y: 20), order: ids, frames: partial) == 3)
        #expect(EditorInsertion.index(at: .zero, order: ids, frames: [:]) == 0)
    }
}
