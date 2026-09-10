// BarAdoptionTests.swift
// Locks the ⌘-drag adoption rules: chevron gating, first-pass baseline,
// zone-change-only adoption, guessed-zone non-persistence, and the
// within-section order fold-in.

import CoreGraphics
import Testing
import PelmetCore

struct BarAdoptionTests {
    @Test func weTypeDraggedLeftOfChevronAdoptsHidden() {
        let input = ItemID.status(bundle: "com.apple.TextInputMenuAgent", title: "微信输入法")
        let result = BarAdoption.reconcile(
            items: [(id: anchor, minX: 2480), (id: input, minX: 2516), (id: chevron, minX: 2560)],
            model: SectionModel(assignments: [anchor.sectionKey: .hidden]),
            previousZones: [input.rawValue: .visible],
            pelmetBundleID: pelmet,
            draggedID: input
        )
        #expect(result?.model.section(of: input) == .hidden)
    }

    let pelmet = "app.fif7y.Pelmet"
    let chevron = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.StatusItem")
    let velja = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
    let figma = ItemID(rawValue: "status:com.figma.Desktop::Item-0")
    let anchor = ItemID(rawValue: "status:com.example.Anchor::Item-0")

    let sound = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.sound")
    let siri = ItemID(rawValue: "status:com.apple.systemuiserver::Siri")

