// SearchPane.swift
// Settings › Search: the command bar's shortcut and the command bar itself
// to try, what it finds and the keys it takes, every alias and icon shortcut
// in one list, and its history. The list reads the command bar's own corpus,
// so names, icons and order are the ones search shows (bar order, Hidden
// first).

import AppKit
import PelmetCore
import SwiftUI

struct SearchPane: View {
    @Environment(AppState.self) private var appState
    /// The command bar's entries, read when the pane shows.
    @State private var corpus: [CommandBarEntry] = []
    /// Icons picked from "Add an icon…" that have no alias or shortcut yet.
    @State private var added: [String] = []

    /// Picks the command bar remembers; the revision makes this re-read when
    /// it saves or resets.
    private var searchPicks: Int {
        _ = appState.searchHistoryRevision
        return appState.commandBar.historyPickCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard {
                SettingRow(
                    title: "Search the menu bar",
                    caption: hotkeyCaption(appState.settings.searchHotkey, conflict: appState.searchHotkeyConflict,
                                           otherwise: "Type a few letters, press Return, and you're in that icon's menu.")
                ) {
                    ShortcutRecorder(shortcut: searchHotkey, fallback: .searchDefault)
                }
                .settingAnchor("searchHotkey")
                SearchDemoStage()
                    .settingAnchor("searchDemo")
            }
            finds
            keys
            aliases
            SettingsCard(title: "History") {
                SettingRow(
                    title: "Search learns what you open",
                    caption: "Icons you pick move up, and a search you repeat goes straight to your last answer. It stays on this Mac."
                ) { EmptyView() }
                SettingRow(
                    title: "Reset Search History",
                    caption: searchPicks == 0
                        ? "Nothing to reset yet. Pelmet learns from the icons you open with Search."
                        : "Forgets which icons you open and what you typed to find them. Shortcuts and aliases stay."
                ) {
                    Button("Reset") {
                        appState.commandBar.resetHistory()
                        appState.searchDemo.refresh()
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(searchPicks == 0)
                }
                .settingAnchor("searchHistory")
            }
        }
        .onAppear {
            corpus = CommandBarCorpus.build(appState: appState)
            appState.searchDemo.activate()
        }
        .onDisappear { appState.searchDemo.deactivate() }
        .onChange(of: appState.settings.itemAliases) { appState.searchDemo.refresh() }
        .onChange(of: appState.settings.itemHotkeys) { appState.searchDemo.refresh() }
    }

    // MARK: - What it finds

    /// Each kind of result with a query that finds one on this Mac: the
    /// person's own icons, not an example they may not have.
    private var finds: some View {
        let items = corpus.filter { $0.candidate.kind == .item }
        let hidden = items.first { $0.candidate.section == .hidden } ?? items.first
        let launcher = corpus.first { $0.candidate.kind == .launcher }
        let alias = appState.settings.itemAliases.values.sorted().first
        return SettingsCard(title: "What it finds") {
            findRow("Every icon, wherever it lives",
                    caption: "Visible, Hidden or Always Hidden. A tag says which.",
                    query: hidden.map { Self.probe($0.candidate.title) })
            findRow("Apps that aren't running",
                    caption: "Their icon isn't in the bar yet. Return opens the app.",
                    query: launcher.map { Self.probe($0.candidate.title) })
            findRow("Names you give",
                    caption: "An alias finds an icon by any word you like.",
                    query: alias)
            findRow("Pelmet's own commands",
                    caption: "Show or hide your icons, edit the layout, switch the animation, check for updates.",
                    query: Self.probe(String(localized: "Edit Layout")))
            findRow("Any setting",
                    caption: "Return takes you straight to it.",
                    query: Self.probe(String(localized: "Hover delay")))
        }
    }

