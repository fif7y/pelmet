import Carbon.HIToolbox
import Testing
@testable import Pelmet

/// A recorded shortcut is registered by key code, so it fires on the physical
/// key whatever input source is on. Its NAME used to come from
/// `charactersIgnoringModifiers`, which does not: ⌥A recorded under Korean
/// input read `⌥ㅁ` and stayed that way afterwards. The name now comes from
/// the Roman layout, with `chars` kept as the fallback.
@MainActor
struct ShortcutKeyNameTests {
    /// Stands in for the real layout so these run without one.
    let roman: @MainActor (Int) -> String? = { keyCode in keyCode == kVK_ANSI_A ? "a" : nil }

    @Test func theRomanLayoutNamesTheKey() {
        #expect(ShortcutRecorder.keyName(keyCode: kVK_ANSI_A, chars: "a", romanKey: roman) == "A")
    }

    @Test func aNonRomanInputSourceDoesNotRenameTheKey() {
        // What the recorder is handed with Korean input on: the same key
        // code, a jamo for its character.
        #expect(ShortcutRecorder.keyName(keyCode: kVK_ANSI_A, chars: "ㅁ", romanKey: roman) == "A")
    }

    @Test func charsRemainTheFallbackWhenTheLayoutHasNothing() {
        #expect(ShortcutRecorder.keyName(keyCode: 999, chars: "π", romanKey: roman) == "Π")
        #expect(ShortcutRecorder.keyName(keyCode: 999, chars: nil, romanKey: roman) == "?")
        #expect(ShortcutRecorder.keyName(keyCode: 999, chars: "x", romanKey: { _ in "" }) == "X")
    }

    @Test func namedKeysStayNamed() {
        // Space is in the table, and the Roman layout would call it " ".
        #expect(ShortcutRecorder.keyName(keyCode: kVK_Space, chars: " ", romanKey: { _ in " " }) == "Space")
        #expect(ShortcutRecorder.keyName(keyCode: kVK_F5, chars: nil, romanKey: { _ in nil }) == "F5")
        #expect(ShortcutRecorder.keyName(keyCode: kVK_LeftArrow, chars: nil, romanKey: { _ in nil }) == "←")
    }
}
