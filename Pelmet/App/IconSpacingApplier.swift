// IconSpacingApplier.swift
// Writes macOS's own icon-spacing keys and gets every process Pelmet can
// reach to read them again: MenuBarAgent (the clock, Control Center and
// the system icons) is restarted, Pelmet relaunches itself. Every other
// app reads the keys when it next opens; nothing short of a login makes
// them all follow at once.

import AppKit
import PelmetCore
import PelmetEngine

enum IconSpacingApplier {
    /// What macOS holds right now, read the way AppKit reads it (per
    /// host), snapped to the slider. The key is the record: Pelmet keeps
    /// no copy of it, so the slider always shows what is in force even
    /// after a change made outside Pelmet.
    static func current() -> Int {
        let value = CFPreferencesCopyValue(
            IconSpacing.spacingKey as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        ) as? Int
        return value.map(IconSpacing.clamped) ?? IconSpacing.macOSDefault
    }

    /// Write (or delete, at the default) both keys, then restart the agent
    /// and Pelmet. Returns only on failure to write.
    @MainActor
    static func apply(_ spacing: Int, appState: AppState) {
        let keys = IconSpacing.keys(for: spacing)
        for (key, value) in [(IconSpacing.spacingKey, keys?.spacing), (IconSpacing.paddingKey, keys?.padding)] {
            CFPreferencesSetValue(
                key as CFString, value.map { $0 as CFNumber }, kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
            )
        }
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else {
            PelmetLog.log("spacing: preferences write failed")
            return
        }
        PelmetLog.log("spacing: applied \(spacing) → \(keys.map { "spacing=\($0.spacing) padding=\($0.padding)" } ?? "keys deleted")")
        rememberStaleApps(appState)

        // The agent respawns on its own within a second; the fresh Pelmet
        // boots against it like any agent restart.
        for agent in NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.agentID) {
            kill(agent.processIdentifier, SIGTERM)
        }
        AppLanguage.relaunchReopeningSettings(tab: .behavior)
    }

    // MARK: - Apps still on the old spacing

    /// Every app with a bar icon at Apply time keeps the old spacing until
    /// it relaunches. Remembered as bundle → pid across Pelmet's own
    /// relaunch: an app is still stale while that same process runs, and
    /// leaves the list the moment it quits or comes back with a new pid.
    private static let staleKey = "pelmet.iconSpacingStaleApps"

    @MainActor
    private static func rememberStaleApps(_ appState: AppState) {
        guard let snap = appState.snapshot else { return }
        var pids: [String: Int] = [:]
        let ids = snap.items.map(\.id) + Array(snap.concealed)
        for bundle in Set(ids.compactMap(\.bundleID)) {
            guard !PelmetBundle.ownIDs.contains(bundle), !MenuBarPolicy.isUnmanagedAppleBundle(bundle),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            else { continue }
            pids[bundle] = Int(app.processIdentifier)
        }
        UserDefaults.standard.set(pids, forKey: staleKey)
    }

    /// Localized names of the apps still running the process that read
    /// the old spacing, sorted. Empty once they have all relaunched (the
    /// record is dropped then).
    static func staleAppNames() -> [String] {
        guard let pids = UserDefaults.standard.dictionary(forKey: staleKey) as? [String: Int] else { return [] }
        var names: [String] = []
        var still: [String: Int] = [:]
        for (bundle, pid) in pids {
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                  app.bundleIdentifier == bundle, !app.isTerminated
            else { continue }
            still[bundle] = pid
            names.append(displayName(of: app) ?? bundle)
        }
        if still.isEmpty { UserDefaults.standard.removeObject(forKey: staleKey) }
        else if still.count != pids.count { UserDefaults.standard.set(still, forKey: staleKey) }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A login-item helper (…/DBngin.app/Contents/Library/LoginItems/
    /// DBnginMenuHelper.app) is named after the app that ships it, the
    /// way the editor's tiles are.
    private static func displayName(of app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL else { return app.localizedName }
        let parts = url.pathComponents
        if parts.count >= 5, parts[parts.count - 2] == "LoginItems", parts[parts.count - 3] == "Library",
           parts[parts.count - 4] == "Contents", parts[parts.count - 5].hasSuffix(".app") {
            let shipping = url.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            return FileManager.default.displayName(atPath: shipping.path)
        }
        return app.localizedName
    }
}