    private func findRow(_ title: LocalizedStringKey, caption: LocalizedStringKey, query: String?) -> some View {
        SettingRow(title: title, caption: caption) {
            if let query {
                Button("Try “\(query)”") {
                    // Typed into the demo above, scrolled into view.
                    appState.settingsFocusRow = "searchDemo"
                    appState.searchDemo.focus(query: query)
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
    }

    /// A name's first word, cut short the way someone would start typing it.
    private static func probe(_ name: String) -> String {
        let word = (name.split(separator: " ").first.map(String.init) ?? name).lowercased()
        return word.count <= 6 ? word : String(word.prefix(5))
    }

    // MARK: - Keys

    private var keys: some View {
        SettingsCard(title: "Keys") {
            keyRow("↩", "Open the icon's menu")
            keyRow("⌘↩", "Show the icon in the menu bar instead")
            keyRow("⇥", "Finish the name it suggests")
            keyRow("↑ ↓", "Move through the results")
            keyRow("⌘K", "More for the selected icon: move it, give it an alias or a shortcut, quit its app")
            keyRow("⌘,", "Open Settings")
            keyRow("⎋", "Go back a step, then close")
        }
    }

    private func keyRow(_ keys: String, _ action: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // The recorder's chip type: modifier glyphs at menu size.
            Text(verbatim: keys)
                .font(.system(size: 13, weight: .medium))
                .kerning(1.5)
                .frame(width: 44, alignment: .leading)
            Text(action)
        }
    }

    // MARK: - Aliases and shortcuts

    private var aliases: some View {
        let listed = listedKeys
        return SettingsCard(title: "Aliases and shortcuts") {
            Text(listed.isEmpty
                 ? LocalizedStringKey("None yet. Give an icon a word of your own, or a shortcut that opens it from any app.")
                 : LocalizedStringKey("An alias finds an icon by any word you like. A shortcut opens its menu from any app. ⌘K on a search result adds them too."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(listed, id: \.self) { key in
                ItemSearchRow(key: key, name: name(for: key), glyph: glyph(for: key), present: entry(for: key) != nil) {
                    let id = ItemID(rawValue: key)
                    appState.setItemAlias("", for: id)
                    appState.setItemHotkey(nil, for: id)
                    added.removeAll { $0 == key }
                }
            }
            addMenu(excluding: Set(listed))
        }
        .settingAnchor("itemShortcuts")
    }

    /// Every icon with an alias or a shortcut, in search's order; ones not
    /// in the bar right now follow, by name.
    private var listedKeys: [String] {
        let settings = appState.settings
        var keys = Set(settings.itemAliases.keys).union(settings.itemHotkeys.keys).union(added)
        var out = corpus.filter { $0.candidate.kind == .item }.map(\.candidate.id).filter { keys.remove($0) != nil }
        out += keys.sorted { name(for: $0).localizedCaseInsensitiveCompare(name(for: $1)) == .orderedAscending }
        return out
    }

    private func addMenu(excluding listed: Set<String>) -> some View {
        let addable = corpus.filter { $0.candidate.kind == .item && !listed.contains($0.candidate.id) }
        return Menu("Add an icon…") {
            ForEach(addable, id: \.candidate.id) { entry in
                Button {
                    added.append(entry.candidate.id)
                } label: {
                    if case .image(let image) = entry.glyph {
                        Image(nsImage: RowGlyphCache.bitmap(for: image))
                    }
                    Text(verbatim: entry.candidate.title)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(addable.isEmpty)
    }

    private func entry(for key: String) -> CommandBarEntry? {
        corpus.first { $0.candidate.kind == .item && $0.candidate.id == key }
    }

    private func name(for key: String) -> String {
        entry(for: key)?.candidate.title ?? ItemNaming.displayName(for: ItemID(rawValue: key))
    }

    /// Search's glyph; for an icon not in the bar, its app's icon.
    private func glyph(for key: String) -> CommandBarRow.Glyph {
        if let entry = entry(for: key) { return entry.glyph }
        if let bundle = ItemID(rawValue: key).bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return .image(NSWorkspace.shared.icon(forFile: url.path))
        }
        return .symbol(CommandBarCorpus.pick("questionmark.app.dashed", "app.dashed"))
    }

    private var searchHotkey: Binding<HotkeySpec?> {
        Binding(
            get: { appState.settings.searchHotkey },
            set: { newValue in
                appState.settings.searchHotkey = newValue
                appState.settingsChanged()
            }
        )
    }
}

/// The command bar itself on a slice of desktop. Every key works and every
/// pick is real: ↩ opens the icon's menu in the bar. The desktop is drawn,
/// not the person's wallpaper: reading that file asks for access to the
/// folder it lives in (iCloud Drive, Documents), 2026-10-09.
private struct SearchDemoStage: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    /// Room for the bar at its tallest, under a strip of desktop.
    private static let top: CGFloat = 22
    private static let height = top + CommandBarLayout.panelHeight(listHeight: CommandBarLayout.tallestListHeight) + 18

    var body: some View {
        let demo = appState.searchDemo
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                backdrop
                    .contentShape(Rectangle())
                    .onTapGesture { demo.focus() }
                    .accessibilityHidden(true)
                demo.view
                    .frame(maxWidth: CommandBarLayout.width)
                    .frame(height: demo.contentHeight)
                    .glassEffect(.regular, in: .rect(cornerRadius: GlassPanel.cornerRadius))
                    .padding(.top, Self.top)
                    .padding(.horizontal, 12)
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Type to try it. It works for real: ↩ opens the icon's menu, ⌘K shows more.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Two soft blooms on a plain ground, enough for the glass to show.
    private var backdrop: some View {
        let dark = colorScheme == .dark
        return ZStack {
            Color(white: dark ? 0.1 : 0.93)
            RadialGradient(colors: [Color(red: dark ? 0.24 : 0.73, green: dark ? 0.31 : 0.8, blue: dark ? 0.61 : 1), .clear],
                           center: UnitPoint(x: 0.18, y: 0.08), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Color(red: dark ? 0.49 : 0.96, green: dark ? 0.24 : 0.77, blue: dark ? 0.49 : 0.86), .clear],
                           center: UnitPoint(x: 0.88, y: 0.26), startRadius: 0, endRadius: 340)
        }
    }
}

/// One icon's alias and shortcut, edited where they show.
private struct ItemSearchRow: View {
    @Environment(AppState.self) private var appState
    let key: String
    let name: String
    let glyph: CommandBarRow.Glyph
    /// False when the icon isn't in the bar right now (its app quit).
    let present: Bool
    let remove: () -> Void

    @State private var alias = ""
    /// Why the last shortcut was refused, until one is kept.
    @State private var refusal: String?
    @FocusState private var aliasFocused: Bool

    private var id: ItemID { ItemID(rawValue: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                RowGlyph(glyph: glyph)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name)
                        .lineLimit(1)
                    if !present {
                        Text("Not in the menu bar right now")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                aliasField
                ShortcutRecorder(shortcut: .constant(appState.settings.itemHotkeys[key]), fallback: nil, accept: record)
                Button {
                    // Emptied first: the field's commit on losing focus
                    // would otherwise save the old alias back right after.
                    alias = ""
                    remove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Remove alias and shortcut")
            }
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { alias = appState.settings.itemAliases[key] ?? "" }
    }

    /// The recorder's chip recipe, holding text instead of keys.
    private var aliasField: some View {
        TextField("Alias", text: $alias)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($aliasFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 130)
            .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(aliasFocused ? 0.04 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PelmetAccent.accent, lineWidth: aliasFocused ? 1.5 : 0))
            .onSubmit(commitAlias)
            .onChange(of: alias) { _, new in
                // The same cap the command bar keeps.
                if new.count > 40 { alias = String(new.prefix(40)) }
            }
            .onChange(of: aliasFocused) { _, focused in
                if !focused { commitAlias() }
            }
    }

    private func commitAlias() {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (appState.settings.itemAliases[key] ?? "") else { return }
        appState.setItemAlias(trimmed, for: id)
    }

    private func record(_ spec: HotkeySpec?) -> Bool {
        if let refused = appState.setItemHotkey(spec, for: id) {
            refusal = spec.map { CommandBarController.message(for: refused, spec: $0) }
            return false
        }
        refusal = nil
        return true
    }
}
