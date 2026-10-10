// PicturePassBatchesTests.swift
// Locks the picture pass's batch math: phantoms never count as drawn,
// leftovers are wanted minus pictured, and a follow-up runs only while the
// last one found something and the cap is not reached.

import CoreGraphics
import Testing
@testable import PelmetCore

struct PicturePassBatchesTests {
    func id(_ name: String) -> ItemID { ItemID(rawValue: "bundle:com.test.\(name)") }
    func f(_ x: CGFloat, _ w: CGFloat = 30) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }

    // MARK: drawn

    @Test func cleanFramesAreAllSolid() {
        let frames = [(key: id("a"), frame: f(900)), (key: id("b"), frame: f(932)), (key: id("c"), frame: f(964))]
        let drawn = PicturePassBatches.drawn(wanted: [id("a"), id("b"), id("c")], frames: frames)
        #expect(drawn.solid.count == 3)
        #expect(drawn.phantoms.isEmpty)
        #expect(drawn.solid[id("b")] == f(932))
    }

    @Test func overlappingFramesAreDroppedAsPhantoms() {
        // 2026-09-21: Velja, DBngin and a separator staggered inside the «,
        // then the first real icon clear of them.
        let frames = [
            (key: id("velja"), frame: f(1044, 37)), (key: id("dbngin"), frame: f(1049, 24)),
            (key: id("sep"), frame: f(1055, 26)), (key: id("openclip"), frame: f(1087, 36)),
        ]
        let drawn = PicturePassBatches.drawn(wanted: [id("velja"), id("dbngin"), id("sep"), id("openclip")], frames: frames)
        #expect(drawn.phantoms == [id("velja"), id("dbngin"), id("sep")])
        #expect(Set(drawn.solid.keys) == [id("openclip")])
    }

    @Test func aPhantomIsToldByItsNeighbourWhetherWantedOrNot() {
        // The visible icon is not wanted, but the wanted one overlapping it
        // is as much a phantom as one overlapping another hidden icon.
        let frames = [(key: id("hidden"), frame: f(1000, 40)), (key: id("visible"), frame: f(1010, 40))]
        let drawn = PicturePassBatches.drawn(wanted: [id("hidden")], frames: frames)
        #expect(drawn.phantoms == [id("hidden")])
        #expect(drawn.solid.isEmpty)
    }

    @Test func unwantedFramesAreNeitherSolidNorPhantom() {
        let frames = [(key: id("a"), frame: f(900)), (key: id("b"), frame: f(900)), (key: id("c"), frame: f(1000))]
        let drawn = PicturePassBatches.drawn(wanted: [id("c")], frames: frames)
        #expect(drawn.solid.keys.contains(id("c")))
        #expect(drawn.solid.count == 1)
        #expect(drawn.phantoms.isEmpty)
    }

    @Test func realNeighboursSharingAxPaddingStaySolid() {
        // Edge to edge, or the ~2pt of padding real neighbours share.
        let frames = [(key: id("a"), frame: f(1232, 34)), (key: id("b"), frame: f(1264, 39)), (key: id("c"), frame: f(1339, 44))]
        let drawn = PicturePassBatches.drawn(wanted: [id("a"), id("b"), id("c")], frames: frames)
        #expect(drawn.solid.count == 3)
        #expect(drawn.phantoms.isEmpty)
    }

    @Test func titleTwinsCollapseToTheLeftmostAndDoNotTrapThemselves() {
        let frames = [(key: id("a"), frame: f(920)), (key: id("a"), frame: f(900)), (key: id("b"), frame: f(960))]
        let drawn = PicturePassBatches.drawn(wanted: [id("a"), id("b")], frames: frames)
        #expect(drawn.solid[id("a")] == f(900))
        #expect(drawn.phantoms.isEmpty)
    }

    @Test func wantedItemsWithoutAFrameAreNeitherSolidNorPhantom() {
        let drawn = PicturePassBatches.drawn(wanted: [id("a"), id("gone")], frames: [(key: id("a"), frame: f(900))])
        #expect(Set(drawn.solid.keys) == [id("a")])
        #expect(drawn.phantoms.isEmpty)
        #expect(PicturePassBatches.drawn(wanted: [id("a")], frames: []) == .init(solid: [:], phantoms: []))
    }

    // MARK: leftovers

    @Test func leftoversAreWantedMinusPictured() {
        let left = PicturePassBatches.leftovers(wanted: [id("a"), id("b"), id("c")], pictured: [id("a"), id("x")])
        #expect(left == [id("b"), id("c")])
    }

    @Test func nothingLeftWhenEverythingWantedIsPictured() {
        #expect(PicturePassBatches.leftovers(wanted: [id("a")], pictured: [id("a"), id("b")]).isEmpty)
        #expect(PicturePassBatches.leftovers(wanted: [], pictured: [id("a")]).isEmpty)
    }

    @Test func aPhantomIsALeftoverBecauseItIsNeverPictured() {
        let frames = [(key: id("a"), frame: f(1000, 40)), (key: id("b"), frame: f(1010, 40)), (key: id("c"), frame: f(1100))]
        let wanted: Set<ItemID> = [id("a"), id("b"), id("c")]
        let drawn = PicturePassBatches.drawn(wanted: wanted, frames: frames)
        let left = PicturePassBatches.leftovers(wanted: wanted, pictured: Set(drawn.solid.keys))
        #expect(left == [id("a"), id("b")])
    }

    // MARK: stop rule

    @Test func noRoundWhenThereAreNoLeftovers() {
        #expect(!PicturePassBatches.wantsAnotherRound(followUpsDone: 0, leftovers: [], lastRoundPictured: 0))
        #expect(!PicturePassBatches.wantsAnotherRound(followUpsDone: 2, leftovers: [], lastRoundPictured: 5))
    }

    @Test func theFirstFollowUpRunsOnLeftoversAlone() {
        #expect(PicturePassBatches.wantsAnotherRound(followUpsDone: 0, leftovers: [id("a")], lastRoundPictured: 0))
    }

    @Test func aRoundThatPicturedNothingEndsTheLoop() {
        #expect(!PicturePassBatches.wantsAnotherRound(followUpsDone: 1, leftovers: [id("a")], lastRoundPictured: 0))
        #expect(PicturePassBatches.wantsAnotherRound(followUpsDone: 1, leftovers: [id("a")], lastRoundPictured: 2))
    }

    @Test func atMostThreeFollowUps() {
        let left: Set<ItemID> = [id("a")]
        #expect(PicturePassBatches.maxFollowUps == 3)
        #expect(PicturePassBatches.wantsAnotherRound(followUpsDone: 2, leftovers: left, lastRoundPictured: 1))
        #expect(!PicturePassBatches.wantsAnotherRound(followUpsDone: 3, leftovers: left, lastRoundPictured: 1))
    }

    @Test func aLoopOverTheRulesRunsTwoBatchesThenStopsWhenTheLastGainsNothing() {
        // Five wanted; the first pass pictures two, batch 1 two more, batch 2 none.
        let wanted: Set<ItemID> = [id("a"), id("b"), id("c"), id("d"), id("e")]
        var pictured: Set<ItemID> = [id("a"), id("b")]
        let gains: [[ItemID]] = [[id("c"), id("d")], []]
        var done = 0
        var last = 0
        var left = PicturePassBatches.leftovers(wanted: wanted, pictured: pictured)
        while PicturePassBatches.wantsAnotherRound(followUpsDone: done, leftovers: left, lastRoundPictured: last) {
            let got = gains[done]
            done += 1
            pictured.formUnion(got)
            last = got.count
            left = PicturePassBatches.leftovers(wanted: wanted, pictured: pictured)
        }
        #expect(done == 2)
        #expect(left == [id("e")])
    }
}
