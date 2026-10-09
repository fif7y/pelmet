import CoreGraphics
import Foundation
import Testing
@testable import PelmetCore

@Suite struct PanelGridTests {
    private func tiles(_ n: Int) -> [PanelTile] {
        (0..<n).map { .item(.bundleKey("t\($0)")) }
    }

    private func t(_ i: Int) -> PanelTile { .item(.bundleKey("t\(i)")) }

    private func grid(
        _ tiles: [PanelTile], columns: Int? = nil, layout: PanelGrid.Layout = .panel,
        names: Bool = false, minimumColumns: Int = 1
    ) -> PanelGrid {
        PanelGrid(tiles: tiles, columns: columns, layout: layout, showsNames: names, minimumColumns: minimumColumns)
    }

    private func counts(_ grid: PanelGrid) -> [Int] { grid.rows.map(\.count) }

    // MARK: - Metrics

    // The numbers come from the design mock's cfg(); a change here is a design change.
    @Test func metricsAreTheMocks() {
        #expect(PanelMetrics.standard(layout: .panel, showsNames: false) == .compact)
        #expect(PanelMetrics.standard(layout: .panel, showsNames: true) == .named)
        #expect(PanelMetrics.standard(layout: .row, showsNames: true) == .row)
        #expect(PanelMetrics.compact.tileSize == CGSize(width: 44, height: 44))
        #expect(PanelMetrics.compact.columnGap == 6 && PanelMetrics.compact.rowGap == 6)
        #expect(PanelMetrics.named.tileSize == CGSize(width: 68, height: 63))
        #expect(PanelMetrics.named.columnGap == 2 && PanelMetrics.named.rowGap == 8)
        #expect(PanelMetrics.named.labelHeight == 13 && PanelMetrics.named.labelGap == 5)
        #expect(PanelMetrics.row.tileSize == CGSize(width: 34, height: 28))
        #expect(PanelMetrics.compact.padding == 10 && PanelMetrics.row.padding == 5)
    }

    // MARK: - Columns

    @Test func autoIsFiveColumnsAndWraps() {
        let g = grid(tiles(7))
        #expect(g.columnCount == 5)
        #expect(counts(g) == [5, 2])
        #expect(g.rows[1][1].tile == t(6))
        #expect(g.rows[1][1].row == 1 && g.rows[1][1].column == 1)
    }

    // No wider than the icons need, so three icons are three columns.
    @Test func theGridShrinksToItsIcons() {
        #expect(grid(tiles(3)).columnCount == 3)
        #expect(grid(tiles(1), columns: 8).columnCount == 1)
    }

    @Test func aSettingIsTheMostNotTheExact() {
        #expect(counts(grid(tiles(7), columns: 3)) == [3, 3, 1])
        #expect(grid(tiles(3), columns: 8).columnCount == 3)
        #expect(grid(tiles(4), columns: 0).columnCount == 1)
        #expect(grid(tiles(12), columns: 10).columnCount == 10)
    }

    // Stacked sections share the widest one's width, never past the setting.
    @Test func minimumColumnsLetSectionsShareAWidth() {
        #expect(grid(tiles(2), minimumColumns: 4).columnCount == 4)
        #expect(grid(tiles(2), columns: 3, minimumColumns: 4).columnCount == 3)
        let wide = PanelGrid.neededColumns(of: tiles(9), maximum: nil)
        #expect(wide == 5)
        #expect(PanelGrid.neededColumns(of: tiles(2), maximum: nil) == 2)
    }

    // MARK: - Frames and size

    @Test func compactFramesAndSize() {
        let g = grid(tiles(7))
        #expect(g.rows[0][0].frame == CGRect(x: 0, y: 0, width: 44, height: 44))
        #expect(g.rows[0][4].frame == CGRect(x: 200, y: 0, width: 44, height: 44))
        #expect(g.rows[1][1].frame == CGRect(x: 50, y: 50, width: 44, height: 44))
        #expect(g.contentSize == CGSize(width: 244, height: 94))
        #expect(g.panelSize == CGSize(width: 264, height: 114))
    }

    @Test func namedFramesAndSize() {
        let g = grid(tiles(7), names: true)
        #expect(g.showsNames)
        #expect(g.rows[1][1].frame == CGRect(x: 70, y: 71, width: 68, height: 63))
        #expect(g.contentSize == CGSize(width: 348, height: 134))
    }

    @Test func aNarrowPanelKeepsItsMinimumWidth() {
        let g = grid(tiles(3))
        #expect(g.contentSize == CGSize(width: 150, height: 44))
        #expect(g.rows[0][2].frame.maxX == 144)
    }

