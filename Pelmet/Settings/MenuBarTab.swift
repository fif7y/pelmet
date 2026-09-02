// MenuBarTab.swift
// The layout editor: three borderless section regions (de-box — soft fills,
// no 1px borders), populated with the REAL icons (chooser shows the actual
// artifact). Direct manipulation: drag chips between and within sections;
// order applies automatically (smart default — no Apply button).

import PelmetCore
import PelmetEngine
import SwiftUI

struct MenuBarTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // No own ScrollView — the settings shell provides scrolling + padding.
        // Generous section rhythm — whitespace is structure, not waste.
        VStack(alignment: .leading, spacing: 30) {
            if !appState.engineCanHide {
                    Label(
                        "Hiding is unavailable on this macOS build — reordering still works.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }

                HStack {
                    Spacer()
                    Button {
                        appState.tidyBar()
                    } label: {
                        Label(
                            appState.tidying ? "Tidying…" : "Tidy bar order",
                            systemImage: "wand.and.stars"
                        )
                        .font(.callout)
                    }
                    .disabled(appState.tidying)
                    .help("Physically arranges the bar to match the sections — icons that sit out of place slide their neighbors on every reveal.")
                }

                EditorSectionView(
                    section: .visible,
                    title: "Visible",
                    caption: "Always in the menu bar",
                    symbol: "eye"
                )
                EditorSectionView(
                    section: .hidden,
                    title: "Hidden",
                    caption: "A hover or click away — or ⌘-drag icons left of the chevron",
                    symbol: "eye.slash"
                )
                EditorSectionView(
                    section: .alwaysHidden,
                    title: "Always Hidden",
                    caption: "Out of sight until you double-click or ⌥-click the chevron",
                    symbol: "moon"
                )

                // The "New" chip above is the same setting made draggable —
                // this row is its discoverable, labeled twin.
                HStack(spacing: 10) {
                    Text("New menu bar icons go to")
                        .font(.callout)
                    PelmetSegments(selection: Binding(
                        get: { appState.settings.sectionModel.newItemsDestination },
                        set: { destination in
                            appState.settings.sectionModel.newItemsDestination = destination
                            appState.settingsChanged()
                        }
                    ), options: [
                        (.visible, "Visible"),
                        (.hidden, "Hidden"),
                        (.alwaysHidden, "Always hidden"),
                    ])
                    Spacer()
                }

                PelmetItemsStrip()

                SeparatorStrip()
        }
        .animation(.spring(duration: 0.3), value: appState.settings.sectionModel)
        // Editing the bar shows the bar: reveal everything while this tab is
        // open so drags in the editor and in the real menubar stay in sync.
        .onAppear {
            appState.reveal([.hidden, .alwaysHidden], reason: .settingsPreview)
        }
        .onDisappear {
            // Collapse the « if a placement expanded it during this session.
            OverflowChevron.restoreAfterEditing()
            appState.applyPointerDisplayPolicyAfterDismissal()
        }
    }
}

// MARK: - Section region

private struct EditorSectionView: View {
    @Environment(AppState.self) private var appState
    let section: PelmetCore.Section
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    let symbol: String

    private var items: [ObservedItem] {
        appState.editorItems(in: section)
    }

    @State private var rowTargeted = false
    /// Tiles are nested drop destinations, so the ROW's isTargeted flips
    /// false over every tile and true in the 6pt gaps — driving the trailing
    /// slot and row highlight straight off it made both pop per tile
    /// crossing, reflowing the whole row each time. `dragEngaged` is the
    /// stable union (row OR any tile targeted) with a short clear delay to
    /// ride out the one-frame gap between a tile untargeting and the row
    /// targeting.
    @State private var tileTargets = 0
    @State private var dragEngaged = false
    @State private var dragDisengage: Task<Void, Never>?

    private func updateDragEngaged() {
        let engaged = rowTargeted || tileTargets > 0
        dragDisengage?.cancel()
        if engaged {
            dragEngaged = true
        } else {
            dragDisengage = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                dragEngaged = false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            // Right-anchored like the real bar — icons cluster at the
            // trailing edge of the screen, so the editor mirrors it.
            FlowLayout(spacing: 6, trailing: true) {
                // New icons spawn at the far LEFT of the status area — the
                // chip marks that landing spot in the destination section.
                if appState.settings.sectionModel.newItemsDestination == section {
                    NewItemsChip()
                }
                ForEach(items, id: \.id.rawValue) { item in
                    ItemTile(item: item, section: section) { targeting in
                        tileTargets = max(0, tileTargets + (targeting ? 1 : -1))
                        updateDragEngaged()
                    }
                }
                // Trailing landing slot: appears while a chip hovers anywhere
                // over the row (append position on a row drop).
                if dragEngaged {
                    LandingSlot()
                }
                if items.isEmpty, !dragEngaged {
                    Text("Drop icons here")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(dragEngaged ? 0.8 : (section == .visible ? 0.35 : 0.55)))
            )
            .animation(.spring(duration: 0.25), value: dragEngaged)
            .dropDestination(for: String.self) { dropped, _ in
                guard let raw = dropped.first else { return false }
                if raw == NewItemsChip.dragID {
                    appState.settings.sectionModel.newItemsDestination = section
                    appState.settingsChanged()
                    return true
                }
                appState.moveItem(ItemID(rawValue: raw), to: section, before: nil)
                return true
            } isTargeted: { targeting in
                rowTargeted = targeting
                updateDragEngaged()
            }
        }
    }
}

