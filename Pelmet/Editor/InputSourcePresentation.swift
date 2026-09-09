import AppKit
import Carbon
import Observation

/// The input menu belongs to TextInputMenuAgent, but its name and artwork
/// belong to the selected input source. Keep them current while the editor is open.
@MainActor @Observable
final class InputSourcePresentation {
    static let shared = InputSourcePresentation()
    private(set) var name = String(localized: "Input Source")
    private(set) var icon: NSImage?

    private init() {
        refresh()
        // Process-lifetime singleton; the distributed observer lives with it.
        _ = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            name = String(localized: "Input Source")
            icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: name)
            return
        }
        func string(_ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        name = string(kTISPropertyLocalizedName) ?? String(localized: "Input Source")
        let bundleID = string(kTISPropertyBundleID)
        var image: NSImage?
        if let raw = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) {
            let url = Unmanaged<CFURL>.fromOpaque(raw).takeUnretainedValue() as URL
            image = NSImage(contentsOf: url)
            // WeType supplies a monochrome menu PDF, which needs template
            // rendering to remain legible in both light and dark settings.
            if bundleID == "com.tencent.inputmethod.wetype" { image?.isTemplate = true }
        }
        if image == nil, let raw = TISGetInputSourceProperty(source, kTISPropertyIconRef) {
            image = NSImage(iconRef: OpaquePointer(raw))
        }
        if image == nil, let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        icon = image ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: name)
    }
}
