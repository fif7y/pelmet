// FlowLayoutTests.swift
// The editor strip's row packing: greedy fill, wrap on overflow, the
// first-item-of-a-row never wraps (even when wider than the row), and the
// right-anchored strips pack from the end so they wrap like the bar reads.

import CoreGraphics
import Testing
@testable import Pelmet

@MainActor
struct FlowLayoutTests {
    func sizes(_ widths: [CGFloat]) -> [CGSize] {
        widths.map { CGSize(width: $0, height: 24) }
    }

    @Test func itemsThatFitStayOnOneRow() {
        let rows = FlowLayout.computeRows(sizes: sizes([100, 100, 100]), width: 400, spacing: 6)
        #expect(rows.count == 1)
        #expect(rows[0].map(\.index) == [0, 1, 2])
    }

    @Test func overflowWrapsToANewRow() {
        let rows = FlowLayout.computeRows(sizes: sizes([200, 200, 200]), width: 450, spacing: 6)
        #expect(rows.map { $0.map(\.index) } == [[0, 1], [2]])
    }

    @Test func oversizedFirstItemNeverWraps() {
        let rows = FlowLayout.computeRows(sizes: sizes([500, 100]), width: 400, spacing: 6)
        #expect(rows.map { $0.map(\.index) } == [[0], [1]])
    }

    @Test func spacingCountsTowardOverflow() {
        // Two 200pt items fit a 400pt row only without spacing.
        let rows = FlowLayout.computeRows(sizes: sizes([200, 200]), width: 400, spacing: 6)
        #expect(rows.map { $0.map(\.index) } == [[0], [1]])
    }

    @Test func packingFromTheEndOverflowsTheLeftmostItem() {
        // The bar's first icon is its rightmost, so the top row keeps the
        // trailing items and the LEADING one (drawn leftmost) falls through.
        let rows = FlowLayout.computeRows(
            sizes: sizes([200, 200, 200]), width: 450, spacing: 6, fromEnd: true
        )
        #expect(rows.map { $0.map(\.index) } == [[1, 2], [0]])
    }

    @Test func packingFromTheEndKeepsRowsInReadingOrder() {
        let rows = FlowLayout.computeRows(
            sizes: sizes([100, 100, 100, 100, 100]), width: 320, spacing: 6, fromEnd: true
        )
        #expect(rows.map { $0.map(\.index) } == [[2, 3, 4], [0, 1]])
    }
}
