import CoreGraphics
import Testing
import PelmetCore
import PelmetEngine
@testable import Pelmet

@MainActor
struct InputMenuPlacementTests {
    let bundle = "com.apple.TextInputMenuAgent"
    var input: ItemID { .status(bundle: bundle, title: "Canadian") }

    @Test func assignedInputMenuQueuesBeforeAnyRegistrationPass() {
        // Menu switched on, agent restarted before a registration pass ran.
        let model = SectionModel(assignments: [input.sectionKey: .hidden], knownBundles: ["com.example.Other"])
        #expect(AppState.relaunchPlacementKeys(for: bundle, model: model) == [input.sectionKey])
        #expect(AppState.relaunchPlacementKeys(for: bundle, model: SectionModel(knownBundles: ["com.example.Other"])).isEmpty)
    }

    @Test func inputMenuRegistersAndQueuesAfterRestart() {
        var model = SectionModel(assignments: [input.sectionKey: .visible])
        let candidates = AppState.registrationCandidates([input])
        #expect(candidates == [input])
        let registered = model.registerObservedItems(candidates)
        #expect(registered)
        #expect(model.knownBundles.contains(bundle))
        #expect(AppState.relaunchPlacementKeys(for: bundle, model: model) == [input.sectionKey])
    }

    /// An existing install (non-empty knownBundles, new icons → Hidden) meets
    /// the system hosts for the first time after updating. They were in the
    /// bar all along: known, never routed. Third-party newcomers still route.
    @Test func existingInstallFoldsSystemHostsWithoutRouting() {
        let clock = ItemID.status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.clock")
        let sound = ItemID.status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.sound")
        let velja = ItemID.status(bundle: "com.sindresorhus.Velja", title: "Item-0")
        var model = SectionModel(newItemsDestination: .hidden, knownBundles: ["com.example.Other"])
        let candidates = AppState.registrationCandidates([clock, sound, input, velja])
        let hosts = AppState.foldSystemHosts(into: &model, candidates: candidates)
        #expect(hosts == [PelmetBundle.agentID, bundle])
        let registered = model.registerObservedItems(candidates)
        #expect(registered)
        #expect(model.section(of: clock) == .visible)
        #expect(model.section(of: sound) == .visible)
        #expect(model.section(of: input) == .visible)
        #expect(model.section(of: velja) == .hidden)
        #expect(model.knownBundles.isSuperset(of: [PelmetBundle.agentID, bundle, "com.sindresorhus.Velja"]))
        // Folded hosts stay eligible for the relaunch re-slot once assigned.
        model.assignments[input.sectionKey] = .hidden
        #expect(AppState.relaunchPlacementKeys(for: bundle, model: model) == [input.sectionKey])
    }

    @Test func freshInstallLeavesFoldingToTheBaselinePass() {
        var model = SectionModel(newItemsDestination: .hidden)
        #expect(AppState.foldSystemHosts(into: &model, candidates: [input]).isEmpty)
        #expect(model.knownBundles.isEmpty)
    }

    @Test func unmanagedAppleAndOwnItemsStayExcluded() {
        for bundle in ["com.apple.UnknownAgent", PelmetBundle.mainID] {
            let id = ItemID.status(bundle: bundle, title: "Item-0")
            let model = SectionModel(assignments: [id: .visible], knownBundles: [bundle])
            #expect(AppState.registrationCandidates([id]).isEmpty)
            #expect(AppState.relaunchPlacementKeys(for: bundle, model: model).isEmpty)
        }
        #expect(AppState.relaunchPlacementKeys(for: bundle, model: SectionModel()).isEmpty)
    }

    @Test func placementResolvesCanonicalAndPreviousLayoutToRestartedNeighbor() {
        let restarted = ItemID.status(bundle: bundle, title: "Item-0")
        let frame = CGRect(x: 600, y: 0, width: 30, height: 24)
        let items = [ObservedItem(id: restarted, frame: frame, appName: "Input Source")]
        for id in [input.sectionKey, input] {
            #expect(PlacementController.liveItem(for: id, in: items)?.frame == frame)
        }
    }

    @Test func placementPrefersExactLiveFrameAndIgnoresUnmeasuredAlias() {
        let other = ItemID.status(bundle: bundle, title: "Canadian CSA")
        let frame = CGRect(x: 600, y: 0, width: 30, height: 24)
        let exact = ObservedItem(id: input, frame: frame, appName: "Canadian")
        let alias = ObservedItem(id: other, frame: frame.offsetBy(dx: 40, dy: 0), appName: "Canadian CSA")
        #expect(PlacementController.liveItem(for: input, in: [alias, exact])?.id == input)
        let stale = ObservedItem(id: input, frame: nil, appName: "Canadian")
        #expect(PlacementController.liveItem(for: input, in: [stale, alias])?.id == other)
        #expect(PlacementController.liveItem(for: input, in: [stale]) == nil)
    }

    @Test func inputMenuDoesNotClampPlacementToItsLeft() {
        let clock = ItemID.status(bundle: "com.apple.ControlCenter", title: "Clock")
        let items = [
            ObservedItem(id: input, frame: CGRect(x: 600, y: 0, width: 30, height: 24), appName: "Canadian"),
            ObservedItem(id: clock, frame: CGRect(x: 1000, y: 0, width: 30, height: 24), appName: "Clock")
        ]
        let systemMinX = items.filter { PlacementController.isProtectedSystemItem($0.id) }
            .compactMap(\.frame?.minX).min()
        #expect(systemMinX == 1000)
        #expect(PlacementGeometry.targetX(
            leftNeighbor: items[0].frame, rightNeighbor: nil, chevron: nil,
            section: .visible, managedMinX: nil, systemMinX: systemMinX, screenMaxX: 1728
        ) == 644)
    }
    @Test func placementUsesMainDisplayAliasWhenExactIDIsOnAnotherDisplay() {
        let alias = ItemID.status(bundle: bundle, title: "Item-0")
        let mainFrame = CGRect(x: 600, y: 0, width: 30, height: 24)
        let items = [
            ObservedItem(id: input, frame: CGRect(x: -600, y: -119, width: 30, height: 24), appName: "Canadian"),
            ObservedItem(id: alias, frame: mainFrame, appName: "Input Source")
        ]
        let match = PlacementController.liveItem(for: input, in: items) {
            MenuBarGeometry.isInBand($0) && $0.midX > 0 && $0.midX < 1728
        }
        #expect(match?.id == alias)
        #expect(match?.frame == mainFrame)
    }

}
