// MenuBarTab.swift
// The layout editor: three borderless section regions (de-box — soft fills,
// no 1px borders), populated with the REAL icons (chooser shows the actual
// artifact). Direct manipulation: drag chips between and within sections;
// order applies automatically (smart default — no Apply button).

import PelmetCore
import PelmetEngine
import SwiftUI

/// Sits on the pane's title row (the settings shell places it) — the one
/// bar-wide action, out of the sections' way.
struct TidyBarButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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
}

/// One header for every card below the editor: title and action on one
/// line, a single short caption underneath. Hierarchy comes from type
/// size and the caption's own line, not from cramming both into a row.
private struct CardHeader<Trailing: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
                trailing()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The "+ Thing ⌄" trigger every card uses — one look for add actions.
private struct AddTrigger: View {
    let title: LocalizedStringKey
    var menuChevron = true

    var body: some View {
        // No explicit font: the ambient body size, which is what SwiftUI's
        // own Menu label renders at — the three add actions must not differ
        // in size just because one of them is a Menu.
        HStack(spacing: 4) {
            Label(title, systemImage: "plus")
            if menuChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
        }
        .foregroundStyle(PelmetAccent.accent)
        .contentShape(Rectangle())
    }
}

struct MenuBarTab: View {
    @Environment(AppState.self) private var appState
    @State private var dragSession = EditorDragSession()

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

                AppStandInsStrip()

                PelmetItemsStrip()

                SeparatorStrip()
        }
        .animation(.spring(duration: 0.3), value: appState.settings.sectionModel)
        .environment(dragSession)
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
    @Environment(EditorDragSession.self) private var session
    let section: PelmetCore.Section
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    let symbol: String

    /// Live tile frames in the strip's coordinate space, for insertion math.
    @State private var frames: [ItemID: CGRect] = [:]

    private var items: [ObservedItem] {
        appState.editorItems(in: section)
    }

    /// Tiles with the lifted one removed — the placeholder stands in for it.
    private var tiles: [ObservedItem] {
        guard let lifted = session.liftedItem else { return items }
        return items.filter { $0.id != lifted }
    }

    private var isTarget: Bool {
        session.target?.section == section
    }

    /// Where the placeholder sits: under the cursor while this strip is the
    /// target; at the lifted tile's home slot while the cursor is over no
    /// strip (so the row doesn't collapse the moment the drag leaves it).
    private var placeholderIndex: Int? {
        switch session.payload {
        case .item(_, let home, let homeIndex):
            if let target = session.target {
                return target.section == section ? min(target.index, tiles.count) : nil
            }
            return home == section ? min(homeIndex, tiles.count) : nil
        default:
            return nil
        }
    }

    private enum Slot: Identifiable {
        case tile(ObservedItem)
        case placeholder

        var id: String {
            switch self {
            case .tile(let item): item.id.rawValue
            case .placeholder: "pelmet.editor.placeholder"
            }
        }
    }

    private var slots: [Slot] {
        var slots = tiles.map(Slot.tile)
        if let index = placeholderIndex { slots.insert(.placeholder, at: index) }
        return slots
    }

    private var coordinateSpace: String { "pelmet.strip.\(section.rawValue)" }

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
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    switch slot {
                    case .tile(let item):
                        ItemTile(item: item, section: section, index: index)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(coordinateSpace))
                            } action: { frames[item.id] = $0 }
                    case .placeholder:
                        SlotPlaceholder()
                    }
                }
                if slots.isEmpty {
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
                    .fill(.quaternary.opacity(isTarget ? 0.8 : (section == .visible ? 0.35 : 0.55)))
            )
            .coordinateSpace(name: coordinateSpace)
            .onDrop(of: [.text], delegate: StripDropDelegate(
                section: section,
                session: session,
                order: { tiles.map(\.id) },
                frames: { frames },
                onDrop: handleDrop
            ))
            .animation(.spring(duration: 0.25), value: session.target)
            .animation(.spring(duration: 0.25), value: session.payload)
        }
    }

    private func handleDrop(_ payload: EditorDragSession.Payload, at index: Int) {
        switch payload {
        case .newItemsChip:
            appState.settings.sectionModel.newItemsDestination = section
            appState.settingsChanged()
        case .item(let id, _, _):
            let others = items.filter { $0.id != id }
            let before = index < others.count ? others[index].id : nil
            appState.moveItem(id, to: section, before: before)
        }
    }
}

