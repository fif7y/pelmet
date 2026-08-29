// MenuBarPolicyTests.swift
// The full systemItem suffix table (including negatives), the exempt set, and
// the Pelmet-extra/unmanaged-Apple predicates.

import CoreGraphics
import Testing
import PelmetCore

struct MenuBarPolicyTests {
    private func menuExtra(_ suffix: String) -> ItemID {
        .status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.\(suffix)")
    }

    @Test func systemItemTableCoversControllableExtras() {
        #expect(MenuBarPolicy.systemItem(for: menuExtra("sound")) == .volume)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("battery")) == .battery)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("wifi")) == .wifi)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("clock")) == .clock)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("bluetooth")) == .bluetooth)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("display")) == .displays)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("displays")) == .displays)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("textinput")) == .keyboard)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("keyboard")) == .keyboard)
        #expect(MenuBarPolicy.systemItem(for: menuExtra("screen-mirroring")) == .screenMirroring)
    }

    @Test func systemItemTableRejectsNonControllableIDs() {
        // The camera pill is a menuextra but NOT individually controllable.
        #expect(MenuBarPolicy.systemItem(for: menuExtra("audiovideo")) == nil)
        // A third-party title that merely ends in a matching suffix is not a
        // system item — the menuextra marker gates the table.
        #expect(MenuBarPolicy.systemItem(for: .status(bundle: "com.example.App", title: "sound")) == nil)
        #expect(MenuBarPolicy.systemItem(for: .bundleKey("com.example.App")) == nil)
    }

    @Test func exemptBundlesArePelmetAndAgent() {
        #expect(
            MenuBarPolicy.identityExemptBundles(pelmetBundleID: "app.fif7y.Pelmet")
                == ["app.fif7y.Pelmet", PelmetBundle.agentID]
        )
    }

    @Test func pelmetExtraIDMatchesOwnedExtrasNotChevron() {
        #expect(MenuBarPolicy.isPelmetExtraID(.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Extra.media")))
        #expect(MenuBarPolicy.isPelmetExtraID(.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Separator.X")))
        #expect(!MenuBarPolicy.isPelmetExtraID(.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.StatusItem")))
        #expect(!MenuBarPolicy.isPelmetExtraID(.status(bundle: "com.example.App", title: "Item-0")))
    }

    @Test func unmanagedAppleBundleIsApplePrefixOnly() {
        #expect(MenuBarPolicy.isUnmanagedAppleBundle("com.apple.Siri"))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle("com.example.App"))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle(nil))
    }

    @Test func bandPredicateAcceptsMainBarBandOnly() {
        #expect(MenuBarGeometry.isInBand(CGRect(x: 100, y: 0, width: 30, height: 24)))
        #expect(!MenuBarGeometry.isInBand(CGRect(x: 100, y: 800, width: 30, height: 24)))
        #expect(!MenuBarGeometry.isInBand(CGRect(x: 100, y: -30, width: 30, height: 24)))
    }
}
