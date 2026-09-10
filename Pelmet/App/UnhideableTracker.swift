// UnhideableTracker.swift
// Observed, not inferred: an icon the bar keeps showing after Pelmet's
// assertion concealed its bundle. Structural hints exist (a bundle-less
// helper host — ChatGPT Classic's ChatGPTHelper — can't be matched by the
// allowlist) but they lie in both directions: the same helper-hosted item
// hid fine while the main app ran (2026-09-09). So the editor's "can't hide"
// badge keys on what the bar actually did.

import Foundation
import PelmetCore

struct UnhideableTracker {
    /// Two sightings this far apart, within one conceal episode, promote a
    /// candidate. Covers the assertion's verify window (items drop out of AX
    /// up to ~3s after the swap) without waiting on the next reveal.
    static let confirmation: TimeInterval = 4

    private(set) var confirmed: Set<ItemID> = []
    private var candidates: [ItemID: Date] = [:]

    /// The assertion was torn down externally: forget first sightings, the
    /// next episode starts clean. Verdicts stand — a real stuck icon will
    /// re-confirm, a wrong one clears the moment its bundle hides.
    mutating func assertionLost() {
        candidates.removeAll()
    }

    /// `live` and `concealed` are canonical section keys. An empty
    /// `concealed` set is a revealed bar (nothing to learn — but a new
    /// episode starts, so first-sighting times reset).
    mutating func observe(live: Set<ItemID>, concealed: Set<ItemID>, at now: Date = Date()) {
        guard !concealed.isEmpty else {
            candidates.removeAll()
            return
        }
        let hidden = concealed.subtracting(live)
        // Every concealed item live at once is the assertion gone (macOS
        // tears it down; the engine re-swaps), not nine apps refusing to
        // hide — the false verdict of 2026-09-09 22:17. No lesson here.
        guard !hidden.isEmpty else {
            candidates.removeAll()
            return
        }
        // Concealed and gone from AX: hiding works — clear any verdict.
        for key in hidden {
            candidates.removeValue(forKey: key)
            confirmed.remove(key)
        }
        for key in concealed.intersection(live) {
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
