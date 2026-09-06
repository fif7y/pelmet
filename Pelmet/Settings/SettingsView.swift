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
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case behavior = "Behavior"
    case menuBar = "Menu Bar"
    case displays = "Displays"
    case about = "About"

    var id: String { rawValue }

    /// Localized label — `rawValue` stays the stable identifier.
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .behavior: "Behavior"
        case .menuBar: "Menu Bar"
        case .displays: "Displays"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .behavior: "cursorarrow.motionlines"
        case .menuBar: "menubar.rectangle"
        case .displays: "display.2"
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
                Text(appState.settingsTab.title)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.bottom, 2)
                switch appState.settingsTab {
                case .general: GeneralPane()
                case .behavior: BehaviorPane()
                case .menuBar: MenuBarTab()
                case .displays: DisplaysPane()
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
                    .fixedSize()
                Spacer(minLength: 0)
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
struct PelmetSegments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, LocalizedStringKey)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                PelmetSegmentButton(label: label, selected: selection == value) {
                    selection = value
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
        .animation(.spring(duration: 0.22), value: selection)
    }
}

private struct PelmetSegmentButton: View {
    let label: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? PelmetAccent.accent : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control
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

struct SettingSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: TimeInterval
    let range: ClosedRange<Double>
    let format: String
    var zeroLabel: String? = nil

    var body: some View {
        SettingRow(title: title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range)
                    .frame(width: 160)
                Text(value == 0 ? (zeroLabel ?? String(format: format, value)) : String(format: format, value))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
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
                caption: "Without it: reopen Pelmet from Spotlight, or right-click a separator or empty menu bar spot.",
                isOn: binding(\.showStatusItem, onSet: { enabled in
                    if !enabled { Self.showIconlessHint() }
                })
            )
            SettingRow(title: "Language", caption: "Relaunches Pelmet to apply.") {
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
        SettingsCard(title: "Reveal") {
            SettingToggleRow(title: "Reveal on hover", isOn: binding(\.revealTriggers.hoverEnabled))
            if appState.settings.revealTriggers.hoverEnabled {
                SettingSliderRow(
                    title: "Hover delay",
                    value: binding(\.revealTriggers.hoverDelay),
                    range: 0.15...0.75,
                    format: "%.2fs"
                )
            }
            SettingToggleRow(title: "Reveal on click in empty menu bar area", isOn: binding(\.revealTriggers.clickEnabled))
            SettingToggleRow(title: "Double-click reveals always-hidden too", isOn: binding(\.revealTriggers.doubleClickForAlwaysHidden))
            SettingRow(title: "Reveal animation") {
                PelmetSegments(selection: binding(\.revealAnimation), options: [
                    (.instant, "Instant"),
                    (.smooth, "Smooth"),
                    (.fade, "Fade"),
                ])
            }
        }

        SettingsCard(title: "Auto-rehide") {
            SettingToggleRow(title: "Automatically rehide", isOn: binding(\.autoRehide))
            if appState.settings.autoRehide {
                SettingSliderRow(
                    title: "After",
                    value: binding(\.rehideDelay),
                    range: 0...10,
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
                Picker("", selection: binding(\.hideSystemExtras)) {
                    Text("Always hidden").tag(true)
                    Text("Show while revealed").tag(false)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
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
                Picker("", selection: Binding(
                    get: { appState.settings.behavior(forDisplayUUID: uuid) },
                    set: { behavior in
                        if let uuid {
                            appState.settings.displayOverrides[uuid] = behavior
                            appState.settingsChanged()
                            appState.displayBehaviorEdited()
                        }
                    }
                )) {
                    Text("Collapse").tag(DisplayBehavior.collapse)
                    Text("Expanded").tag(DisplayBehavior.alwaysShowAll)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
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
            Button {
                SparkleController.shared.probe()
            } label: {
                Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PelmetAccent.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(PelmetAccent.accent.opacity(0.13), in: Capsule())
            }
            .buttonStyle(.plain)
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
