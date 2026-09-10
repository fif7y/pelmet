// BarAdoption.swift
// Pure bar→model reconciliation for a user's native ⌘-drag: menubar-positional
// sections keyed off Pelmet's chevron (the visible/hidden boundary), zone-CHANGE
// detection against the last pass, and within-section order fold-in.
// Extracted from AppState so the confidence rules and order reconciliation are
// unit-testable; the app shim replays `log` into PelmetLog and persists `model`.

import CoreGraphics
import Foundation

public enum BarAdoption {
    public struct Result: Sendable {
        public let model: SectionModel
        /// Zone tracking to carry into the next pass (confident measurements
        /// only — a guessed zone must never become a baseline).
        public let zones: [String: Section]
        /// Where the chevron measured this pass — the next pass compares.
        public let chevronX: CGFloat?
        /// Where each measured item sat this pass — an item that moved
        /// since the last pass was dragged, whatever the chevron did.
        public let positions: [String: CGFloat]
        /// Zone readings that disagreed with the baseline this pass and wait
        /// for the next pass to agree before they adopt.
        public let pendingZones: [String: Section]
        public let changed: Bool
        public let log: [String]
    }

    /// Reconcile the observed bar against the model. `items` is every
    /// observed item with its frame's minX (nil when concealed/unmeasured),
    /// in snapshot order. Without a measurable chevron (the user can hide
    /// Pelmet's status item entirely) the clusters themselves are the only
    /// boundary: an item measured at/right of the visible cluster's left edge
    /// reads visible, one at/left of the concealable clusters' right edge
    /// reads into the hidden side, and the gap between them is ambiguous —
    /// the model's word stands. Cluster edges are computed from the (stale,
    /// mid-drag) model, so the dragged item itself poisons every OTHER item's
    /// reading — chevron-less zone adoption therefore applies ONLY to
    /// `draggedID` (the item the band monitor saw ⌘-dragged, whose
    /// self-excluded pools are clean); everyone else still gets confident
    /// readings folded into the zone baseline. The within-section order
    /// fold-in needs only live frames and always runs.
    ///
    /// Anything sitting LEFT of the chevron (smaller AX x) is adopted into
    /// Hidden; right of it back to Visible. Always-Hidden has no physical
    /// marker of its own; its live cluster IS the boundary — an item dropped
    /// among/left of always-hidden members (only visible during a full
    /// reveal) adopts in, one dropped among the hidden cluster adopts out.
    /// Reflows shift every frame but never an item's relative position — only
    /// a real user drag does. That makes zone-CHANGE the safe adoption
    /// trigger: a settings-assigned item still sitting in its old zone is
    /// never "corrected" back.
    public static func reconcile(
        items: [(id: ItemID, minX: CGFloat?)],
        model startModel: SectionModel,
        previousZones: [String: Section],
        previousChevronX: CGFloat? = nil,
        previousPositions: [String: CGFloat] = [:],
        pendingZones: [String: Section] = [:],
        userDragged: Bool = false,
        pelmetBundleID: String,
        draggedID: ItemID? = nil
    ) -> Result? {
        let chevron = items.first(where: {
            MenuBarPolicy.isChevronID($0.id, pelmetBundleID: pelmetBundleID)
        })
        let chevronX = chevron?.minX

        var log: [String] = []
        var zones = previousZones
        var pending = pendingZones
        var model = startModel
        var changed = false
        let isFirstPass = previousZones.isEmpty
        // The boundary itself moved since the last pass, and not by a user
        // drag of the chevron: Pelmet's own extras right of the chevron
        // collapse on conceal and the agent re-slots the chevron past a
        // third-party item that registered between them (Figma, 2026-09-08:
        // chevron 1427 → 1497 across a conceal, Figma steady at 1465, and
        // the zone-change rule flipped it to Hidden). A zone change measured
        // against a boundary that moved says nothing about the item — such
        // a pass re-baselines only; the ⌘-dragged item still adopts.
        let chevronMoved: Bool = {
            guard let chevronX, let previousChevronX, draggedID != chevron?.id else { return false }
            return abs(chevronX - previousChevronX) > 4
        }()
        log.append("adopt: chevronX=\(chevronX.map { "\($0)" } ?? "none") firstPass=\(isFirstPass) trackedZones=\(previousZones.count)\(chevronMoved ? " boundaryMoved(from \(previousChevronX!)) — only moved items adopt" : "")")
        var positions: [String: CGFloat] = [:]
        for item in items { if let x = item.minX { positions[item.id.rawValue] = x } }
        // In the pass that follows a real ⌘-drag, an item that itself
        // travelled since the last pass is the dragged one even when the
        // drop x missed it — the moved boundary says nothing about it
        // (ChatGPT 1535 → 1417 across a conceal on a bar whose chevron
        // shifts every cycle, 2026-09-08). Only then: Pelmet's own placement
        // drags move items too, and counting those adopted every editor
        // drop into Always Hidden on an interleaved bar (0.2.17 regression).
        func itemMoved(_ id: ItemID, _ x: CGFloat) -> Bool {
            guard userDragged, let before = previousPositions[id.rawValue] else { return false }
            return abs(x - before) > 20
        }
        // Cluster edges from the PRE-adoption model: the always-hidden and
        // hidden members' live frames (only present during a full reveal).
        // Self-excluded per item below so an item never bounds itself. The
        // dragged item is excluded from both pools outright: its model
        // section is stale by definition (that is what the drag changes), so
        // its new x would otherwise stretch its OLD cluster over the
        // neighbors it landed among and adopt them out (the always-hidden
        // separator read "inside hidden" when Sconce dropped left of it,
        // 2026-09-05).
        let clusterX: [(id: ItemID, x: CGFloat, section: Section)] = items.compactMap {
            guard let x = $0.minX, $0.id != draggedID else { return nil }
            let section = model.section(of: $0.id)
            guard section != .visible else { return nil }
            return ($0.id, x, section)
        }
        // The visible cluster's measured members — its left edge is the
        // implicit boundary when the chevron is hidden. Self-excluded per
        // item below so a dragged item never bounds itself.
        let visibleX: [(id: ItemID, x: CGFloat)] = items.compactMap {
            guard let x = $0.minX, $0.id != draggedID, model.section(of: $0.id) == .visible else { return nil }
            return ($0.id, x)
        }
        for item in items {
            guard MenuBarPolicy.isZoneAdoptable(item.id, pelmetBundleID: pelmetBundleID),
                  let x = item.minX
            else { continue }
            let current = model.section(of: item.id)
            let zone: Section
            var confident = true
            // true = concealable side, false = visible side, nil = no
            // measurable boundary on either side of this x.
            let concealableSide: Bool?
            if let chevronX {
                concealableSide = x < chevronX
            } else {
                // No chevron: adopt only INSIDE a measured cluster — the gap
                // between the clusters has no boundary to judge against.
                let visMin = visibleX.filter { $0.id != item.id }.map(\.x).min()
                let hiddenMax = clusterX.filter { $0.id != item.id }.map(\.x).max()
                if let visMin, x >= visMin {
                    concealableSide = false
                } else if let hiddenMax, x <= hiddenMax {
                    concealableSide = true
                } else {
                    concealableSide = nil
                }
            }
            if concealableSide == nil {
                // Unbounded — the model's word stands, and the guess must
                // not become a baseline.
                zone = current
                confident = false
            } else if concealableSide == false {
                zone = .visible
            } else {
                let ahMax = clusterX
                    .filter { $0.section == .alwaysHidden && $0.id != item.id }
                    .map(\.x).max()
                let hMin = clusterX
                    .filter { $0.section == .hidden && $0.id != item.id }
                    .map(\.x).min()
                if let ahMax, x < ahMax {
                    zone = .alwaysHidden
                } else if let hMin, x > hMin {
                    zone = .hidden
                } else {
                    // Between the clusters, or a cluster is concealed and
                    // unmeasurable — ambiguous, so the model's word stands
                    // (an always-hidden item stays; anything else is hidden).
                    zone = current == .alwaysHidden ? .alwaysHidden : .hidden
                    confident = false
                }
            }
            let previousZone = zones[item.id.rawValue]
            // A guessed zone must never become a baseline: a new app lands
            // far left, reads "hidden" while concealed (ambiguous) and
            // "alwaysHidden" on the next full reveal — that flap would adopt
            // as if the user dragged it. Only measured zones persist.
            // Chevron-less baselines additionally require agreement with the
            // model: a drag reflows the bar and fires order-change passes
            // BEFORE the drag-end pass — folding the moved item's new side
            // into the baseline there would eat the adoption (previousZone
            // would already equal the drag-end reading).
            let boundaryOnly = chevronMoved && !itemMoved(item.id, x)
            // A zone change without a user drag needs two agreeing passes.
            // A pass that lands while a full reveal collapses reads the
            // always-hidden cluster's edge from whichever members are still
            // present — three hidden items adopted into Always Hidden in one
            // pass and flapped back over the next two (2026-09-09). The
            // baseline stays put until the next pass reads the same zone.
            let awaitingConfirmation = confident && !isFirstPass && !boundaryOnly
                && item.id != draggedID && previousZone != nil && previousZone != zone && zone != current
            if awaitingConfirmation, pending[item.id.rawValue] != zone {
                pending[item.id.rawValue] = zone
                log.append("adopt: \(item.id.rawValue) reads \(zone) — confirming on the next pass")
                continue
            }
            if !awaitingConfirmation { pending.removeValue(forKey: item.id.rawValue) }
            if confident, chevronX != nil || zone == current {
                zones[item.id.rawValue] = zone
            } else if boundaryOnly {
                // Measured against a boundary that moved, and not even
                // confidently: the old baseline is void too, or the next
                // steady pass would adopt the same phantom change.
                zones.removeValue(forKey: item.id.rawValue)
            }
            // Chevron-less readings are baseline-only except for the dragged
            // item — see the doc comment (stale-model poisoning).
            guard chevronX != nil || item.id == draggedID else { continue }
            if item.id == draggedID {
                // The ⌘-drag gesture itself is the evidence — a fresh boot may
                // hold no baseline for the dragged item yet (observed live:
                // the only revealed pass ran 90ms AFTER the drop, and the
                // agreement rule above rightly refused to baseline the moved
                // position), so a confident reading adopts without one.
                // With a chevron too: a cluster's edge member (self-excluded,
                // it reads "between the clusters") NEVER earns a baseline, so
                // the zone-change rule alone could never move the leftmost
                // hidden item into Always Hidden (Sconce, 2026-09-05).
                guard confident else { continue }
            } else {
                // First sighting establishes a baseline; only a zone CHANGE
                // adopts — and only against a boundary that stood still.
                guard !isFirstPass, !boundaryOnly, let previousZone, previousZone != zone else { continue }
            }
            guard zone != current else { continue }
            if zone == .visible {
                model.assignments.removeValue(forKey: item.id.sectionKey)
            } else {
                model.assignments[item.id.sectionKey] = zone
            }
            log.append("adopt: \(item.id.rawValue) → \(zone)")
            // The accepted zone IS the new baseline (the chevron-less store
            // above skipped it because it disagreed with the pre-drag model).
            zones[item.id.rawValue] = zone
            pending.removeValue(forKey: item.id.rawValue)
            changed = true
        }
        // Within-section order: the editor treats the explicit stored order as
        // authoritative, so a manual ⌘-drag would otherwise show at its OLD
        // slot forever. Fold the bar's left-to-right reality back in: entries
        // with live frames reorder to match X, frame-nil (concealed) entries
        // hold their slots, entries whose section changed drop out, and
        // newly-adopted members slot in by X. Safe here because adopt only
        // runs on a settled bar — reflows shift frames but preserve X order.
        // Keyed canonically (leftmost frame wins for multi-item bundles) —
        // order arrays hold canonical section keys.
        // Pelmet's own items (extras, stand-ins) re-enter layout at the
        // agent's slot on every reveal — their bar X is never the user's
        // intent unless the user ⌘-dragged that very item. They hold their
        // model slot like frame-nil entries (a stand-in walked next to its
        // app's own icon on every Settings open, 2026-09-09).
        let liveX: [ItemID: CGFloat] = items.reduce(into: [:]) {
            guard let x = $1.minX else { return }
            if $1.id.bundleID == pelmetBundleID, $1.id != draggedID { return }
            let key = $1.id.sectionKey
            $0[key] = min($0[key] ?? .greatestFiniteMagnitude, x)
        }
        for (section, order) in model.order {
            var newOrder = order.filter { model.section(of: $0) == section }
            let liveSlots = newOrder.indices.filter { liveX[newOrder[$0]] != nil }
            let sortedLive = liveSlots.map { newOrder[$0] }.sorted { liveX[$0]! < liveX[$1]! }
            for (offset, slot) in liveSlots.enumerated() { newOrder[slot] = sortedLive[offset] }
            var known = Set(newOrder)
            let missing = items.filter {
                $0.minX != nil && !known.contains($0.id.sectionKey)
                    && model.section(of: $0.id) == section
                    && MenuBarPolicy.isZoneAdoptable($0.id, pelmetBundleID: pelmetBundleID)
            }
            for item in missing.sorted(by: { liveX[$0.id.sectionKey]! < liveX[$1.id.sectionKey]! }) {
                let key = item.id.sectionKey
                guard known.insert(key).inserted else { continue }
                let x = liveX[key]!
                let insertAfter = newOrder.lastIndex { liveX[$0].map { $0 < x } == true }
                newOrder.insert(key, at: insertAfter.map { $0 + 1 } ?? 0)
            }
            if newOrder != order {
                model.order[section] = newOrder
                log.append("adopt: \(section) order reconciled from bar")
                changed = true
            }
        }
        return Result(model: model, zones: zones, chevronX: chevronX, positions: positions, pendingZones: pending, changed: changed, log: log)
    }
}
