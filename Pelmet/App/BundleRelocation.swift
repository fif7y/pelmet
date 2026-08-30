// BundleRelocation.swift
// Sparkle installs updates under the pre-update filename, so nook-era users
// end up with a Nook.app that contains Pelmet. Beyond the cosmetic confusion,
// it's a TCC hazard: renaming the bundle after an Accessibility prompt has
// fired invalidates the recorded grant. So the very first thing a mis-named
// bundle does — before migration, before any TCC interaction — is rename
// itself and relaunch from the final path.

import AppKit

enum BundleRelocation {
    /// Returns true when the app is relaunching and the caller must not
    /// continue booting.
    static func relocateIfNeeded() -> Bool {
        let url = Bundle.main.bundleURL
        guard url.lastPathComponent == "Nook.app" else { return false }
        let dest = url.deletingLastPathComponent().appendingPathComponent("Pelmet.app")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return false }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            // Read-only volume, translocation, permissions — run from where
            // we are rather than dying over a filename.
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }
}
