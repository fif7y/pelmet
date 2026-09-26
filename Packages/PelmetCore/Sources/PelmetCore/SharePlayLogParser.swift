// SharePlayLogParser.swift
// SharePlay as Control Center narrates it. Its `faceTime` log category says,
// in the clear, when the FaceTime controller goes active or inactive and
// which AV mode the conversation is in (macOS 27, probed 2026-09-25). In a
// call, SharePlay included, the controls live in the camera pill and no
// SharePlay icon shows (walked with Pelmet quit while Music played over
// SharePlay in a video call). A session with no call (from Messages, or
// kept after hanging up: "AV-less", avMode 0) keeps the pill up wearing
// the SharePlay glyph with no camera or mic on, and Pelmet's Camera & mic
// item follows it through these lines. Pure string work so real lines can be pinned in a test.

import Foundation

public struct SharePlayState: Equatable, Sendable {
    /// Control Center's FaceTime controller is running a conversation.
    public var controllerActive = false
    /// The conversation's TUConversationAVMode: 0 none (AV-less), 1 audio,
    /// 2 video. Nil until a line names it.
    public var avMode: Int?

    public init() {}

    /// Where Apple's SharePlay icon would be in the bar.
    public var isLive: Bool { controllerActive && avMode == 0 }

    /// Folds one `faceTime` message in; false when it wasn't one of ours.
    @discardableResult
    public mutating func read(_ message: String) -> Bool {
        if message.hasPrefix("[Controller] is activating") {
            controllerActive = true
            if let mode = Self.number(after: "avMode = `", in: message) { avMode = mode }
        } else if message.hasPrefix("[Controller] is now inactive")
            || message.hasPrefix("[Controller] is already inactive") {
            self = SharePlayState()
        } else if message.hasPrefix("[Session] Updating state for avMode") {
            // "[Session] Updating state for avMode `.video`"
            if message.contains("`.none`") { avMode = 0 }
            else if message.contains("`.audio`") { avMode = 1 }
            else if message.contains("`.video`") { avMode = 2 }
        } else if message.hasPrefix("[Controller] User requested to continue AVLess SharePlay") {
            avMode = 0
        } else {
            return false
        }
        return true
    }

    /// "… state = `3`, avMode = `2`, uuid = …" → 2.
    private static func number(after key: String, in message: String) -> Int? {
        guard let range = message.range(of: key) else { return nil }
        return Int(message[range.upperBound...].prefix { $0.isNumber })
    }
}