/// Ghost slot marking where new menu bar icons land — the
/// `newItemsDestination` setting as a draggable artifact. Dashed placeholder
/// language (kin to LandingSlot), not a bordered tile: it is a slot, not an
/// item.
private struct NewItemsChip: View {
    static let dragID = "pelmet.new-items-marker"

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "sparkle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 20)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            .tertiary.opacity(0.6),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
            Text("New")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: 52)
        }
        .help("New menu bar icons land here — drag into another section to change it")
        .draggable(Self.dragID)
    }
}

/// Animated placeholder showing where a dragged chip will land.
private struct LandingSlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(.tint.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
            .frame(width: 34, height: 34)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

// MARK: - Icon tile

private struct ItemTile: View {
    @Environment(AppState.self) private var appState
    let item: ObservedItem
    let section: PelmetCore.Section
    /// Reports targeting transitions up so the section row can keep its
    /// drag affordances stable while the chip crosses nested destinations.
    var onTargeting: (Bool) -> Void = { _ in }
    @State private var hovered = false
    @State private var targeted = false

    private var displayName: String {
        if item.id.rawValue.contains("Pelmet.Separator") {
            return String(localized: "Separator")
        }
        if item.id.rawValue.contains("::com.apple.menuextra.") {
            let suffix = item.id.rawValue.components(separatedBy: ".").last ?? String(localized: "System")
            return suffix.replacingOccurrences(of: "-", with: " ").capitalized
        }
        return item.appName ?? item.id.bundleID?.components(separatedBy: ".").last ?? "?"
    }

    private var isSystemIcon: Bool {
        MenuBarPolicy.systemItem(for: item.id) != nil
    }

    /// Same-bundle siblings hide together (assertion granularity is per
    /// bundle) — surface that with a link badge instead of hiding the fact.
    /// System icons are exempt: they share the agent's bundle but hide
    /// individually via the system allowlist.
    private var hasBundleSiblings: Bool {
        // Pelmet's own items (extras, separators) hide individually.
        guard !isSystemIcon, let bundle = item.id.bundleID,
              bundle != PelmetBundle.mainID else { return false }
        // A live tile with a same-bundle sibling means count > 1; a concealed
        // tile with a live twin never reaches here (editorItems drops it).
        return (appState.bundleCounts[bundle] ?? 0) > 1
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let icon = ItemImageCache.icon(for: item.id) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.background.opacity(hovered ? 1 : 0.65))
                        .shadow(color: .black.opacity(hovered ? 0.18 : 0.08), radius: hovered ? 4 : 2, y: 1)
                )
                if hasBundleSiblings {
                    Image(systemName: "link")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                        .help("Icons from the same app hide together")
                }
                if isSystemIcon {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                        .help("System icon — Pelmet places it; whether it exists in the bar is set in System Settings › Control Center")
                }
            }
            Text(displayName)
                .font(.system(size: 9))
                .foregroundStyle(hovered ? .secondary : .tertiary)
                .lineLimit(1)
                .frame(maxWidth: 52)
        }
        .onHover { hovered = $0 }
        // Insertion gap: the tile slides right and an accent bar marks where
        // the dragged chip will land (before this tile).
        .padding(.leading, targeted ? 16 : 0)
        .overlay(alignment: .leading) {
            if targeted {
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: 34)
                    .offset(x: 5, y: -7)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.22), value: targeted)
        .draggable(item.id.rawValue)
        .dropDestination(for: String.self) { dropped, _ in
            guard let raw = dropped.first, raw != item.id.rawValue else { return false }
            if raw == NewItemsChip.dragID {
                appState.settings.sectionModel.newItemsDestination = section
                appState.settingsChanged()
                return true
            }
            appState.moveItem(ItemID(rawValue: raw), to: section, before: item.id)
            return true
        } isTargeted: { targeting in
            if targeting != targeted { onTargeting(targeting) }
            targeted = targeting
        }
    }
}

// MARK: - Pelmet items

/// Pelmet's own proxy items — they bypass the OS limitation that hides system
/// extras under assertions, because Pelmet controls their visibility directly.
private struct PelmetItemsStrip: View {
    @Environment(AppState.self) private var appState
    @State private var shortcutNames: [String] = []

    private func hasKind(_ kind: ExtraKind) -> Bool {
        appState.settings.extraItems.contains { $0.kind == kind }
    }

