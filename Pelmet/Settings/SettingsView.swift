// SettingsView.swift
// Sidebar-shell settings: tab list on the left, one scrolling pane on the
// right. De-box throughout — panes are borderless cards on soft fills, the
// brand accent carries selection and controls. About pane included.

import PelmetCore
import PelmetEngine
import ServiceManagement
import SwiftUI

/// The brand accent — pelmet purple; slightly lighter in dark mode for contrast.
enum PelmetAccent {
    static let nsColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.494, green: 0.373, blue: 0.949, alpha: 1)  // #7E5FF2
            : NSColor(red: 0.408, green: 0.255, blue: 0.929, alpha: 1)  // #6841ED
    }
    static let accent = Color(nsColor: nsColor)

    /// GitHub-star gold: bright on dark, amber on light so the label stays legible.
    static let star = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.84, blue: 0.2, alpha: 1)    // #FFD633
            : NSColor(red: 0.72, green: 0.5, blue: 0.0, alpha: 1)    // #B88000
    })
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case behavior = "Behavior"
    case menuBar = "Menu Bar"
    case displays = "Displays"
    case thanks = "Thanks"
    case about = "About"

    var id: String { rawValue }

    /// Localized label — `rawValue` stays the stable identifier.
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .behavior: "Behavior"
        case .menuBar: "Menu Bar"
        case .displays: "Displays"
        case .thanks: "Thanks"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .behavior: "cursorarrow.motionlines"
        case .menuBar: "menubar.rectangle"
        case .displays: "display.2"
        case .thanks: "heart"
        case .about: "shippingbox"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    // Selection lives on AppState so the window controller can reset it to
    // General on every open — the hosting view survives window close, and a
    // window reopening straight onto the Menu Bar tab fired its full-reveal
    // preview before the user asked for anything.
    private var tab: Binding<SettingsTab> {
        Binding(
            get: { appState.settingsTab },
            set: { appState.settingsTab = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(tab: tab)
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .tint(PelmetAccent.accent)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text(appState.settingsTab.title)
                        .font(.system(size: 22, weight: .semibold))
                    Spacer()
                    // The pane's one bar-wide action rides the title row —
                    // vertical space below belongs to the sections.
                    if appState.settingsTab == .menuBar {
                        TidyBarButton()
                    }
                }
                .padding(.bottom, 2)
                switch appState.settingsTab {
                case .general: GeneralPane()
                case .behavior: BehaviorPane()
                case .menuBar: MenuBarTab()
                case .displays: DisplaysPane()
                case .thanks: ThanksPane()
                case .about: AboutPane()
                }
            }
            .padding(28)
            .padding(.top, 16)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Environment(AppState.self) private var appState
    @Binding var tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                // Everything above is the app's settings; Thanks and About
                // are the rest. One quiet hairline marks the split.
                if item == .thanks {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                }
                SidebarRow(
                    item: item,
                    selected: tab == item,
                    // The Accessibility row lives in General; the dot says
                    // "something here needs you" from any tab.
                    attention: item == .general && !appState.accessibilityGranted,
                    // An available update chips the About row in the same
                    // accent as its "Update to…" button — a trail for someone
                    // who just opened Settings.
                    badge: item == .about && SparkleController.shared.availableVersion != nil
                        ? "Update" : nil
                ) { tab = item }
            }
            Spacer()
        }
        .padding(10)
        // Clear the traffic lights — the sidebar runs under the titlebar.
        .padding(.top, 42)
        .frame(width: 196, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.35))
    }
}