    @Test func systemExtraDraggedRightOfChevronAdoptsVisible() {
        // 2026-09-08: Sound ⌘-dragged right of the chevron kept hiding on
        // rehide — adoption skipped every com.apple. bundle, including the
        // extras the assertion can individually allow. Siri (unmanageable,
        // hard-pinned by the agent) must still be ignored.
        var model = SectionModel()
        model.assignments[sound.sectionKey] = .hidden
        model.assignments[siri.sectionKey] = .hidden
        model.order[.hidden] = [sound.sectionKey]
        model.order[.visible] = []
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1421),
                (id: sound, minX: 1516),
                (id: siri, minX: 1657),
            ],
            model: model,
            previousZones: [sound.rawValue: .hidden],
            pelmetBundleID: pelmet,
            draggedID: sound
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[sound.sectionKey] == nil)
        #expect(result?.model.order[.hidden] == [])
        #expect(result?.model.order[.visible] == [sound.sectionKey])
        #expect(result?.model.assignments[siri.sectionKey] == .hidden)
        #expect(result?.zones[siri.rawValue] == nil)
    }

    @Test func movedChevronReBaselinesInsteadOfAdopting() {
        // Figma, 2026-09-08: registered right of the chevron and adopted
        // Visible; on conceal Pelmet's extras right of the chevron folded and
        // the agent re-slotted the chevron past Figma (1427 → 1497, Figma
        // steady at 1465). The item never moved — no adoption, new baseline.
        var model = SectionModel()
        model.order[.visible] = [figma.sectionKey]
        let pass2 = BarAdoption.reconcile(
            items: [(id: figma, minX: 1465), (id: chevron, minX: 1497)],
            model: model,
            previousZones: [figma.rawValue: .visible],
            previousChevronX: 1427,
            pelmetBundleID: pelmet
        )
        #expect(pass2?.changed == false)
        #expect(pass2?.model.assignments[figma.sectionKey] == nil)
        // Collapsed bar: no hidden cluster measurable, so the reading is a
        // guess — the stale Visible baseline is dropped, not replaced.
        #expect(pass2?.zones[figma.rawValue] == nil)
        #expect(pass2?.chevronX == 1497)
        // Same bar again, chevron steady: still nothing to adopt.
        let pass3 = BarAdoption.reconcile(
            items: [(id: figma, minX: 1465), (id: chevron, minX: 1497)],
            model: model,
            previousZones: pass2!.zones,
            previousChevronX: pass2!.chevronX,
            pelmetBundleID: pelmet
        )
        #expect(pass3?.changed == false)
        // A ⌘-drag of the chevron itself IS a re-sectioning: adoption runs.
        let dragged = BarAdoption.reconcile(
            items: [(id: figma, minX: 1465), (id: chevron, minX: 1497)],
            model: model,
            previousZones: [figma.rawValue: .visible],
            previousChevronX: 1427,
            pelmetBundleID: pelmet,
            draggedID: chevron
        )
        #expect(dragged?.model.assignments[figma.sectionKey] == .hidden)
        // The item itself travelled since the last pass (a ⌘-drag the band
        // monitor's drop x missed): it adopts even though the chevron moved.
        let travelled = BarAdoption.reconcile(
            items: [(id: figma, minX: 1417), (id: chevron, minX: 1497)],
            model: model,
            previousZones: [figma.rawValue: .visible],
            previousChevronX: 1459,
            previousPositions: [figma.rawValue: 1535],
            userDragged: true,
            pelmetBundleID: pelmet
        )
        #expect(travelled?.model.assignments[figma.sectionKey] == .hidden)
        #expect(travelled?.positions[figma.rawValue] == 1417)
        // The same travel without a user drag is Pelmet's own placement
        // (an editor drop): the boundary guard holds (0.2.17 regression —
        // every editor drop adopted the item into Always Hidden).
        let placed = BarAdoption.reconcile(
            items: [(id: figma, minX: 1417), (id: chevron, minX: 1497)],
            model: model,
            previousZones: [figma.rawValue: .visible],
            previousChevronX: 1459,
            previousPositions: [figma.rawValue: 1535],
            pelmetBundleID: pelmet
        )
        #expect(placed?.changed == false)
        #expect(placed?.model.assignments[figma.sectionKey] == nil)
    }

    @Test func missingChevronSkipsZoneAdoptionButStillFoldsOrder() {
        // The user can hide Pelmet's status item — no boundary, so zones
        // must not move, but a bar ⌘-drag still reorders within a section.
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.order[.hidden] = [velja.sectionKey, figma.sectionKey]
        let result = BarAdoption.reconcile(
            items: [
                (id: velja, minX: 500),
                (id: figma, minX: 400),
            ],
            model: model,
            previousZones: [velja.rawValue: .hidden, figma.rawValue: .hidden],
            pelmetBundleID: pelmet
        )
        #expect(result?.model.order[.hidden] == [figma.sectionKey, velja.sectionKey])
        #expect(result?.model.assignments[velja.sectionKey] == .hidden)
        #expect(result?.zones == [velja.rawValue: .hidden, figma.rawValue: .hidden])
    }

    @Test func noChevronDropInsideVisibleClusterAdoptsVisible() {
        // The Vorssaint case (2026-08-31): icon hidden, full reveal, an
        // always-hidden item ⌘-dragged in among the visible cluster must
        // adopt visible — the cluster's left edge is the implicit boundary.
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .alwaysHidden
        let result = BarAdoption.reconcile(
            items: [
                (id: anchor, minX: 900),   // visible cluster member
                (id: velja, minX: 950),    // dropped to its right
            ],
            model: model,
            previousZones: [velja.rawValue: .alwaysHidden, anchor.rawValue: .visible],
            pelmetBundleID: pelmet,
            draggedID: velja
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == nil)
        #expect(result?.zones[velja.rawValue] == .visible)
        // The dragged item's stale model entry poisons the neighbor's reading
        // (anchor sits left of a "concealable" at 950) — but only the dragged
        // item may adopt without a chevron, so anchor must not move.
        #expect(result?.model.assignments[anchor.sectionKey] == nil)
    }

    @Test func noChevronDropInsideConcealableClusterAdoptsHidden() {
        var model = SectionModel()
        model.assignments[figma.sectionKey] = .hidden
        model.assignments[anchor.sectionKey] = .hidden
        let result = BarAdoption.reconcile(
            items: [
                (id: figma, minX: 300),
                (id: anchor, minX: 400),
                (id: velja, minX: 350),    // visible item dropped mid-cluster
            ],
            model: model,
            previousZones: [
                velja.rawValue: .visible,
                figma.rawValue: .hidden,
                anchor.rawValue: .hidden,
            ],
            pelmetBundleID: pelmet,
            draggedID: velja
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == .hidden)
    }

    @Test func noChevronDraggedItemAdoptsWithoutABaseline() {
        // Fresh boot: no revealed pass ran before the drag, so the dragged
        // item has no baseline — the gesture is the evidence and a confident
        // reading must adopt anyway (observed live 2026-08-31 22:26).
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .alwaysHidden
        model.assignments[anchor.sectionKey] = .alwaysHidden
        let result = BarAdoption.reconcile(
            items: [
                (id: figma, minX: 300),
                (id: velja, minX: 350),    // dropped mid always-hidden cluster
                (id: anchor, minX: 400),
            ],
            model: model,
            previousZones: [:],
            pelmetBundleID: pelmet,
            draggedID: velja
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == .alwaysHidden)
    }

    @Test func noChevronWithoutDraggedIDNeitherAdoptsNorEatsTheDrag() {
        // Order-change passes fire DURING a drag with no dragged id — they
        // must neither adopt nor fold the moved item's new side into the
        // baseline, or the drag-end pass would see previousZone == zone and
        // skip the adoption.
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .alwaysHidden
        let result = BarAdoption.reconcile(
            items: [
                (id: anchor, minX: 900),
                (id: velja, minX: 950),
            ],
            model: model,
            previousZones: [velja.rawValue: .alwaysHidden, anchor.rawValue: .visible],
            pelmetBundleID: pelmet
        )
        #expect(result?.model.assignments[velja.sectionKey] == .alwaysHidden)
        #expect(result?.zones[velja.rawValue] == .alwaysHidden)
    }

    @Test func noChevronLeftmostVisibleMemberIsNotFalseAdopted() {
        // The leftmost visible item always reads left of every OTHER visible
        // member; without a chevron that gap must stay ambiguous, never a
        // demotion to hidden.
        var model = SectionModel()
        model.assignments[figma.sectionKey] = .hidden
        let result = BarAdoption.reconcile(
            items: [
                (id: figma, minX: 300),
                (id: anchor, minX: 500),   // leftmost visible
                (id: velja, minX: 600),    // second visible
            ],
            model: model,
            previousZones: [
                anchor.rawValue: .visible,
                velja.rawValue: .visible,
                figma.rawValue: .hidden,
            ],
            pelmetBundleID: pelmet
        )
        #expect(result?.changed == false)
        #expect(result?.model.assignments[anchor.sectionKey] == nil)
        #expect(result?.zones[anchor.rawValue] == .visible)
    }

    @Test func firstPassBaselinesZonesWithoutAdopting() {
        let result = BarAdoption.reconcile(
            items: [(id: chevron, minX: 1000), (id: velja, minX: 1100)],
            model: SectionModel(),
            previousZones: [:],
            pelmetBundleID: pelmet
        )
        #expect(result?.changed == false)
        #expect(result?.zones[velja.rawValue] == .visible)
        #expect(result?.model.assignments.isEmpty == true)
    }

    /// A non-dragged zone change adopts on the second agreeing pass.
    func twoPasses(items: [(id: ItemID, minX: CGFloat?)], model: SectionModel, previousZones: [String: Section]) -> BarAdoption.Result? {
        let first = BarAdoption.reconcile(items: items, model: model, previousZones: previousZones, pelmetBundleID: pelmet)
        return BarAdoption.reconcile(
            items: items, model: model,
            previousZones: first?.zones ?? previousZones, pendingZones: first?.pendingZones ?? [:],
            pelmetBundleID: pelmet
        )
    }

    @Test func zoneChangeAdoptsIntoHidden() {
        var model = SectionModel()
        model.assignments[anchor.sectionKey] = .hidden
        let items: [(id: ItemID, minX: CGFloat?)] = [(chevron, 1000), (anchor, 400), (velja, 500)]
        let first = BarAdoption.reconcile(
            items: items, model: model,
            previousZones: [velja.rawValue: .visible, anchor.rawValue: .hidden],
            pelmetBundleID: pelmet
        )
        #expect(first?.changed == false)
        #expect(first?.pendingZones[velja.rawValue] == .hidden)
        let result = twoPasses(items: items, model: model, previousZones: [velja.rawValue: .visible, anchor.rawValue: .hidden])
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == .hidden)
        #expect(result?.zones[velja.rawValue] == .hidden)
    }

    @Test func zoneChangeAdoptsBackToVisible() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = twoPasses(
            items: [(chevron, 1000), (velja, 1200)], model: model,
            previousZones: [velja.rawValue: .hidden]
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == nil)
    }

    @Test func draggedLeftmostHiddenMemberAdoptsAlwaysHiddenWithoutABaseline() {
        // The Sconce case (2026-09-05): the LEFTMOST hidden member never
        // earns a confident baseline — self-excluded, it always reads
        // "between the clusters" — so the zone-change rule could never fire
        // for it. The ⌘-drag itself is the evidence: a confident reading of
        // the dragged item adopts with a chevron too.
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden          // Sconce stand-in
        model.assignments[figma.sectionKey] = .hidden          // Snib stand-in
        model.assignments[anchor.sectionKey] = .alwaysHidden   // trailing AH separator
        model.order[.hidden] = [velja.sectionKey, figma.sectionKey]
        model.order[.alwaysHidden] = [anchor.sectionKey]
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1000),
                (id: figma, minX: 430),
                (id: anchor, minX: 370),
                (id: velja, minX: 340),   // dropped LEFT of the AH cluster's right edge
            ],
            model: model,
            previousZones: [figma.rawValue: .hidden, anchor.rawValue: .alwaysHidden],
            pelmetBundleID: pelmet,
            draggedID: velja
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == .alwaysHidden)
        #expect(result?.zones[velja.rawValue] == .alwaysHidden)
        // The dragged item's stale .hidden entry must not stretch the hidden
        // cluster over the AH separator it landed left of.
        #expect(result?.model.assignments[anchor.sectionKey] == .alwaysHidden)
        #expect(result?.model.order[.hidden] == [figma.sectionKey])
        #expect(result?.model.order[.alwaysHidden] == [velja.sectionKey, anchor.sectionKey])
    }

    @Test func draggedItemBetweenClustersKeepsTheModelsWord() {
        // Dropped right of the AH cluster and left of the hidden one: still
        // ambiguous even for the dragged item — no boundary to judge against.
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.assignments[anchor.sectionKey] = .alwaysHidden
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1000),
                (id: figma, minX: 430),
                (id: velja, minX: 400),
                (id: anchor, minX: 370),
            ],
            model: model,
            previousZones: [figma.rawValue: .hidden, anchor.rawValue: .alwaysHidden],
            pelmetBundleID: pelmet,
            draggedID: velja
        )
        #expect(result?.model.assignments[velja.sectionKey] == .hidden)
        #expect(result?.zones[velja.rawValue] == nil)
    }

    @Test func ambiguousZoneConservesModelAndDoesNotPersist() {
        // No measurable hidden/always-hidden cluster besides the item itself
        // → ambiguous; the model's word stands and the guess is not tracked.
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = BarAdoption.reconcile(
            items: [(id: chevron, minX: 1000), (id: velja, minX: 300)],
            model: model,
            previousZones: [velja.rawValue: .visible],
            pelmetBundleID: pelmet
        )
        #expect(result?.changed == false)
        #expect(result?.zones[velja.rawValue] == .visible)
        #expect(result?.model.assignments[velja.sectionKey] == .hidden)
    }

    @Test func liveOrderFoldsBackIntoExplicitOrder() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.order[.hidden] = [velja.sectionKey, figma.sectionKey]
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1000),
                (id: velja, minX: 500),
                (id: figma, minX: 400),
            ],
            model: model,
            previousZones: [velja.rawValue: .hidden, figma.rawValue: .hidden],
            pelmetBundleID: pelmet
        )
        #expect(result?.changed == true)
        #expect(result?.model.order[.hidden] == [figma.sectionKey, velja.sectionKey])
        #expect(result?.log.contains("adopt: hidden order reconciled from bar") == true)
    }

    @Test func ownItemHoldsItsModelSlotUnlessDragged() {
        let standIn = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.App.ABCD")
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.assignments[standIn.sectionKey] = .hidden
        model.order[.hidden] = [velja.sectionKey, figma.sectionKey, standIn.sectionKey]
        let items: [(id: ItemID, minX: CGFloat?)] = [
            (id: chevron, minX: 1000),
            (id: velja, minX: 400),
            // Re-entered layout between its neighbors — not the user's doing.
            (id: standIn, minX: 450),
            (id: figma, minX: 500),
        ]
        let zones = [velja.rawValue: Section.hidden, figma.rawValue: .hidden, standIn.rawValue: .hidden]
        let held = BarAdoption.reconcile(
            items: items, model: model, previousZones: zones, pelmetBundleID: pelmet
        )
        #expect(held?.model.order[.hidden] == [velja.sectionKey, figma.sectionKey, standIn.sectionKey])
        let dragged = BarAdoption.reconcile(
            items: items, model: model, previousZones: zones, pelmetBundleID: pelmet, draggedID: standIn
        )
        #expect(dragged?.model.order[.hidden] == [velja.sectionKey, standIn.sectionKey, figma.sectionKey])
    }

    @Test func sectionChangedEntryDropsOutOfOrder() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .alwaysHidden
        model.order[.hidden] = [velja.sectionKey, figma.sectionKey]
        let result = BarAdoption.reconcile(
            items: [(id: chevron, minX: 1000)],
            model: model,
            previousZones: [velja.rawValue: .hidden],
            pelmetBundleID: pelmet
        )
        #expect(result?.changed == true)
        #expect(result?.model.order[.hidden] == [velja.sectionKey])
    }

    @Test func liveNewcomerInsertsByX() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.order[.hidden] = [velja.sectionKey]
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1000),
                (id: velja, minX: 500),
                (id: figma, minX: 400),
            ],
            model: model,
            previousZones: [velja.rawValue: .hidden, figma.rawValue: .hidden],
            pelmetBundleID: pelmet
        )
        #expect(result?.changed == true)
        #expect(result?.model.order[.hidden] == [figma.sectionKey, velja.sectionKey])
    }
}

