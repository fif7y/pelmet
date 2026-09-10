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

    // MARK: - The layout and the drop slot must agree

    /// `FlowLayout` packs from the end and `EditorInsertion` counts the rows
    /// BELOW the cursor; those two facts only work together, and until now
    /// each was asserted against hand-written frames — change the wrap
    /// direction alone and both suites still passed. This derives the frames
    /// from the layout itself, so the pair is locked.
    @MainActor
    @Test func dropSlotAgreesWithTheRowsTheLayoutPacks() {
        let spacing: CGFloat = 6
        let width: CGFloat = 130
        let sizes = Array(repeating: CGSize(width: 34, height: 48), count: 5)
        let rows = FlowLayout.computeRows(
            sizes: sizes, width: width, spacing: spacing, fromEnd: true
        )

        // Mirrors FlowLayout.placeSubviews: rows top to bottom, each one
        // right-anchored, tiles left to right within a row.
        var frames: [ItemID: CGRect] = [:]
        var y: CGFloat = 0
        for row in rows {
            let rowWidth = row.map(\.size.width).reduce(0, +)
                + spacing * CGFloat(max(row.count - 1, 0))
            var x = max(width - rowWidth, 0)
            for (index, size) in row {
                frames[ids[index]] = CGRect(origin: CGPoint(x: x, y: y), size: size)
                x += size.width + spacing
            }
            y += (row.map(\.size.height).max() ?? 0) + spacing
        }
        #expect(frames.count == ids.count)

        // Every tile's own slot is recoverable from where it was drawn: just
        // inside its leading edge inserts AT it, just inside its trailing
        // edge inserts AFTER it.
        for (index, id) in ids.enumerated() {
            let frame = frames[id]!
            let leading = CGPoint(x: frame.minX + 1, y: frame.midY)
            let trailing = CGPoint(x: frame.maxX - 1, y: frame.midY)
            #expect(EditorInsertion.index(at: leading, order: ids, frames: frames) == index)
            #expect(EditorInsertion.index(at: trailing, order: ids, frames: frames) == index + 1)
        }
    }
}
