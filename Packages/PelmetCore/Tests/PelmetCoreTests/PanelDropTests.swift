import CoreGraphics
import Foundation
import Testing
@testable import PelmetCore

@Suite struct PanelDropTests {
    // A 1000x800 display, y up: the bar is the top 38pt, the panel hangs 6pt
    // under it at the right, 200 wide, from y 600 down to 400.
    private let bar = CGRect(x: 0, y: 762, width: 1000, height: 38)
    private let panel = CGRect(x: 780, y: 400, width: 200, height: 356)

    private func zones(
        didntFit: CGRect? = nil, fold: CGRect? = nil, alwaysHidden: CGRect? = nil,
        groups: [PanelDropZones.Group] = []
    ) -> PanelDropZones {
        PanelDropZones(bar: bar, panel: panel, didntFit: didntFit, fold: fold, alwaysHidden: alwaysHidden, groups: groups)
    }

    @Test func theBarAboveIsVisible() {
        let z = zones()
        #expect(z.hit(at: CGPoint(x: 100, y: 780)) == .section(.visible))
        // The display's top row, where a pushed pointer sits.
        #expect(z.hit(at: CGPoint(x: 100, y: 800)) == .section(.visible))
        // Over the panel's own column too: the bar wins over the zone's margin.
        #expect(z.hit(at: CGPoint(x: 900, y: 765)) == .section(.visible))
    }

    @Test func thePanelIsHiddenByDefault() {
        let z = zones()
        #expect(z.hit(at: CGPoint(x: 880, y: 600)) == .section(.hidden))
        // The zone's margin: 16 past the sides, 28 below, 16 above.
        #expect(z.hit(at: CGPoint(x: 765, y: 600)) == .section(.hidden))
        #expect(z.hit(at: CGPoint(x: 995, y: 600)) == .section(.hidden))
        #expect(z.hit(at: CGPoint(x: 880, y: 375)) == .section(.hidden))
    }

    @Test func pastTheZoneIsNothing() {
        let z = zones()
        #expect(z.hit(at: CGPoint(x: 700, y: 600)) == .none)
        #expect(z.hit(at: CGPoint(x: 880, y: 360)) == .none)
        #expect(z.hit(at: CGPoint(x: 1010, y: 600)) == .none)
        // Below the bar, off the panel to the left: the desktop.
        #expect(z.hit(at: CGPoint(x: 100, y: 500)) == .none)
    }

    @Test func theFoldIsAlwaysHiddenAndSprings() {
        // The tile fold is a tile of Hidden's grid: it wins over Hidden.
        let z = zones(fold: CGRect(x: 800, y: 560, width: 44, height: 44))
        #expect(z.hit(at: CGPoint(x: 820, y: 580)) == .fold)
        #expect(z.hit(at: CGPoint(x: 820, y: 580)).section == .alwaysHidden)
        // A little past its edge still counts.
        #expect(z.hit(at: CGPoint(x: 847, y: 580)) == .fold)
        #expect(z.hit(at: CGPoint(x: 860, y: 580)) == .section(.hidden))
    }

    @Test func anOpenAlwaysHiddenOwnsTheGridAndWhatIsBelow() {
        let z = zones(fold: CGRect(x: 790, y: 560, width: 180, height: 20),
                      alwaysHidden: CGRect(x: 790, y: 410, width: 180, height: 140))
        #expect(z.hit(at: CGPoint(x: 880, y: 500)) == .section(.alwaysHidden))
        // Its top edge and below, down to the zone's margin.
        #expect(z.hit(at: CGPoint(x: 880, y: 550)) == .section(.alwaysHidden))
        #expect(z.hit(at: CGPoint(x: 880, y: 380)) == .section(.alwaysHidden))
        // Above it, Hidden's grid.
        #expect(z.hit(at: CGPoint(x: 880, y: 640)) == .section(.hidden))
    }

    @Test func didntFitTakesNoDrop() {
        let z = zones(didntFit: CGRect(x: 790, y: 660, width: 180, height: 90))
        #expect(z.hit(at: CGPoint(x: 880, y: 700)) == .none)
        // The padding above it, under the bar.
        #expect(z.hit(at: CGPoint(x: 880, y: 757)) == .none)
        // Its bottom edge and the gap to Hidden's header.
        #expect(z.hit(at: CGPoint(x: 880, y: 657)) == .none)
        #expect(z.hit(at: CGPoint(x: 880, y: 600)) == .section(.hidden))
    }

    @Test func theRowTakesTheNearestGroup() {
        // One row at y 700…728: Didn't fit, Always Hidden, Hidden, left to right.
        func tiles(from x: CGFloat, count: Int) -> [CGRect] {
            (0..<count).map { CGRect(x: x + CGFloat($0) * 34, y: 700, width: 34, height: 28) }
        }
        let row = PanelDropZones(
            bar: bar, panel: CGRect(x: 600, y: 690, width: 380, height: 48),
            groups: [
                .init(kind: .didntFit, tiles: tiles(from: 610, count: 2)),
                .init(kind: .alwaysHidden, tiles: tiles(from: 700, count: 2)),
                .init(kind: .hidden, tiles: tiles(from: 800, count: 3)),
            ])
        #expect(row.hit(at: CGPoint(x: 620, y: 714)) == .none)
        #expect(row.hit(at: CGPoint(x: 720, y: 714)) == .section(.alwaysHidden))
        #expect(row.hit(at: CGPoint(x: 850, y: 714)) == .section(.hidden))
        // The divider between groups goes to the nearer side.
        #expect(row.hit(at: CGPoint(x: 772, y: 714)) == .section(.alwaysHidden))
        #expect(row.hit(at: CGPoint(x: 790, y: 714)) == .section(.hidden))
        // The zone's margin past the last tile.
        #expect(row.hit(at: CGPoint(x: 990, y: 714)) == .section(.hidden))
        // The bar is still the bar.
        #expect(row.hit(at: CGPoint(x: 850, y: 780)) == .section(.visible))
    }

    @Test func wrappedRowsKeepTheirOwnRow() {
        // Two rows; the pointer on the lower one is closer to its tile than to
        // the upper row's, whatever the columns say.
        let row = PanelDropZones(
            bar: bar, panel: CGRect(x: 600, y: 650, width: 380, height: 90),
            groups: [
                .init(kind: .hidden, tiles: [CGRect(x: 800, y: 700, width: 34, height: 28)]),
                .init(kind: .alwaysHidden, tiles: [CGRect(x: 790, y: 670, width: 34, height: 28)]),
            ])
        #expect(row.hit(at: CGPoint(x: 810, y: 712)) == .section(.hidden))
        #expect(row.hit(at: CGPoint(x: 810, y: 684)) == .section(.alwaysHidden))
    }

    @Test func hitSectionForEachHit() {
        #expect(PanelDropZones.Hit.none.section == nil)
        #expect(PanelDropZones.Hit.section(.visible).section == .visible)
        #expect(PanelDropZones.Hit.fold.section == .alwaysHidden)
    }
}