private struct SidebarRow: View {
    let item: SettingsTab
    let selected: Bool
    var attention = false
    var badge: LocalizedStringKey? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                // Size the row for the semibold weight so selecting never
                // reflows — the regular label sits over a hidden bold twin.
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(item.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    }
                    .lineLimit(1)
                    // No fixedSize: a long title (ru "О программе" beside
                    // "Обновить") must ellipsize rather than run under the
                    // badge and the attention dot it shares the row with.
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if attention {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                }
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(PelmetAccent.accent, in: Capsule())
                }
            }
            .foregroundStyle(selected ? PelmetAccent.accent : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected
                        ? PelmetAccent.accent.opacity(0.16)
                        : .primary.opacity(hovered ? 0.06 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

// MARK: - Segments

/// De-boxed button group: soft-fill track, the selected chip carried by the
/// brand accent — every option visible at once, no menu to open.
/// Outbound help links. The FAQ is one page with named anchors.
enum PelmetLinks {
    static let faqAppLaunchers = URL(string: "https://github.com/fif7y/pelmet/blob/main/docs/FAQ.md#app-launchers")!
}

struct PelmetSegments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, LocalizedStringKey)]
    /// Row-sized: sits inside a card, so it needs a stronger fill to
    /// separate from the card's own and smaller type to match row captions.
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                PelmetSegmentButton(label: label, selected: selection == value, compact: compact) {
                    selection = value
                }
            }
        }
        .padding(compact ? 2 : 3)
        .background(
            RoundedRectangle(cornerRadius: compact ? 8 : 9)
                .fill(.quaternary.opacity(compact ? 0.6 : 0.35))
        )
        .animation(.spring(duration: 0.22), value: selection)
    }
}

private struct PelmetSegmentButton: View {
    let label: LocalizedStringKey
    let selected: Bool
    var compact = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: compact ? 11 : 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? PelmetAccent.accent : .secondary)
                .padding(.horizontal, compact ? 9 : 10)
                .padding(.vertical, compact ? 3 : 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected
                            ? PelmetAccent.accent.opacity(0.16)
                            : .primary.opacity(hovered ? 0.06 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

// MARK: - Card + rows

/// The card's own surface — soft fill, no outline (de-box). Used by the
/// Menu Bar tab's item cards, which set their own row rhythm and each had
/// the inset, radius and fill typed out by hand. `SettingsCard` keeps its
/// inline chain: it needs `.frame(maxWidth:)` BETWEEN the inset and the
/// fill, and modifier order is geometry here, not style.
extension View {
    func pelmetCardSurface(cornerRadius: CGFloat = 12) -> some View {
        self
            .padding(14)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary.opacity(0.35)))
    }
}

/// Borderless grouping card: soft fill, no outline (de-box).
struct SettingsCard<Content: View>: View {
    var title: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
        }
    }
}

/// Title + optional caption on the left, any control on the right.
/// A menu that sizes to the SELECTED value, not to its widest option.
/// SwiftUI's `.pickerStyle(.menu)` reserves room for the longest entry, so
/// one long translation inflated the closed control and squeezed the row's
/// own label into a ragged column (French "Afficher lorsque la barre est
/// déployée" made the closed "Toujours masqués" ~280pt wide).
struct PelmetMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, LocalizedStringKey)]
    /// Row-sized: a caption-weight label with no button chrome, for a menu
    /// that sits inside a card row rather than beside a setting.
    var borderless = false

    private var currentLabel: LocalizedStringKey {
        options.first { $0.0 == selection }?.1 ?? ""
    }

    var body: some View {
        Menu {
            // Toggles carry the native checkmark; a Label's symbol is
            // dropped by macOS menus.
            ForEach(options, id: \.0) { value, label in
                Toggle(label, isOn: Binding(
                    get: { selection == value },
                    set: { if $0 { selection = value } }
                ))
            }
        } label: {
            Text(currentLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .modifier(MenuPickerChrome(borderless: borderless))
    }
}

/// The two chromes are different view types, so the branch lives in a
/// modifier SwiftUI can resolve statically. Nothing outside the borderless
/// branch touches the bordered picker's appearance.
private struct MenuPickerChrome: ViewModifier {
    let borderless: Bool

    func body(content: Content) -> some View {
        if borderless {
            content
                .menuStyle(.borderlessButton)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            content
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: Text
    var caption: LocalizedStringKey? = nil
    let control: Control

    /// Literal titles localize through the string catalog.
    init(title: LocalizedStringKey, caption: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = Text(title)
        self.caption = caption
        self.control = control()
    }

    /// Runtime titles (display names, user data) are shown as-is.
    init(verbatim title: String, @ViewBuilder control: () -> Control) {
        self.title = Text(verbatim: title)
        self.control = control()
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        // A long title beside a fixed-width control (a menu Picker sizes to
        // its widest option) squeezed the text into a ragged column —
        // French "Lecture en cours, commandes de caméra, AirDrop,
        // Concentration" wrapped to four lines beside its own caption.
        // Side by side while both fit, control below when they don't.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                label
                Spacer(minLength: 16)
                control
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                HStack { Spacer(minLength: 0); control }
            }
        }
    }
}

struct SettingToggleRow: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, caption: caption) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// Six glyphs for the menu bar icon, drawn at bar size. Picking one repaints
/// the live status item through settingsChanged().
struct StatusIconPicker: View {
    @Binding var selection: StatusIconStyle

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatusIconStyle.allCases) { style in
                StatusIconTile(symbol: style.symbol(revealed: false), selected: selection == style) {
                    selection = style
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
        .animation(.spring(duration: 0.22), value: selection)
    }
}

