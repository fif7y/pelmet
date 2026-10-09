// RevealRouting.swift
// Where hidden icons show up when a reveal fires (docs/PANEL-PLAN.md §2): the
// menu bar as today, or a panel. The panel is a second way to show the same
// sections, not a second reveal: the rehide machine still owns revealed /
// concealed, and this only decides which presenter draws it.

import Foundation

/// What the user chose for "Show hidden icons in". Stored in the settings
/// blob, so an unknown raw value (a newer build's, hand-edited) reads as the
/// menu bar: a downgrade lands on the behaviour every build has.
public enum RevealTarget: String, Codable, CaseIterable, Sendable {
    case menuBar
    case panel
    /// The panel as one row of bar-scale icons.
    case row

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RevealTarget(rawValue: raw) ?? .menuBar
    }

    /// How the panel lays tiles out for this target; nil when the icons stay
    /// in the bar.
    public var panelLayout: PanelGrid.Layout? {
        switch self {
        case .menuBar: nil
        case .panel: .panel
        case .row: .row
        }
    }
}

public enum RevealRouting {
    public enum Destination: Equatable, Sendable {
        case bar
        case panel
    }

    /// Reveals a person asks for follow the setting. The rest need the real
    /// bar: Apply and the editor's preview measure and drag icons that are on
    /// it, a ⌘-drag needs the hidden run as a drop target, the always-show
    /// policy is "don't hide anything here", and an item asked for in the bar
    /// is the point. No `default:`, so a new reason has to pick a side.
    public static func destination(for reason: RevealReason, target: RevealTarget) -> Destination {
        switch reason {
        case .hover, .click, .doubleClick, .hotkey, .statusItem:
            target == .menuBar ? .bar : .panel
        case .displayPolicy, .settingsPreview, .barDrag, .itemInBar:
            .bar
        }
    }
}
