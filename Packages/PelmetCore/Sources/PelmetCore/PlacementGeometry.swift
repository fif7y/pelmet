// PlacementGeometry.swift
// Pure neighbour math for Apply's ⌘-drags (see ApplyPass for the
// measurement/verification context) — locked by PlacementGeometryTests.

import CoreGraphics

public enum PlacementGeometry {
    /// Post-drag order check: the item must sit right of its left neighbor
    /// and left of its right one (mids pre-filtered to the item's band;
    /// a missing neighbor imposes no bound).
    public static func inSlot(x: CGFloat, leftMidX: CGFloat?, rightMidX: CGFloat?) -> Bool {
        if let leftMidX, x < leftMidX { return false }
        if let rightMidX, x > rightMidX { return false }
        return true
    }

    /// Target when both slot bounds are live: the midpoint of the bounds'
    /// CENTERS, from raw frames. Valid even when packed icons leave no edge
    /// gap — the drop only needs to land between the mids for the agent to
    /// slot between them (over a day of drags every between-centers drop
    /// landed, 2026-09-09). Hot-corner floor (200) and trailing clamp
    /// (maxX−60) keep the drop off the corners.
    public static func betweenCentersX(left: CGRect, right: CGRect, screenMaxX: CGFloat) -> CGFloat {
        min(max((left.midX + right.midX) / 2, 200), screenMaxX - 60)
    }

    /// Primary-display band membership: an AX walk can carry another
    /// display's bar (its own coordinate origin).
    public static func isPrimary(_ f: CGRect, screenMaxX: CGFloat) -> Bool {
        MenuBarGeometry.isInBand(f) && f.midX > 0 && f.midX < screenMaxX
    }

    /// How many measured items the native « has trapped: the bar overflows
    /// exactly when two or more in-band frames share a minX (real items
    /// never share an x; verified 2026-08-21: 8 trapped separators at
    /// exactly one x). The editor's overflow note reads this.
    public static func overflowTrappedCount(_ minXs: [CGFloat]) -> Int {
        var count = 0
        for (i, x) in minXs.enumerated()
        where minXs.enumerated().contains(where: { $0.offset != i && abs($0.element - x) < 0.5 }) {
            count += 1
        }
        return count
    }
}
