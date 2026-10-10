// PicturePassBatches.swift
// The pure side of the picture pass's follow-up batches (docs/PANEL-PLAN.md
// §8): which drawn frames can be cropped, which wanted items are still
// without a picture, and when another round is worth its time. The pass
// itself (reveals, strips, covers) lives in TransitionCoordinator.
// Locked by PicturePassBatchesTests.

import CoreGraphics

public enum PicturePassBatches {
    /// Rounds after the first full-section one.
    public static let maxFollowUps = 3

    /// What a settled walk drew of the items a round wanted.
    public struct Drawn: Equatable, Sendable {
        /// Wanted items on the bar, clear of every other frame: safe to crop.
        public let solid: [ItemID: CGRect]
        /// Wanted items whose frame overlaps another's. The native « holds
        /// them: the frame is a phantom, and a crop of it would take the
        /// neighbour's pixels (`PlacementGeometry.overflowTrapped`).
        public let phantoms: Set<ItemID>

        public init(solid: [ItemID: CGRect], phantoms: Set<ItemID>) {
            self.solid = solid
            self.phantoms = phantoms
        }
    }

    /// `frames` is every primary-band frame the walk read, wanted or not: a
    /// phantom is told by its neighbours, and one overlapping a visible icon
    /// is as much a phantom as one overlapping another hidden icon. Twins of
    /// one key (title variants) collapse to the leftmost, as the editor's
    /// bar reading does, or they would overlap themselves.
    public static func drawn(wanted: Set<ItemID>, frames: [(key: ItemID, frame: CGRect)]) -> Drawn {
        var byKey: [ItemID: CGRect] = [:]
        for (key, frame) in frames {
            if let existing = byKey[key], existing.minX <= frame.minX { continue }
            byKey[key] = frame
        }
        let entries = Array(byKey)
        let trapped = Set(PlacementGeometry.overflowTrapped(entries.map(\.value)).map { entries[$0].key })
        var solid: [ItemID: CGRect] = [:]
        var phantoms = Set<ItemID>()
        for (key, frame) in entries where wanted.contains(key) {
            if trapped.contains(key) {
                phantoms.insert(key)
            } else {
                solid[key] = frame
            }
        }
        return Drawn(solid: solid, phantoms: phantoms)
    }

    /// Wanted items with no picture yet. What a round did not reach, drew
    /// only as a phantom, or never drew at all.
    public static func leftovers(wanted: Set<ItemID>, pictured: Set<ItemID>) -> Set<ItemID> {
        wanted.subtracting(pictured)
    }

    /// Whether to run another follow-up. None when everything has a picture
    /// (the common case: nothing extra happens), at the cap, or when the
    /// round before pictured nothing new: the same items would draw the same
    /// way. `lastRoundPictured` is ignored before the first follow-up.
    public static func wantsAnotherRound(followUpsDone: Int, leftovers: Set<ItemID>, lastRoundPictured: Int) -> Bool {
        guard !leftovers.isEmpty, followUpsDone < maxFollowUps else { return false }
        return followUpsDone == 0 || lastRoundPictured > 0
    }
}
