// OverflowChevronLabelsTests.swift
// The « is found by its AX description, which MenuBarAgent localizes to the
// SYSTEM language. Locks the loctable-backed matcher: every translation of
// the show/hide labels resolves, English is always present, and unrelated
// descriptions are rejected.

import Foundation
import Testing
@testable import Pelmet

struct OverflowChevronLabelsTests {
    @Test func englishIsAlwaysSeeded() {
        #expect(OverflowChevronLabels.expandedState(forDescription: "Show Hidden Menu Bar Items") == false)
        #expect(OverflowChevronLabels.expandedState(forDescription: "Hide Menu Bar Items") == true)
        #expect(OverflowChevronLabels.expandedState(forDescription: "Hide Menu Bar Items ") == true)
    }

    @Test func unrelatedDescriptionsAreRejected() {
        #expect(OverflowChevronLabels.expandedState(forDescription: "Clock") == nil)
        #expect(OverflowChevronLabels.expandedState(forDescription: "Menu Bar Items") == nil)
        #expect(OverflowChevronLabels.expandedState(forDescription: "") == nil)
    }

    @Test func systemTableCoversOtherLanguages() throws {
        let table = try #require(OverflowChevronLabels.load(at: OverflowChevronLabels.defaultURL),
                                 "MenuBarCore.loctable missing on this macOS")
        #expect(table.show.count > 20, "expected dozens of localizations, got \(table.show.count)")
        #expect(table.hide.count > 20)
        #expect(OverflowChevronLabels.expandedState(forDescription: "Masquer les éléments de la barre des menus") == true)
        #expect(OverflowChevronLabels.expandedState(forDescription: "Afficher les éléments masqués de la barre des menus") == false)
        #expect(OverflowChevronLabels.expandedState(forDescription: "メニューバー項目を非表示") == true)
    }

    @Test func missingTableFallsBackToNil() {
        #expect(OverflowChevronLabels.load(at: URL(fileURLWithPath: "/nonexistent.loctable")) == nil)
    }
}