    @Test func noTilesNoSize() {
        let g = grid([])
        #expect(g.rows.isEmpty && g.columnCount == 0)
        #expect(g.contentSize == .zero && g.panelSize == .zero)
        #expect(g.firstTile == nil)
        #expect(grid([.rowBreak, .rowBreak]).rows.isEmpty)
    }

    // MARK: - Row breaks

    @Test func aBreakStartsANewRowWithAGroupGap() {
        let g = grid([t(0), t(1), .rowBreak, t(2), t(3), t(4)])
        #expect(counts(g) == [2, 3])
        #expect(g.columnCount == 3)
        // A tile and its row gap (50), then the separator's own 4pt between two row gaps (10).
        #expect(g.rows[1][0].frame.minY == 60)
        #expect(g.contentSize.height == 104)
    }

    // A wrapped row inside one group is only a row gap apart.
    @Test func wrappingInsideAGroupAddsNoGroupGap() {
        let g = grid(tiles(6), columns: 3)
        #expect(g.rows[1][0].frame.minY == 50)
    }

    @Test func breaksNeverMakeEmptyRows() {
        let g = grid([.rowBreak, t(0), .rowBreak, .rowBreak, t(1), .rowBreak])
        #expect(counts(g) == [1, 1])
        #expect(g.rows.allSatisfy { !$0.isEmpty })
        #expect(g.placement(of: .rowBreak) == nil)
    }

    @Test func eachGroupWrapsOnItsOwn() {
        let g = grid([t(0), t(1), t(2), t(3), .rowBreak, t(4)], columns: 3)
        #expect(counts(g) == [3, 1, 1])
        // Wrapped once (50), a row (44 + 6), then the group gap (4 + 6).
        #expect(g.rows[2][0].frame.minY == 110)
    }

    // MARK: - Row layout

    @Test func rowIsOneRowWithNoNames() {
        let g = grid(tiles(8), columns: 2, layout: .row, names: true)
        #expect(counts(g) == [8])
        #expect(g.columnCount == 8)
        #expect(!g.showsNames)
        #expect(g.metrics == .row)
        #expect(g.rows[0][3].frame == CGRect(x: 102, y: 0, width: 34, height: 28))
        #expect(g.contentSize == CGSize(width: 272, height: 28))
        #expect(g.panelSize == CGSize(width: 282, height: 38))
    }

    @Test func breaksAreDividersInARow() {
        let g = grid([.rowBreak, t(0), t(1), .rowBreak, .rowBreak, t(2), .rowBreak], layout: .row)
        #expect(counts(g) == [3])
        #expect(g.dividers == [CGRect(x: 68, y: 0, width: 13, height: 28)])
        #expect(g.rows[0][2].frame.minX == 81)
        #expect(g.contentSize.width == 115)
    }

    @Test func panelLayoutHasNoDividers() {
        #expect(grid([t(0), .rowBreak, t(1)]).dividers.isEmpty)
    }

    // MARK: - Arrow keys

    @Test func rightAndLeftWalkTheRowsAndStopAtTheEnds() {
        let g = grid(tiles(7))
        #expect(g.neighbour(of: t(0), toward: .right) == t(1))
        #expect(g.neighbour(of: t(4), toward: .right) == t(5))
        #expect(g.neighbour(of: t(6), toward: .right) == nil)
        #expect(g.neighbour(of: t(5), toward: .left) == t(4))
        #expect(g.neighbour(of: t(0), toward: .left) == nil)
    }

    @Test func upAndDownKeepTheColumnAndClampToAShortRow() {
        let g = grid(tiles(7))
        #expect(g.neighbour(of: t(1), toward: .down) == t(6))
        #expect(g.neighbour(of: t(3), toward: .down) == t(6))
        #expect(g.neighbour(of: t(6), toward: .up) == t(1))
        #expect(g.neighbour(of: t(2), toward: .up) == nil)
        #expect(g.neighbour(of: t(6), toward: .down) == nil)
    }

    // Groups are rows to the keyboard.
    @Test func arrowsCrossARowBreak() {
        let g = grid([t(0), t(1), .rowBreak, t(2), t(3), t(4)])
        #expect(g.neighbour(of: t(1), toward: .right) == t(2))
        #expect(g.neighbour(of: t(1), toward: .down) == t(3))
    }

    @Test func aRowOnlyGoesAlongAndAnUnknownTileGoesNowhere() {
        let g = grid(tiles(3), layout: .row)
        #expect(g.neighbour(of: t(0), toward: .right) == t(1))
        #expect(g.neighbour(of: t(2), toward: .right) == nil)
        #expect(g.neighbour(of: t(1), toward: .up) == nil)
        #expect(g.neighbour(of: t(1), toward: .down) == nil)
        #expect(g.neighbour(of: t(9), toward: .left) == nil)
        #expect(g.firstTile == t(0))
    }
}