private struct StatusIconTile: View {
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? PelmetAccent.accent : .secondary)
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected
                            ? PelmetAccent.accent.opacity(0.16)
                            : .primary.opacity(hovered ? 0.06 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

/// A quiet explanatory box inside a card — for the "what happens if" line
/// that is too long to sit as a row caption.
struct SettingNote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

struct SettingSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: TimeInterval
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var zeroLabel: String? = nil

    var body: some View {
        SettingRow(title: title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 160)
                Text(value == 0 ? (zeroLabel ?? String(format: format, value)) : String(format: format, value))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // "Instant" is 48pt in English and ~72 in French; the
                    // box may grow, it must not clip the value it exists
                    // to show.
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppState.self) private var appState
    @State private var language = AppLanguage.current

    var body: some View {
        SettingsCard {
            SettingToggleRow(
                title: "Launch at login",
                isOn: binding(\.launchAtLogin) { enabled in
                    try? enabled
                        ? SMAppService.mainApp.register()
                        : SMAppService.mainApp.unregister()
                }
            )
            SettingToggleRow(
                title: "Show Pelmet icon in the menu bar",
                isOn: binding(\.showStatusItem, onSet: { enabled in
                    if !enabled { Self.showIconlessHint() }
                })
            )
            if appState.settings.showStatusItem {
                SettingRow(title: "Icon") {
                    StatusIconPicker(selection: binding(\.statusIconStyle))
                }
            }
            SettingNote("Without it: reopen Pelmet from Spotlight, or right-click a separator or empty menu bar spot.")
        }

        SettingsCard(title: "Language") {
            SettingRow(title: "Display language", caption: "Relaunches Pelmet to apply.") {
                Picker("", selection: $language) {
                    Text("System language").tag(AppLanguage.system)
                    Divider()
                    ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
                        Text(verbatim: language.endonym).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: language) { _, newValue in
                    guard newValue != AppLanguage.current else { return }
                    AppLanguage.set(newValue)
                    AppLanguage.offerRelaunch()
                }
            }
        }

        SettingsCard(title: "Permissions") {
            SettingRow(
                title: "Accessibility",
                caption: appState.accessibilityGranted
                    ? "How Pelmet sees the menu bar and moves its icons."
                    : "Off. Pelmet can't see or arrange the menu bar without it."
            ) {
                if appState.accessibilityGranted {
                    StatusChip(text: "Granted", symbol: "checkmark.circle.fill", tint: .green)
                } else {
                    AccentChipButton(text: "Grant access", symbol: "hand.raised.fill") {
                        SettingsWindowController.shared.lowerForSystemPrompt()
                        AccessibilityAccess.request()
                    }
                }
            }
            SettingRow(
                title: "Screen Recording",
                caption: appState.screenRecordingGranted
                    ? "Lets the animation styles play over the system's own show and hide."
                    : "Optional. Without it, icons show and hide the way macOS does it."
            ) {
                if appState.screenRecordingGranted {
                    StatusChip(text: "Granted", symbol: "checkmark.circle.fill", tint: .green)
                } else {
                    AccentChipButton(text: "Grant access", symbol: "rectangle.dashed.badge.record") {
                        SettingsWindowController.shared.lowerForSystemPrompt()
                        ScreenRecordingAccess.request()
                    }
                }
            }
        }
        .task {
            // The grant lands in System Settings, outside our window —
            // poll while the tab is up so the chip flips without a relaunch.
            while !Task.isCancelled {
                appState.refreshScreenRecording()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func binding<T>(
        _ keyPath: WritableKeyPath<SettingsStore, T>,
        onSet: ((T) -> Void)? = nil
    ) -> Binding<T> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { newValue in
                appState.settings[keyPath: keyPath] = newValue
                onSet?(newValue)
                appState.settingsChanged()
            }
        )
    }

    /// One-time orientation when the user goes iconless.
    static func showIconlessHint() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Pelmet stays a click away")
        alert.informativeText = String(localized: "You can always open Pelmet Settings by:\n\n•  Opening Pelmet again from Spotlight or Finder\n•  Right-clicking any Pelmet separator in the menu bar\n•  Right-clicking an empty spot in the menu bar")
        alert.alertStyle = .informational
        alert.runModal()
    }
}

