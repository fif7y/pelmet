// ItemImageCache.swift
// Icon resolution for the layout editor: the owning app's icon for
// third-party items, the system symbol for Apple items, and Pelmet's own
// rendered glyphs for its items. (Live bar-glyph capture existed once —
// SCK crops of the shared "Menubar" window — but proved unfixable: faded
// captures from an inactive bar, notch-occluded garbage, tag-drift misses.
// Removed 2026-08-21 in favor of app icons only.)

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
enum ItemImageCache {
    private static var appIcons: [String: NSImage] = [:]

    private static var pelmetItemSymbols: [String: String] = [:]
    private static var pelmetItemImages: [String: NSImage] = [:]

    /// ExtrasManager registers each Pelmet item's SF Symbol by item title.
    static func registerPelmetItem(title: String, symbol: String) {
        pelmetItemSymbols[title] = symbol
    }

    /// Direct image registration for Pelmet items whose glyph is not an SF
    /// Symbol (separators render their text glyph).
    static func registerPelmetItem(title: String, image: NSImage) {
        pelmetItemImages[title] = image
    }

    static func icon(for item: ItemID) -> NSImage? {
        if let image = pelmetItemImages.first(where: { item.rawValue.hasSuffix($0.key) })?.value {
            return image
        }
        if let symbol = pelmetItemSymbols.first(where: { item.rawValue.hasSuffix($0.key) })?.value {
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let bundleID = item.bundleID {
            if bundleID == PelmetBundle.agentID {
                return systemSymbol(for: item)
            }
            if let cached = appIcons[bundleID] {
                return cached
            }
            let icon = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first?.icon
            if let icon {
                icon.size = NSSize(width: 20, height: 20)
                appIcons[bundleID] = icon
            }
            return icon
        }
        return nil
    }

    /// com.apple.menuextra.* → the SF Symbol the real item draws.
    private static func systemSymbol(for item: ItemID) -> NSImage? {
        let id = item.rawValue
        let symbol: String
        if id.contains("wifi") { symbol = "wifi" }
        else if id.contains("battery") { symbol = "battery.75percent" }
        else if id.contains("bluetooth") { symbol = "bluetooth" }
        else if id.contains("screen-mirroring") { symbol = "airplayvideo" }
        else if id.contains("clock") { symbol = "clock" }
        else if id.contains("audiovideo") { symbol = "video" }
        else if id.contains("controlcenter") { symbol = "switch.2" }
        else if id.contains("sound") { symbol = "speaker.wave.2" }
        else { symbol = "circle.dashed" }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}
