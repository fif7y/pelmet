import Foundation
import Testing
@testable import PelmetCore

@Suite struct PanelModelTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func key(_ bundle: String) -> ItemID { .bundleKey(bundle) }
    private func tile(_ bundle: String) -> PanelTile { .item(key(bundle)) }
    /// The raw form the walk reports: a title on top of the bundle.
    private func raw(_ bundle: String, _ title: String = "Item") -> ItemID { .status(bundle: bundle, title: title) }
    private func separator(_ n: Int = 1) -> ItemID {
        .status(bundle: PelmetBundle.mainID, title: "Pelmet.Separator.00000000-0000-0000-0000-00000000000\(n)")
    }
    private func separatorKey(_ n: Int) -> ItemID { separator(n).sectionKey }

    private func roster(hidden: [String] = [], always: [String] = [], extra: [ItemID: Section] = [:]) -> Roster {
        var members = extra
        for b in hidden { members[key(b)] = .hidden }
        for b in always { members[key(b)] = .alwaysHidden }
        return Roster(members: members)
    }

    private func candidate(
        _ bundle: String, _ title: String, alias: String? = nil, section: Section = .hidden
    ) -> SearchCandidate {
        SearchCandidate(id: key(bundle).rawValue, kind: .item, title: title, alias: alias, section: section)
    }

    // MARK: - Membership and order

    @Test func tilesFollowTheRosterNotTheWalk() {
        let model = PanelModel.build(
            roster: roster(hidden: ["a", "b"], always: ["c"]),
            items: [raw("a"), raw("b"), raw("c"), raw("d")])
        #expect(model.section(.hidden)?.tiles == [tile("a"), tile("b")])
        #expect(model.section(.alwaysHidden)?.tiles == [tile("c")])
        #expect(model.section(.didntFit) == nil)
    }

    // A stale roster entry (the app quit and is gone from the walk) has no tile.
    @Test func anItemTheWalkDidNotSeeHasNoTile() {
        let model = PanelModel.build(roster: roster(hidden: ["a", "gone"]), items: [raw("a")])
        #expect(model.section(.hidden)?.tiles == [tile("a")])
    }

    @Test func drawnOrderComesFirstThenWalkOrder() {
        let model = PanelModel.build(
            roster: roster(hidden: ["a", "b", "c", "d"]),
            items: [raw("a"), raw("b"), raw("c"), raw("d")],
            drawnOrder: [.hidden: [raw("c"), raw("a")]])
        #expect(model.section(.hidden)?.tiles == [tile("c"), tile("a"), tile("b"), tile("d")])
    }

    // Order drawn for another section, or for an item that left, is not a claim here.
    @Test func drawnOrderOfOtherSectionsAndGoneItemsIsIgnored() {
        let model = PanelModel.build(
            roster: roster(hidden: ["a", "b"], always: ["c"]),
            items: [raw("a"), raw("b"), raw("c")],
            drawnOrder: [.hidden: [raw("c"), raw("gone"), raw("b")], .alwaysHidden: [raw("a")]])
        #expect(model.section(.hidden)?.tiles == [tile("b"), tile("a")])
        #expect(model.section(.alwaysHidden)?.tiles == [tile("c")])
    }

    // Title variants of one bundle are one tile.
    @Test func titleVariantsCollapseToTheSectionKey() {
        let model = PanelModel.build(
            roster: roster(hidden: ["a"]),
            items: [raw("a", "One"), raw("a", "Two")],
            drawnOrder: [.hidden: [raw("a", "Three")]])
        #expect(model.section(.hidden)?.tiles == [tile("a")])
    }

    @Test func pelmetsChevronNeverGetsATile() {
        let chevron = ItemID.status(bundle: PelmetBundle.mainID, title: "Pelmet.StatusItem")
        let model = PanelModel.build(
            roster: Roster(members: [chevron.sectionKey: .hidden]), items: [chevron])
        #expect(model.section(.hidden)?.tiles == [])
    }

    // MARK: - Separators

    private var withSeparators: (roster: Roster, items: [ItemID]) {
        (roster(hidden: ["a", "b", "c"], extra: [separatorKey(1): .hidden, separatorKey(2): .hidden]),
         [raw("a"), separator(1), raw("b"), raw("c"), separator(2)])
    }

    @Test func separatorsAreDroppedUnlessTheyBreakRows() {
        let (roster, items) = withSeparators
        let model = PanelModel.build(roster: roster, items: items)
        #expect(model.section(.hidden)?.tiles == [tile("a"), tile("b"), tile("c")])
    }

    @Test func separatorsBecomeRowBreaksWhenAsked() {
        let (roster, items) = withSeparators
        var options = PanelOptions()
        options.separatorsBreakRows = true
        let model = PanelModel.build(roster: roster, items: items, options: options)
        // The trailing separator is not a break: nothing follows it.
        #expect(model.section(.hidden)?.tiles == [tile("a"), .rowBreak, tile("b"), tile("c")])
        #expect(model.section(.hidden)?.count == 3)
    }

    @Test func leadingAndDoubledSeparatorsMakeNoBreak() {
        var options = PanelOptions()
        options.separatorsBreakRows = true
        let model = PanelModel.build(
            roster: roster(
                hidden: ["a", "b"],
                extra: [separatorKey(1): .hidden, separatorKey(2): .hidden, separatorKey(3): .hidden]),
            items: [separator(1), raw("a"), separator(2), separator(3), raw("b")],
            options: options)
        #expect(model.section(.hidden)?.tiles == [tile("a"), .rowBreak, tile("b")])
    }

    // MARK: - Didn't fit

    @Test func didntFitIsItsOwnSectionOnTop() {
        let model = PanelModel.build(
            roster: roster(hidden: ["a"]),
            items: [raw("a"), raw("v1"), raw("v2")],
            didntFit: [raw("v2"), raw("v1")])
        #expect(model.sections.map(\.kind) == [.didntFit, .hidden])
        #expect(model.section(.didntFit)?.tiles == [tile("v2"), tile("v1")])
    }

    // One tile each: an icon in the notice's list leaves its own section.
    @Test func didntFitTakesItsTilesOutOfTheOtherSections() {
        let model = PanelModel.build(
            roster: roster(hidden: ["a", "b"]),
            items: [raw("a"), raw("b")], didntFit: [raw("b", "X"), raw("b", "Y")])
        #expect(model.section(.didntFit)?.tiles == [tile("b")])
        #expect(model.section(.hidden)?.tiles == [tile("a")])
    }

    @Test func didntFitSkipsSeparatorsAndTheChevron() {
        let chevron = ItemID.status(bundle: PelmetBundle.mainID, title: "Pelmet.StatusItem")
        let model = PanelModel.build(roster: Roster(), items: [], didntFit: [separator(), chevron])
        #expect(model.section(.didntFit) == nil)
    }

    // MARK: - Launchers

    @Test func launchersJoinTheSectionTheirAppIsIn() {
        let model = PanelModel.build(
            roster: roster(hidden: ["a", "ln"], always: ["lo"]),
            items: [raw("a")], launchers: ["ln", "lo", "stranger"])
        #expect(model.section(.hidden)?.tiles == [tile("a"), .launcher("ln")])
        #expect(model.section(.alwaysHidden)?.tiles == [.launcher("lo")])
    }

    // An app that is running has its own tile; a launcher beside it would double it.
    @Test func aRunningAppGetsNoLauncher() {
        let model = PanelModel.build(
            roster: roster(hidden: ["a"]), items: [raw("a")], launchers: ["a"])
        #expect(model.section(.hidden)?.tiles == [tile("a")])
    }

    @Test func tileSearchIDsMatchTheCommandBarsCandidates() {
        #expect(tile("a").searchID == "bundle:a")
        #expect(PanelTile.launcher("com.x").searchID == "launcher:com.x")
        #expect(PanelTile.rowBreak.searchID == nil)
    }

    // MARK: - Always Hidden fold

    private func foldModel(_ mode: PanelOptions.AlwaysHiddenMode, open: Bool = false, requested: Bool = false) -> PanelModel {
        var options = PanelOptions()
        options.alwaysHidden = mode
        options.alwaysHiddenOpen = open
        return PanelModel.build(
            roster: roster(hidden: ["a"], always: ["b", "c"]),
            items: [raw("a"), raw("b"), raw("c")],
            options: options, alwaysHiddenRequested: requested)
    }

    @Test func foldedIsClosedOnEveryOpen() {
        let section = foldModel(.folded, open: true).section(.alwaysHidden)
        #expect(section?.isFolded == true)
        #expect(section?.count == 2)
    }

    @Test func asLeftKeepsTheFoldAsItWas() {
        #expect(foldModel(.asLeft, open: false).section(.alwaysHidden)?.isFolded == true)
        #expect(foldModel(.asLeft, open: true).section(.alwaysHidden)?.isFolded == false)
    }

    @Test func hiddenDropsAlwaysHidden() {
        let model = foldModel(.hidden)
        #expect(model.section(.alwaysHidden) == nil)
        #expect(model.section(.hidden)?.tiles == [tile("a")])
    }

    // ⌥-click, double-click and the Always Hidden shortcut still reach it.
    @Test func theOpenersAskOpensItInEveryMode() {
        for mode in PanelOptions.AlwaysHiddenMode.allCases {
            #expect(foldModel(mode, requested: true).section(.alwaysHidden)?.isFolded == false)
        }
    }

    @Test func noAlwaysHiddenIconsMeansNoFoldRow() {
        let model = PanelModel.build(roster: roster(hidden: ["a"]), items: [raw("a")])
        #expect(model.section(.alwaysHidden) == nil)
    }

    @Test func nothingHiddenStillShowsTheHiddenSectionAtRest() {
        let model = PanelModel.build(roster: Roster(), items: [raw("v")])
        #expect(model.sections.map(\.kind) == [.hidden])
        #expect(model.section(.hidden)?.tiles == [])
        #expect(model.isEmpty)
    }

    // MARK: - Filter

    private var corpus: [SearchCandidate] {
        [candidate("dis", "Discord"), candidate("pw", "1Password", alias: "vault"),
         candidate("dock", "Docker"), candidate("fig", "Figma", section: .alwaysHidden),
         SearchCandidate(id: "launcher:com.sp", kind: .launcher, title: "Spotify")]
    }

    private func filtered(_ query: String, mode: PanelOptions.AlwaysHiddenMode = .folded) -> PanelModel {
        var options = PanelOptions()
        options.alwaysHidden = mode
        return PanelModel.build(
            roster: roster(hidden: ["dis", "pw", "dock", "com.sp"], always: ["fig"]),
            items: [raw("dis"), raw("pw"), raw("dock"), raw("fig")],
            launchers: ["com.sp"], options: options,
            query: query, candidates: corpus, now: now)
    }

    @Test func filterKeepsWhatMatchesInRankOrder() {
        let model = filtered("do")
        // Docker starts with it, Discord only has the letters in order: the
        // walk saw Discord first, rank puts Docker ahead.
        #expect(model.section(.hidden)?.tiles == [tile("dock"), tile("dis")])
        #expect(model.bestMatch == tile("dock"))
    }

    @Test func filterReachesAliasesAndLaunchers() {
        #expect(filtered("vault").section(.hidden)?.tiles == [tile("pw")])
        #expect(filtered("spot").section(.hidden)?.tiles == [.launcher("com.sp")])
    }

    // Search covers both sections, whatever the setting says.
    @Test func filterShowsAlwaysHiddenOpenEvenWhenTheSettingHidesIt() {
        for mode in PanelOptions.AlwaysHiddenMode.allCases {
            let section = filtered("fig", mode: mode).section(.alwaysHidden)
            #expect(section?.tiles == [tile("fig")])
            #expect(section?.isFolded == false)
        }
    }

    @Test func filterLeavesOutSectionsWithNoMatch() {
        let model = filtered("fig")
        #expect(model.sections.map(\.kind) == [.alwaysHidden])
        #expect(model.bestMatch == tile("fig"))
        let none = filtered("zzzz")
        #expect(none.sections.isEmpty && none.isEmpty && none.bestMatch == nil)
    }

    @Test func filterDropsRowBreaks() {
        var options = PanelOptions()
        options.separatorsBreakRows = true
        let model = PanelModel.build(
            roster: roster(hidden: ["dis", "dock"], extra: [separatorKey(1): .hidden]),
            items: [raw("dis"), separator(1), raw("dock")],
            options: options, query: "do", candidates: corpus, now: now)
        #expect(model.section(.hidden)?.tiles == [tile("dock"), tile("dis")])
    }

    @Test func filterReachesDidntFitToo() {
        let model = PanelModel.build(
            roster: Roster(), items: [raw("dis")], didntFit: [raw("dis")],
            query: "disc", candidates: corpus, now: now)
        #expect(model.section(.didntFit)?.tiles == [tile("dis")])
        #expect(model.section(.hidden) == nil)
    }

    // Only spaces typed is not a filter yet.
    @Test func aBlankQueryIsNoFilter() {
        let model = filtered("   ")
        #expect(model.section(.hidden)?.tiles.count == 4)
        #expect(model.section(.alwaysHidden)?.isFolded == true)
        #expect(model.bestMatch == nil)
    }
}