/// Ghost slot marking where new menu bar icons land — the
/// `newItemsDestination` setting as a draggable artifact. Dashed placeholder
/// language (kin to SlotPlaceholder), not a bordered tile: it is a slot, not
/// an item.
private struct NewItemsChip: View {
    @Environment(EditorDragSession.self) private var session
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
        .onDrag {
            session.begin(.newItemsChip)
            return NSItemProvider(object: Self.dragID as NSString)
        }
    }
}

/// The one slot that moves during a drag: the lifted tile's stand-in, sized
/// like a tile so the row keeps its rhythm.
private struct SlotPlaceholder: View {
    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 9)
                .fill(.tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                )
                .frame(width: 34, height: 34)
            Text(" ")
                .font(.system(size: 9))
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

// MARK: - Icon tile

private struct ItemTile: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorDragSession.self) private var session
    let item: ObservedItem
    let section: PelmetCore.Section
    /// Position among the strip's slots at lift time — the home slot the
    /// placeholder keeps open while the cursor is over no strip.
    let index: Int
    @State private var hovered = false
    /// The hover card for inactive icons (unhideable / superseded). Opens
    /// after a beat over the tile, stays while the pointer is on the tile
    /// or the card (it holds a button), closes a beat after leaving both.
    @State private var cardShown = false
    @State private var cardHovered = false
    @State private var cardWork: Task<Void, Never>?

    private var displayName: String {
        if item.id.rawValue.contains("Pelmet.Separator") {
            return String(localized: "Separator")
        }
        // Pelmet's own extras: name the thing, not the app that hosts it.
        if item.id.rawValue.contains("Pelmet.MediaControls") {
            return String(localized: "Media")
        }
        if item.id.rawValue.contains("Pelmet.CameraMic") {
            return String(localized: "Camera")
        }
        if item.id.rawValue.contains("Pelmet.AirDrop") {
            return String(localized: "AirDrop")
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

    /// One of Pelmet's app stand-ins — same icon and name as the app it
    /// stands in for, so the tile says which one it is.
    private var isAppStandIn: Bool {
        item.id.rawValue.contains("::Pelmet.App.")
    }

    private var hasStandIn: Bool {
        guard let bundle = item.id.bundleID else { return false }
        return appState.settings.extraItems.contains { $0.kind == .appStandIn && $0.bundleID == bundle }
    }

    /// The bar kept this icon after Pelmet concealed it (observed, not
    /// inferred — see UnhideableTracker).
    private var isUnhideable: Bool {
        !isAppStandIn && (
            appState.unhideableKeys.contains(item.id.sectionKey)
                || appState.isBundlelessHost(item.id)
        )
    }

    /// The app's own icon, still in the bar after the user added a stand-in
    /// for it. Reads as inactive: the stand-in is the one that counts now.
    private var isSuperseded: Bool {
        hasStandIn && !isAppStandIn
    }

    private func scheduleCard() {
        guard isUnhideable || isSuperseded else { return }
        cardWork?.cancel()
        let wantShown = hovered || cardHovered
        guard wantShown != cardShown else { return }
        cardWork = Task {
            try? await Task.sleep(for: wantShown ? .milliseconds(450) : .milliseconds(250))
            guard !Task.isCancelled else { return }
            cardShown = wantShown
        }
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
                if isSuperseded {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                } else if isUnhideable {
                    // Outranks the link badge: "can't hide" matters more
                    // than "hides together".
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                } else if isAppStandIn {
                    Image(systemName: "sparkles")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                        .help("Pelmet stand-in — click opens the app; hides like any Pelmet item")
                } else if hasBundleSiblings {
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
        .opacity(isSuperseded || isUnhideable ? 0.4 : 1)
        .onHover { over in
            hovered = over
            scheduleCard()
        }
        .popover(isPresented: $cardShown, arrowEdge: .top) {
            InactiveIconCard(
                name: displayName,
                hasStandIn: hasStandIn,
                helperHosted: appState.isBundlelessHost(item.id),
                addStandIn: item.id.bundleID.map { bundle in
                    { appState.addAppStandIn(bundleID: bundle, name: displayName, in: section) }
                }
            )
            .onHover { over in
                cardHovered = over
                scheduleCard()
            }
        }
        .onDrag {
            hovered = false
            cardShown = false
            session.begin(.item(item.id, home: section, homeIndex: index))
            return NSItemProvider(object: item.id.rawValue as NSString)
        }
        .contextMenu {
            if isUnhideable || isSuperseded, let bundle = item.id.bundleID {
                if hasStandIn {
                    Text("Stand-in added — now turn this icon off in \(displayName)'s settings")
                } else {
                    Button("Add a stand-in for \(displayName)") {
                        appState.addAppStandIn(bundleID: bundle, name: displayName, in: section)
                    }
                }
                Link("Why can't Pelmet hide this?", destination: PelmetLinks.faqAppStandIns)
            }
        }
    }
}

/// Hover card for an icon Pelmet can't hide: what is going on, and the one
/// thing to do about it. Two states — no stand-in yet (offer one) and
/// stand-in exists (turn the app's own icon off). No border, soft fill,
/// one primary action.
private struct InactiveIconCard: View {
    let name: String
    let hasStandIn: Bool
    /// The icon's host is a bundle-less helper — the one cause Pelmet can
    /// name; otherwise the bar simply kept the icon when asked to hide it.
    let helperHosted: Bool
    let addStandIn: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasStandIn {
                Text("Its stand-in is ready")
                    .font(.headline)
                Text("Turn this icon off in \(name)'s settings. The stand-in takes over from there.")
            } else {
                Text("Incompatible app")
                    .font(.headline)
                if helperHosted {
                    Text("\(name) runs its menu bar icon from a helper macOS doesn't count as an app, so it won't show.")
                } else {
                    Text("macOS kept it in the bar when Pelmet asked to hide it.")
                }
                Text("A stand-in fixes that: a Pelmet shortcut that opens \(name) and works like any other menu bar item.")
            }
            HStack(spacing: 12) {
                if !hasStandIn, let addStandIn {
                    Button("Add a stand-in", action: addStandIn)
                        .buttonStyle(.borderedProminent)
                        .tint(PelmetAccent.accent)
                }
                Link("Learn more", destination: PelmetLinks.faqAppStandIns)
                    .foregroundStyle(PelmetAccent.accent)
            }
            .padding(.top, 2)
            if !hasStandIn {
                Text("Then turn the original off in \(name)'s settings.")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .frame(width: 260, alignment: .leading)
        .padding(14)
        // The popover hands key focus to its first control; a hover card
        // is not a form, so no ring on "Learn more".
        .focusEffectDisabled()
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
            CardHeader(
                symbol: "sparkles", title: "Pelmet items",
                caption: "Pelmet's own system extras — they hide like any icon"
            ) {
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
                    AddTrigger(title: "Shortcut", menuChevron: false)
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
                    caption: "Shows while audio plays. Click to play or pause, right-click for tracks.",
                    isOn: hasKind(.mediaControls)
                ) { toggleKind(.mediaControls, on: $0) }
                PelmetItemRow(
                    symbol: "video.fill", title: "Camera & mic indicator",
                    caption: "Appears while a camera or mic is live.",
                    isOn: hasKind(.cameraMicIndicator)
                ) { toggleKind(.cameraMicIndicator, on: $0) }
                PelmetItemRow(
                    symbol: ExtrasManager.airdropSymbol, title: "AirDrop",
                    caption: "Opens AirDrop in Finder.",
                    isOn: hasKind(.airdrop)
                ) { toggleKind(.airdrop, on: $0) }
                ForEach(appState.settings.extraItems.filter { $0.kind == .shortcut }) { spec in
                    HStack(spacing: 8) {
                        Image(systemName: spec.symbol ?? "bolt.fill")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(spec.shortcutName ?? String(localized: "Shortcut"))
                            .font(.callout)
                        Text("Runs the shortcut.")
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

// MARK: - App stand-ins

/// A Pelmet icon that opens an app. The answer for apps whose own icon Pelmet
/// can never hide (bundle-less helper hosts — ChatGPT Classic), and a launcher
/// for anything else. Mirrors the Pelmet-items card: same header, same
/// borderless "+" picker, same row shape.
private struct AppStandInsStrip: View {
    @Environment(AppState.self) private var appState

    private var standIns: [ExtraItemSpec] {
        appState.settings.extraItems.filter { $0.kind == .appStandIn }
    }

    private func showPicker() {
        // Out of the list: apps that already have a stand-in, and apps whose
        // real icon the editor can already manage (a stand-in would just
        // duplicate it). Incompatible icons stay — that is the whole point.
        let menu = ExtrasManager.appPickerMenu(
            barBundles: Set(appState.bundleCounts.keys),
            excluding: Set(standIns.compactMap(\.bundleID))
                .union(appState.manageableBarBundles)
        ) { app in
            appState.addAppStandIn(bundleID: app.bundleID, name: app.name)
        }
        PelmetLog.log("extras: app picker (\(menu.items.count) items)")
        // Off the button's own event turn: popping synchronously inside a
        // SwiftUI action ends the menu's tracking with the same click.
        let point = NSEvent.mouseLocation
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: point, in: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(
                symbol: "app.dashed", title: "App stand-ins",
                caption: "A Pelmet icon that opens an app — hides like any icon"
            ) {
                // AppKit menu behind a SwiftUI-styled trigger (SwiftUI's Menu
                // drops custom images on macOS).
                Button(action: showPicker) { AddTrigger(title: "App") }
                    .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(standIns) { spec in
                    AppStandInRow(spec: spec)
                }
                // Always-on guidance, not an empty state: the one thing a
                // user must know is that the app's OWN icon has to go.
                HStack(spacing: 6) {
                    Text("For apps whose own icon won't hide: add its stand-in, then turn that icon off in the app.")
                        .foregroundStyle(.tertiary)
                    Link("Learn more", destination: PelmetLinks.faqAppStandIns)
                        .foregroundStyle(PelmetAccent.accent)
                    Spacer()
                }
                .font(.caption)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
        }
    }
}

private struct AppStandInRow: View {
    @Environment(AppState.self) private var appState
    let spec: ExtraItemSpec

    @State private var pickingIcon = false
    @State private var iconHovered = false

    private func setRule(_ rule: StandInShowRule) {
        guard let index = appState.settings.extraItems.firstIndex(where: { $0.id == spec.id }) else { return }
        appState.settings.extraItems[index].showRule = rule
        appState.settingsChanged()
    }

    private func setSymbol(_ symbol: String?) {
        guard let index = appState.settings.extraItems.firstIndex(where: { $0.id == spec.id }) else { return }
        appState.settings.extraItems[index].symbol = symbol
        appState.settingsChanged()
    }

    private static func label(_ rule: StandInShowRule) -> LocalizedStringKey {
        switch rule {
        case .whileRunning: "Shows while the app runs"
        case .always: "Always shows — opens the app"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // The icon is a chooser: a soft tile with a chevron, the same
            // idiom as the rule menu beside it, brighter on hover.
            Button { pickingIcon = true } label: {
                HStack(spacing: 3) {
                    StandInGlyph(spec: spec, size: 18)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.secondary.opacity(iconHovered ? 0.2 : 0.1))
                        )
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { iconHovered = $0 }
            .help("Change icon")
            .popover(isPresented: $pickingIcon, arrowEdge: .bottom) {
                StandInIconPicker(spec: spec, choose: setSymbol)
            }
            Text(spec.appName ?? spec.bundleID ?? "?")
                .font(.callout)
            // The row's caption IS the rule: a quiet menu, not a segmented
            // control per row.
            Menu {
                // Toggles render the native checkmark on the current rule
                // (a Label's symbol is dropped by macOS menus).
                ForEach(StandInShowRule.allCases, id: \.self) { rule in
                    Toggle(Self.label(rule), isOn: Binding(
                        get: { rule == spec.resolvedShowRule },
                        set: { if $0 { setRule(rule) } }
                    ))
                }
            } label: {
                Text(Self.label(spec.resolvedShowRule))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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

/// A stand-in's glyph as it appears in the bar: the picked SF Symbol, else
/// the app's own icon, else a dashed placeholder for an app that is gone.
private struct StandInGlyph: View {
    let spec: ExtraItemSpec
    let size: CGFloat

    var body: some View {
        if let symbol = spec.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.8))
                .foregroundStyle(.primary)
        } else if let icon = ExtrasManager.appIcon(for: spec, size: size) {
            Image(nsImage: icon)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
        }
    }
}

/// Glyph chooser for a stand-in. Every option renders the real thing at bar
/// size — the app's own icon first (the default), then the symbol set.
/// Selected = accent ring over a soft fill, never a 1px cage.
private struct StandInIconPicker: View {
    let spec: ExtraItemSpec
    let choose: (String?) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8)

    /// A curated starter grid until the user types; then the whole system
    /// catalog, ranked by SymbolCatalog.search.
    private var symbols: [String] {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? ExtrasManager.standInSymbols
            : SymbolCatalog.search(query)
    }

    private func cell(symbol: String?) -> some View {
        let selected = spec.symbol == symbol
        return Button { choose(symbol) } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14))
                } else if let icon = ExtrasManager.appIcon(for: spec, size: 16) {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 14))
                }
            }
            .foregroundStyle(selected ? PelmetAccent.accent : .primary)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? PelmetAccent.accent.opacity(0.16) : Color.secondary.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(PelmetAccent.accent, lineWidth: selected ? 1.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu bar icon")
                .font(.headline)
            cell(symbol: nil)
                .overlay(alignment: .trailing) {
                    Text("App icon")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .offset(x: 58)
                }
            Divider()
            // Soft capsule, no border (de-box); the field's own focus ring
            // is off with the rest of the card.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField(
                    String(localized: "Search from \(SymbolCatalog.all.count.formatted()) icons"),
                    text: $query
                )
                    .textFieldStyle(.plain)
                    .focused($searching)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.09)))
            ScrollView {
                if symbols.isEmpty {
                    Text("No icons match")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(symbols, id: \.self) { symbol in
                            cell(symbol: symbol)
                        }
                    }
                }
            }
            .frame(height: 210)
        }
        .padding(14)
        .frame(width: 306)
        .focusEffectDisabled()
        .onAppear { searching = true }
    }
}

// MARK: - Separators

private struct SeparatorStrip: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(
                symbol: "divide", title: "Separators",
                caption: "Dividers for the bar — ⌘-drag them anywhere"
            ) {
                Button {
                    appState.settings.separators.append(SeparatorSpec(style: .dot))
                    appState.settingsChanged()
                } label: {
                    AddTrigger(title: "Separator", menuChevron: false)
                }
                .buttonStyle(.plain)
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
