import AppKit
import Carbon
import PelmetCore
import PelmetEngine
import Testing
@testable import Pelmet

@MainActor
struct InputSourcePresentationTests {
    @Test func inputMenuTileUsesActiveSourceNameInsteadOfHostName() throws {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let property = try #require(TISGetInputSourceProperty(source, kTISPropertyLocalizedName))
        let name = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
        let item = ObservedItem(id: .bundleKey(PelmetBundle.textInputAgentID), frame: nil, appName: "TextInputMenuAgent")
        let tile = ItemTile(item: item, section: .hidden, index: 0)
        #expect(tile.displayName == name)
        #expect(tile.displayName != "TextInputMenuAgent")
    }

    @Test func inputMenuIconDoesNotUseHostApplicationPlaceholder() throws {
        let id = ItemID.bundleKey(PelmetBundle.textInputAgentID)
        let image = try #require(ItemImageCache.icon(for: id))
        if let host = NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.textInputAgentID).first?.icon {
            host.size = NSSize(width: 20, height: 20)
            #expect(image.tiffRepresentation != host.tiffRepresentation)
        }
    }
}
