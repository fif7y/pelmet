// PanelPane.swift
// Settings › Panel: where the hidden icons show (the bar, a panel, a row)
// over a preview of it, and the panel's options. The preview is the panel's
// own view, built by the presenter from the same settings, so the two never
// disagree, and it answers clicks, right-clicks, the edge drag and typing
// as the panel does (docs/PANEL-PLAN.md §5 Phase 5).

import AppKit
import PelmetCore
import SwiftUI

struct PanelPane: View {
    @Environment(AppState.self) private var appState

    private var target: RevealTarget { appState.revealTarget }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard {
                // The tab's one big choice, drawn as what each option looks
                // like. The caption sits under the cards so a longer one
                // never moves them from under the pointer that picked one.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Show hidden icons in")
                        .font(.system(size: 13, weight: .semibold))
                    RevealTargetPicker(selection: targetBinding)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .settingAnchor("hiddenIconsIn")
                PanelPreviewStage(target: target)
            }
            if target == .menuBar {
                SettingNote("Pick Panel or Row to set names, columns and groups.")
            } else {
                icons
            }
        }
        .onChange(of: appState.settingsFocusRow, initial: true) { _, row in
            // Search found a row this mode doesn't draw: land on the picker
            // that brings it.
            guard let row, Self.modeRows[row].map({ !$0.contains(target) }) == true else { return }
            appState.settingsFocusRow = "hiddenIconsIn"
        }
    }

    /// The Icons rows and the modes that draw them.
    private static let modeRows: [String: Set<RevealTarget>] = [
        "panelNames": [.panel], "panelColumns": [.panel], "panelClosedApps": [.panel, .row],
        "panelGroups": [.panel, .row], "panelAlwaysHidden": [.panel, .row], "panelFold": [.panel],
    ]

    private var caption: LocalizedStringKey {
        switch target {
        case .menuBar: "They slide out beside the chevron."
        case .panel: "A grid under the chevron, in your menu bar order. Nothing hides behind the notch."
        case .row: "One row under the menu bar, at menu bar size. Nothing hides behind the notch."
        }
    }

    private var icons: some View {
        let options = appState.settings.panel
        return SettingsCard(title: "Icons") {
            if target == .panel {
                SettingRow(title: "Columns",
                           caption: "Auto picks a width that fits your icons. You can also drag the panel's edge.") {
                    PelmetMenuPicker(selection: binding(\.columns), options: columnChoices(options.columns))
                }
                .settingAnchor("panelColumns")
                // Dimmed, not removed, with Always Hidden off: gone, it would
                // pull the Always Hidden picker up from under the pointer.
                SettingRow(title: "Fold", caption: "What you click to open Always Hidden.") {
                    PelmetSegments(selection: binding(\.alwaysHiddenFold), options: [
                        (.tile, "Tile"), (.count, "Count"), (.handle, "Handle"),
                    ], compact: true)
                }
                .disabled(options.alwaysHidden == .hidden)
                .opacity(options.alwaysHidden == .hidden ? 0.45 : 1)
                .settingAnchor("panelFold")
            }
            SettingRow(title: "Always Hidden", caption: alwaysHiddenCaption(options.alwaysHidden)) {
                PelmetMenuPicker(selection: binding(\.alwaysHidden), options: [
                    (.folded, "Folded each time"), (.asLeft, "As you left it"), (.hidden, "Don't show"),
                ])
            }
            .settingAnchor("panelAlwaysHidden")
            if target == .panel {
                SettingToggleRow(title: "Show names", caption: "Names under each icon. Off fits more in a row.",
                                 isOn: binding(\.showsNames))
                    .settingAnchor("panelNames")
            }
            SettingToggleRow(title: "Show closed apps", caption: "Apps that aren't running, dimmed. A click opens one.",
                             isOn: binding(\.showsClosedApps))
                .settingAnchor("panelClosedApps")
            SettingToggleRow(
                title: "Separators start a new row",
                caption: target == .row
                    ? "Keeps the groups you made in the menu bar apart."
                    : "Keeps the groups you made in the menu bar together, one row each.",
                isOn: binding(\.separatorsBreakRows))
                .settingAnchor("panelGroups")
        }
    }

    /// The row draws no fold: its right-click menu shows them.
    private func alwaysHiddenCaption(_ mode: PanelOptions.AlwaysHiddenMode) -> LocalizedStringKey {
        switch (target, mode) {
        case (.row, .hidden): "Out of the row. ⌥-click the chevron or search to reach them."
        case (.row, _): "Out of the row until you turn them on in its right-click menu."
        case (_, .hidden): "Out of the panel. ⌥-click the chevron or search to reach them."
        default: "The fold at the end of the panel."
        }
    }

    /// Auto and 3 to 8, plus a width the edge drag set outside them.
    private func columnChoices(_ current: Int?) -> [(Int?, LocalizedStringKey)] {
        var counts = Array(3...8)
        if let current, !counts.contains(current) { counts.append(current); counts.sort() }
        return [(nil, "Auto")] + counts.map { (Optional($0), LocalizedStringKey(String($0))) }
    }

    /// Picked here, the layout is the setting: the dev override gives way.
    private var targetBinding: Binding<RevealTarget> {
        Binding(get: { appState.revealTarget }, set: { appState.panelPresenter.setTarget($0) })
    }

    private func binding<T>(_ keyPath: WritableKeyPath<PanelOptions, T>) -> Binding<T> {
        Binding(
            get: { appState.settings.panel[keyPath: keyPath] },
            set: { newValue in
                appState.settings.panel[keyPath: keyPath] = newValue
                appState.settingsChanged()
            })
    }
}

