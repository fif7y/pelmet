// MenuBarPolicyTests.swift
// The full systemItem suffix table (including negatives), the exempt set, and
// the Pelmet-extra/unmanaged-Apple predicates.

import CoreGraphics
import Testing
import PelmetCore

struct MenuBarPolicyTests {
    @Test func textInputAgentUsesKeyboardPolicyAcrossSourceNames() {
        for title in ["微信输入法", "ABC", "拼音"] {
            let id = ItemID.status(bundle: "com.apple.TextInputMenuAgent", title: title)
            #expect(MenuBarPolicy.systemItem(for: id) == .keyboard)
            #expect(MenuBarPolicy.isZoneAdoptable(id, pelmetBundleID: PelmetBundle.fallbackID))
        }
        #expect(MenuBarPolicy.systemItem(for: .status(bundle: "com.example.App", title: "微信输入法")) == nil)
    }

    @Test func inputSourceSwitchPreservesSection() {
        let weType = ItemID.status(bundle: "com.apple.TextInputMenuAgent", title: "微信输入法")
        let abc = ItemID.status(bundle: "com.apple.TextInputMenuAgent", title: "ABC")
        let model = SectionModel(assignments: [weType.sectionKey: .hidden])
        #expect(model.section(of: abc) == .hidden)
        #expect(MenuBarPolicy.systemItem(for: weType.sectionKey) == .keyboard)
    }

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
        #expect(MenuBarPolicy.systemItem(for: menuExtra("controlcenter")) == .primaryBentoBox)
    }

    // The clock and Control Center hide like Sound but never move.
    @Test func pinnedSystemItemsAreTheClockAndControlCenter() {
        #expect(MenuBarPolicy.isPinnedSystemItem(menuExtra("clock")))
        #expect(MenuBarPolicy.isPinnedSystemItem(menuExtra("controlcenter")))
        #expect(MenuBarPolicy.isSectionManageable(menuExtra("controlcenter")))
        #expect(!MenuBarPolicy.isPinnedSystemItem(menuExtra("sound")))
        #expect(!MenuBarPolicy.isPinnedSystemItem(.status(bundle: "com.example.App", title: "clock")))
    }

    @Test func systemItemTableRejectsNonControllableIDs() {
        // The camera pill is a menuextra but NOT individually controllable.
        #expect(MenuBarPolicy.systemItem(for: menuExtra("audiovideo")) == nil)
        // A third-party title that merely ends in a matching suffix is not a
        // system item — the menuextra marker gates the table.
        #expect(MenuBarPolicy.systemItem(for: .status(bundle: "com.example.App", title: "sound")) == nil)
        #expect(MenuBarPolicy.systemItem(for: .bundleKey("com.example.App")) == nil)
    }

    @Test func exemptBundlesArePelmetItsHelpersAndAgent() {
        #expect(
            MenuBarPolicy.identityExemptBundles(pelmetBundleID: "app.fif7y.Pelmet")
                == PelmetBundle.helperIDs.union(["app.fif7y.Pelmet", PelmetBundle.agentID])
        )
    }

    @Test func pelmetExtraIDMatchesOwnedExtrasNotChevron() {
        #expect(MenuBarPolicy.isPelmetExtraID(.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Extra.media")))
        #expect(MenuBarPolicy.isPelmetExtraID(.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Separator.X")))
        #expect(!MenuBarPolicy.isPelmetExtraID(.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.StatusItem")))
        #expect(!MenuBarPolicy.isPelmetExtraID(.status(bundle: "com.example.App", title: "Item-0")))
    }

    // Only the hosts whose items are the system's are unmanaged as apps;
    // every other Apple process is an app like any other (2026-09-19).
    @Test func unmanagedAppleBundlesAreTheSystemItemHosts() {
        #expect(MenuBarPolicy.isUnmanagedAppleBundle(PelmetBundle.agentID))
        #expect(MenuBarPolicy.isUnmanagedAppleBundle(PelmetBundle.textInputAgentID))
        #expect(MenuBarPolicy.isUnmanagedAppleBundle("com.apple.controlcenter"))
        #expect(MenuBarPolicy.isUnmanagedAppleBundle("com.apple.screencaptureui"))
        #expect(!MenuBarPolicy.isSectionManageable(.status(bundle: "com.apple.screencaptureui", title: "Item-0")))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle("com.apple.weather.menu"))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle("com.apple.systemuiserver"))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle("com.example.App"))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle(nil))
    }

    // Agents are classified by where they live, not by name: whatever
    // CoreServices process puts up an item next is the system's too.
    @Test func registeredSystemAgentsAreUnmanagedExceptThePinnedHost() {
        MenuBarPolicy.resetSystemAgentsForTesting()
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle("com.apple.AirPlayUIAgent"))
        MenuBarPolicy.registerSystemAgents(["com.apple.AirPlayUIAgent", "com.apple.systemuiserver"])
        #expect(MenuBarPolicy.isUnmanagedAppleBundle("com.apple.AirPlayUIAgent"))
        #expect(!MenuBarPolicy.isUnmanagedAppleBundle("com.apple.systemuiserver"))
        #expect(!MenuBarPolicy.isSectionManageable(.status(bundle: "com.apple.AirPlayUIAgent", title: "Item-0")))
        #expect(MenuBarPolicy.isSystemAgentLocation("/System/Library/CoreServices/screencaptureui.app"))
        #expect(!MenuBarPolicy.isSystemAgentLocation("/System/Applications/Weather.app/Contents/PlugIns/WeatherMenu.appex"))
        #expect(!MenuBarPolicy.isSystemAgentLocation("/System/Library/PrivateFrameworks/AppSSOKerberos.framework/Support/KerberosMenuExtra.app"))
        MenuBarPolicy.resetSystemAgentsForTesting()
    }

    @Test func kerberosMenuExtraIsSectionManageable() {
        let item = ItemID.status(bundle: "com.apple.KerberosMenuExtra", title: "Item-0")
        #expect(MenuBarPolicy.isSectionManageable(item))
        #expect(MenuBarPolicy.systemItem(for: item) == nil)
    }

    @Test func passwordsMenuBarExtraIsSectionManageable() {
        let item = ItemID.status(bundle: "com.apple.Passwords.MenuBarExtra", title: "Item-0")
        #expect(MenuBarPolicy.isSectionManageable(item))
        #expect(MenuBarPolicy.systemItem(for: item) == nil)
    }

    // #36: any Apple process with an item of its own is hideable AND
    // movable like a third-party app — Weather today, the next login-item
    // extra tomorrow — without a patch per name. Only the known-pinned host
    // (SystemUIServer) is kept out of zone adoption.
    @Test func appleHostsWithOwnItemsAreManagedLikeAppsByDefault() {
        let weather = ItemID.status(bundle: "com.apple.weather.menu", title: "Weather")
        #expect(MenuBarPolicy.isBundleHideableAppleHost("com.apple.weather.menu"))
        #expect(MenuBarPolicy.isSectionManageable(weather))
        #expect(MenuBarPolicy.systemItem(for: weather) == nil)
        #expect(MenuBarPolicy.isZoneAdoptable(weather, pelmetBundleID: PelmetBundle.fallbackID))
        #expect(!MenuBarPolicy.isPinnedAppleHost("com.apple.weather.menu"))
        #expect(MenuBarPolicy.isBundleHideableAppleHost("com.apple.KerberosMenuExtra"))
        #expect(MenuBarPolicy.isBundleHideableAppleHost("com.apple.Passwords.MenuBarExtra"))
        let siri = ItemID.status(bundle: "com.apple.systemuiserver", title: "Siri")
        #expect(MenuBarPolicy.isBundleHideableAppleHost("com.apple.systemuiserver"))
        #expect(MenuBarPolicy.isPinnedAppleHost("com.apple.systemuiserver"))
        #expect(MenuBarPolicy.isSectionManageable(siri))
        #expect(!MenuBarPolicy.isZoneAdoptable(siri, pelmetBundleID: PelmetBundle.fallbackID))
    }

    // The hosts whose items are the system's stay on the SystemItem path:
    // the agent's menuextras, the input menu, Control Center.
    @Test func systemItemHostsAreNotBundleHideable() {
        #expect(!MenuBarPolicy.isBundleHideableAppleHost(PelmetBundle.agentID))
        #expect(!MenuBarPolicy.isBundleHideableAppleHost(PelmetBundle.textInputAgentID))
        #expect(!MenuBarPolicy.isBundleHideableAppleHost("com.apple.controlcenter"))
        #expect(!MenuBarPolicy.isBundleHideableAppleHost("com.example.App"))
        #expect(!MenuBarPolicy.isBundleHideableAppleHost(nil))
        // The camera pill stays unmanageable: a menuextra without a SystemItem.
        #expect(!MenuBarPolicy.isSectionManageable(menuExtra("audiovideo")))
    }

    // Hideable and movable are different questions (PR #38): the pinned
    // set is the system-item hosts plus the host macOS refuses to drag.
    @Test func positionPinnedIsTheSystemItemHostsPlusTheDragRefusingHost() {
        for bundle in [PelmetBundle.agentID, PelmetBundle.textInputAgentID, MenuBarPolicy.controlCenterID, PelmetBundle.systemUIServerID] {
            #expect(MenuBarPolicy.isPositionPinnedAppleBundle(bundle))
        }
        // Real ⌘-drags move these (2026-09-19), so they are not pinned.
        for bundle in ["com.apple.Passwords.MenuBarExtra", "com.apple.weather.menu", "com.example.App"] {
            #expect(!MenuBarPolicy.isPositionPinnedAppleBundle(bundle))
        }
        #expect(!MenuBarPolicy.isPositionPinnedAppleBundle(nil))
    }

    @Test func bandPredicateAcceptsMainBarBandOnly() {
        #expect(MenuBarGeometry.isInBand(CGRect(x: 100, y: 0, width: 30, height: 24)))
        #expect(!MenuBarGeometry.isInBand(CGRect(x: 100, y: 800, width: 30, height: 24)))
        #expect(!MenuBarGeometry.isInBand(CGRect(x: 100, y: -30, width: 30, height: 24)))
    }

    @Test func bandOfASideDisplayCountsItsCopiesNotAParkedRegistration() {
        // Three displays in CG global space: built-in at the origin, a side
        // display whose top sits 113pt above it, one top-aligned to the right.
        let builtIn = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let left = CGRect(x: -2560, y: -113, width: 2560, height: 1440)
        let right = CGRect(x: 1800, y: 0, width: 3440, height: 1440)
        let leftCopy = CGRect(x: -234, y: -113, width: 30, height: 24)
        #expect(MenuBarGeometry.isInBand(leftCopy, ofDisplay: left))
        #expect(!MenuBarGeometry.isInBand(leftCopy, ofDisplay: builtIn))
        #expect(!MenuBarGeometry.isInBand(leftCopy))
        #expect(MenuBarGeometry.isInBand(CGRect(x: 100, y: 0, width: 30, height: 24), ofDisplay: builtIn))
        // A registration parked under a stale assertion is on no display's bar.
        let parked = CGRect(x: 4800, y: -164, width: 30, height: 24)
        for display in [builtIn, left, right] {
            #expect(!MenuBarGeometry.isInBand(parked, ofDisplay: display))
        }
    }
}