extension BarAdoptionTests {
    @Test func zoneChangeWithoutDragNeedsTwoAgreeingPasses() {
        // 2026-09-09: a pass that landed while a full reveal collapsed read
        // three hidden items inside the always-hidden cluster and adopted
        // them in one go. A non-dragged change now waits for the next pass.
        var model = SectionModel()
        model.assignments[anchor.sectionKey] = .alwaysHidden
        model.assignments[velja.sectionKey] = .hidden
        model.order[.alwaysHidden] = [anchor.sectionKey]
        model.order[.hidden] = [velja.sectionKey]
        // Velja reads inside the always-hidden cluster (left of its member).
        let items = [(id: anchor, minX: CGFloat(1200)), (id: velja, minX: CGFloat(1180)), (id: chevron, minX: CGFloat(1421))]
        let first = BarAdoption.reconcile(
            items: items, model: model,
            previousZones: [velja.rawValue: .hidden, anchor.rawValue: .alwaysHidden],
            pelmetBundleID: pelmet
        )
        #expect(first?.model.assignments[velja.sectionKey] == .hidden)
        #expect(first?.pendingZones[velja.rawValue] == .alwaysHidden)
        #expect(first?.zones[velja.rawValue] == .hidden)
        // The reading flips back: nothing adopts, the candidate is dropped.
        let flipped = BarAdoption.reconcile(
            items: [(id: anchor, minX: 1200), (id: velja, minX: 1300), (id: chevron, minX: 1421)],
            model: model,
            previousZones: first!.zones, pendingZones: first!.pendingZones,
            pelmetBundleID: pelmet
        )
        #expect(flipped?.model.assignments[velja.sectionKey] == .hidden)
        #expect(flipped?.pendingZones[velja.rawValue] == nil)
        // Two agreeing passes adopt.
        let second = BarAdoption.reconcile(
            items: items, model: model,
            previousZones: first!.zones, pendingZones: first!.pendingZones,
            pelmetBundleID: pelmet
        )
        #expect(second?.model.assignments[velja.sectionKey] == .alwaysHidden)
        #expect(second?.pendingZones[velja.rawValue] == nil)
    }
}
