// PanelGrid.swift
// Where the tiles of one panel section go: rows, frames, the size it needs and
// which tile an arrow key lands on (docs/PANEL-PLAN.md §2). Pure geometry, so
// the view draws what this says and the keyboard follows the same rows. Frames
// are relative to the content's top-left, y down, padding not included.

import CoreGraphics
import Foundation

/// Sizes and gaps in points, from the design mock (panel.src.html `cfg()`):
/// the numbers the panel was designed with, in one place.
public struct PanelMetrics: Equatable, Sendable {
    /// One grid cell. With names it is taller than the well to fit the label.
    public var tileSize: CGSize
    /// The filled rounded square the icon sits on, centered at the top of
    /// the cell. In the row layout it fills the cell.
    public var wellSize: CGSize
    public var columnGap: CGFloat
    public var rowGap: CGFloat
    /// Between the content and the panel's edge.
    public var padding: CGFloat
    public var labelGap: CGFloat
    public var labelHeight: CGFloat
    /// What a separator that starts a new row adds between two groups, on top
    /// of the row gap either side (a 4pt row in the mock's grid).
    public var groupGap: CGFloat
    /// A separator in the row layout: a thin divider between icons.
    public var dividerWidth: CGFloat
    /// The panel never gets narrower than this, whatever its columns.
    public var minimumContentWidth: CGFloat

    public static let compact = PanelMetrics(
        tileSize: CGSize(width: 44, height: 44), wellSize: CGSize(width: 44, height: 44),
        columnGap: 6, rowGap: 6, padding: 10, labelGap: 0, labelHeight: 0,
        groupGap: 4, dividerWidth: 0, minimumContentWidth: 150)

    public static let named = PanelMetrics(
        tileSize: CGSize(width: 68, height: 63), wellSize: CGSize(width: 44, height: 44),
        columnGap: 2, rowGap: 8, padding: 10, labelGap: 5, labelHeight: 13,
        groupGap: 4, dividerWidth: 0, minimumContentWidth: 150)

    public static let row = PanelMetrics(
        tileSize: CGSize(width: 34, height: 28), wellSize: CGSize(width: 34, height: 28),
        columnGap: 0, rowGap: 2, padding: 5, labelGap: 0, labelHeight: 0,
        groupGap: 0, dividerWidth: 13, minimumContentWidth: 0)

    public static func standard(layout: PanelGrid.Layout, showsNames: Bool) -> PanelMetrics {
        switch layout {
        case .row: .row
        case .panel: showsNames ? .named : .compact
        }
    }
}

public struct PanelGrid: Equatable, Sendable {
    public enum Layout: Sendable {
        /// Rows of tiles under the chevron.
        case panel
        /// The same tiles in one row, no names.
        case row
    }

    public enum Direction: Sendable {
        case left, right, up, down
    }

    public struct Placement: Equatable, Sendable {
        public let tile: PanelTile
        public let row: Int
        public let column: Int
        public let frame: CGRect
    }

    public let layout: Layout
    /// Names are a panel option; the row never has them.
    public let showsNames: Bool
    public let metrics: PanelMetrics
    /// Columns the grid is wide, at most the setting and no wider than the
    /// widest group needs.
    public let columnCount: Int
    /// Never empty rows: a break only separates groups.
    public let rows: [[Placement]]
    /// The row layout's separators, between two icons. Empty in the panel
    /// layout, where a separator is the gap between two rows.
    public let dividers: [CGRect]
    /// Zero when there are no tiles.
    public let contentSize: CGSize

    private let positions: [PanelTile: Placement]

