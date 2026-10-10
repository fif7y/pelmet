// PanelKeys.swift
// The panel's keys, shared by the open panel and the Settings preview:
// type to filter, arrows along the grids, Return opens, Esc clears.

import AppKit
import PelmetCore
import SwiftUI

enum PanelKey {
    case escape, enter, delete
    case move(PanelGrid.Direction)
    case type(String)

    /// The open panel's key, from its monitor.
    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 53: self = .escape
        case 36, 76: self = .enter  // Return, Enter
        case 51: self = .delete
        case 123: self = .move(.left)
        case 124: self = .move(.right)
        case 125: self = .move(.down)
        case 126: self = .move(.up)
        default:
            guard event.modifierFlags.intersection([.command, .control]).isEmpty, let typed = event.characters
            else { return nil }
            self = .type(typed)
        }
    }

    /// The preview's key, from SwiftUI.
    init?(_ press: KeyPress) {
        switch press.key {
        case .escape: self = .escape
        case .return, KeyEquivalent("\u{3}"): self = .enter  // Return, Enter
        case .delete: self = .delete
        case .leftArrow: self = .move(.left)
        case .rightArrow: self = .move(.right)
        case .downArrow: self = .move(.down)
        case .upArrow: self = .move(.up)
        default:
            guard press.modifiers.intersection([.command, .control]).isEmpty else { return nil }
            self = .type(press.characters)
        }
    }

    /// `query` with `typed` added, or nil when the key types nothing: a
    /// function key, a space before any letter.
    static func query(_ query: String, typing typed: String) -> String? {
        guard !typed.isEmpty,
              // Function keys type private-use characters.
              typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }),
              !(query.isEmpty && typed == " ")
        else { return nil }
        return query + typed
    }
}

/// Where an arrow takes the selection.
enum PanelStep {
    case select(PanelTile)
    /// Down past the last section, with Always Hidden folded.
    case unfold
    case stay
}

extension PanelContent {
    /// Along the section's grid; off its edge into the next section, and
    /// down past the last one opens a folded Always Hidden. With nothing
    /// selected, the first tile.
    func step(from selected: PanelTile?, toward direction: PanelGrid.Direction) -> PanelStep {
        let grids = blocks.filter { !$0.isFolded }.map(\.grid)
        func select(_ tile: PanelTile?) -> PanelStep { tile.map(PanelStep.select) ?? .stay }
        guard let current = selected, let g = grids.firstIndex(where: { $0.placement(of: current) != nil }),
              let here = grids[g].placement(of: current)
        else { return select(grids.lazy.compactMap(\.firstTile).first) }
        if let next = grids[g].neighbour(of: current, toward: direction) { return .select(next) }
        func atColumn(_ row: [PanelGrid.Placement]?) -> PanelTile? {
            guard let row, !row.isEmpty else { return nil }
            return row[min(here.column, row.count - 1)].tile
        }
        switch direction {
        case .right where g + 1 < grids.count: return select(grids[g + 1].firstTile)
        case .left where g > 0: return select(grids[g - 1].rows.last?.last?.tile)
        case .down where g + 1 < grids.count: return select(atColumn(grids[g + 1].rows.first))
        case .up where g > 0: return select(atColumn(grids[g - 1].rows.last))
        case .down where blocks.contains(where: \.isFolded): return .unfold
        default: return .stay
        }
    }
}
