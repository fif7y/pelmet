// PlacementGeometryTests.swift
// Locks Apply's neighbour math: between-centers target with the corner
// floor 200 / trailing clamp maxX−60, the slot check, primary-band
// membership and the overflow trapped count.

import CoreGraphics
import Testing
@testable import PelmetCore

struct PlacementGeometryTests {
    let maxX: CGFloat = 1728
    func rect(_ x: CGFloat, width: CGFloat = 30) -> CGRect {
        CGRect(x: x, y: 0, width: width, height: 24)
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
        #expect(PlacementGeometry.betweenCentersX(left: rect(1690), right: rect(1720), screenMaxX: maxX)
            == maxX - 60)
    }

    @Test func primaryBandRejectsOtherDisplaysAndOffBandFrames() {
        #expect(PlacementGeometry.isPrimary(rect(1100), screenMaxX: maxX))
        #expect(!PlacementGeometry.isPrimary(CGRect(x: 1100, y: 500, width: 30, height: 24), screenMaxX: maxX))
        #expect(!PlacementGeometry.isPrimary(rect(-614), screenMaxX: maxX))
        #expect(!PlacementGeometry.isPrimary(rect(1800), screenMaxX: maxX))
    }

    @Test func trappedCountIsEveryFrameSharingAMinX() {
        #expect(PlacementGeometry.overflowTrappedCount([909, 909.2, 950, 1005, 909.1]) == 3)
        #expect(PlacementGeometry.overflowTrappedCount([900, 950, 1005]) == 0)
        #expect(PlacementGeometry.overflowTrappedCount([]) == 0)
    }
}
