// OrderDrift.swift
// The order supervisor's judgement: which live items sit on the wrong side
// of the chevron for the section the model gives them. Pure — the app layer
// decides when to measure (a reveal settle, with the hidden cluster
// materialized) and how to correct (a placement drag under that reveal).
//
// Why a supervisor at all: the agent keeps a concealed item's place as a
// remembered position, not a slot. Any move that shifts the chevron while
// hidden items are absent strands the ones next to it on the visible side
// at the next reveal (Snib, 2026-09-09: an own-item drag across the chevron
// moved it 38pt left, past Snib's remembered x). Adoption correctly refuses
// to move such an item into Visible (it was not user-dragged), so without a
// physical correction the drift is permanent.

import CoreGraphics

public enum OrderDrift {
    /// Ids whose measured side of the chevron disagrees with the model:
    /// hidden/always-hidden items measured right of the chevron, visible
    /// ones measured left of it. Unmeasured items (nil minX), the chevron
    /// itself, and anything the agent pins (system modules, Apple bundles)
    /// are never reported — a correction has to be a drag we can perform.
    public static func misplaced(
        items: [(id: ItemID, minX: CGFloat?)],
        chevronMinX: CGFloat,
        model: SectionModel,
        pelmetBundleID: String
    ) -> [ItemID] {
        items.compactMap { entry in
            guard let minX = entry.minX,
                  let bundle = entry.id.bundleID,
                  !entry.id.isSystemModule,
                  !MenuBarPolicy.isUnmanagedAppleBundle(bundle),
                  MenuBarPolicy.isZoneAdoptable(entry.id, pelmetBundleID: pelmetBundleID)
            else { return nil }
            let leftOfChevron = minX < chevronMinX
            switch model.section(of: entry.id) {
            case .visible:
                return leftOfChevron ? entry.id : nil
            case .hidden, .alwaysHidden:
                return leftOfChevron ? nil : entry.id
            }
        }
    }

    /// Pelmet-owned items (extras, stand-ins, separators) measured outside
    /// the slot their section order gives them: left of their nearest
    /// measured left neighbor, or right of their nearest measured right one.
    /// Own items re-enter layout at the agent's remembered POSITION on every
    /// reveal, and adoption holds their model slot, so without a physical
    /// correction the bar and the editor disagree for good (a Comet stand-in
    /// sat left of Vorssaint while the model had it after Snib, 2026-09-09).
    public static func ownItemsOutOfOrder(
        items: [(id: ItemID, minX: CGFloat?)],
        model: SectionModel,
        pelmetBundleID: String
    ) -> [ItemID] {
        let x: [ItemID: CGFloat] = items.reduce(into: [:]) {
            guard let minX = $1.minX else { return }
            let key = $1.id.sectionKey
            $0[key] = min($0[key] ?? .greatestFiniteMagnitude, minX)
        }
        return items.compactMap { entry in
            guard let minX = entry.minX,
                  entry.id.bundleID == pelmetBundleID,
                  MenuBarPolicy.isPelmetExtraID(entry.id)
            else { return nil }
            let order = model.order[model.section(of: entry.id)] ?? []
            guard let index = order.firstIndex(of: entry.id.sectionKey) else { return nil }
            let left = order[..<index].reversed().lazy.compactMap { x[$0] }.first
            let right = order[(index + 1)...].lazy.compactMap { x[$0] }.first
            if let left, minX < left { return entry.id }
            if let right, minX > right { return entry.id }
            return nil
        }
    }
}