/// The end of a menu bar on a strip of desktop, the panel hanging under its
/// chevron as it does on screen. In Menu bar mode the chevron slides drawn
/// icons out the way the Animation setting does.
private struct PanelPreviewStage: View {
    @Environment(AppState.self) private var appState
    let target: RevealTarget

    /// This preview's filter, selection and fold, apart from the real panel's.
    @State private var query = ""
    @State private var selected: PanelTile?
    @State private var foldOpen = false
    @State private var panelShown = true
    @State private var barRevealed = false
    @State private var revealTask: Task<Void, Never>?
    /// The panel's right edge in the window: it stays put while the left
    /// edge is dragged, as on screen.
    @State private var panelMaxX: CGFloat = 0
    @State private var tip: String?
    @State private var tipTask: Task<Void, Never>?
    @State private var height = Self.minHeight
    @State private var shrinkTask: Task<Void, Never>?
    /// Bumped when the presenter has pictures or apps this hasn't drawn.
    @State private var revision = 0
    @FocusState private var focused: Bool

    private static let minHeight: CGFloat = 110
    private static let maxHeight: CGFloat = 620
    private static let barHeight: CGFloat = 24
    private static let dot: CGFloat = 12
    private static let gap: CGFloat = 10
    private static let inset: CGFloat = 14
    private static let visibleDots = 3
    private static let hiddenDots = 4
    /// The chevron's right edge, in from the stage's.
    private static let chevronInset = inset + CGFloat(visibleDots) * (dot + gap)

    private var presenter: PanelPresenter { appState.panelPresenter }

    var body: some View {
        let _ = revision
        let built = target.panelLayout.flatMap {
            presenter.previewContent(layout: $0, query: query, selected: selected, foldOpen: foldOpen)
        }
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                DemoBackdrop()
                    .contentShape(Rectangle())
                    .onTapGesture { if target != .menuBar { focused = true } }
                    .accessibilityHidden(true)
                bar
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            // An overlay sets no size: a panel wider than the stage runs off
            // its left edge, as it would off the screen's, and the stage
            // stays the card's width.
            .overlay(alignment: .topTrailing) {
                if let built, panelShown {
                    panel(built.content, model: built.model)
                        .padding(.top, Self.barHeight + PanelPresenter.gapBelowBar)
                        .padding(.trailing, Self.chevronInset - PanelPresenter.pastChevron)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focusable(target != .menuBar)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in key(press) }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            presenter.readCorpus()
            revision += 1
        }
        .onChange(of: target, initial: true) { _, target in switched(to: target) }
        .task(id: passKey) { picture() }
    }

    private var hint: LocalizedStringKey {
        switch target {
        case .menuBar: "Try it: click the chevron."
        case .panel: "Try it: drag the panel's left edge, right-click it, or click it and type."
        case .row: "Try it: right-click it, or click it and type."
        }
    }

    // MARK: - Bar

