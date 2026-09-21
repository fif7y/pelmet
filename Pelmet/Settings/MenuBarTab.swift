// MenuBarTab.swift
// The layout editor: three borderless section regions (de-box — soft fills,
// no 1px borders), populated with the REAL icons (chooser shows the actual
// artifact). Direct manipulation: drag chips between and within sections;
// order applies automatically (smart default — no Apply button).

import PelmetCore
import PelmetEngine
import SwiftUI

/// Sits on the pane's title row (the settings shell places it). Sets core
/// (docs/CORE-SETS.md M1): the editor is a drawing; this is the one door
/// through which the bar moves. Shows the pending move count (drawn edits
/// plus icons on the wrong side of the chevron) and Discard beside it.
struct ApplyBarButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let pending = appState.applyPending
        let failed = appState.applyReport.map { !$0.failed.isEmpty } ?? false
        let count = appState.pendingMoveCount
        HStack(spacing: 10) {
            // The pass runs silently with the cursor hidden (blind spot 3):
            // say what it did, or people press it twice.
            if !appState.applying, let report = appState.applyReport {
                Group {
                    let notMoved = report.failed.count + report.skipped.filter { $0.why == .notOnScreen }.count
                    if notMoved == 0 {
                        Text("Moved \(report.applied.count)")
                    } else {
                        Text("Moved \(report.applied.count), \(notMoved) not moved")
                            .help("Icons behind macOS's « have no place to be dragged from yet")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if !appState.settings.orderEdits.isEmpty, !appState.applying {
                Button("Discard") { appState.discardOrderEdits() }
                    .font(.callout)
                    .help("Forget the pending order changes; the editor shows the bar as it is")
            }
            // Same chip family as General's permission row (de-box, tinted
            // capsule): green while there is something to apply, so a
            // change in the editor visibly asks for the click; grey and
            // inert when the bar already matches.
            let title: Text = appState.applying ? Text("Applying…")
                : failed ? Text("Retry")
                : count > 0 ? Text("Apply (\(count))")
                : Text("Apply")
            let tint: Color = failed ? .orange : pending ? .green : .secondary
            TintChipButton(
                text: title,
                icon: Image(systemName: failed ? "arrow.clockwise" : "wand.and.stars"),
                tint: tint
            ) {
                appState.applyOrderEdits()
            }
            .disabled(appState.applying || !pending)
            .animation(.easeOut(duration: 0.2), value: pending)
            .help("Move the bar to match the editor: your order, and every icon on its section's side of the chevron. Each icon is dragged once with the cursor hidden; nothing moves until you press this.")
        }
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

    private var newItemsLabel: some View {
        Text("New menu bar icons go to").font(.callout)
    }

    private var newItemsSegments: some View {
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
    }

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
                if appState.overflowTrappedCount > 0 {
                    Label(
                        "Your menu bar is full: \(appState.overflowTrappedCount) icons sit behind macOS's « until there's room. Pelmet leaves them where they are.",
                        systemImage: "rectangle.compress.vertical"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                // Label + three segments is ~550pt in German against a
                // 468pt floor at the minimum window, and segments can't
                // wrap. Side by side while it fits, stacked when it doesn't.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        newItemsLabel
                        newItemsSegments
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        newItemsLabel
                        newItemsSegments
                    }
                }

                AppLaunchersStrip()

                PelmetItemsStrip()

                SeparatorStrip()
        }
        .animation(.spring(duration: 0.3), value: appState.settings.sectionModel)
        .environment(dragSession)
        // The editor is a drawing, nothing in the bar needs to be on screen
        // for it. Apply reveals what it must measure, then puts the bar
        // back (Gab, 2026-09-20).
        .onDisappear {
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
    /// Takes the tile count rather than reading `tiles` — every read of it
    /// rebuilds the board (see `slots(_:)`).
    private func placeholderIndex(tileCount: Int) -> Int? {
        switch session.payload {
        case .item(_, let home, let homeIndex):
            if let target = session.target {
                return target.section == section ? min(target.index, tileCount) : nil
            }
            return home == section ? min(homeIndex, tileCount) : nil
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

    /// `tiles` walks `AppState.editorItems`, which rebuilds the whole board
    /// (LaunchServices lookups included) on every call. One body pass used
    /// to make two — `slots` and `placeholderIndex` each asked — across
    /// three strips. Build it once and hand it down.
    private func slots(_ tiles: [ObservedItem]) -> [Slot] {
        var slots = tiles.map(Slot.tile)
        if let index = placeholderIndex(tileCount: tiles.count) {
            slots.insert(.placeholder, at: index)
        }
        return slots
    }

    private var coordinateSpace: String { "pelmet.strip.\(section.rawValue)" }

    var body: some View {
        let tiles = self.tiles
        let placedSlots = slots(tiles)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                // Italian runs 93 chars here and this caption is the only
                // place the ⌘-drag shortcut is taught — let it wrap rather
                // than squeeze the title beside it.
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // Right-anchored like the real bar — icons cluster at the
            // trailing edge of the screen, so the editor mirrors it.
            FlowLayout(spacing: 6, trailing: true) {
                // New icons spawn at the far LEFT of the status area — the
                // chip marks that landing spot in the destination section.
                if appState.settings.sectionModel.newItemsDestination == section {
                    NewItemsChip()
                }
                ForEach(Array(placedSlots.enumerated()), id: \.element.id) { index, slot in
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
                if placedSlots.isEmpty {
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
                order: { self.tiles.map(\.id) },
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
        if item.id.bundleID == PelmetBundle.textInputAgentID {
            return InputSourcePresentation.shared.name
        }
        // Pelmet's own items: name the thing, not the app that hosts it.
        switch item.id.pelmetItem {
        case .separator: return String(localized: "Separator")
        case .mediaControls: return String(localized: "Media")
        case .cameraMic: return String(localized: "Camera")
        case .airdrop: return String(localized: "AirDrop")
        case .timer: return String(localized: "Timer")
        case .userSwitching: return String(localized: "Users")
        case .timeMachine: return String(localized: "Time Machine")
        case .siri: return String(localized: "Siri")
        case .focus: return String(localized: "Focus")
        default: break
        }
        // SystemUIServer's extras enumerate as one item titled with every
        // extra it shows ("Siri, TimeMachine"): name each, comma-joined.
        if item.id.bundleID == PelmetBundle.systemUIServerID,
           case .status(_, let title) = item.id.parsed {
            let names = title.components(separatedBy: ", ").map { extra -> String in
                switch extra {
                case "TimeMachine": String(localized: "Time Machine")
                case "Item-0": String(localized: "System")
                default: extra
                }
            }
            return names.joined(separator: ", ")
        }
        if item.id.rawValue.contains("::com.apple.menuextra.") {
            let suffix = item.id.rawValue.components(separatedBy: ".").last ?? String(localized: "System")
            return suffix.replacingOccurrences(of: "-", with: " ").capitalized
        }
        // Apple's login-item extras are named after their executable
        // ("PasswordsMenuBarExtra", "WeatherMenu"); the tile says what the
        // icon is: the app that ships it.
        if let bundle = item.id.bundleID, MenuBarPolicy.isBundleHideableAppleHost(bundle),
           let shipping = Self.shippingAppName(for: bundle) {
            return shipping
        }
        return item.appName ?? item.id.bundleID?.components(separatedBy: ".").last ?? "?"
    }

    /// Finder's localized name of the app a login-item extra ships inside
    /// (…/Weather.app/Contents/Library/LoginItems/WeatherMenu.app → "Weather").
    /// nil for a host that is its own app. One LaunchServices lookup per
    /// bundle, then cached: the board asks on every tile render.
    private static var shippingAppNames: [String: String?] = [:]
    private static func shippingAppName(for bundle: String) -> String? {
        if let cached = shippingAppNames[bundle] { return cached }
        var name: String?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let parts = url.pathComponents
            // <App>.app / Contents / Library / LoginItems / <Extra>.app
            if parts.count >= 5, parts[parts.count - 2] == "LoginItems", parts[parts.count - 3] == "Library",
               parts[parts.count - 4] == "Contents", parts[parts.count - 5].hasSuffix(".app") {
                let app = url.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                name = FileManager.default.displayName(atPath: app.path)
            }
        }
        shippingAppNames[bundle] = name
        return name
    }

    private var isSystemIcon: Bool {
        MenuBarPolicy.systemItem(for: item.id) != nil
    }

    /// One of Pelmet's app launchers — same icon and name as the app it
    /// stands in for, so the tile says which one it is.
    private var isAppLauncher: Bool {
        item.id.isPelmetAppLauncher
    }

    private var hasLauncher: Bool {
        guard let bundle = item.id.bundleID else { return false }
        return appState.settings.extraItems.contains { $0.kind == .appLauncher && $0.bundleID == bundle }
    }

    /// The bar kept this icon after Pelmet concealed it (observed, not
    /// inferred — see UnhideableTracker).
    private var isUnhideable: Bool {
        !isAppLauncher && (
            appState.unhideableKeys.contains(item.id.sectionKey)
                || appState.isBundlelessHost(item.id)
                || appState.isDestroyedHost(item.id)
        )
    }

    /// The app's own icon, still in the bar after the user added a launcher
    /// for it. Reads as inactive: the launcher is the one that counts now.
    private var isSuperseded: Bool {
        hasLauncher && !isAppLauncher
    }

    /// macOS pins this item's spot (SystemUIServer's Siri and Time
    /// Machine, the clock at the bar's end). It hides, it just can't be
    /// dragged — so the tile says so rather than looking as movable as its
    /// neighbours.
    private var isPinnedBySystem: Bool {
        MenuBarPolicy.isPinnedAppleHost(item.id.bundleID)
            || MenuBarPolicy.systemItem(for: item.id) == .clock
    }

    /// Only SystemUIServer's pair has no capturable icon; the other pinned
    /// host (Kerberos) has a real one and keeps it.
    private var drawsOwnPinnedGlyph: Bool {
        item.id.bundleID == PelmetBundle.systemUIServerID
    }

    /// The enumerator's un-localized title ("Siri, TimeMachine") — what the
    /// glyph is keyed on, since the display name is translated.
    private var rawExtraTitle: String {
        if case .status(_, let title) = item.id.parsed { return title }
        return ""
    }

    /// The bar item swallowed Pelmet's drags three placements running; it
    /// hides fine but stays where its app put it (see AppState.immovableBundles).
    private var isImmovable: Bool {
        !isAppLauncher && appState.isImmovable(item.id)
    }

    private func scheduleCard() {
        guard isUnhideable || isSuperseded || isImmovable else { return }
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
              !PelmetBundle.ownIDs.contains(bundle) else { return false }
        // A live tile with a same-bundle sibling means count > 1; a concealed
        // tile with a live twin never reaches here (editorItems drops it).
        return (appState.bundleCounts[bundle] ?? 0) > 1
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isPinnedBySystem, drawsOwnPinnedGlyph {
                        // What the bar hands over for these is a blank
                        // rounded square that read as a broken tile. Draw
                        // Apple's own mark instead, ahead of the capture —
                        // the tile shows the real thing.
                        Image(nsImage: ExtraGlyph.pinnedAppleExtra(rawTitle: rawExtraTitle))
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    } else if let icon = ItemImageCache.icon(for: item.id) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                // Pinned tiles don't move, so they sit back: a flatter fill
                // and no lift, against the raised tiles you CAN drag.
                .opacity(isPinnedBySystem && !hovered ? 0.55 : 1)
                .padding(7)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.background.opacity(isPinnedBySystem ? 0.35 : (hovered ? 1 : 0.65)))
                        .shadow(
                            color: .black.opacity(isPinnedBySystem ? 0 : (hovered ? 0.18 : 0.08)),
                            radius: isPinnedBySystem ? 0 : (hovered ? 4 : 2),
                            y: isPinnedBySystem ? 0 : 1
                        )
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
                } else if isPinnedBySystem {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                        .help("Pinned by macOS — Pelmet can hide it, but not move it")
                } else if isAppLauncher {
                    Image(systemName: "sparkles")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                        .help("Pelmet app launcher — click opens the app; hides like any Pelmet item")
                } else if hasBundleSiblings {
                    Image(systemName: "link")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: 4, y: -4)
                        .help("Icons from the same app hide together")
                }
                if appState.isOutOfPlace(item.id) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(.background))
                        .offset(x: -4, y: -4)
                        .help("Not in place yet — it hides with this section, but sits on the other side of the chevron until Apply moves it")
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
                .truncationMode(.tail)
                .frame(maxWidth: 52)
        }
        // 52pt is ~11 Latin characters — anything longer (and every label
        // at a larger text size) needs a way back to the full name.
        .help(displayName)
        .opacity(isSuperseded || isUnhideable ? 0.4 : 1)
        .onHover { over in
            hovered = over
            scheduleCard()
        }
        .popover(isPresented: $cardShown, arrowEdge: .top) {
            InactiveIconCard(
                name: displayName,
                hasLauncher: hasLauncher,
                helperHosted: appState.isBundlelessHost(item.id),
                immovable: isImmovable && !isUnhideable,
                pinnedBySystem: isPinnedBySystem,
                missingReplacements: item.id.bundleID == PelmetBundle.systemUIServerID
                    ? appState.missingAppleReplacements
                    : [],
                isClock: MenuBarPolicy.systemItem(for: item.id) == .clock,
                usePelmetReplacements: { appState.useAppleExtraReplacements() },
                // A system icon shares the agent's bundle: a launcher for it
                // would open MenuBarAgent and draw nothing (the clock, 2026-09-21).
                addLauncher: isSystemIcon || MenuBarPolicy.isBundleHideableAppleHost(item.id.bundleID) ? nil : item.id.bundleID.map { bundle in
                    { appState.addAppLauncher(bundleID: bundle, name: displayName, in: section) }
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
                if hasLauncher {
                    Text("Launcher added — now turn this icon off in \(displayName)'s settings")
                } else {
                    Button("Add a launcher for \(displayName)") {
                        appState.addAppLauncher(bundleID: bundle, name: displayName, in: section)
                    }
                }
                Link("Why can't Pelmet hide this?", destination: PelmetLinks.faqAppLaunchers)
            }
        }
    }
}

/// Hover card for an icon Pelmet can't hide: what is going on, and the one
/// thing to do about it. Two states — no launcher yet (offer one) and
/// launcher exists (turn the app's own icon off). No border, soft fill,
/// one primary action.
private struct InactiveIconCard: View {
    let name: String
    let hasLauncher: Bool
    /// The icon's host is a bundle-less helper — the one cause Pelmet can
    /// name; otherwise the bar simply kept the icon when asked to hide it.
    let helperHosted: Bool
    /// Hides fine, won't be moved: the app's tray swallows synthetic drags.
    let immovable: Bool
    /// Hides fine, won't be moved, and no launcher applies: macOS itself
    /// pins the host (SystemUIServer's Siri / Time Machine).
    let pinnedBySystem: Bool
    /// SystemUIServer's pair only: which of Pelmet's Siri and Time Machine
    /// are still off. The card names exactly those and offers to turn them
    /// on, rather than dead-ending on "can't move it". Empty for the other
    /// pinned host (Kerberos), which has no replacement.
    let missingReplacements: [ExtraKind]
    /// The clock: pinned at the bar's end, hideable through the allowlist.
    let isClock: Bool
    let usePelmetReplacements: () -> Void
    let addLauncher: (() -> Void)?

    private func replacementButton(_ title: LocalizedStringKey) -> some View {
        Button(title, action: usePelmetReplacements)
            .buttonStyle(.borderedProminent)
            .tint(PelmetAccent.accent)
    }

    @ViewBuilder
    private var cardActions: some View {
        if !hasLauncher, let addLauncher {
            Button("Add a launcher", action: addLauncher)
                .buttonStyle(.borderedProminent)
                .tint(PelmetAccent.accent)
        }
        switch missingReplacements {
        case [.siri]:
            replacementButton("Use Pelmet's Siri")
        case [.timeMachine]:
            replacementButton("Use Pelmet's Time Machine")
        case [.siri, .timeMachine]:
            replacementButton("Use Pelmet's Siri and Time Machine")
        default:
            EmptyView()
        }
        if !pinnedBySystem {
            Link("Learn more", destination: PelmetLinks.faqAppLaunchers)
                .foregroundStyle(PelmetAccent.accent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasLauncher {
                Text("Its launcher is ready")
                    .font(.headline)
                Text("Turn this icon off in \(name)'s settings. The launcher takes over from there.")
            } else if pinnedBySystem {
                Text("Pinned by macOS")
                    .font(.headline)
                switch missingReplacements {
                case [.siri]:
                    Text("Siri is a locked macOS system icon. Turn on Pelmet's Siri below for an icon you can move.")
                case [.timeMachine]:
                    Text("Time Machine is a locked macOS system icon. Turn on Pelmet's Time Machine below for an icon you can move.")
                case [.siri, .timeMachine]:
                    Text("Siri and Time Machine are locked macOS system icons. Turn on Pelmet's Siri and Time Machine below for separate icons you can move.")
                default:
                    if isClock {
                        Text("The clock always sits at the right edge, so it can't be moved. Drop it in a hidden section to hide it.")
                    } else {
                        Text("Pelmet can hide \(name), but macOS keeps it in its own spot, so the editor can't move it.")
                    }
                }
            } else if immovable {
                Text("Stays where its app put it")
                    .font(.headline)
                Text("\(name) ignores the moves Pelmet makes in the bar, so it keeps its own spot. Hold ⌘ and drag it yourself, or give it a launcher.")
            } else {
                Text("Incompatible app")
                    .font(.headline)
                if helperHosted {
                    Text("\(name) runs its menu bar icon from a helper macOS doesn't count as an app, so it won't show.")
                } else {
                    Text("macOS kept it in the bar when Pelmet asked to hide it.")
                }
                Text("An app launcher fixes that: a Pelmet icon that opens \(name) and works like any other menu bar item.")
            }
            // Fixed-width card: a German or Italian button label pushed
            // "Learn more" — the only route to the FAQ — past the edge.
            // Side by side while both fit, stacked otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { cardActions }
                VStack(alignment: .leading, spacing: 8) { cardActions }
            }
            .padding(.top, 2)
            if !hasLauncher, !immovable {
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

    /// The glyph style of a singleton kind (media, camera & mic, AirDrop).
    private func styleBinding(_ kind: ExtraKind) -> Binding<ExtraStyle> {
        Binding(
            get: { appState.settings.extraItems.first { $0.kind == kind }?.resolvedStyle ?? .static },
            set: { style in
                guard let index = appState.settings.extraItems.firstIndex(where: { $0.kind == kind }) else { return }
                appState.settings.extraItems[index].style = style
                appState.settingsChanged()
            }
        )
    }

    /// When an activity-driven singleton kind sits in the bar (media
    /// controls, Time Machine, Focus).
    private func ruleBinding(_ kind: ExtraKind) -> Binding<ExtraShowRule> {
        Binding(
            get: { appState.settings.extraItems.first { $0.kind == kind }?.resolvedShowRule ?? kind.defaultShowRule },
            set: { rule in
                guard let index = appState.settings.extraItems.firstIndex(where: { $0.kind == kind }) else { return }
                appState.settings.extraItems[index].showRule = rule
                appState.settingsChanged()
            }
        )
    }

    private func toggleKind(_ kind: ExtraKind, on: Bool) {
        if on, !hasKind(kind) {
            appState.addExtra(ExtraItemSpec(kind: kind))
        } else if !on {
            appState.removeExtras(of: kind)
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
                            appState.addExtra(
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
                    caption: "Click to play or pause, right-click for tracks.",
                    isOn: hasKind(.mediaControls),
                    style: styleBinding(.mediaControls),
                    rule: ruleBinding(.mediaControls)
                ) { toggleKind(.mediaControls, on: $0) }
                PelmetItemRow(
                    symbol: "video.fill", title: "Camera & mic indicator",
                    caption: "Appears while a camera or mic is live.",
                    isOn: hasKind(.cameraMicIndicator)
                ) { toggleKind(.cameraMicIndicator, on: $0) }
                PelmetItemRow(
                    symbol: "siri", title: "Siri",
                    caption: "Opens Siri. Apple's own icon turns off in System Settings while this is on.",
                    isOn: hasKind(.siri)
                ) { toggleKind(.siri, on: $0) }
                PelmetItemRow(
                    symbol: "timer", title: "Timer",
                    caption: "A countdown that stays in the bar. Click for durations, rings when it ends.",
                    isOn: hasKind(.timer)
                ) { toggleKind(.timer, on: $0) }
                PelmetItemRow(
                    symbol: "moon.fill", title: "Focus",
                    caption: "Shows which Focus is on. Click for the Focus panel.",
                    isOn: hasKind(.focus),
                    rule: ruleBinding(.focus)
                ) { toggleKind(.focus, on: $0) }
                PelmetItemRow(
                    symbol: ExtraGlyph.timeMachineSymbol, title: "Time Machine",
                    caption: "Latest backup, Back Up Now. Apple's own icon turns off in System Settings while this is on.",
                    isOn: hasKind(.timeMachine),
                    rule: ruleBinding(.timeMachine)
                ) { toggleKind(.timeMachine, on: $0) }
                PelmetItemRow(
                    symbol: "", image: ExtraGlyph.airdrop, title: "AirDrop",
                    caption: "Opens AirDrop in Finder.",
                    isOn: hasKind(.airdrop)
                ) { toggleKind(.airdrop, on: $0) }
                PelmetItemRow(
                    symbol: "person.crop.circle", title: "Fast user switching",
                    caption: "Other users, the login window, lock screen.",
                    isOn: hasKind(.userSwitching)
                ) { toggleKind(.userSwitching, on: $0) }
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
                        RemoveRowButton {
                            appState.settings.extraItems.removeAll { $0.id == spec.id }
                            appState.settingsChanged()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .pelmetCardSurface()
        }
    }
}

private struct PelmetItemRow: View {
    let symbol: String
    /// A drawn glyph in place of the symbol (AirDrop's mark).
    var image: NSImage? = nil
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    let isOn: Bool
    /// Static or animated glyph (media controls only), offered once the
    /// item is on — the same in-row borderless menu the launcher rows use.
    var style: Binding<ExtraStyle>? = nil
    /// Shows when active or always (media, Time Machine, Focus), same
    /// menu, same moment.
    var rule: Binding<ExtraShowRule>? = nil
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image).renderingMode(.template)
                } else {
                    Image(systemName: symbol)
                }
            }
            .frame(width: 18)
            .foregroundStyle(.secondary)
            // The title holds its line; the caption is what wraps. Italian
            // captions run 105 chars against a 440pt card, and without this
            // the title wrapped mid-phrase beside its own caption.
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isOn, let style {
                PelmetMenuPicker(
                    selection: style,
                    options: [(.static, "Static"), (.animated, "Animated")],
                    borderless: true
                )
            }
            if isOn, let rule {
                PelmetMenuPicker(
                    selection: rule,
                    options: [(.whenActive, "When active"), (.always, "Always")],
                    borderless: true
                )
            }
            Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - App launchers

/// A Pelmet icon that opens an app. The answer for apps whose own icon Pelmet
/// can never hide (bundle-less helper hosts — ChatGPT Classic), and a launcher
/// for anything else. Mirrors the Pelmet-items card: same header, same
/// borderless "+" picker, same row shape.
private struct AppLaunchersStrip: View {
    @Environment(AppState.self) private var appState

    private var launchers: [ExtraItemSpec] {
        appState.settings.extraItems.filter { $0.kind == .appLauncher }
    }

    private func showPicker() {
        // Out of the list: apps that already have a launcher, and apps whose
        // real icon the editor can already manage (a launcher would just
        // duplicate it). Incompatible icons stay — that is the whole point.
        let menu = ExtrasManager.appPickerMenu(
            barBundles: Set(appState.bundleCounts.keys),
            excluding: Set(launchers.compactMap(\.bundleID))
                .union(appState.manageableBarBundles)
        ) { app in
            appState.addAppLauncher(bundleID: app.bundleID, name: app.name)
        }
        PelmetLog.log("extras: app picker (\(menu.items.count) items)")
        // Off the button's own event turn: popping synchronously inside a
        // SwiftUI action ends the menu's tracking with the same click.
        let point = NSEvent.mouseLocation
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: point, in: nil)
        }
    }

    private var guidance: some View {
        Text("Incompatible app not showing up in the menu bar? Add an app launcher.")
            .foregroundStyle(.tertiary)
    }

    private var learnMore: some View {
        Link("Learn more", destination: PelmetLinks.faqAppLaunchers)
            .foregroundStyle(PelmetAccent.accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // No header trigger: the add row below is the same door, and a
            // nav yields to the CTA it duplicates.
            CardHeader(
                symbol: "app.dashed", title: "App launchers",
                caption: "A Pelmet icon that opens an app — hides like any icon"
            ) { EmptyView() }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(launchers.enumerated()), id: \.element.id) { index, spec in
                    if index > 0 { RowDivider() }
                    AppLauncherRow(spec: spec)
                }
                if !launchers.isEmpty { RowDivider() }
                // The list's own add row — the entry point, and the whole
                // card when nothing is added yet.
                AddLauncherRow(action: showPicker)
                // Always-on guidance: the one thing a user must know is why
                // this feature exists at all.
                // The sentence alone is ~470pt in French against 440pt of
                // card, so the link can't share its line unconditionally.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { guidance; learnMore; Spacer() }
                    VStack(alignment: .leading, spacing: 3) { guidance; learnMore }
                }
                .font(.caption)
                .padding(.top, 9)
            }
            .pelmetCardSurface()
        }
    }
}

