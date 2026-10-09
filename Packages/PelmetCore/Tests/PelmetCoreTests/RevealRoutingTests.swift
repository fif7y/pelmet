import Foundation
import Testing
@testable import PelmetCore

@Suite struct RevealRoutingTests {
    // A reveal a person asks for follows the setting; the menu bar target is
    // the bar for every reason.
    private func followsTheSetting(_ reason: RevealReason) {
        #expect(RevealRouting.destination(for: reason, target: .menuBar) == .bar)
        #expect(RevealRouting.destination(for: reason, target: .panel) == .panel)
        #expect(RevealRouting.destination(for: reason, target: .row) == .panel)
    }

    // These need the real bar whatever the setting says.
    private func alwaysTheBar(_ reason: RevealReason) {
        for target in RevealTarget.allCases {
            #expect(RevealRouting.destination(for: reason, target: target) == .bar)
        }
    }

    @Test func hoverFollowsTheSetting() { followsTheSetting(.hover) }
    @Test func clickFollowsTheSetting() { followsTheSetting(.click) }
    @Test func doubleClickFollowsTheSetting() { followsTheSetting(.doubleClick) }
    @Test func hotkeyFollowsTheSetting() { followsTheSetting(.hotkey) }
    @Test func statusItemFollowsTheSetting() { followsTheSetting(.statusItem) }

    // Apply and the editor's preview measure and drag icons that are on the bar.
    @Test func settingsPreviewIsAlwaysTheBar() { alwaysTheBar(.settingsPreview) }
    // A ⌘-drag needs the hidden run on screen as a drop target.
    @Test func barDragIsAlwaysTheBar() { alwaysTheBar(.barDrag) }
    // "Always show everything here" is the bar by definition.
    @Test func displayPolicyIsAlwaysTheBar() { alwaysTheBar(.displayPolicy) }
    // Pelmet's own extras and "show in bar" ask for the bar itself.
    @Test func itemInBarIsAlwaysTheBar() { alwaysTheBar(.itemInBar) }

    @Test func rowTargetUsesThePanelPresenterInItsRowLayout() {
        #expect(RevealTarget.menuBar.panelLayout == nil)
        #expect(RevealTarget.panel.panelLayout == .panel)
        #expect(RevealTarget.row.panelLayout == .row)
    }

    // A downgrade, or a hand-edited blob, lands on the menu bar.
    @Test func unknownTargetDecodesAsTheMenuBar() throws {
        func decode(_ raw: String) throws -> RevealTarget {
            try JSONDecoder().decode([RevealTarget].self, from: Data("[\"\(raw)\"]".utf8))[0]
        }
        #expect(try decode("panel") == .panel)
        #expect(try decode("row") == .row)
        #expect(try decode("menuBar") == .menuBar)
        #expect(try decode("floatingBar") == .menuBar)
        #expect(try decode("") == .menuBar)
        let back = try JSONDecoder().decode([RevealTarget].self, from: JSONEncoder().encode(RevealTarget.allCases))
        #expect(back == RevealTarget.allCases)
    }
}
