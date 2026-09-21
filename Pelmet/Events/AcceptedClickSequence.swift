// AcceptedClickSequence.swift
// Tracks only clicks Pelmet accepted as empty-menu-bar clicks. NSEvent's
// clickCount also includes clicks rejected by our hit tests (for example a
// status-item popover shadow overlapping the bottom of the menu bar), so it
// cannot by itself decide whether Pelmet received a deliberate double click.

import Foundation

struct AcceptedClickSequence {
    private var firstAcceptedAt: TimeInterval?

    mutating func reset() {
        firstAcceptedAt = nil
    }

    /// Returns Pelmet's logical click count. A raw second/triple click is a
    /// double only when the preceding click was also accepted by Pelmet and
    /// is still inside the system double-click interval.
    mutating func accept(
        rawCount: Int,
        timestamp: TimeInterval,
        doubleClickInterval: TimeInterval
    ) -> Int {
        if let firstAcceptedAt,
           rawCount >= 2,
           timestamp >= firstAcceptedAt,
           timestamp - firstAcceptedAt <= doubleClickInterval {
            self.firstAcceptedAt = timestamp
            return 2
        }
        firstAcceptedAt = timestamp
        return 1
    }
}