/// Hairline between rows inside a card — a separator between siblings,
/// not a border around anything (de-box).
/// The "take this row away" affordance — same glyph, same weight, wherever
/// a card row can be removed.
private struct RemoveRowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
            .frame(height: 1)
    }
}

/// The add entry point, shaped like a row so it reads as "the next one goes
/// here" — and the whole card in the empty state. Dashed tile = a slot, not
/// an item: the same language as the editor's "New" chip above.
private struct AddLauncherRow: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PelmetAccent.accent)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(PelmetAccent.accent.opacity(hovered ? 0.14 : 0))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                hovered ? PelmetAccent.accent.opacity(0.6) : Color.secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1, dash: [3.5, 3])
                            )
                    )
                Text("Add a new app launcher")
                    .font(.callout)
                    .foregroundStyle(PelmetAccent.accent)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(PelmetAccent.accent.opacity(0.75))
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct AppLauncherRow: View {
    @Environment(AppState.self) private var appState
    let spec: ExtraItemSpec

    @State private var pickingIcon = false
    @State private var iconHovered = false

    private func setRule(_ rule: ExtraShowRule) {
        guard let index = appState.settings.extraItems.firstIndex(where: { $0.id == spec.id }) else { return }
        appState.settings.extraItems[index].showRule = rule
        appState.settingsChanged()
    }

    private func setSymbol(_ symbol: String?) {
        guard let index = appState.settings.extraItems.firstIndex(where: { $0.id == spec.id }) else { return }
        appState.settings.extraItems[index].symbol = symbol
        appState.settingsChanged()
    }

    private var ruleBinding: Binding<ExtraShowRule> {
        Binding(get: { spec.resolvedShowRule }, set: { setRule($0) })
    }

    /// The narrow fallback: the current rule as a label, the full choice one
    /// click away — the app's own menu-sizes-to-its-selection control.
    private var ruleMenu: some View {
        PelmetMenuPicker(
            selection: ruleBinding,
            options: ExtraShowRule.allCases.map { ($0, Self.label($0)) },
            borderless: true
        )
    }

    private static func label(_ rule: ExtraShowRule) -> LocalizedStringKey {
        switch rule {
        case .whenActive: "Only while app is running"
        case .always: "Always shows"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // The icon is a chooser: a soft tile with a chevron, the same
            // idiom as the rule menu beside it, brighter on hover.
            Button { pickingIcon = true } label: {
                HStack(spacing: 3) {
                    LauncherGlyph(spec: spec, size: 18)
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
                LauncherIconPicker(spec: spec, choose: setSymbol)
            }
            Text(spec.appName ?? spec.bundleID ?? "?")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
            // Two options, so show both: a segmented control reads without a
            // click where the old menu label read as caption text. The app's
            // own segmented idiom, one size down for a card row.
            //
            // ViewThatFits, not a width budget on the translations: the pair
            // is ~330pt in Russian against 556pt of card, but a long app
            // name, a larger accessibility text size or a narrower window
            // can still squeeze it. When it no longer fits, one degrading
            // step to the menu — same choice, one click deeper — instead of
            // a clipped control.
            ViewThatFits(in: .horizontal) {
                PelmetSegments(
                    selection: ruleBinding,
                    options: ExtraShowRule.allCases.map { ($0, Self.label($0)) },
                    compact: true
                )
                ruleMenu
            }
            RemoveRowButton {
                appState.settings.extraItems.removeAll { $0.id == spec.id }
                appState.settingsChanged()
            }
        }
        .padding(.vertical, 4)
    }
}

/// A launcher's glyph as it appears in the bar: the picked SF Symbol, else
/// the app's own icon, else a dashed placeholder for an app that is gone.
private struct LauncherGlyph: View {
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

/// Glyph chooser for a launcher. Every option renders the real thing at bar
/// size — the app's own icon first (the default), then the symbol set.
/// Selected = accent ring over a soft fill, never a 1px cage.
private struct LauncherIconPicker: View {
    let spec: ExtraItemSpec
    let choose: (String?) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8)

    /// A curated starter grid until the user types; then the whole system
    /// catalog, ranked by SymbolCatalog.search.
    private var symbols: [String] {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? ExtrasManager.launcherSymbols
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
            // Laid out, not nudged: a hardcoded offset pinned the label's
            // right edge and grew it leftward over the tile in every
            // language longer than English (ru "Значок приложения").
            HStack(spacing: 8) {
                cell(symbol: nil)
                Text("App icon")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
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

/// A separator as it reads in the editor. Drawn styles show their own
/// character; the spacer has none, so it shows the gap itself as a dashed
/// slot — the "nothing lives here" shape the board already uses for empty
/// tiles. It wore `␣` before, which only says "space" to someone who knows
/// the convention, and the spacer went unfound because of it.
private struct SeparatorGlyph: View {
    let style: SeparatorStyle

    var body: some View {
        if style == .space {
            RoundedRectangle(cornerRadius: 2.5)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 12, height: 10)
        } else {
            Text(style.rawValue)
                .font(.system(size: 14, weight: .medium))
        }
    }
}

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
                    appState.addSeparator()
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
                SeparatorGlyph(style: separator.style)
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
                        SeparatorGlyph(style: style)
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
            // Every style has exactly one thing to tune, so the row is never
            // empty: a drawn glyph has opacity, and the spacer — whose whole
            // job is the gap — has width. Picking the spacer used to collapse
            // the popover to a bare button row with nothing to adjust.
            if separator.style == .space {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { separator.width },
                        set: { value in
                            separator.width = value.rounded()
                            appState.settingsChanged()
                        }
                    ), in: SeparatorSpec.widthRange)
                    Text("\(Int(separator.width)) pt")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .help("Spacer width in the menu bar")
            } else {
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
            // The popover focuses its first taker and rings it, which read as
            // a second selection competing with the tint ring that marks the
            // style actually in use (Gab, 2026-09-17: "the Focused state on
            // the most left item that always remains there"). One signal per
            // state. Disabling the EFFECT, not focusability, so the controls
            // stay keyboard-reachable; it propagates to the whole subtree.
            .focusEffectDisabled()
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
