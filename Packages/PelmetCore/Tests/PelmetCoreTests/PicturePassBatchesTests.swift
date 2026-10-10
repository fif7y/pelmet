// PicturePassBatchesTests.swift
// Locks the picture pass's batch decisions: which wanted items a follow-up
// is for (frameless or phantom on the primary bar, nothing else), which
// frames a follow-up may crop, the guards and the cover budget that stop
// one, and the stop rule.

import CoreGraphics
import Testing
@testable import PelmetCore

struct PicturePassBatchesTests {
    let maxX: CGFloat = 1728
    func id(_ name: String) -> ItemID { ItemID(rawValue: "bundle:com.test.\(name)") }
    func f(_ x: CGFloat, _ w: CGFloat = 30) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }
    func walk(_ entries: (String, CGRect?)...) -> [(key: ItemID, frame: CGRect?)] {
        entries.map { (key: id($0.0), frame: $0.1) }
    }

    // MARK: readings and leftovers

    @Test func cleanFramesAreNotLeftovers() {
        // A clear frame whose cut came back blank (animated wallpaper, an
        // empty glyph) reads clear too: a second reveal would give the same.
        let items = walk(("a", f(900)), ("b", f(932)), ("c", f(964)))
        let wanted: Set<ItemID> = [id("a"), id("b"), id("c")]
        #expect(PicturePassBatches.readings(wanted: wanted, items: items, primaryMaxX: maxX).values.allSatisfy { $0 == .clear })
        #expect(PicturePassBatches.leftovers(wanted: wanted, items: items, primaryMaxX: maxX).isEmpty)
    }

    @Test func framelessItemsAreLeftovers() {
        let items = walk(("a", f(900)), ("b", nil))
        let left = PicturePassBatches.leftovers(wanted: [id("a"), id("b")], items: items, primaryMaxX: maxX)
        #expect(left == [id("b")])
    }

    @Test func phantomsAreLeftoversAndTheirNeighbourOnlyIfItOverlapsToo() {
        // 2026-09-21: Velja, DBngin and a separator staggered inside the «,
        // then the first real icon clear of them.
        let items = walk(("velja", f(1044, 37)), ("dbngin", f(1049, 24)), ("sep", f(1055, 26)), ("openclip", f(1087, 36)))
        let wanted: Set<ItemID> = [id("velja"), id("dbngin"), id("sep"), id("openclip")]
        let readings = PicturePassBatches.readings(wanted: wanted, items: items, primaryMaxX: maxX)
        #expect(readings[id("openclip")] == .clear)
        #expect(PicturePassBatches.leftovers(wanted: wanted, items: items, primaryMaxX: maxX) == [id("velja"), id("dbngin"), id("sep")])
    }

    @Test func aPhantomIsToldByAnUnwantedVisibleNeighbourToo() {
        let items = walk(("hidden", f(1000, 40)), ("visible", f(1010, 40)))
        let left = PicturePassBatches.leftovers(wanted: [id("hidden")], items: items, primaryMaxX: maxX)
        #expect(left == [id("hidden")])
    }

    @Test func otherDisplaysFramesAreNotLeftovers() {
        // Left of the primary display, and right of its edge.
        let items = walk(("left", f(-614)), ("right", f(1800)), ("here", f(900)))
        let wanted: Set<ItemID> = [id("left"), id("right"), id("here")]
        let readings = PicturePassBatches.readings(wanted: wanted, items: items, primaryMaxX: maxX)
        #expect(readings[id("left")] == .elsewhere)
        #expect(readings[id("right")] == .elsewhere)
        #expect(PicturePassBatches.leftovers(wanted: wanted, items: items, primaryMaxX: maxX).isEmpty)
    }

    @Test func itemsTheWalkNeverSawAreNotLeftovers() {
        // Passwords draws nothing under any assertion: no follow-up for it.
        let items = walk(("a", f(900)))
        let readings = PicturePassBatches.readings(wanted: [id("a"), id("passwords")], items: items, primaryMaxX: maxX)
        #expect(readings[id("passwords")] == .unseen)
        #expect(PicturePassBatches.leftovers(wanted: [id("a"), id("passwords")], items: items, primaryMaxX: maxX).isEmpty)
    }

    @Test func unwantedItemsAreNeverLeftovers() {
        let items = walk(("a", f(900)), ("b", nil), ("c", f(900)))
        #expect(PicturePassBatches.leftovers(wanted: [], items: items, primaryMaxX: maxX).isEmpty)
        #expect(PicturePassBatches.leftovers(wanted: [id("a")], items: items, primaryMaxX: maxX) == [id("a")])
    }

    @Test func realNeighboursSharingAxPaddingAreNotLeftovers() {
        // Edge to edge, or the ~2pt of padding real neighbours share.
        let items = walk(("a", f(1232, 34)), ("b", f(1264, 39)), ("c", f(1339, 44)))
        #expect(PicturePassBatches.leftovers(wanted: [id("a"), id("b"), id("c")], items: items, primaryMaxX: maxX).isEmpty)
    }

    @Test func titleTwinsReadAsTheirLeftmostPrimaryFrameAndDoNotTrapThemselves() {
        // One twin frameless, one framed: framed. One on the side bar, one here: here.
        let items = walk(("a", nil), ("a", f(800)), ("b", f(-500)), ("b", f(900)), ("c", f(1000)), ("c", f(1020)))
        let readings = PicturePassBatches.readings(wanted: [id("a"), id("b"), id("c")], items: items, primaryMaxX: maxX)
        #expect(readings[id("a")] == .clear)
        #expect(readings[id("b")] == .clear)
        #expect(readings[id("c")] == .clear)
    }

    @Test func remainingIsWhatTheFollowUpDidNotPicture() {
        let left = PicturePassBatches.remaining([id("b"), id("c")], pictured: [id("c"), id("x")])
        #expect(left == [id("b")])
        #expect(PicturePassBatches.remaining([id("a")], pictured: [id("a")]).isEmpty)
        #expect(PicturePassBatches.remaining([], pictured: [id("a")]).isEmpty)
    }

    // MARK: what a follow-up may crop

    @Test func aFollowUpCropsOnlyClearFrames() {
        let frames = [(key: id("a"), frame: f(1000, 40)), (key: id("b"), frame: f(1010, 40)), (key: id("c"), frame: f(1100))]
        let drawn = PicturePassBatches.drawn(wanted: [id("a"), id("b"), id("c")], frames: frames)
        #expect(drawn.phantoms == [id("a"), id("b")])
        #expect(Set(drawn.solid.keys) == [id("c")])
        #expect(drawn.solid[id("c")] == f(1100))
    }

    @Test func aFollowUpIgnoresFramesItDidNotAskFor() {
        let frames = [(key: id("a"), frame: f(900)), (key: id("b"), frame: f(900)), (key: id("c"), frame: f(1000))]
        let drawn = PicturePassBatches.drawn(wanted: [id("c")], frames: frames)
        #expect(Set(drawn.solid.keys) == [id("c")])
        #expect(drawn.phantoms.isEmpty)
    }

    @Test func aFollowUpCollapsesTwinsToTheLeftmost() {
        let frames = [(key: id("a"), frame: f(920)), (key: id("a"), frame: f(900)), (key: id("b"), frame: f(960))]
        let drawn = PicturePassBatches.drawn(wanted: [id("a"), id("b")], frames: frames)
        #expect(drawn.solid[id("a")] == f(900))
        #expect(drawn.phantoms.isEmpty)
        #expect(PicturePassBatches.drawn(wanted: [id("a")], frames: []) == .init(solid: [:], phantoms: []))
    }

    // MARK: guards and budget

    let clear = PicturePassBatches.Conditions(hasCover: true, hasEmptyBarPicture: true, otherPressHoldsBar: false, waiterPending: false)

    @Test func nothingStopsARoundWhenEveryGuardHoldsAndTimeRemains() {
        #expect(PicturePassBatches.blocker(clear, elapsed: 0.8, batch: 2, ceiling: 8.5) == nil)
    }

    @Test func eachGuardStopsARound() {
        var c = clear
        c.hasCover = false
        #expect(PicturePassBatches.blocker(c, elapsed: 0.8, batch: 2, ceiling: 8.5) == .noCover)
        c = clear
        c.hasEmptyBarPicture = false
        #expect(PicturePassBatches.blocker(c, elapsed: 0.8, batch: 2, ceiling: 8.5) == .noEmptyBarPicture)
        c = clear
        c.otherPressHoldsBar = true
        #expect(PicturePassBatches.blocker(c, elapsed: 0.8, batch: 2, ceiling: 8.5) == .pressHoldsBar)
        c = clear
        c.waiterPending = true
        #expect(PicturePassBatches.blocker(c, elapsed: 0.8, batch: 2, ceiling: 8.5) == .waiterPending)
    }

    @Test func theFirstFailingGuardIsTheReason() {
        let all = PicturePassBatches.Conditions(hasCover: false, hasEmptyBarPicture: false, otherPressHoldsBar: true, waiterPending: true)
        #expect(PicturePassBatches.blocker(all, elapsed: 99, batch: 2, ceiling: 8.5) == .noCover)
        var c = all
        c.hasCover = true
        #expect(PicturePassBatches.blocker(c, elapsed: 99, batch: 2, ceiling: 8.5) == .noEmptyBarPicture)
        c.hasEmptyBarPicture = true
        #expect(PicturePassBatches.blocker(c, elapsed: 99, batch: 2, ceiling: 8.5) == .pressHoldsBar)
        c.otherPressHoldsBar = false
        #expect(PicturePassBatches.blocker(c, elapsed: 99, batch: 2, ceiling: 8.5) == .waiterPending)
        c.waiterPending = false
        #expect(PicturePassBatches.blocker(c, elapsed: 99, batch: 2, ceiling: 8.5) == .noTime)
    }

    @Test func aRoundStartsOnlyIfItsBatchAndTheLiftReserveFit() {
        // elapsed + batch + 1.5 <= ceiling, the edge included.
        #expect(PicturePassBatches.liftReserve == 1.5)
        #expect(PicturePassBatches.roundFits(elapsed: 5.0, batch: 2, ceiling: 8.5))
        #expect(!PicturePassBatches.roundFits(elapsed: 5.01, batch: 2, ceiling: 8.5))
        #expect(!PicturePassBatches.roundFits(elapsed: 1.0, batch: 2, ceiling: 4.0))
        #expect(PicturePassBatches.blocker(clear, elapsed: 5.01, batch: 2, ceiling: 8.5) == .noTime)
    }

    @Test func blockerReasonsReadAsLogText() {
        #expect(PicturePassBatches.Blocker.noCover.reason == "no cover")
        #expect(PicturePassBatches.Blocker.noEmptyBarPicture.reason == "no empty-bar picture")
        #expect(PicturePassBatches.Blocker.pressHoldsBar.reason == "a press holds the bar")
        #expect(PicturePassBatches.Blocker.waiterPending.reason == "a reveal or press is waiting")
        #expect(PicturePassBatches.Blocker.noTime.reason == "not enough cover time left")
    }

    // MARK: stop rule

    @Test func noRoundWhenNothingIsOwed() {
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
        // Three owed after the first round; batch 1 pictures two, batch 2 none.
        var left: Set<ItemID> = [id("c"), id("d"), id("e")]
        let gains: [Set<ItemID>] = [[id("c"), id("d")], []]
        var done = 0
        var last = 0
        while PicturePassBatches.wantsAnotherRound(followUpsDone: done, leftovers: left, lastRoundPictured: last) {
            let got = gains[done]
            done += 1
            last = got.count
            left = PicturePassBatches.remaining(left, pictured: got)
        }
        #expect(done == 2)
        #expect(left == [id("e")])
    }
}
