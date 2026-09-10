// OrderDriftTests.swift
// Locks the supervisor's judgement: side-of-chevron vs model section, with
// unmeasured, system, Apple, and chevron entries left alone.

import CoreGraphics
import Testing
import PelmetCore

struct OrderDriftTests {
    let pelmet = "app.fif7y.Pelmet"
    let chevron = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.StatusItem")
    let camera = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.CameraMic")
    let snib = ItemID(rawValue: "status:app.fif7y.Snib::Item-0")
    let velja = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
    let sound = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.sound")
    let siri = ItemID(rawValue: "status:com.apple.systemuiserver::Siri")

    func model() -> SectionModel {
        var m = SectionModel()
        m.assignments[snib.sectionKey] = .hidden
        m.assignments[velja.sectionKey] = .alwaysHidden
        m.assignments[camera.sectionKey] = .visible
        return m
    }

    @Test func hiddenItemRightOfChevronIsMisplaced() {
        let out = OrderDrift.misplaced(
            items: [(velja, 1200), (snib, 1442), (chevron, 1421), (camera, 1459)],
            chevronMinX: 1421, model: model(), pelmetBundleID: pelmet
        )
        #expect(out == [snib])
    }

    @Test func visibleOwnItemLeftOfChevronIsMisplaced() {
        let out = OrderDrift.misplaced(
            items: [(snib, 1380), (camera, 1421), (chevron, 1459)],
            chevronMinX: 1459, model: model(), pelmetBundleID: pelmet
        )
        #expect(out == [camera])
    }

    @Test func orderedBarReportsNothing() {
        let out = OrderDrift.misplaced(
            items: [(velja, 1200), (snib, 1380), (chevron, 1421), (camera, 1459)],
            chevronMinX: 1421, model: model(), pelmetBundleID: pelmet
        )
        #expect(out.isEmpty)
    }

    @Test func unmeasuredSystemAndChevronEntriesAreIgnored() {
        let out = OrderDrift.misplaced(
            items: [(snib, nil), (sound, 1300), (siri, 1310), (chevron, 1421)],
            chevronMinX: 1421, model: model(), pelmetBundleID: pelmet
        )
        #expect(out.isEmpty)
    }

    @Test func ownItemOutsideItsModelSlotIsReported() {
        let pelmet = "app.fif7y.Pelmet"
        let comet = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.App.C0")
        let vorssaint = ItemID(rawValue: "status:com.vorssaint.utils::Item-0")
        let snib = ItemID(rawValue: "status:app.fif7y.Snib::Item-0")
        var model = SectionModel()
        for id in [comet, vorssaint, snib] { model.assignments[id.sectionKey] = .hidden }
        model.order[.hidden] = [vorssaint.sectionKey, snib.sectionKey, comet.sectionKey]
        // Bar: Comet, Vorssaint, Snib — Comet re-entered left of everyone.
        let out = OrderDrift.ownItemsOutOfOrder(
            items: [(id: comet, minX: 400), (id: vorssaint, minX: 430), (id: snib, minX: 460)],
            model: model, pelmetBundleID: pelmet
        )
        #expect(out == [comet])
        // Bar: Vorssaint, Snib, Comet — in its slot.
        let ok = OrderDrift.ownItemsOutOfOrder(
            items: [(id: vorssaint, minX: 400), (id: snib, minX: 430), (id: comet, minX: 460)],
            model: model, pelmetBundleID: pelmet
        )
        #expect(ok.isEmpty)
    }
}
