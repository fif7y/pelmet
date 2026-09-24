// AppLanguage.swift
// In-app language override. Writes the per-app `AppleLanguages` default —
// the same key System Settings › Language & Region › Applications uses — so
// the two stay in sync. Bundle localization is fixed at launch, hence the
// relaunch.

import AppKit

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case en, de, fr, es, it
    case ptBR = "pt-BR"
    case ja
    case zhHans = "zh-Hans"
    case ko, ru

    var id: String { rawValue }

    /// Endonyms — a language name is shown in itself, never translated.
    var endonym: String {
        switch self {
        case .system: ""
        case .en: "English"
        case .de: "Deutsch"
        case .fr: "Français"
        case .es: "Español"
        case .it: "Italiano"
        case .ptBR: "Português (Brasil)"
        case .ja: "日本語"
        case .zhHans: "简体中文"
        case .ko: "한국어"
        case .ru: "Русский"
        }
    }

    private static let key = "AppleLanguages"
    private static let reopenKey = "pelmet.reopenSettingsAfterRelaunch"

    /// The app-level override only — the inherited system list doesn't count.
    static var current: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first
        else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    static func set(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    /// Relaunch on the user's say-so; the new instance lands back in Settings.
    static func offerRelaunch() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch Pelmet to change its language?")
        alert.informativeText = String(localized: "The new language applies the next time Pelmet opens. Your menu bar layout is kept.")
        alert.addButton(withTitle: String(localized: "Relaunch Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: reopenKey)
        relaunch()
    }

    /// Consumed once by the app delegate after a relaunch: the Settings tab
    /// to reopen on, nil when the relaunch was not ours.
    static func takeReopenSettingsTab() -> SettingsTab? {
        defer { UserDefaults.standard.removeObject(forKey: reopenKey) }
        guard let raw = UserDefaults.standard.string(forKey: reopenKey) else { return nil }
        return SettingsTab(rawValue: raw) ?? .general
    }

    /// Relaunch Pelmet and land back on `tab` (the icon spacing Apply,
    /// which needs a fresh process to read macOS's spacing).
    static func relaunchReopeningSettings(tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: reopenKey)
        relaunch()
    }

    /// Spawn a watcher that opens a fresh instance only after this one has
    /// fully quit — two overlapping instances would fight over the bar.
    private static func relaunch() {
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\""
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", script, Bundle.main.bundleURL.path]
        try? watcher.run()
        NSApp.terminate(nil)
    }
}
