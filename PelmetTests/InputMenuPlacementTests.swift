import CoreGraphics
import Testing
import PelmetCore
import PelmetEngine
@testable import Pelmet

@MainActor
struct InputMenuPlacementTests {
    let bundle = "com.apple.TextInputMenuAgent"
    var input: ItemID { .status(bundle: bundle, title: "Canadian") }

    @Test func inputMenuRegistersAndQueuesAfterRestart() {
        var model = SectionModel(assignments: [input.sectionKey: .visible])
        let candidates = AppState.registrationCandidates([input])
        #expect(candidates == [input])
        let registered = model.registerObservedItems(candidates)
        #expect(registered)
        #expect(model.knownBundles.contains(bundle))
        #expect(AppState.relaunchPlacementKeys(for: bundle, model: model) == [input.sectionKey])
    }

    @Test func newInputMenuUsesNewItemDestination() {
        var model = SectionModel(newItemsDestination: .hidden, knownBundles: ["com.example.Other"])
        let registered = model.registerObservedItems(AppState.registrationCandidates([input]))
        #expect(registered)
        #expect(model.section(of: input) == .hidden)
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
}
