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

    // The Always Hidden shortcut (#67) is never off: an upgraded blob and a
    // null both take ⌃⌥⌘, and a recorded one survives a save.
    @Test func alwaysHiddenHotkeyDefaultsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.alwaysHiddenHotkey == .alwaysHiddenDefault)
        let null = try JSONDecoder().decode(SettingsStore.self, from: Data(#"{"alwaysHiddenHotkey":null}"#.utf8))
        #expect(null.alwaysHiddenHotkey == .alwaysHiddenDefault)
        var settings = SettingsStore()
        settings.alwaysHiddenHotkey = HotkeySpec(keyCode: 0x2F, modifiers: 0x900, display: "⌥⌘.")
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.alwaysHiddenHotkey == settings.alwaysHiddenHotkey)
    }

    // Turned off on purpose (#79) survives a save; only a missing, null or
    // unreadable value falls back to the default.
    @Test func turnedOffHotkeyRoundTrips() throws {
        var settings = SettingsStore()
        settings.hotkey = .off
        settings.searchHotkey = .off
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.hotkey?.isOff == true && back.searchHotkey?.isOff == true)
        #expect(back.settingsHotkey == .settingsDefault)
        #expect(!HotkeySpec.default.isOff)
    }

    // The command bar's shortcut (⌥⌘K) falls back to its default too.
    @Test func searchHotkeyDefaultsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.searchHotkey == .searchDefault)
        #expect(HotkeySpec.searchDefault.display == "⌥⌘K")
        let null = try JSONDecoder().decode(SettingsStore.self, from: Data(#"{"searchHotkey":null}"#.utf8))
        #expect(null.searchHotkey == .searchDefault)
        var settings = SettingsStore()
        settings.searchHotkey = HotkeySpec(keyCode: 0x25, modifiers: 0x900, display: "⌥⌘L")
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.searchHotkey == settings.searchHotkey)
    }

    // Per-item shortcuts and aliases are new fields: an older blob has none,
    // and a bad value costs only that field.
    @Test func itemHotkeysAndAliasesDefaultEmptyAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.itemHotkeys.isEmpty)
        #expect(legacy.itemAliases.isEmpty)
        let bad = try JSONDecoder().decode(
            SettingsStore.self, from: Data(#"{"itemHotkeys":"nope","itemAliases":[1],"autoRehide":false}"#.utf8))
        #expect(bad.itemHotkeys.isEmpty && bad.itemAliases.isEmpty)
        #expect(bad.autoRehide == false)
        var settings = SettingsStore()
        settings.itemHotkeys["bundle:com.example.app"] = HotkeySpec(keyCode: 0x0D, modifiers: 0x900, display: "⌥⌘W")
        settings.itemAliases["bundle:com.example.app"] = "work"
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.itemHotkeys == settings.itemHotkeys)
        #expect(back.itemAliases == settings.itemAliases)
    }
}