    private func toggleKind(_ kind: ExtraKind, on: Bool) {
        if on, !hasKind(kind) {
            appState.settings.extraItems.append(ExtraItemSpec(kind: kind))
        } else if !on {
            appState.settings.extraItems.removeAll { $0.kind == kind }
        }
        appState.settingsChanged()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Pelmet items")
                    .font(.headline)
                Text("Pelmet-made stand-ins for the system extras — these live in any section")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    if shortcutNames.isEmpty {
                        Text("No shortcuts in your library")
                    }
                    ForEach(shortcutNames, id: \.self) { name in
                        Button(name) {
                            appState.settings.extraItems.append(
                                ExtraItemSpec(kind: .shortcut, shortcutName: name, symbol: "bolt.fill")
                            )
                            appState.settingsChanged()
                        }
                    }
                } label: {
                    Label("Shortcut", systemImage: "plus")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .onAppear {
                    Task.detached {
                        let names = ExtrasManager.availableShortcuts()
                        await MainActor.run { shortcutNames = names }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                PelmetItemRow(
                    symbol: "playpause.fill", title: "Media controls",
                    caption: "Shows while audio plays (lingers a few minutes after) — click plays/pauses, right-click for tracks",
                    isOn: hasKind(.mediaControls)
                ) { toggleKind(.mediaControls, on: $0) }
                PelmetItemRow(
                    symbol: "video.fill", title: "Camera & mic indicator",
                    caption: "Exists only while a camera or mic is live — its section just decides where it appears",
                    isOn: hasKind(.cameraMicIndicator)
                ) { toggleKind(.cameraMicIndicator, on: $0) }
                PelmetItemRow(
                    symbol: ExtrasManager.airdropSymbol, title: "AirDrop",
                    caption: "Opens Finder's AirDrop view",
                    isOn: hasKind(.airdrop)
                ) { toggleKind(.airdrop, on: $0) }
                ForEach(appState.settings.extraItems.filter { $0.kind == .shortcut }) { spec in
                    HStack(spacing: 8) {
                        Image(systemName: spec.symbol ?? "bolt.fill")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(spec.shortcutName ?? String(localized: "Shortcut"))
                            .font(.callout)
                        Text("Runs your shortcut")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            appState.settings.extraItems.removeAll { $0.id == spec.id }
                            appState.settingsChanged()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
        }
    }
}

private struct PelmetItemRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Separators

private struct SeparatorStrip: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "divide")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Separators")
                    .font(.headline)
                Text("Decorative dividers you can ⌘-drag anywhere in the bar")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    appState.settings.separators.append(SeparatorSpec(style: .dot))
                    appState.settingsChanged()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a separator")
            }

            if !appState.settings.separators.isEmpty {
                HStack(spacing: 8) {
                    ForEach($state.settings.separators) { $separator in
                        SeparatorChip(separator: $separator) {
                            // Read the binding BEFORE the removeAll: the
                            // predicate runs inside a modify access on
                            // `settings`, and a @Binding get in there re-enters
                            // the settings getter — exclusivity crash.
                            let id = separator.id
                            appState.settings.separators.removeAll { $0.id == id }
                            appState.settingsChanged()
                        }
                    }
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
            }
        }
    }
}

private struct SeparatorChip: View {
    @Environment(AppState.self) private var appState
    @Binding var separator: SeparatorSpec
    let onDelete: () -> Void
    @State private var showsChooser = false
    @State private var hovered = false

    var body: some View {
        Button {
            showsChooser = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(separator.style == .space ? "␣" : separator.style.rawValue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(separator.style == .space ? .tertiary : .secondary)
                    .opacity(separator.style == .space ? 1 : max(separator.opacity, 0.25))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(.background.opacity(0.8))
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    )
                if hovered {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .popover(isPresented: $showsChooser, arrowEdge: .bottom) {
            // The chooser renders the real glyphs, current one ring-selected.
            VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(SeparatorStyle.allCases, id: \.self) { style in
                    Button {
                        separator.style = style
                        appState.settingsChanged()
                    } label: {
                        Text(style == .space ? "␣" : style.rawValue)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary.opacity(separator.style == style ? 0.8 : 0.3))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.tint, lineWidth: separator.style == style ? 1.5 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(Self.name(for: style))
                }
            }
            if separator.style != .space {
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { separator.opacity },
                        set: { value in
                            separator.opacity = value
                            appState.settingsChanged()
                        }
                    ), in: 0.1...1)
                    Text(separator.opacity, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .help("Separator opacity in the menu bar")
            }
            }
            .padding(10)
            .frame(width: 240)
        }
    }

    /// Localized twin of `SeparatorStyle.displayName` (PelmetCore has no catalog).
    private static func name(for style: SeparatorStyle) -> LocalizedStringKey {
        switch style {
        case .pipe: "Pipe"
        case .dot: "Dot"
        case .chevronLeft: "Chevron ‹"
        case .chevronRight: "Chevron ›"
        case .dash: "Dash"
        case .space: "Invisible spacer"
        }
    }
}

// MARK: - Flow layout

/// Minimal wrapping layout for icon tiles. `trailing` anchors each row to the
/// right edge (reading order unchanged) — the editor sections use it so they
/// mirror the real bar, which grows from the right side of the screen.