// MARK: - Behavior

/// How the bar behaves day to day: what reveals it, when it closes, and the
/// two macOS quirks Pelmet works around. App-level settings stay in General.
private struct BehaviorPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsCard(title: "Animation") {
            AnimationShowcase(selection: binding(\.revealAnimation))
        }

        SettingsCard(title: "Reveal") {
            SettingToggleRow(title: "Reveal on hover", isOn: binding(\.revealTriggers.hoverEnabled))
            if appState.settings.revealTriggers.hoverEnabled {
                SettingSliderRow(
                    title: "Hover delay",
                    value: binding(\.revealTriggers.hoverDelay),
                    range: 0.1...0.5,
                    step: 0.1,
                    format: "%.1fs"
                )
            }
            SettingToggleRow(title: "Reveal on click in empty menu bar area", isOn: binding(\.revealTriggers.clickEnabled))
            SettingToggleRow(title: "Double-click reveals always-hidden too", isOn: binding(\.revealTriggers.doubleClickForAlwaysHidden))
        }

        SettingsCard(title: "Auto-rehide") {
            SettingToggleRow(title: "Automatically rehide", isOn: binding(\.autoRehide))
            if appState.settings.autoRehide {
                SettingSliderRow(
                    title: "After",
                    value: binding(\.rehideDelay),
                    range: 0...5,
                    step: 0.5,
                    format: "%.2gs",
                    zeroLabel: String(localized: "Instant")
                )
            }
            SettingToggleRow(title: "Rehide when clicking elsewhere", isOn: binding(\.rehideOnClickElsewhere))
        }

        SettingsCard(title: "System extras") {
            SettingRow(
                title: "Now Playing, camera controls, AirDrop, Focus",
                caption: "macOS hides these whenever any icons are concealed — they can only appear while the whole bar is revealed."
            ) {
                PelmetMenuPicker(
                    selection: binding(\.hideSystemExtras),
                    options: [
                        (true, LocalizedStringKey("Always hidden")),
                        (false, LocalizedStringKey("Show while revealed")),
                    ]
                )
            }
        }

        SettingsCard(title: "Notification Center") {
            SettingToggleRow(
                title: "Clicking the clock opens Notification Center",
                caption: "macOS blocks that click while any icons are hidden. Pelmet shows everything for a blink so it gets through.",
                isOn: binding(\.clockOpensNotificationCenter)
            )
        }
    }

    private func binding<T>(
        _ keyPath: WritableKeyPath<SettingsStore, T>,
        onSet: ((T) -> Void)? = nil
    ) -> Binding<T> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { newValue in
                appState.settings[keyPath: keyPath] = newValue
                onSet?(newValue)
                appState.settingsChanged()
            }
        )
    }
}

// MARK: - Displays

private struct DisplaysPane: View {
    var body: some View {
        SettingsCard {
            ForEach(NSScreen.screens, id: \.self) { screen in
                DisplayRow(screen: screen)
            }
        }
    }
}

private struct DisplayRow: View {
    @Environment(AppState.self) private var appState
    let screen: NSScreen

    private var uuid: String? { screen.displayUUIDString }

    private var hasNotch: Bool {
        screen.safeAreaInsets.top > 0
    }

