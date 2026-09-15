import Foundation
import Testing
@testable import PelmetCore

@Suite struct SettingsStoreTests {
    @Test func invalidEnumFieldFallsBackWithoutResettingOthers() throws {
        var store = SettingsStore()
        store.onboardingCompleted = true
        store.rehideDelay = 3.5
        let data = try JSONEncoder().encode(store)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Simulate a downgrade: a raw value this build's enum doesn't know.
        json["displayTemplate"] = "someFutureBehavior"
        let poisoned = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SettingsStore.self, from: poisoned)
        #expect(decoded.displayTemplate == SettingsStore().displayTemplate)
        #expect(decoded.onboardingCompleted == true)
        #expect(decoded.rehideDelay == 3.5)
    }

    /// The one rule the right-click opt-out has to keep: with no icon in the
    /// bar it is the only way back into Settings, so it cannot be off.
    @Test func hidingTheIconKeepsTheRightClickMenuReachable() {
        var store = SettingsStore()
        store.barRightClickMenu = false
        store.showStatusItem = true
        #expect(store.barRightClickMenuActive == false)

        // Turning the icon off after opting out is the lockout a disabled
        // control alone would not have caught.
        store.showStatusItem = false
        #expect(store.barRightClickMenuActive)

        // And the stored choice survives, so putting the icon back restores it.
        store.showStatusItem = true
        #expect(store.barRightClickMenuActive == false)
    }

    /// A blob written before the setting existed keeps today's behaviour.
    @Test func settingsSavedBeforeTheOptOutStillOpenTheMenu() throws {
        let data = try JSONEncoder().encode(SettingsStore())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "barRightClickMenu")
        let older = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SettingsStore.self, from: older)
        #expect(decoded.barRightClickMenu)
        #expect(decoded.barRightClickMenuActive)
    }
}

@Suite struct HotkeySettingsTests {
    private func json(_ store: SettingsStore) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
    }

    @Test func freshStoreCarriesTheDefaultShortcut() {
        #expect(SettingsStore().hotkey == .default)
        #expect(SettingsStore().settingsHotkey == .settingsDefault)
        #expect(HotkeySpec.default.display == "⌥⌘,")
        #expect(HotkeySpec.settingsDefault.display == "⇧⌥⌘,")
    }

    /// Blobs written before the default existed have no `hotkey` key, and a
    /// dev build briefly wrote an explicit null: both take the default.
    @Test func missingOrNullShortcutTakesTheDefault() throws {
        var blob = try json(SettingsStore())
        blob.removeValue(forKey: "hotkey")
        blob.removeValue(forKey: "settingsHotkey")
        var decoded = try JSONDecoder().decode(SettingsStore.self, from: JSONSerialization.data(withJSONObject: blob))
        #expect(decoded.hotkey == .default)
        #expect(decoded.settingsHotkey == .settingsDefault)
        blob["hotkey"] = NSNull()
        decoded = try JSONDecoder().decode(SettingsStore.self, from: JSONSerialization.data(withJSONObject: blob))
        #expect(decoded.hotkey == .default)
    }

    @Test func recordedShortcutRoundTripsWithItsDisplay() throws {
        var store = SettingsStore()
        store.hotkey = HotkeySpec(keyCode: 49, modifiers: 0x1000, display: "⌃Space")
        let decoded = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(store))
        #expect(decoded.hotkey == store.hotkey)
        #expect(decoded.hotkey?.display == "⌃Space")
    }

    /// A pre-display blob holding the default combo shows as "⌥⌘," anyway.
    @Test func legacySpecWithoutDisplayGetsTheDefaultGlyphs() throws {
        let data = Data(#"{"hotkey":{"keyCode":43,"modifiers":2304}}"#.utf8)
        let decoded = try JSONDecoder().decode(SettingsStore.self, from: data)
        #expect(decoded.hotkey?.display == "⌥⌘,")
    }
}