    private var bar: some View {
        let open = target == .menuBar ? barRevealed : panelShown
        return HStack(spacing: Self.gap) {
            if target == .menuBar {
                // Clipped at the chevron, so a slide comes out from behind it.
                HStack(spacing: Self.gap) {
                    ForEach(0..<Self.hiddenDots, id: \.self) { _ in dot }
                }
                .offset(x: hiddenOffset)
                .opacity(barRevealed ? 1 : 0)
                .animation(MockBar.animation(appState.settings.revealAnimation, revealed: barRevealed), value: barRevealed)
                .frame(width: hiddenWidth, alignment: .trailing)
                .clipped()
            }
            Button(action: chevronClicked) {
                Image(systemName: open ? "chevron.right" : "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PelmetAccent.accent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: Self.dot, height: Self.barHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            ForEach(0..<Self.visibleDots, id: \.self) { _ in dot }
        }
        .padding(.trailing, Self.inset)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: Self.barHeight)
        .background(.ultraThinMaterial)
    }

    private var dot: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(Color.primary.opacity(0.75))
            .frame(width: Self.dot, height: Self.dot)
    }

    private var hiddenWidth: CGFloat { CGFloat(Self.hiddenDots) * Self.dot + CGFloat(Self.hiddenDots - 1) * Self.gap }

    private var hiddenOffset: CGFloat {
        guard appState.settings.revealAnimation == .smooth, !barRevealed else { return 0 }
        return hiddenWidth  // parked behind the chevron
    }

    private func chevronClicked() {
        if target == .menuBar {
            barRevealed.toggle()
        } else {
            withAnimation(panelShown
                ? .timingCurve(0.55, 0, 0.8, 0.4, duration: AppTiming.panelExit)
                : .timingCurve(0.16, 1, 0.3, 1, duration: AppTiming.panelEntrance)) {
                panelShown.toggle()
            }
            if !panelShown { focused = false }
        }
    }

    // MARK: - Panel

    private func panel(_ content: PanelContent, model: PanelModel) -> some View {
        var shown = content
        shown.columnsTip = tip
        let drawn = shown
        return PanelView(
            content: drawn,
            // A first click selects, so a click before typing stays here;
            // the selected tile, or Return, opens for real.
            onPress: { tile in
                focused = true
                // The fold tile is a control, not an icon: it opens at once.
                if tile == .fold {
                    selected = tile
                    flipFold(drawn)
                } else if drawn.selected == tile {
                    presenter.press(tile)
                } else {
                    selected = tile
                }
            },
            onFold: { flipFold(drawn) },
            tileMenu: { presenter.menu(for: $0) },
            panelMenu: { presenter.panelMenu(shown: drawn) { flipFold(drawn) } },
            onColumnsDrag: { x, ended in dragColumns(x: x, ended: ended, model: model) },
            onColumnsReset: {
                presenter.setAutoColumns()
                showTip(String(localized: "Auto"), for: 0.8)
            })
            .glassEffect(.regular, in: .rect(cornerRadius: PanelPresenter.cornerRadius))
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                panelMaxX = frame.maxX
                fit(Self.barHeight + PanelPresenter.gapBelowBar + frame.height + 20)
            }
    }

    /// Grows at once; shrinks once things settle (a fold closing, a menu
    /// going), and not while typing, so the rows below stay put.
    private func fit(_ need: CGFloat) {
        let need = min(max(need, Self.minHeight), Self.maxHeight)
        shrinkTask?.cancel()
        if need >= height {
            height = need
        } else if query.isEmpty {
            shrinkTask = Task {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.22)) { height = need }
            }
        }
    }

    private func switched(to target: RevealTarget) {
        revealTask?.cancel()
        query = ""
        selected = nil
        foldOpen = false
        panelShown = true
        barRevealed = false
        focused = false
        guard target == .menuBar else { return }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.22)) { height = Self.minHeight }
        // Once, so the style shows without a click.
        revealTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { barRevealed = true }
        }
    }

    private func flipFold(_ shown: PanelContent) {
        foldOpen = presenter.flipFold(shown: shown.showsAlwaysHidden, foldOpen: foldOpen)
    }

    private func dragColumns(x: CGFloat, ended: Bool, model: PanelModel) {
        let columns = presenter.setColumns(distance: panelMaxX - x, model: model)
        showTip(String(localized: "\(columns) per row"), for: ended ? 0.5 : nil)
    }

    private func showTip(_ text: String, for seconds: Double?) {
        tipTask?.cancel()
        tip = text
        guard let seconds else { return }
        tipTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { tip = nil }
        }
    }

    // MARK: - Keys

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard let layout = target.panelLayout, let key = PanelKey(press),
              let built = presenter.previewContent(layout: layout, query: query, selected: selected, foldOpen: foldOpen)
        else { return .ignored }
        switch key {
        case .escape:
            if query.isEmpty { focused = false } else { setQuery("", layout: layout) }
        case .enter:
            if let tile = built.content.selected ?? built.model.bestMatch {
                if tile == .fold { flipFold(built.content) } else { presenter.press(tile) }
            }
        case .move(let direction):
            switch built.content.step(from: built.content.selected, toward: direction) {
            case .select(let tile): selected = tile
            case .unfold: flipFold(built.content)
            case .stay: break
            }
        case .delete:
            if !query.isEmpty { setQuery(String(query.dropLast()), layout: layout) }
        case .type(let typed):
            guard let new = PanelKey.query(query, typing: typed) else { return .ignored }
            setQuery(new, layout: layout)
        }
        return .handled
    }

    private func setQuery(_ new: String, layout: PanelGrid.Layout) {
        query = new
        selected = new.isEmpty ? nil
            : presenter.previewContent(layout: layout, query: new, selected: nil, foldOpen: foldOpen)?.model.bestMatch
    }

    // MARK: - Pictures

    /// What can bring tiles with no picture yet into view.
    private var passKey: String {
        let options = appState.settings.panel
        return "\(target.rawValue) \(foldOpen) \(options.alwaysHidden.rawValue) \(options.alwaysHiddenOpen)"
    }

    /// The pass the panel runs on open, for the tiles the preview shows
    /// with a stand-in.
    private func picture() {
        guard let layout = target.panelLayout,
              let missing = presenter.previewContent(layout: layout, query: "", selected: nil, foldOpen: foldOpen)?.missing,
              !missing.isEmpty
        else { return }
        presenter.picturePassIfNeeded(missing) { revision += 1 }
    }
}