    var body: some View {
        SettingRow(verbatim: screen.localizedName) {
            HStack(spacing: 8) {
                if hasNotch {
                    Text("Notch")
                        .font(.caption2)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                PelmetMenuPicker(selection: Binding(
                    get: { appState.settings.behavior(forDisplayUUID: uuid) },
                    set: { behavior in
                        if let uuid {
                            appState.settings.displayOverrides[uuid] = behavior
                            appState.settingsChanged()
                            appState.displayBehaviorEdited()
                        }
                    }
                ), options: [
                    (DisplayBehavior.collapse, LocalizedStringKey("Collapse")),
                    (DisplayBehavior.alwaysShowAll, LocalizedStringKey("Expanded")),
                ])
            }
        }
    }
}

// MARK: - Thanks

/// The ask, made once and quietly. One solid CTA (sponsor); stars, follows
/// and sharing are tinted chips. Every link is a public URL — nothing here
/// needs a key, and the star count comes from the unauthenticated API.
private struct ThanksPane: View {
    @State private var stars = GitHubStars.cached

    private static let sponsor = URL(string: "https://github.com/sponsors/fif7y")!
    private static let repo = URL(string: "https://github.com/fif7y/pelmet")!
    private static let issues = URL(string: "https://github.com/fif7y/pelmet/issues")!
    private static let x = URL(string: "https://x.com/FIF7Y")!
    private static let instagram = URL(string: "https://www.instagram.com/madebyfif7y/")!
    private static let website = URL(string: "https://pelmet.fif7y.com")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pelmet is free. It stays that way.")
                .font(.title3.weight(.semibold))
            Text("One person builds it on evenings and weekends. No account, no tracking, no upsell.\nIf it earned a spot in your bar, here's how to help.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
            AccentChipButton(text: "Sponsor on GitHub", symbol: "heart.fill") { open(Self.sponsor) }
            Text("From a coffee a month. Keeps the releases coming.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SettingsCard {
            Text("A star helps more people find Pelmet.")
            HStack(spacing: 10) {
                TintChipButton(text: "Star on GitHub", symbol: "star.fill", tint: PelmetAccent.star) { open(Self.repo) }
                if let stars {
                    Text("\(stars) stars")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }

        SettingsCard {
            Text("Follow along for releases and what's next.")
            HStack(spacing: 10) {
                TintChipButton(verbatim: "@FIF7Y", icon: XGlyph()) { open(Self.x) }
                TintChipButton(verbatim: "@madebyfif7y", icon: InstagramGlyph()) { open(Self.instagram) }
                ShareLink(item: Self.website) {
                    ChipLabel(text: Text("Tell a friend"), icon: Image(systemName: "square.and.arrow.up"))
                }
                .buttonStyle(.plain)
            }
        }

        VStack(spacing: 4) {
            Text("Enjoy the extra room up there.")
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("Found a bug?")
                Link("Report an issue", destination: Self.issues)
            }
            .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .task {
            if let count = await GitHubStars.fetch() { stars = count }
        }
    }

    private func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// Star count from the public repos endpoint: no token, one fetch per pane
/// visit, last value cached so the number is there on the next open.
enum GitHubStars {
    private static let key = "thanks.githubStars"

    static var cached: Int? { UserDefaults.standard.object(forKey: key) as? Int }

    static func fetch() async -> Int? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/fif7y/pelmet")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["stargazers_count"] as? Int
        else { return nil }
        UserDefaults.standard.set(count, forKey: key)
        return count
    }
}

/// The X mark: one heavy diagonal, one light one across it.
struct XGlyph: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var light = Path()
            light.move(to: CGPoint(x: w * 0.92, y: h * 0.08))
            light.addLine(to: CGPoint(x: w * 0.08, y: h * 0.92))
            context.stroke(light, with: .foreground, style: StrokeStyle(lineWidth: w * 0.11, lineCap: .round))
            var heavy = Path()
            heavy.move(to: CGPoint(x: w * 0.08, y: h * 0.08))
            heavy.addLine(to: CGPoint(x: w * 0.92, y: h * 0.92))
            context.stroke(heavy, with: .foreground, style: StrokeStyle(lineWidth: w * 0.2, lineCap: .round))
        }
    }
}

