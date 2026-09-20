// PlacementGeometryTests.swift
// Locks the placement choreography constants: neighbor midpoint, ±14
// one-sided offsets, zone fallbacks (−20/−15/+25), corner floor 200 /
// trailing clamp maxX−60, and the chevron ±12 side constraint applied LAST.

import CoreGraphics
import Testing
@testable import PelmetCore

struct PlacementGeometryTests {
    let maxX: CGFloat = 1728
    func rect(_ x: CGFloat, width: CGFloat = 30) -> CGRect {
        CGRect(x: x, y: 0, width: width, height: 24)
    }

    @Test func bothNeighborsAimAtTheMidpoint() {
        let x = PlacementGeometry.targetX(
            leftNeighbor: rect(400), rightNeighbor: rect(500),
            chevron: nil, section: .hidden, managedMinX: nil, screenMaxX: maxX
        )
        #expect(x == 465)
    }

    @Test func oneSidedNeighborsUsePlusMinusFourteen() {
        let left = PlacementGeometry.targetX(
            leftNeighbor: rect(400), rightNeighbor: nil,
            chevron: nil, section: .hidden, managedMinX: nil, screenMaxX: maxX
        )
        #expect(left == 444)
        let right = PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: rect(500),
            chevron: nil, section: .hidden, managedMinX: nil, screenMaxX: maxX
        )
        #expect(right == 486)
    }

    @Test func zoneFallbacksAnchorOnChevronAndManagedEdge() {
        let chevron = rect(1000)
        #expect(PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: chevron,
            section: .alwaysHidden, managedMinX: 600, screenMaxX: maxX
        ) == 580)
        #expect(PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: chevron,
            section: .hidden, managedMinX: nil, screenMaxX: maxX
        ) == 985)
        #expect(PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: chevron,
            section: .visible, managedMinX: nil, screenMaxX: maxX
        ) == 1055)
    }

    @Test func nothingToAnchorAgainstIsNil() {
        #expect(PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: nil,
            section: .hidden, managedMinX: nil, screenMaxX: maxX
        ) == nil)
    }

    @Test func cornerFloorAndTrailingClampApply() {
        // Far-left midpoint gets floored to 200.
        #expect(PlacementGeometry.targetX(
            leftNeighbor: rect(40), rightNeighbor: rect(120),
            chevron: nil, section: .hidden, managedMinX: nil, screenMaxX: maxX
        ) == 200)
        // Far-right one-sided target clamps to maxX − 60.
        #expect(PlacementGeometry.targetX(
            leftNeighbor: rect(maxX - 40), rightNeighbor: nil,
            chevron: nil, section: .visible, managedMinX: nil, screenMaxX: maxX
        ) == maxX - 60)
    }

    @Test func chevronSideConstraintOutranksTheCornerFloor() {
        // A far-left chevron: the 200 floor would push a hidden-section
        // target right of it — the ±12 side clamp applied LAST wins.
        let chevron = rect(150)
        let x = PlacementGeometry.targetX(
            leftNeighbor: nil, rightNeighbor: nil, chevron: chevron,
            section: .hidden, managedMinX: nil, screenMaxX: maxX
        )
        #expect(x == 138)
    }

    @Test func systemClusterClampAppliesLast() {
        // Midpoint (1465) sits inside the protected trailing cluster —
        // clamp to just left of it (1450 − 12).
        let x = PlacementGeometry.targetX(
            leftNeighbor: rect(1400), rightNeighbor: rect(1500),
            chevron: nil, section: .hidden, managedMinX: nil,
            systemMinX: 1450, screenMaxX: maxX
        )
        #expect(x == 1438)
    }

    @Test func inSlotChecksOrderAgainstPresentNeighborsOnly() {
        #expect(PlacementGeometry.inSlot(x: 450, leftMidX: 400, rightMidX: 500))
        #expect(!PlacementGeometry.inSlot(x: 390, leftMidX: 400, rightMidX: 500))
        #expect(!PlacementGeometry.inSlot(x: 510, leftMidX: 400, rightMidX: 500))
        #expect(PlacementGeometry.inSlot(x: 510, leftMidX: 400, rightMidX: nil))
        #expect(PlacementGeometry.inSlot(x: 390, leftMidX: nil, rightMidX: nil))
    }

    @Test func betweenCentersUsesMidpointWithCornerClamps() {
        #expect(PlacementGeometry.betweenCentersX(left: rect(400), right: rect(500), screenMaxX: maxX)
            == 465)
        #expect(PlacementGeometry.betweenCentersX(left: rect(40), right: rect(120), screenMaxX: maxX)
            == 200)
    }

    // MARK: Lifted predicates

    @Test func bandMembershipNeedsTheSameBandOnThePrimaryDisplay() {
        let dragged = rect(1200)
        #expect(PlacementGeometry.inBand(rect(1100), of: dragged, screenMaxX: maxX))
        #expect(!PlacementGeometry.inBand(CGRect(x: 1100, y: 500, width: 30, height: 24), of: dragged, screenMaxX: maxX))
        #expect(!PlacementGeometry.inBand(rect(-614), of: dragged, screenMaxX: maxX))
        #expect(!PlacementGeometry.inBand(rect(1800), of: dragged, screenMaxX: maxX))
    }

    @Test func phantomSharesAMinXInTheBand() {
        let f = rect(1195)
        #expect(PlacementGeometry.isPhantom(f, amongOthers: [rect(1195.2), rect(900)]))
        #expect(!PlacementGeometry.isPhantom(f, amongOthers: [rect(1196), rect(900)]))
        #expect(!PlacementGeometry.isPhantom(f, amongOthers: [CGRect(x: 1195, y: 500, width: 30, height: 24)]))
        // Trapped count: every frame that shares a minX with another one.
        #expect(PlacementGeometry.overflowTrappedCount([909, 909.2, 950, 1005, 909.1]) == 3)
        #expect(PlacementGeometry.overflowTrappedCount([900, 950, 1005]) == 0)
        #expect(PlacementGeometry.overflowTrappedCount([]) == 0)
    }

    @Test func liftedShiftsOnlyRightNeighborsOfThirdPartyDrags() {
        let dragged = rect(500)
        #expect(PlacementGeometry.lifted(rect(600), dragged: dragged, ownItem: false) == rect(570))
        #expect(PlacementGeometry.lifted(rect(400), dragged: dragged, ownItem: false) == rect(400))
        #expect(PlacementGeometry.lifted(rect(600), dragged: dragged, ownItem: true) == rect(600))
    }

    @Test func chevronCapsTheSectionBoundaryOnly() {
        // alwaysHidden 0..<2, hidden 2..<5, visible 5...
        let lastOfHidden = PlacementGeometry.chevronCaps(index: 4, leftIdx: 3, rightIdx: 5, alwaysHiddenEnd: 2, hiddenEnd: 5)
        #expect(lastOfHidden == (left: false, right: true))
        let firstOfVisible = PlacementGeometry.chevronCaps(index: 5, leftIdx: 4, rightIdx: 6, alwaysHiddenEnd: 2, hiddenEnd: 5)
        #expect(firstOfVisible == (left: true, right: false))
        let midHidden = PlacementGeometry.chevronCaps(index: 3, leftIdx: 2, rightIdx: 4, alwaysHiddenEnd: 2, hiddenEnd: 5)
        #expect(midHidden == (left: false, right: false))
        let alwaysHidden = PlacementGeometry.chevronCaps(index: 1, leftIdx: 0, rightIdx: nil, alwaysHiddenEnd: 2, hiddenEnd: 5)
        #expect(alwaysHidden == (left: false, right: false))
    }

    @Test func alreadyAtSlotIsAnOrderWithBothBoundsElseProximity() {
        #expect(PlacementGeometry.alreadyAtSlot(x: 1500, leftMidX: 1400, rightMidX: 1600, targetX: 0, fallbackTarget: false))
        // Neighbor's very x is not "between".
        #expect(!PlacementGeometry.alreadyAtSlot(x: 1554, leftMidX: 1554, rightMidX: 1600, targetX: 0, fallbackTarget: false))
        #expect(PlacementGeometry.alreadyAtSlot(x: 1505, leftMidX: nil, rightMidX: 1600, targetX: 1500, fallbackTarget: false))
        #expect(!PlacementGeometry.alreadyAtSlot(x: 1520, leftMidX: nil, rightMidX: 1600, targetX: 1500, fallbackTarget: false))
        #expect(PlacementGeometry.alreadyAtSlot(x: 1520, leftMidX: nil, rightMidX: nil, targetX: 1500, fallbackTarget: true))
    }

    @Test func hiddenZoneIsTouchedFromEitherEnd() {
        #expect(PlacementGeometry.touchesHiddenZone(x: 1100, targetX: 1300, chevronMidX: 1233))
        #expect(PlacementGeometry.touchesHiddenZone(x: 1300, targetX: 1100, chevronMidX: 1233))
        #expect(!PlacementGeometry.touchesHiddenZone(x: 1300, targetX: 1400, chevronMidX: 1233))
    }
}