/// Menu bar, Panel or Row as three cards, each a sketch of where the hidden
/// icons go: the tab's main choice, so it reads first.
private struct RevealTargetPicker: View {
    @Binding var selection: RevealTarget

    var body: some View {
        HStack(spacing: 10) {
            ForEach([(RevealTarget.menuBar, LocalizedStringKey("Menu bar")), (.panel, "Panel"), (.row, "Row")], id: \.0) { target, label in
                RevealTargetCard(target: target, label: label, selected: selection == target) {
                    selection = target
                }
            }
        }
        .animation(.spring(duration: 0.22), value: selection)
    }
}

private struct RevealTargetCard: View {
    let target: RevealTarget
    let label: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RevealTargetSketch(target: target, ink: selected ? PelmetAccent.accent : .secondary)
                Text(label)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? PelmetAccent.accent : .primary)
            }
            .padding(6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? PelmetAccent.accent.opacity(0.14) : Color.primary.opacity(hovered ? 0.08 : 0.04))
                    .shadow(color: .black.opacity(selected ? 0.2 : 0), radius: 4, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(PelmetAccent.accent, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A menu bar strip with the chevron and three shown icons, and the hidden
/// ones in `ink`: beside the chevron, in a grid under it, or in a row.
private struct RevealTargetSketch: View {
    let target: RevealTarget
    let ink: Color

    private static let icon: CGFloat = 7
    private static let gap: CGFloat = 3
    private static let edge: CGFloat = 8

    private func icons(_ count: Int, _ color: Color) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: Self.icon, height: Self.icon)
            }
        }
    }

    private func well<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                if target == .menuBar { icons(3, ink) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(target == .menuBar ? ink : .secondary)
                icons(3, Color.primary.opacity(0.35))
            }
            .padding(.horizontal, Self.edge)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: 14)
            .background(Color.primary.opacity(0.08))
            switch target {
            case .menuBar:
                EmptyView()
            case .panel:
                well { VStack(spacing: Self.gap) { icons(3, ink); icons(3, ink) } }
                    // Under the chevron, as the panel opens.
                    .padding(.trailing, Self.edge + 3 * Self.icon + 2 * Self.gap)
            case .row:
                well { icons(6, ink) }
                    .padding(.trailing, Self.edge)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: 50, alignment: .top)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
