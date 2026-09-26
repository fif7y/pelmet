// SharePlayLogParserTests.swift
// Real Control Center `faceTime` messages from macOS 27 (2026-09-25): a
// FaceTime video call, then Music over SharePlay in it. The AV-less
// continue line follows the binary's format string.

import Testing
@testable import PelmetCore

struct SharePlayLogParserTests {
    static let activating = "[Controller] is activating from callback conversationManager(_:conversationUpdatedMessagesGroupName:), state = `3`, avMode = `2`, uuid = `<private>`"
    static let nowInactive = "[Controller] is now inactive. From callback conversationManager(_:conversationUpdatedMessagesGroupName:)"
    static let alreadyInactive = "[Controller] is already inactive. During callback conversationManager(_:removedActiveConversation:)"

    @Test func aCallShowsNoIconEvenWhileSharing() {
        var state = SharePlayState()
        let known = [
            state.read(Self.activating),
            state.read("[Session] Updating state for avMode `.video`"),
        ]
        #expect(known == [true, true])
        #expect(state.controllerActive && state.avMode == 2)
        // Music over SharePlay in the call: the controls stay in the pill.
        let activity = state.read("[Session] New activity state created for `updateActivity(_:_:)`")
        #expect(!activity)
        #expect(!state.isLive)
    }

    @Test func hangingUpOnASessionKeepsItAsAVLess() {
        var state = SharePlayState()
        state.read(Self.activating)
        state.read("[Session] Updating state for avMode `.none`")
        #expect(state.isLive)
        state = SharePlayState()
        state.read(Self.activating)
        state.read("[Controller] User requested to continue AVLess SharePlay")
        #expect(state.isLive)
    }

    @Test func anAVLessActivationIsLive() {
        var state = SharePlayState()
        state.read("[Controller] is activating from callback conversationManager(_:stateChangedFor:), state = `3`, avMode = `0`, uuid = `<private>`")
        #expect(state.avMode == 0)
        #expect(state.isLive)
    }

    @Test func inactiveClearsEverything() {
        var state = SharePlayState()
        state.read(Self.activating)
        state.read("[Session] Updating state for avMode `.none`")
        state.read(Self.nowInactive)
        #expect(state == SharePlayState())
        state.read(Self.activating)
        state.read(Self.alreadyInactive)
        #expect(!state.controllerActive)
    }

    @Test func otherLinesAreIgnored() {
        var state = SharePlayState()
        let known = [state.read("[Controller] isSharePlayAllowed changed to true"), state.read("__viewWillAppear")]
        #expect(known == [false, false])
        #expect(state == SharePlayState())
    }
}
