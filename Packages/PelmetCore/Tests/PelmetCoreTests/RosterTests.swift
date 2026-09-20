import Foundation
import Testing
@testable import PelmetCore

@Suite struct RosterTests {
    private func id(_ bundle: String, _ title: String = "Item") -> ItemID {
        ItemID(rawValue: "status:\(bundle)::\(title)")
    }

    private func key(_ bundle: String) -> ItemID {
        ItemID(rawValue: "bundle:\(bundle)")
    }

    @Test func absentIsVisibleAndTitleVariantsShareTheKey() {
        let roster = Roster(members: [key("com.figma.Desktop"): .hidden])
        #expect(roster.section(of: id("com.figma.Desktop", "A")) == .hidden)
        #expect(roster.section(of: id("com.figma.Desktop", "B")) == .hidden)
        #expect(roster.section(of: id("com.herd.app")) == .visible)
    }

    @Test func preMigrationFullIDStillResolves() {
        let full = id("com.figma.Desktop", "Old")
        let roster = Roster(members: [full: .alwaysHidden])
        #expect(roster.section(of: full) == .alwaysHidden)
    }

    @Test func assignVisibleRemovesTheEntry() {
        var roster = Roster(members: [key("com.figma.Desktop"): .hidden])
        roster.assign(key("com.figma.Desktop"), to: .visible)
        #expect(roster.members.isEmpty)
        roster.assign(key("com.figma.Desktop"), to: .alwaysHidden)
        #expect(roster.members == [key("com.figma.Desktop"): .alwaysHidden])
    }

    @Test func oneVisibleItemPinsItsWholeBundle() {
        let roster = Roster(members: [id("com.x.app", "Hide"): .hidden])
        let observed = [id("com.x.app", "Hide"), id("com.x.app", "Show"), id("com.y.app")]
        // Title-keyed entry only matches its own title; the sibling is visible.
        #expect(roster.mustShowBundles(observedItems: observed, revealing: []) == ["com.x.app", "com.y.app"])
        #expect(roster.concealableBundleIDs(observedItems: observed, revealing: []).isEmpty)
    }

    @Test func revealedSectionShowsAndConcealedHides() {
        let roster = Roster(members: [key("com.x.app"): .hidden, key("com.z.app"): .alwaysHidden])
        let observed = [id("com.x.app"), id("com.z.app"), id("com.y.app")]
        #expect(roster.concealableBundleIDs(observedItems: observed, revealing: []) == ["com.x.app", "com.z.app"])
        #expect(roster.concealableBundleIDs(observedItems: observed, revealing: [.hidden]) == ["com.z.app"])
        #expect(roster.mustShowBundles(observedItems: observed, revealing: [.hidden]) == ["com.x.app", "com.y.app"])
    }

    @Test func sectionModelDelegatesToItsRoster() {
        let model = SectionModel(assignments: [key("com.x.app"): .hidden])
        #expect(model.roster == Roster(members: [key("com.x.app"): .hidden]))
        #expect(model.section(of: id("com.x.app")) == .hidden)
        #expect(model.concealableBundleIDs(observedItems: [id("com.x.app")], revealing: []) == ["com.x.app"])
    }
}

@Suite struct RosterRuleTests {
    private func id(_ bundle: String, _ title: String = "Item") -> ItemID {
        ItemID(rawValue: "status:\(bundle)::\(title)")
    }

    @Test func newAppLandsInTheDestination() {
        #expect(RosterRule.landing(for: id("com.figma.Desktop"), newItemsDestination: .hidden) == .hidden)
        #expect(RosterRule.landing(for: id("com.figma.Desktop"), newItemsDestination: .alwaysHidden) == .alwaysHidden)
    }

    @Test func visibleDestinationIsNoEntry() {
        #expect(RosterRule.landing(for: id("com.figma.Desktop"), newItemsDestination: .visible) == nil)
    }

    @Test func systemHostsAreUnmanaged() {
        #expect(RosterRule.landing(for: id(PelmetBundle.controlCenterIDForTests), newItemsDestination: .hidden) == nil)
        // An allowlisted system extra stays manageable through its identifier.
        let wifi = ItemID(rawValue: "status:\(PelmetBundle.agentID)::com.apple.menuextra.wifi")
        #expect(RosterRule.landing(for: wifi, newItemsDestination: .hidden) == .hidden)
    }
}

private extension PelmetBundle {
    static var controlCenterIDForTests: String { MenuBarPolicy.controlCenterID }
}
