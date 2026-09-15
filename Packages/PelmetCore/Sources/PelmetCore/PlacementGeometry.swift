// PlacementGeometry.swift
// Pure target math for synthetic ⌘-drag placement. Constants here are
// choreography tuned live against the agent (see PlacementController for the
// measurement/verification context) — locked by PlacementGeometryTests.
// The predicates below were lifted out of `physicallyPlaceNow`'s nested
// closures (2026-09-14) so each judgement is a function over values.

import CoreGraphics

public enum PlacementGeometry {
    /// Target X for a drop: neighbor-midpoint when both sides are live,
    /// one-sided ±14pt offsets, or chevron-anchored zone fallbacks
    /// (−20/−15/+25) — then the hot-corner floor (200) / trailing clamp
    /// (maxX−60), and the chevron side constraint (±12) applied LAST: the
    /// corner floor once pushed a hidden-section target right of a far-left
    /// chevron, dropping the item into the wrong side. Nil when there is
    /// nothing to anchor against (no neighbors and no chevron).
    public static func targetX(
        leftNeighbor: CGRect?,
        rightNeighbor: CGRect?,
        chevron: CGRect?,
        section: Section,
        managedMinX: CGFloat?,
        systemMinX: CGFloat? = nil,
        screenMaxX: CGFloat
    ) -> CGFloat? {
        var targetX: CGFloat
        switch (leftNeighbor, rightNeighbor) {
        case (let left?, let right?) where left.maxX < right.minX:
            targetX = (left.maxX + right.minX) / 2
        case (let left?, _):
            targetX = left.maxX + 14
        case (_, let right?):
            targetX = right.minX - 14
        default:
            guard let chevron else { return nil }
            let anchor = managedMinX ?? chevron.minX
            switch section {
            case .alwaysHidden: targetX = anchor - 20
            case .hidden: targetX = chevron.minX - 15
            case .visible: targetX = chevron.maxX + 25
            }
        }
        // Never approach screen corners (hot corners: Mission Control) or
        // leave the trailing status area.
        targetX = min(max(targetX, 200), screenMaxX - 60)
        if let chevron {
            switch section {
            case .visible:
                targetX = max(targetX, chevron.maxX + 12)
            case .hidden, .alwaysHidden:
                targetX = min(targetX, chevron.minX - 12)
            }
        }
        // The trailing system cluster (Control Center, Clock, pinned
        // menuextras) is protected — even a real ⌘-drag can't drop right of
        // it. Model order can still place an item "before" a system member
        // (system items hide/show but never physically move), which computes
        // a target inside the cluster; the closest POSSIBLE slot is just
        // left of it. Verified live 2026-08-21: drops at 1492/1522 (inside
        // the cluster) bounced entirely.
        if let systemMinX {
            targetX = min(targetX, systemMinX - 12)
        }
        return targetX
    }

    /// Post-drag order check: the item must sit right of its left neighbor
    /// and left of its right one (mids pre-filtered to the item's band;
    /// a missing neighbor imposes no bound).
    public static func inSlot(x: CGFloat, leftMidX: CGFloat?, rightMidX: CGFloat?) -> Bool {
        if let leftMidX, x < leftMidX { return false }
        if let rightMidX, x > rightMidX { return false }
        return true
    }

    /// Primary target when both slot bounds are live: the midpoint of the
    /// bounds' CENTERS, from raw (unlifted) frames. Valid even when packed
    /// icons leave no edge gap — the drop only needs to land between the
    /// mids for the agent to slot between them. Promoted from retry to first
    /// attempt 2026-09-09: over a day of placements every anchored first
    /// drag missed (the system-cluster clamp aimed Media controls at 1493 for
    /// a slot at 1574) and every between-centers retry landed. Same corner
    /// clamps as `targetX`.
    public static func betweenCentersX(left: CGRect, right: CGRect, screenMaxX: CGFloat) -> CGFloat {
        min(max((left.midX + right.midX) / 2, 200), screenMaxX - 60)
    }

    // MARK: - Predicates lifted from the drag sequence

