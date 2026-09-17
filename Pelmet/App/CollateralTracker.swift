// CollateralTracker.swift
// The inverse of UnhideableTracker: an icon the bar DESTROYED although
// Pelmet's allowlist protects it.
//
// macOS 27's MenuBarAgent resolves no registered host for a status item whose
// app runs from outside /Applications — iStat Menus 7 keeps its menu bar
// helper in ~/Library/Application Support — and logs the item's bundle
// identifier as nil ("Host or location not found for disallowing status item:
// nil"). A nil identifier can never match an entry in the assessment
// assertion's allowlist, so the agent treats the item as an assessment
// violation and unregisters its scenes, however diligently Pelmet allows the
// bundle (issue #30, root-caused by ShawnRn with a /Applications symlink that
// made the same items survive the same assertion).
//
// Pelmet can't stop that — the resolution happens inside the agent. What it
// can do is stop LOSING the item: the icon is unassigned, so the editor's
// stored-tile path never held it; it is not in Pelmet's concealed set,
// because Pelmet never asked for it; and its AX frame is gone. It fell
// through every branch of EditorItemsBuilder and showed up under neither
// Visible nor Hidden. A confirmed casualty keeps its tile and wears the
// "can't hide" badge, so the user can at least see it and reach for a
// launcher.
//
// Observed, not inferred, for the same reason UnhideableTracker is: structural
// hints (the bundle path) point the right way but not reliably enough to
// accuse an app on their own. The verdict keys on what the bar actually did.

import Foundation
import PelmetCore

struct CollateralTracker {
    /// Two sightings this far apart, within one conceal episode, promote a
    /// candidate — long enough that the AX drop-out latency around a swap
    /// (items leave the tree for up to ~3s) can't be mistaken for a kill.
    static let confirmation: TimeInterval = 4

    private(set) var confirmed: Set<ItemID> = []
    private var candidates: [ItemID: Date] = [:]
    /// Canonical keys seen live at least once this session — the only items
    /// that can go missing. Without it a bundle that never had an icon would
    /// look like a casualty forever.
    private var everSeen: Set<ItemID> = []

    /// The assertion was torn down externally: forget first sightings, the
    /// next episode starts clean. Verdicts stand — a real casualty
    /// re-confirms, a wrong one clears the moment its icon is back.
    mutating func assertionLost() {
        candidates.removeAll()
    }

    /// `live` are the canonical section keys of third-party items in the bar
    /// right now. `concealing` are the bundles Pelmet's assertion is
    /// deliberately hiding — anything in there is missing on purpose.
    /// An empty `concealing` is a revealed bar: nothing is hidden, so
    /// nothing can have been killed for being hidden.
    mutating func observe(
        live: Set<ItemID>,
        concealing: Set<String>,
        running: (String) -> Bool,
        at now: Date = Date()
    ) {
        everSeen.formUnion(live)
        // The app quit: it owes the bar no icon. Drops the verdict and the
        // memory of ever having seen it, so a relaunch starts clean.
        let gone = everSeen.filter { $0.bundleID.map { !running($0) } ?? true }
        for key in gone {
            everSeen.remove(key)
            candidates.removeValue(forKey: key)
            confirmed.remove(key)
        }
        guard !concealing.isEmpty else {
            candidates.removeAll()
            return
        }
        // Back in the bar under a live assertion: nothing killed it.
        for key in live {
            candidates.removeValue(forKey: key)
            confirmed.remove(key)
        }
        let missing = everSeen.subtracting(live).filter { key in
            guard let bundle = key.bundleID else { return false }
            return !concealing.contains(bundle)
        }
        // Every protected item missing at once is the bar between states
        // (a swap's AX latency, an adoption window), not a mass killing —
        // the same false-verdict guard UnhideableTracker learned on
        // 2026-09-09. A real casualty is a minority of a populated bar.
        guard !live.isEmpty else {
            candidates.removeAll()
            return
        }
        for key in missing {
            if let first = candidates[key] {
                if now.timeIntervalSince(first) >= Self.confirmation {
                    confirmed.insert(key)
                }
            } else {
                candidates[key] = now
            }
        }
    }
}
