import Foundation
import Testing
@testable import PelmetCore

@Suite struct ItemIdentityResolverTests {
    // The real drift pair from the 2026-08-20 incident.
    let veljaOld = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
    let veljaNew = ItemID(rawValue: "status:com.sindresorhus.Velja::Left and right arrows in a filled circle")
    let picker = ItemID(rawValue: "status:com.sindresorhus.Color-Picker::Water drop")
    let pelmetExtra = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.MediaControls")
    let systemSound = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.sound")
    let exempt: Set<String> = ["app.fif7y.Pelmet", "com.apple.MenuBarAgent"]

    @Test func carriedAliasDroppedWhenBundleLiveUnderNewTag() {
        let stale = ItemIdentityResolver.staleCarriedIDs(
            carried: [veljaOld, picker],
            liveIDs: [veljaNew],
            runningBundles: ["com.sindresorhus.Velja", "com.sindresorhus.Color-Picker"],
            exemptBundles: exempt
        )
        #expect(stale == [veljaOld: .staleAlias])
    }

    @Test func carriedEntryForQuitAppDropped() {
        let stale = ItemIdentityResolver.staleCarriedIDs(
            carried: [picker],
            liveIDs: [],
            runningBundles: ["com.sindresorhus.Velja"],
            exemptBundles: exempt
        )
        #expect(stale == [picker: .quitApp])
    }

    @Test func carriedConcealedItemOfRunningAppKept() {
        // Concealed = unobservable but running: the normal case, never pruned.
        let stale = ItemIdentityResolver.staleCarriedIDs(
            carried: [picker],
            liveIDs: [veljaNew],
            runningBundles: ["com.sindresorhus.Velja", "com.sindresorhus.Color-Picker"],
            exemptBundles: exempt
        )
        #expect(stale.isEmpty)
    }

    @Test func exemptBundlesNeverPruned() {
        // Pelmet extras + system items mix live and hidden legitimately.
        let stale = ItemIdentityResolver.staleCarriedIDs(
            carried: [pelmetExtra, systemSound],
            liveIDs: [ItemID(rawValue: "status:app.fif7y.Pelmet::Chevron")],
            runningBundles: [],
            exemptBundles: exempt
        )
        #expect(stale.isEmpty)
    }

    @Test func concealedTwinsCollapseToAssignedWinner() {
        let losers = ItemIdentityResolver.concealedTwinLosers(
            concealedIDs: [veljaOld, veljaNew, picker, pelmetExtra],
            exemptBundles: exempt,
            isAssigned: { $0 == veljaNew }
        )
        #expect(losers == [veljaOld])
    }

    @Test func concealedTwinsDeterministicWithoutAssignment() {
        let losersA = ItemIdentityResolver.concealedTwinLosers(
            concealedIDs: [veljaOld, veljaNew],
            exemptBundles: exempt,
            isAssigned: { _ in false }
        )
        let losersB = ItemIdentityResolver.concealedTwinLosers(
            concealedIDs: [veljaNew, veljaOld],
            exemptBundles: exempt,
            isAssigned: { _ in false }
        )
        #expect(losersA == losersB)
        #expect(losersA.count == 1)
    }
}