    /// Only a frame in the SAME menu-bar band as the dragged item, on the
    /// primary display, is trustworthy: an AX walk can carry another
    /// display's bar (its own coordinate origin), and one foreign neighbor
    /// frame aimed a drop at x=268 on a status area that starts around
    /// x=1050.
    public static func inBand(_ f: CGRect, of dragged: CGRect, screenMaxX: CGFloat) -> Bool {
        MenuBarGeometry.isInBand(f)
            && abs(f.midY - dragged.midY) < 30
            && f.midX > 0 && f.midX < screenMaxX
    }

    /// Primary-display band membership with no dragged item to align to.
    public static func isPrimary(_ f: CGRect, screenMaxX: CGFloat) -> Bool {
        MenuBarGeometry.isInBand(f) && f.midX > 0 && f.midX < screenMaxX
    }

    /// A trapped-in-overflow registration reports a phantom frame sharing
    /// its minX with another item in the same band — real items never share
    /// an x (verified 2026-08-21: 8 trapped separators at exactly one x).
    public static func isPhantom(_ frame: CGRect, amongOthers others: some Sequence<CGRect>) -> Bool {
        others.contains { abs($0.minX - frame.minX) < 0.5 && abs($0.midY - frame.midY) < 30 }
    }

    /// A neighbor frame in the "lifted" coordinate space: once the drag
    /// picks the item up the gap it leaves closes, shifting everything
    /// right of its origin left by one item width. EXCEPT for Pelmet's own
    /// items: dragging an own-process item keeps the bar frozen, the gap
    /// does not close (verified: raw-frame drop swaps, lifted-frame drop
    /// reverts).
    public static func lifted(_ neighbor: CGRect, dragged: CGRect, ownItem: Bool) -> CGRect {
        guard !ownItem, neighbor.minX > dragged.midX else { return neighbor }
        return neighbor.offsetBy(dx: -dragged.width, dy: 0)
    }

    /// The desired order has no chevron in it, so a LAST-of-Hidden item's
    /// right neighbor is the first Visible one — "between Snib and Sound"
    /// holds on BOTH sides of the chevron. At the hidden/visible boundary
    /// the live chevron caps the slot instead; mirror for first-of-Visible.
    /// `index` is the item's slot in the global order, `leftIdx`/`rightIdx`
    /// its live neighbors' slots (nil when none).
    public static func chevronCaps(
        index: Int, leftIdx: Int?, rightIdx: Int?,
        alwaysHiddenEnd: Int, hiddenEnd: Int
    ) -> (left: Bool, right: Bool) {
        let right = index >= alwaysHiddenEnd && index < hiddenEnd
            && (rightIdx.map { $0 >= hiddenEnd } ?? true)
        let left = index >= hiddenEnd
            && (leftIdx.map { $0 < hiddenEnd } ?? true)
        return (left, right)
    }

    /// Already at its slot? With both bounds live the slot is an ORDER:
    /// strictly between the bound centers, with a margin — a freshly hosted
    /// own item can report the very x of its neighbor (Media controls at
    /// Sound's 1554, 2026-09-09) and must still be dragged. Without both
    /// bounds fall back to x proximity: a full icon-width tolerance silently
    /// swallowed every one-slot move, so 10pt — except with NO live
    /// neighbors, where the target is a zone-approximate chevron fallback
    /// and chasing it exactly just bounces (40pt).
    public static func alreadyAtSlot(
        x: CGFloat, leftMidX: CGFloat?, rightMidX: CGFloat?,
        targetX: CGFloat, fallbackTarget: Bool
    ) -> Bool {
        if let leftMidX, let rightMidX, leftMidX < rightMidX {
            return leftMidX + 2 < x && x < rightMidX - 2
        }
        return abs(x - targetX) < (fallbackTarget ? 40 : 10)
    }

    /// The hidden zone is untouchable while its items are absent: a drag
    /// that starts or ends left of the chevron shifts it past a concealed
    /// item's remembered position (Snib, 2026-09-09).
    public static func touchesHiddenZone(x: CGFloat, targetX: CGFloat, chevronMidX: CGFloat) -> Bool {
        x < chevronMidX || targetX < chevronMidX
    }
}
