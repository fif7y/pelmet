// UnhideableTrackerTests.swift
// Locks the observed "can't hide" rule: two sightings ≥4s apart within one
// conceal episode confirm; a proper conceal clears; a reveal resets timing.

import Foundation
import Testing
import PelmetCore
@testable import Pelmet

struct UnhideableTrackerTests {
    let gpt = ItemID(rawValue: "status:com.openai.chat::Item-0").sectionKey
    let snib = ItemID(rawValue: "status:app.fif7y.Snib::Item-0").sectionKey
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func confirmsAfterTwoSpacedSightingsAndClearsWhenHidden() {
        var tracker = UnhideableTracker()
        tracker.observe(live: [gpt], concealed: [gpt, snib], at: t0)
        #expect(tracker.confirmed.isEmpty)
        tracker.observe(live: [gpt], concealed: [gpt, snib], at: t0.addingTimeInterval(1))
        #expect(tracker.confirmed.isEmpty)
        tracker.observe(live: [gpt], concealed: [gpt, snib], at: t0.addingTimeInterval(5))
        #expect(tracker.confirmed == [gpt])
        tracker.observe(live: [], concealed: [gpt, snib], at: t0.addingTimeInterval(60))
        #expect(tracker.confirmed.isEmpty)
    }

    @Test func everythingLiveIsALostAssertionNotAVerdict() {
        var tracker = UnhideableTracker()
        tracker.observe(live: [gpt, snib], concealed: [gpt, snib], at: t0)
        tracker.observe(live: [gpt, snib], concealed: [gpt, snib], at: t0.addingTimeInterval(10))
        #expect(tracker.confirmed.isEmpty)
        // Siblings hid, ChatGPT stayed: that is the signal — but the clock
        // starts here, not at the lost-assertion sighting.
        tracker.observe(live: [gpt], concealed: [gpt, snib], at: t0.addingTimeInterval(12))
        #expect(tracker.confirmed.isEmpty)
        tracker.observe(live: [gpt], concealed: [gpt, snib], at: t0.addingTimeInterval(17))
        #expect(tracker.confirmed == [gpt])
    }

    @Test func revealResetsTimingButKeepsVerdict() {
        var tracker = UnhideableTracker()
        tracker.observe(live: [gpt], concealed: [gpt, snib], at: t0)
        tracker.observe(live: [gpt, snib], concealed: [], at: t0.addingTimeInterval(2))
        // First sighting of the new episode: no promotion off the stale clock.
        tracker.observe(live: [gpt], concealed: [gpt, snib], at: t0.addingTimeInterval(30))
        #expect(tracker.confirmed.isEmpty)
        tracker.observe(live: [gpt], concealed: [gpt, snib], at: t0.addingTimeInterval(35))
        #expect(tracker.confirmed == [gpt])
        tracker.observe(live: [gpt, snib], concealed: [], at: t0.addingTimeInterval(40))
        #expect(tracker.confirmed == [gpt])
    }
}
