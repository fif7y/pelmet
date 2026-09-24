import Foundation
import Testing
@testable import PelmetCore

struct SettingsStoreTests {
    // "Show while revealed" is overridden while a Pelmet replica of a
    // collateral extra is on (#39: the camera pill came back on every hover).
    @Test func collateralReplicaForcesTheSystemExtrasHold() {
        var settings = SettingsStore()
        settings.hideSystemExtras = false
        settings.extraItems = []
        #expect(!settings.effectiveHideSystemExtras)
        settings.extraItems = [ExtraItemSpec(kind: .siri)]
        #expect(!settings.effectiveHideSystemExtras)
        settings.extraItems = [ExtraItemSpec(kind: .cameraMicIndicator)]
        #expect(settings.replacesCollateralExtras)
        #expect(settings.effectiveHideSystemExtras)
        settings.hideSystemExtras = true
        settings.extraItems = []
        #expect(settings.effectiveHideSystemExtras)
    }

    // Pending order edits survive a quit (docs/CORE-SETS.md M1), and a blob
    // saved before the field existed decodes with none pending.
    @Test func orderEditsRoundTripAndDefault() throws {
        var settings = SettingsStore()
        let a = ItemID.bundleKey("com.a"), b = ItemID.bundleKey("com.b")
        settings.orderEdits = OrderEdits(
            order: [.hidden: [b, a]], previousSection: [a: .visible], previousOrder: [.hidden: [b], .visible: [a]],
            created: [b])
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(SettingsStore.self, from: data)
        #expect(back.orderEdits == settings.orderEdits)
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.orderEdits.isEmpty)
        // An edit set saved before `previousSection` existed still decodes.
        let older = try JSONDecoder().decode(
            OrderEdits.self, from: Data(#"{"order":[]}"#.utf8))
        #expect(older.isEmpty)
        #expect(!OrderEdits(previousSection: [a: .hidden]).isEmpty)
        var edits = settings.orderEdits
        edits.clearOrder(for: .hidden)
        #expect(edits.order[.hidden] == nil && edits.previousOrder[.hidden] == nil && edits.previousOrder[.visible] == [a])
        // Placing the section that held the created item retires it from Discard.
        #expect(edits.created.isEmpty)
    }
}
