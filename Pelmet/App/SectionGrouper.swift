// SectionGrouper.swift
// "Keep sections grouped" (docs/CORE-SETS.md, #80). Pelmet hides by
// membership and the bar's physical order is the truth, so an icon whose
// side of the chevron disagrees with its section (a relaunched app macOS put
// on the wrong side, an editor drop across sections: membership changed,
// nothing moved) looks fine collapsed and reappears on the wrong side at
// the next reveal, shifting the visible icons. This watches for those
// strays and relocates only them through the Apply door
// (`ApplyPass.Scope.strays`: input idle, cursor hidden, input suppressed).
//
// Only a stray Pelmet can explain is moved (`StrayLedger`): one newly seen,
// relaunched, or whose section changed while its side did not. An icon whose
// side flipped by hand (a user ⌘-drag BarAdoption could not read, a drop from
// another display) stays where the user put it. Never re-sorts within a
// section, never reads the pending editor `OrderEdits`. Bounded:
// `StrayBudget` allows two attempts per item and section, then the item is
// left to the editor's "not in place" badge and Apply. On by default; the
// escape hatch is the `pelmet.keepSectionsGrouped` bool (false = no
// synthetic drag outside Apply).
//
// Logging: a state is logged once per change (`group: no strays`,
// `group: N stray(s) …`, `group: waiting — <why>`), so a blocked pass is
// never silent and a quiet bar is not noisy.

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class SectionGrouper {
    static let defaultsKey = "pelmet.keepSectionsGrouped"
    /// Missing = on: no Settings UI, the key is the escape hatch.
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private weak var appState: AppState?
    private var pending: Task<Void, Never>?
    /// When the first change not yet checked arrived (see `groupingMaxWait`).
    private var changedSince: ContinuousClock.Instant?
    private var lastRoster: Roster?
    private var budget = StrayBudget()
    private var ledger = StrayLedger()
    /// What the last pass tried to move: their side flips are ours.
    private var ownMoves: Set<ItemID> = []
    private var passRunning = false
    private var lastState = ""
    private var lastWaiting: String?
    private var observers: [NSObjectProtocol] = []
    private var menuDepth = 0
    private var menuBeganAt: Date?
    private var menuEndedAt: Date?

    init(appState: AppState) {
        self.appState = appState
    }

    /// AppKit posts these for every menu this process tracks: the status
    /// item's and separators' context menus, Settings' pop-up pickers.
    func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.menuDepth == 0 { self.menuBeganAt = .now }
                    self.menuDepth += 1
                }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuDepth = max(0, self.menuDepth - 1)
                    if self.menuDepth == 0 { self.menuEndedAt = .now }
                }
            },
        ]
        if !Self.isOn { note("group: off (\(Self.defaultsKey))") }
    }

    /// A menu is tracking, or just was (it fades for a beat). A depth that
    /// never came back down is not trusted past five minutes.
    var menuIsOpen: Bool {
        if menuDepth > 0, let began = menuBeganAt, Date.now.timeIntervalSince(began) < 300 { return true }
        if let ended = menuEndedAt, Date.now.timeIntervalSince(ended) < AppTiming.groupingMenuHold { return true }
        return false
    }

    /// The owner of an on-screen window at the pop-up-menu level, from any
    /// process: another app's open menu (or a popover-menu ItemPress opened)
    /// that no notification of ours announces. Narrow like the band
    /// monitor's elevated-window test: visible and menu-sized, since helper
    /// apps keep invisible windows at high levels.
    static func popUpMenuOwner() -> String? {
        guard let list = ConcealGhostOverlay.onScreenWindows() else { return nil }
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == level,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"], width > 20, height > 12
            else { continue }
            return w[kCGWindowOwnerName as String] as? String ?? "pid \(w[kCGWindowOwnerPID as String] ?? "?")"
        }
        return nil
    }

    /// The roster was assigned: look again only if it actually changed.
    func noteRoster(_ roster: Roster) {
        guard roster != lastRoster else { return }
        lastRoster = roster
        noteChange()
    }

    /// The bar or the roster changed: look again once it has been quiet, and
    /// at the latest `groupingMaxWait` after the first change nobody has
    /// looked at yet.
    func noteChange() {
        guard Self.isOn else {
            pending?.cancel()
            pending = nil
            note("group: off (\(Self.defaultsKey))")
            return
        }
        let now = ContinuousClock.now
        let first = changedSince ?? now
        changedSince = first
        let left = AppTiming.groupingMaxWait - first.duration(to: now)
        schedule(after: min(AppTiming.groupingDebounce, max(.zero, left)))
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await check()
        }
    }

    private func note(_ line: String) {
        guard line != lastState else { return }
        lastState = line
        PelmetLog.log(line)
    }

    private func check() async {
        // The pass below must not be cancelled by the snapshots it causes:
        // `noteChange` cancels `pending`, and a cancelled sleep inside the
        // pass returns at once.
        pending = nil
        changedSince = nil
        guard !passRunning else { return }
        guard Self.isOn, let appState, let snap = appState.snapshot else { return }
        guard appState.pelmetChevronItem(in: snap) != nil else {
            note("group: no chevron on the bar — nothing to group against")
            return
        }
        let roster = appState.settings.sectionModel.roster
        lastRoster = roster
        let strays = ApplyPass.strays(for: appState, snapshot: snap)
        // Looks first, so a flip is judged against the last look and not
        // against what this check is about to do.
        let byHand = ledger.observe(
            ApplyPass.sightings(for: appState, snapshot: snap), strays: Set(strays), ownMoves: ownMoves
        )
        ownMoves = []
        for id in byHand where strays.contains(id) {
            PelmetLog.log("group: \(id.rawValue) moved by hand — left where it is")
        }
        let verdict = budget.check(ledger.actionable(strays), roster: roster)
        if !verdict.newlyExhausted.isEmpty {
            PelmetLog.log("group: giving up on [\(Self.names(verdict.newlyExhausted))] after \(budget.limit) attempts — left to Apply")
        }
        guard !strays.isEmpty else {
            lastWaiting = nil
            note("group: no strays")
            return
        }
        let ready = verdict.ready
        guard !ready.isEmpty else {
            lastWaiting = nil
            note("group: \(strays.count) stray(s) [\(Self.names(strays))] — none to move (by hand, or out of attempts)")
            return
        }
        note("group: \(ready.count) stray(s) [\(Self.names(ready))]")
        if let gate = appState.groupingGate() {
            if lastWaiting != gate.why {
                lastWaiting = gate.why
                PelmetLog.log("group: waiting — \(gate.why)")
            }
            // Transient gates clear on their own: look again on the beat.
            // The others end with a snapshot or roster change.
            if gate.transient { schedule(after: AppTiming.groupingDebounce) }
            return
        }
        lastWaiting = nil
        PelmetLog.log("group: relocating [\(Self.names(ready))] (attempt \(budget.used(ready[0], roster: roster) + 1)/\(budget.limit))")
        lastState = ""
        passRunning = true
        ownMoves = Set(ready)
        let report = await appState.runGroupingPass(allowing: Set(ready))
        passRunning = false
        guard let report, !report.abandoned else {
            // Nothing was dragged (an Apply pass has the bar, or the user
            // came back): not our flips, and no attempt spent.
            ownMoves = []
            schedule(after: AppTiming.groupingDebounce)
            return
        }
        budget.spend(ready, roster: roster)
        PelmetLog.log("group: pass applied=\(report.applied.count) failed=\(report.failed.count) skipped=\(report.skipped.count)")
        // Look again: a second attempt for what stayed, or "no strays".
        schedule(after: AppTiming.groupingDebounce)
    }

    private static func names(_ ids: [ItemID]) -> String {
        ids.map(\.rawValue).joined(separator: ", ")
    }
}