    /// - Parameters:
    ///   - columns: the most columns a row may have; nil is Auto, 5. The row
    ///     layout ignores it.
    ///   - minimumColumns: for sections stacked in one panel, which share a
    ///     width: the widest of their `neededColumns`.
    public init(
        tiles: [PanelTile],
        columns: Int?,
        layout: Layout,
        showsNames: Bool,
        minimumColumns: Int = 1,
        metrics: PanelMetrics? = nil
    ) {
        let names = layout == .panel && showsNames
        let metrics = metrics ?? .standard(layout: layout, showsNames: names)
        self.layout = layout
        self.showsNames = names
        self.metrics = metrics

        var rows: [[Placement]] = []
        var dividers: [CGRect] = []
        let size: CGSize
        switch layout {
        case .panel:
            let groups = Self.groups(of: tiles)
            let count = Self.columnCount(maximum: columns, tiles: tiles, minimum: minimumColumns)
            var y: CGFloat = 0
            for group in groups {
                for start in stride(from: 0, to: group.count, by: count) {
                    if !rows.isEmpty {
                        y += metrics.tileSize.height + metrics.rowGap
                        if start == 0 { y += metrics.groupGap + metrics.rowGap }
                    }
                    let r = rows.count
                    rows.append(group[start..<min(start + count, group.count)].enumerated().map { c, tile in
                        Placement(
                            tile: tile, row: r, column: c,
                            frame: CGRect(
                                x: CGFloat(c) * (metrics.tileSize.width + metrics.columnGap), y: y,
                                width: metrics.tileSize.width, height: metrics.tileSize.height))
                    })
                }
            }
            self.columnCount = groups.isEmpty ? 0 : count
            let width = CGFloat(count) * metrics.tileSize.width + CGFloat(count - 1) * metrics.columnGap
            size = rows.isEmpty ? .zero : CGSize(
                width: max(width, metrics.minimumContentWidth), height: y + metrics.tileSize.height)
        case .row:
            var x: CGFloat = 0
            var placed: [Placement] = []
            var pendingBreak = false
            for tile in tiles {
                if tile == .rowBreak {
                    // Leading and doubled dividers go; a trailing one is
                    // never reached because it waits for a tile after it.
                    pendingBreak = !placed.isEmpty
                    continue
                }
                if pendingBreak {
                    dividers.append(CGRect(x: x, y: 0, width: metrics.dividerWidth, height: metrics.tileSize.height))
                    x += metrics.dividerWidth
                    pendingBreak = false
                }
                placed.append(Placement(
                    tile: tile, row: 0, column: placed.count,
                    frame: CGRect(x: x, y: 0, width: metrics.tileSize.width, height: metrics.tileSize.height)))
                x += metrics.tileSize.width + metrics.columnGap
            }
            if !placed.isEmpty { rows = [placed] }
            self.columnCount = placed.count
            size = placed.isEmpty ? .zero : CGSize(
                width: max(x - metrics.columnGap, metrics.minimumContentWidth), height: metrics.tileSize.height)
        }
        self.rows = rows
        self.dividers = dividers
        self.contentSize = size
        self.positions = Dictionary(
            rows.joined().map { ($0.tile, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The content plus the panel's padding on every side.
    public var panelSize: CGSize {
        guard contentSize != .zero else { return .zero }
        return CGSize(
            width: contentSize.width + 2 * metrics.padding,
            height: contentSize.height + 2 * metrics.padding)
    }

    public func placement(of tile: PanelTile) -> Placement? { positions[tile] }
    public func frame(of tile: PanelTile) -> CGRect? { positions[tile]?.frame }

    /// Where the keyboard starts.
    public var firstTile: PanelTile? { rows.first?.first?.tile }

    /// The tile an arrow key moves to; nil at an edge, where the caller may
    /// carry on into another section or the search field. Left and right
    /// run along the rows and wrap from one row's end to the next row's
    /// start. Up and down keep the column, landing on the last tile of a
    /// shorter row.
    public func neighbour(of tile: PanelTile, toward direction: Direction) -> PanelTile? {
        guard let here = positions[tile] else { return nil }
        let r = here.row, c = here.column
        switch direction {
        case .right:
            if c + 1 < rows[r].count { return rows[r][c + 1].tile }
            return r + 1 < rows.count ? rows[r + 1][0].tile : nil
        case .left:
            if c > 0 { return rows[r][c - 1].tile }
            return r > 0 ? rows[r - 1][rows[r - 1].count - 1].tile : nil
        case .down:
            guard r + 1 < rows.count else { return nil }
            return rows[r + 1][min(c, rows[r + 1].count - 1)].tile
        case .up:
            guard r > 0 else { return nil }
            return rows[r - 1][min(c, rows[r - 1].count - 1)].tile
        }
    }

    // MARK: - Columns

    /// Columns the panel layout gives these tiles: no wider than the widest
    /// group, at most `maximum` (nil is Auto, 5), at least `minimum`.
    public static func neededColumns(of tiles: [PanelTile], maximum: Int?) -> Int {
        columnCount(maximum: maximum, tiles: tiles, minimum: 1)
    }

    private static func columnCount(maximum: Int?, tiles: [PanelTile], minimum: Int) -> Int {
        let most = max(1, maximum ?? PanelOptions.autoColumns)
        let widest = groups(of: tiles).map(\.count).max() ?? 0
        return min(most, max(widest, minimum, 1))
    }

    /// The tiles between breaks; a break never makes an empty group.
    private static func groups(of tiles: [PanelTile]) -> [[PanelTile]] {
        tiles.split(separator: .rowBreak, omittingEmptySubsequences: true).map(Array.init)
    }
}