/// The Instagram camera: rounded frame, lens, flash dot.
struct InstagramGlyph: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let stroke = w * 0.11
            let frame = CGRect(x: w * 0.08, y: h * 0.08, width: w * 0.84, height: h * 0.84)
            context.stroke(Path(roundedRect: frame, cornerRadius: w * 0.26), with: .foreground, lineWidth: stroke)
            let lens = CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.4, height: h * 0.4)
            context.stroke(Path(ellipseIn: lens), with: .foreground, lineWidth: stroke)
            let dot = CGRect(x: w * 0.66, y: h * 0.2, width: w * 0.14, height: h * 0.14)
            context.fill(Path(ellipseIn: dot), with: .foreground)
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @Environment(AppState.self) private var appState

    private var version: String {
        let info = Bundle.main
        let short = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(localized: "Version \(short) (\(build))")
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Gabriel Faucon"
    }

    var body: some View {
        VStack(spacing: 6) {
            AnimatedAppIcon(size: 96)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            Text("Pelmet")
                .font(.system(size: 30, weight: .semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(spacing: 10) {
                if SparkleController.shared.isConfigured {
                    updateRow
                }
                Button("Replay the intro") {
                    OnboardingController.shared.present(appState: appState)
                }
            }
            .padding(.top, 18)

            HStack(spacing: 18) {
                Link("Website", destination: URL(string: "https://pelmet.fif7y.com")!)
                Link("GitHub", destination: URL(string: "https://github.com/fif7y/pelmet")!)
                Link("Report an issue", destination: URL(string: "https://github.com/fif7y/pelmet/issues")!)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 22)

            if SparkleController.shared.isConfigured {
                updatesCard
                    .padding(.top, 28)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .onAppear { SparkleController.shared.probe() }
    }

    /// Two preferences, both quiet by design: scheduled checks never open a
    /// window (see SparkleController); these decide what a found update
    /// does instead.
    @ViewBuilder private var updatesCard: some View {
        @Bindable var appState = appState
        SettingsCard(title: "Updates") {
            SettingToggleRow(
                title: "Download updates automatically",
                caption: "Installs on the next quit.",
                isOn: Binding(
                    get: { SparkleController.shared.automaticallyDownloadsUpdates },
                    set: { SparkleController.shared.automaticallyDownloadsUpdates = $0 }
                )
            )
            SettingToggleRow(
                title: "Notify me when an update is available",
                isOn: Binding(
                    get: { appState.settings.notifyOnUpdates },
                    set: { appState.settings.notifyOnUpdates = $0; appState.settingsChanged() }
                )
            )
            if let checked = SparkleController.shared.lastUpdateCheckDate {
                Text("Last checked \(checked, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Inline update state — no "you're up to date" alert; the pane just
    /// shows it. One capsule chip per state (de-box: tinted fill, no
    /// borders); only "update available" is a true CTA and gets the solid
    /// accent fill.
    @ViewBuilder private var updateRow: some View {
        switch SparkleController.shared.status {
        case .available(let version):
            AccentChipButton(text: "Update to \(version)", symbol: "arrow.down.circle.fill") {
                SparkleController.shared.checkForUpdates()
            }
        case .checking:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        case .upToDate:
            StatusChip(text: "You're on the latest version", symbol: "checkmark.seal.fill", tint: .green)
        case .unknown:
            TintChipButton(text: "Check for updates", symbol: "arrow.triangle.2.circlepath") {
                SparkleController.shared.probe()
            }
        }
    }
}

// MARK: - Chips

/// De-boxed state chip: tinted fill, no border. Shared by About's update
/// state and General's permission row so the two read as one family.
struct StatusChip: View {
    let text: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

/// The one true CTA treatment: solid brand accent, white label.
struct AccentChipButton: View {
    let text: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(PelmetAccent.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The tinted sibling of AccentChipButton: accent text on a soft accent fill.
/// One recipe (ChipLabel) so About's update chip and the Thanks chips cannot
/// drift apart.
struct TintChipButton<Icon: View>: View {
    let text: Text
    let icon: Icon
    var tint: Color = PelmetAccent.accent
    let action: () -> Void

    init(text: LocalizedStringKey, symbol: String, tint: Color = PelmetAccent.accent, action: @escaping () -> Void) where Icon == Image {
        self.text = Text(text)
        self.icon = Image(systemName: symbol)
        self.tint = tint
        self.action = action
    }

    /// Handles and other runtime strings, shown as-is with a custom glyph.
    init(verbatim text: String, icon: Icon, action: @escaping () -> Void) {
        self.text = Text(verbatim: text)
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ChipLabel(text: text, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

struct ChipLabel<Icon: View>: View {
    let text: Text
    let icon: Icon
    var tint: Color = PelmetAccent.accent

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 13, height: 13)
            text
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(tint.opacity(0.13), in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Animation showcase

/// Three cards, one per style, each a mock bar (squircles + chevron) playing
/// that style's show/hide loop. Only one plays at a time: the selected card,
/// or the hovered one while the pointer is on it (the selected card pauses,
/// then resumes on hover out). A card at rest shows its name instead.
struct AnimationShowcase: View {
    @Binding var selection: RevealAnimation
    @State private var hovered: RevealAnimation?

    private static let styles: [(RevealAnimation, LocalizedStringKey)] = [
        (.instant, "Instant"), (.smooth, "Smooth"), (.fade, "Fade"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.styles, id: \.0) { style, title in
                AnimationStyleCard(
                    style: style,
                    title: title,
                    selected: selection == style,
                    playing: hovered == style || (hovered == nil && selection == style)
                ) {
                    selection = style
                }
                .onHover { inside in
                    if inside { hovered = style } else if hovered == style { hovered = nil }
                }
            }
        }
    }
}

private struct AnimationStyleCard: View {
    let style: RevealAnimation
    let title: LocalizedStringKey
    let selected: Bool
    let playing: Bool
    let select: () -> Void

    @State private var revealed = false
    @State private var pressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The name lives above the card so it stays readable while the
            // card plays; the selected one carries an Active tag.
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? PelmetAccent.accent : .secondary)
                if selected {
                    Text("Active")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PelmetAccent.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(PelmetAccent.accent.opacity(0.16)))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.leading, 2)
            .animation(.easeInOut(duration: 0.2), value: selected)

            MockBar(style: style, revealed: revealed)
                .opacity(playing ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.25), value: playing)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? PelmetAccent.accent.opacity(0.14) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(PelmetAccent.accent.opacity(selected ? 0.7 : 0), lineWidth: 1)
                )
                .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 8, y: 3)
                .scaleEffect(pressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.15), value: pressed)
                .animation(.easeInOut(duration: 0.2), value: selected)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .onTapGesture(perform: select)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .task(id: playing) {
            // The loop: show, hold, hide, hold. A card at rest shows the
            // collapsed bar — frame one of the animation, dimmed.
            guard playing else { revealed = false; return }
            revealed = false
            try? await Task.sleep(for: .milliseconds(350))
            while !Task.isCancelled {
                revealed = true
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled else { break }
                revealed = false
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }
}

/// A menu bar in miniature: three hidden squircles left of the chevron,
/// two visible ones right of it. The hidden group moves the way the real
/// style does, with the same durations (AppTiming).
private struct MockBar: View {
    let style: RevealAnimation
    let revealed: Bool

    private let dot: CGFloat = 12
    private let gap: CGFloat = 9

    var body: some View {
        HStack(spacing: gap) {
            // Hidden group, clipped at the chevron so a slide emerges from
            // behind it exactly like the real strip.
            HStack(spacing: gap) {
                ForEach(0..<3, id: \.self) { _ in squircle }
            }
            .offset(x: hiddenOffset)
            .opacity(revealed ? 1 : 0)
            .animation(hiddenAnimation, value: revealed)
            .frame(width: 3 * dot + 2 * gap, alignment: .trailing)
            .clipped()

            Image(systemName: revealed ? "chevron.right" : "chevron.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PelmetAccent.accent)
                .frame(width: 12)
                .contentTransition(.symbolEffect(.replace))

            ForEach(0..<2, id: \.self) { _ in squircle }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }

    private var squircle: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.8))
            .frame(width: dot, height: dot)
    }

    private var hiddenOffset: CGFloat {
        guard case .smooth = style, !revealed else { return 0 }
        return 3 * dot + 2 * gap  // parked behind the chevron
    }

    private var hiddenAnimation: Animation? {
        switch style {
        case .instant:
            nil
        case .smooth:
            revealed
                ? .timingCurve(0.16, 1, 0.3, 1, duration: AppTiming.smoothRevealDuration)
                : .timingCurve(0.55, 0, 0.8, 0.4, duration: AppTiming.smoothExitDuration)
        case .fade:
            .timingCurve(0.42, 0, 0.58, 1, duration: revealed ? AppTiming.fadeRevealDuration : AppTiming.fadeExitDuration)
        }
    }
}
