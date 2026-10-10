// SettingsIndex.swift
// The setting rows the command bar can jump to, by label and a few words
// people reach for instead of it ("hotkey", "startup"). Static on purpose: the
// panes are SwiftUI and carry no registry to read. Labels are the rows' own
// catalog keys, so a row renamed there must be renamed here. Return opens
// Settings on the row's tab.

import Foundation

struct SettingsIndexEntry {
    let id: String
    let title: String
    let tab: SettingsTab
    let keywords: [String]
}

enum SettingsIndex {
    /// Localized at call time (the command bar builds it when it opens).
    static func entries() -> [SettingsIndexEntry] {
        func general(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .general, keywords: keywords)
        }
        func behavior(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .behavior, keywords: keywords)
        }
        func panel(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .panel, keywords: keywords)
        }
        func search(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .search, keywords: keywords)
        }
        return [
            general("launchAtLogin", String(localized: "Launch at login"),
                    ["startup", "login items", "open at login", "boot"]),
            general("showStatusItem", String(localized: "Show Pelmet icon in the menu bar"),
                    ["chevron", "icon", "iconless", "hide icon"]),
            general("hotkey", String(localized: "Keyboard shortcut"),
                    ["hotkey", "shortcut", "toggle", "show hide", "key"]),
            general("settingsHotkey", String(localized: "Open Settings"),
                    ["hotkey", "shortcut"]),
            general("rightClickMenu", String(localized: "Right-click menu"),
                    ["context menu", "empty spot", "bar menu"]),
            general("language", String(localized: "Display language"),
                    ["language", "translation", "locale"]),
            general("accessibility", String(localized: "Accessibility"),
                    ["permission", "access", "grant", "allow"]),
            general("screenRecording", String(localized: "Screen Recording"),
                    ["permission", "capture", "grant", "allow", "cover"]),

            behavior("animation", String(localized: "Animation"),
                     ["reveal", "smooth", "fade", "instant", "transition", "style", "speed"]),
            behavior("iconSpacing", String(localized: "Space between icons"),
                     ["gap", "padding", "spacing", "tight", "wide"]),
            behavior("hoverReveal", String(localized: "Reveal on hover"),
                     ["hover", "pointer", "mouse", "hands-free"]),
            behavior("hoverDelay", String(localized: "Hover delay"),
                     ["delay", "wait", "pointer"]),
            behavior("clickReveal", String(localized: "Reveal on click in empty menu bar area"),
                     ["click", "empty area", "blank"]),
            behavior("doubleClickReveal", String(localized: "Double-click reveals always-hidden too"),
                     ["double click", "always hidden"]),
            behavior("autoRehide", String(localized: "Automatically rehide"),
                     ["auto hide", "conceal", "timer", "delay", "seconds", "close"]),
            behavior("rehideElsewhere", String(localized: "Rehide when clicking elsewhere"),
                     ["click outside", "dismiss", "conceal"]),
            behavior("systemExtras", String(localized: "System extras"),
                     ["now playing", "camera", "airdrop", "focus", "timer", "collateral"]),
            behavior("clockClick", String(localized: "Clicking the clock opens Notification Center"),
                     ["notification center", "clock", "calendar", "shortcut"]),

            panel("hiddenIconsIn", String(localized: "Show hidden icons in"),
                  ["panel", "grid", "row", "notch", "overflow", "dropdown", "tray", "layout"]),
            panel("panelNames", String(localized: "Show names"),
                  ["labels", "names", "titles", "panel"]),
            panel("panelColumns", String(localized: "Columns"),
                  ["width", "per row", "grid", "panel"]),
            panel("panelGroups", String(localized: "Separators start a new row"),
                  ["groups", "separator", "dividers", "panel"]),
            panel("panelAlwaysHidden", String(localized: "Always Hidden"),
                  ["fold", "always hidden", "panel"]),

            search("searchHotkey", String(localized: "Search the menu bar"),
                   ["command bar", "find", "shortcut", "hotkey"]),
            search("itemShortcuts", String(localized: "Aliases and shortcuts"),
                   ["alias", "nickname", "shortcut", "hotkey", "icon shortcut"]),
            search("searchHistory", String(localized: "Reset Search History"),
                   ["history", "forget", "learning", "frecency", "clear"]),
        ]
    }

    /// The tab's name as the sidebar shows it, for a row's subtitle.
    static func tabName(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: String(localized: "General")
        case .behavior: String(localized: "Behavior")
        case .menuBar: String(localized: "Menu Bar")
        case .panel: String(localized: "Panel")
        case .search: String(localized: "Search")
        default: tab.rawValue
        }
    }
}
