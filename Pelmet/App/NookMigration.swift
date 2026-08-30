// NookMigration.swift
// One-shot defaults migration for the nook → Pelmet rename (v0.2.0).
//
// The bundle ID changed app.fif7y.Nook → app.fif7y.Pelmet, which hands the app
// a brand-new empty UserDefaults suite. On first launch under the new ID this
// copies every key from the old domain, rewriting the identifiers that embed
// the old bundle ID or the old "Nook."-prefixed item titles (settings blob,
// NSStatusItem autosave position keys). The old domain is left on disk so a
// downgrade still finds its data. The old SMAppService login item cannot be
// unregistered from this bundle identity; the new one is registered instead
// and the orphan is called out in the release notes.

import Foundation
import PelmetEngine
import ServiceManagement

enum NookMigration {
    static let oldBundleID = "app.fif7y.Nook"
    static let newBundleID = "app.fif7y.Pelmet"
    private static let markerKey = "app.fif7y.Pelmet.migratedFromNook"

    /// True on installs that came from nook (marker present AND the old
    /// domain exists) — used to adapt the accessibility re-grant UX.
    static var didMigrate: Bool {
        UserDefaults.standard.bool(forKey: markerKey)
            && UserDefaults.standard.persistentDomain(forName: oldBundleID) != nil
    }
    private static let newSettingsKey = "app.fif7y.Pelmet.settings.v1"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: markerKey) else { return }
        guard defaults.data(forKey: newSettingsKey) == nil else {
            defaults.set(true, forKey: markerKey)
            return
        }
        guard let old = defaults.persistentDomain(forName: oldBundleID) else {
            defaults.set(true, forKey: markerKey)
            return
        }

        for (key, value) in old {
            defaults.set(migratedValue(value), forKey: migratedKey(key))
        }
        defaults.set(true, forKey: markerKey)

        // Re-register launch-at-login under the new identity if it was on.
        if let data = defaults.data(forKey: newSettingsKey),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["launchAtLogin"] as? Bool == true {
            try? SMAppService.mainApp.register()
        }
        PelmetLog.log("migration: copied \(old.count) defaults from \(oldBundleID)")
    }

    /// Old-ID and old-title fragments appear in key names (the settings blob's
    /// own key, NSStatusItem autosave keys like "NSStatusItem Preferred
    /// Position Nook.Separator.<UUID>").
    static func migratedKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: oldBundleID, with: newBundleID)
            .replacingOccurrences(of: " Nook.", with: " Pelmet.")
    }

    /// The settings blob is JSON; ItemIDs inside it read
    /// "status:app.fif7y.Nook::Nook.<title>" — rewrite both halves.
    static func migratedValue(_ value: Any) -> Any {
        guard let data = value as? Data,
              let text = String(data: data, encoding: .utf8),
              text.contains(oldBundleID) || text.contains("::Nook.")
        else { return value }
        let rewritten = text
            .replacingOccurrences(of: oldBundleID, with: newBundleID)
            .replacingOccurrences(of: "::Nook.", with: "::Pelmet.")
        return Data(rewritten.utf8)
    }
}
