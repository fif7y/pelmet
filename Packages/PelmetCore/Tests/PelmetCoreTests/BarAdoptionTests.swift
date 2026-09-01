// BarAdoptionTests.swift
// Locks the ⌘-drag adoption rules: chevron gating, first-pass baseline,
// zone-change-only adoption, guessed-zone non-persistence, and the
// within-section order fold-in.

import CoreGraphics
import Testing
import PelmetCore

struct BarAdoptionTests {
    let pelmet = "app.fif7y.Pelmet"
    let chevron = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.StatusItem")
    let velja = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
    let figma = ItemID(rawValue: "status:com.figma.Desktop::Item-0")
    let anchor = ItemID(rawValue: "status:com.example.Anchor::Item-0")

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

    @Test func zoneChangeAdoptsIntoHidden() {
        var model = SectionModel()
        model.assignments[anchor.sectionKey] = .hidden
        let result = BarAdoption.reconcile(
            items: [
                (id: chevron, minX: 1000),
                (id: anchor, minX: 400),
                (id: velja, minX: 500),
            ],
            model: model,
            previousZones: [velja.rawValue: .visible, anchor.rawValue: .hidden],
            pelmetBundleID: pelmet
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == .hidden)
        #expect(result?.zones[velja.rawValue] == .hidden)
    }

    @Test func zoneChangeAdoptsBackToVisible() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = BarAdoption.reconcile(
            items: [(id: chevron, minX: 1000), (id: velja, minX: 1200)],
            model: model,
            previousZones: [velja.rawValue: .hidden],
            pelmetBundleID: pelmet
        )
        #expect(result?.changed == true)
        #expect(result?.model.assignments[velja.sectionKey] == nil)
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
