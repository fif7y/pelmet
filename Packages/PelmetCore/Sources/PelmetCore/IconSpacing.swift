// IconSpacing.swift
// The gap between menu bar icons is macOS's own knob: two per-host global
// preferences (`NSStatusItemSpacing`, `NSStatusItemSelectionPadding`) every
// process reads once, when it creates its status items. Pelmet exposes one
// slider and derives both values here, so the pair can never drift apart.

import Foundation

public enum IconSpacing {
    /// What macOS uses with the keys unset (measured 2026-09-22: 14pt
    /// between two of Pelmet's own items, 16 between Control Center and
    /// the clock).
    public static let macOSDefault = 16
    /// The slider's stops, the default in the middle. The bottom stop is
    /// 1, not 4: macOS takes it (measured 2026-09-23, Pelmet relaunched,
    /// agent restarted: chevron→media 33pt at default, 21 at 4, 18 at 1;
    /// 0 buys one more point and reads as "off", so 1 it is). The stops
    /// are not evenly spaced, so the slider runs on their index.
    public static let steps: [Int] = [1, 4, 8, 12, 16, 20, 24, 28]

    /// The stop nearest a spacing, as a slider position.
    public static func index(of spacing: Int) -> Int {
        steps.indices.min { abs(steps[$0] - spacing) < abs(steps[$1] - spacing) } ?? steps.firstIndex(of: macOSDefault)!
    }

    public static let spacingKey = "NSStatusItemSpacing"
    public static let paddingKey = "NSStatusItemSelectionPadding"

    /// The values to write for a spacing, nil at the default (the keys are
    /// deleted, macOS is back in charge). Padding is the room inside each
    /// icon's hit area: it follows the spacing down so a tight bar reads
    /// tight, and stops at macOS's own value on the way up.
    public static func keys(for spacing: Int) -> (spacing: Int, padding: Int)? {
        guard spacing != macOSDefault else { return nil }
        return (spacing, max(6, min(spacing, macOSDefault)))
    }

    public static func clamped(_ spacing: Int) -> Int {
        steps.min { abs($0 - spacing) < abs($1 - spacing) } ?? macOSDefault
    }
}
