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
}
