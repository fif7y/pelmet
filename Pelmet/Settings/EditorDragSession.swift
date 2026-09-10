// EditorDragSession.swift
// One drag session shared by the three editor strips: which tile is lifted
// and where it would land right now. Each strip is a SINGLE drop target that
// tracks the cursor continuously (DropDelegate.dropUpdated) and moves one
// placeholder by the midpoint rule — the previous per-tile nested targets
// re-padded a different tile on every crossing (with a no-target frame in
// each 6pt gap), so a drag across a row reflowed it three times per tile
// and read as jitter.

import AppKit
import PelmetCore
import PelmetEngine
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class EditorDragSession {
    enum Payload: Equatable {
        /// A tile lifted from `home`, which sat at `homeIndex` in that strip.
        case item(ItemID, home: PelmetCore.Section, homeIndex: Int)
        case newItemsChip
    }

    struct Target: Equatable {
        let section: PelmetCore.Section
        /// Insertion index among the strip's tiles with the lifted one removed.
        let index: Int
    }

    private(set) var payload: Payload?
    var target: Target?
    private var endWatcher: Task<Void, Never>?

    var liftedItem: ItemID? {
        if case .item(let id, _, _) = payload { return id }
        return nil
    }

    func begin(_ payload: Payload) {
        PelmetLog.log("editor-drag: begin \(payload)")
        self.payload = payload
        target = nil
        endWatcher?.cancel()
        // SwiftUI exposes no drag-end hook and the drop delegate only fires
        // on a landing; a drop outside every strip would leave the tile
        // lifted forever. Watch the button instead.
        endWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if NSEvent.pressedMouseButtons == 0 {
                    // Let a landing's performDrop run first.
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    self?.end(reason: "button up (buttons=\(NSEvent.pressedMouseButtons))")
                    return
                }
            }
        }
    }

    func end(reason: String) {
        if payload != nil { PelmetLog.log("editor-drag: end — \(reason)") }
        endWatcher?.cancel()
        endWatcher = nil
        payload = nil
        target = nil
    }
}

/// Pure insertion math over measured tile frames (strip coordinates), so
/// it's testable without SwiftUI. Tiles wrap into rows; the row under the
/// cursor (or the nearest one) is scanned left→right and the cursor lands
/// before the first tile whose midpoint it hasn't passed. Frames are the
/// LIVE ones — with the placeholder already inserted — which is what makes
/// the rule stable: moving the placeholder past a tile shifts that tile
/// away from the cursor, never back under it.
///
/// A strip packs from the END (`FlowLayout(trailing:)`), so the TOP row
/// holds the highest indices and index 0 is the bottom row's leftmost tile.
/// A row's base index is therefore everything BELOW it, not above.
nonisolated enum EditorInsertion {
    static func index(at point: CGPoint, order: [ItemID], frames: [ItemID: CGRect]) -> Int {
        let placed = order.compactMap { id in frames[id].map { (id: id, frame: $0) } }
        guard !placed.isEmpty else { return 0 }

        var rows: [[(id: ItemID, frame: CGRect)]] = []
        for entry in placed.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            if let last = rows.last?.last, abs(last.frame.minY - entry.frame.minY) < 2 {
                rows[rows.count - 1].append(entry)
            } else {
                rows.append([entry])
            }
        }

        func distance(_ row: [(id: ItemID, frame: CGRect)]) -> CGFloat {
            let f = row[0].frame
            if point.y < f.minY { return f.minY - point.y }
            if point.y > f.maxY { return point.y - f.maxY }
            return 0
        }
        let rowIndex = rows.indices.min { distance(rows[$0]) < distance(rows[$1]) } ?? 0
        let row = rows[rowIndex].sorted { $0.frame.minX < $1.frame.minX }
        let below = rows[(rowIndex + 1)...].reduce(0) { $0 + $1.count }
        let within = row.firstIndex { point.x < $0.frame.midX } ?? row.count
        return below + within
    }
}

/// The strip's drop target. Holds no state of its own: reads the session
/// and the strip's measured frames through closures so SwiftUI can rebuild
/// it freely.
struct StripDropDelegate: DropDelegate {
    let section: PelmetCore.Section
    let session: EditorDragSession
    let order: () -> [ItemID]
    let frames: () -> [ItemID: CGRect]
    let onDrop: (EditorDragSession.Payload, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        if session.payload == nil { PelmetLog.log("editor-drag: \(section) refused — no session") }
        return session.payload != nil
    }

    func dropEntered(info: DropInfo) {
        track(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if session.target?.section == section { session.target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload = session.payload else {
            PelmetLog.log("editor-drag: drop with no session")
            return false
        }
        let index = session.target?.section == section
            ? session.target!.index
            : EditorInsertion.index(at: info.location, order: order(), frames: frames())
        PelmetLog.log("editor-drag: drop → \(section) index=\(index)")
        session.end(reason: "drop")
        onDrop(payload, index)
        return true
    }

    private func track(_ info: DropInfo) {
        // SwiftUI sends one more dropUpdated ~300ms after performDrop; with
        // no session it must not re-target the strip (highlight would stick).
        guard session.payload != nil else { return }
        // The chip always lands at the strip's far left — only the strip
        // highlight matters, not a slot.
        let index = session.payload == .newItemsChip
            ? 0
            : EditorInsertion.index(at: info.location, order: order(), frames: frames())
        let target = EditorDragSession.Target(section: section, index: index)
        if session.target != target { session.target = target }
    }
}
