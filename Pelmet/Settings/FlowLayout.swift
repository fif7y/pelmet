// FlowLayout.swift
// Wrapping row layout for the editor strips; `trailing` right-anchors each
// row like the real menubar AND packs from the right, so a strip wraps the
// way the bar reads: first icon top-right, overflow continues below.
// Row packing is a pure static so it's testable without SwiftUI.

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var trailing: Bool = false

    /// Pure row packing over measured sizes: greedy fill, wrap when the next
    /// item would overflow — but never wrap the first item of a row.
    /// `fromEnd` packs the LAST subview first: the menu bar's first icon is
    /// its rightmost, so a right-anchored strip has to wrap like RTL text —
    /// the top row holds the trailing items, the leftmost ones fall through.
    /// Rows stay in top-to-bottom order and each row in left-to-right order.
    static func computeRows(
        sizes: [CGSize], width: CGFloat, spacing: CGFloat, fromEnd: Bool = false
    ) -> [[(index: Int, size: CGSize)]] {
        let order: [(index: Int, size: CGSize)] = sizes.enumerated()
            .map { (index: $0.offset, size: $0.element) }
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for entry in (fromEnd ? order.reversed() : order) {
            if x + entry.size.width > width, x > 0 {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(entry)
            x += entry.size.width + spacing
        }
        return fromEnd ? rows.map { Array($0.reversed()) } : rows
    }

    /// SwiftUI calls `sizeThatFits` and then `placeSubviews` for the same
    /// pass, and each one used to re-measure every subview — an editor strip
    /// re-rendered on hover, drag and every model change, so the tiles were
    /// measured twice per pass for nothing. The cache keeps the measurements
    /// and the packed rows, and only re-packs when the width changes.
    struct Cache {
        var sizes: [CGSize]
        var width: CGFloat
        var rows: [[(index: Int, size: CGSize)]]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: .nan, rows: [])
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.width = .nan
        cache.rows = []
    }

    private func rows(width: CGFloat, cache: inout Cache) -> [[(index: Int, size: CGSize)]] {
        if cache.width == width { return cache.rows }
        cache.rows = Self.computeRows(
            sizes: cache.sizes,
            width: width,
            spacing: spacing,
            fromEnd: trailing
        )
        cache.width = width
        return cache.rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? 400
        var height: CGFloat = 0
        for (rowIndex, row) in rows(width: width, cache: &cache).enumerated() {
            if rowIndex > 0 { height += spacing }
            height += row.map(\.size.height).max() ?? 0
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for row in rows(width: bounds.width, cache: &cache) {
            let rowWidth = row.map(\.size.width).reduce(0, +)
                + spacing * CGFloat(max(row.count - 1, 0))
            var x = trailing ? max(bounds.maxX - rowWidth, bounds.minX) : bounds.minX
            let rowHeight = row.map(\.size.height).max() ?? 0
            for (index, size) in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
