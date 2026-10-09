// RevealPresenter.swift
// The seam between "the rehide machine decided to show these sections" and
// how they get shown (docs/PANEL-PLAN.md §2). The machine still owns revealed
// and concealed; a presenter only draws it. Today the bar is the only one.

import PelmetCore

@MainActor
protocol RevealPresenter: AnyObject {
    func reveal(_ sections: Set<PelmetCore.Section>, trace: PerfTrace)
    func conceal(trace: PerfTrace)
}

/// The menu bar itself: the covers, the assertion swap and the pictures, as
/// `TransitionCoordinator` has always run them.
@MainActor
final class BarPresenter: RevealPresenter {
    private let transitions: TransitionCoordinator

    init(transitions: TransitionCoordinator) {
        self.transitions = transitions
    }

    func reveal(_ sections: Set<PelmetCore.Section>, trace: PerfTrace) {
        transitions.performReveal(sections, trace: trace)
    }

    func conceal(trace: PerfTrace) {
        transitions.performConceal(trace: trace)
    }
}
