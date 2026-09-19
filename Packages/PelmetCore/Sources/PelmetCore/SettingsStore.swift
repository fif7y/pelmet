// SettingsStore.swift
// All user preferences, one Codable blob in UserDefaults. Tiny data — no files,
// no CoreData. Every option here expresses a real user preference (options that
// exist to work around engine unreliability are banned by design).

import Foundation

public struct HotkeySpec: Codable, Equatable, Sendable {
    /// Carbon key code + modifier flags (stored raw for the recorder).
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// Glyphs captured at record time ("⌥⌘,"), so showing the shortcut needs
    /// no keyboard-layout math. Empty on blobs written before it existed.
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String = "") {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// ⌥⌘, — nothing in macOS binds it, and "," is already the settings key
    /// everywhere. Carbon constants inlined so PelmetCore stays Carbon-free:
    /// kVK_ANSI_Comma = 0x2B, cmdKey | optionKey = 0x100 | 0x800.
    public static let `default` = HotkeySpec(keyCode: 0x2B, modifiers: 0x900, display: "⌥⌘,")
    /// ⇧⌥⌘, opens Settings — the toggle combo plus shift (shiftKey = 0x200).
    public static let settingsDefault = HotkeySpec(keyCode: 0x2B, modifiers: 0xB00, display: "⇧⌥⌘,")

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, display }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt32.self, forKey: .keyCode)
        modifiers = try c.decode(UInt32.self, forKey: .modifiers)
        display = (try? c.decodeIfPresent(String.self, forKey: .display)) ?? ""
        if display.isEmpty, keyCode == Self.default.keyCode, modifiers == Self.default.modifiers {
            display = Self.default.display
        }
    }
}

public enum DisplayBehavior: String, Codable, Equatable, Sendable {
    /// Never conceal while the pointer is on this display.
    case alwaysShowAll
    /// Collapse; reveal via the configured triggers.
    case collapse
}

public struct RevealTriggers: Codable, Equatable, Sendable {
    public var hoverEnabled: Bool
    public var hoverDelay: TimeInterval
    public var clickEnabled: Bool
    public var doubleClickForAlwaysHidden: Bool

    public init(
        hoverEnabled: Bool = true,
        hoverDelay: TimeInterval = 0.1,
        clickEnabled: Bool = true,
        doubleClickForAlwaysHidden: Bool = true
    ) {
        self.hoverEnabled = hoverEnabled
        self.hoverDelay = hoverDelay
        self.clickEnabled = clickEnabled
        self.doubleClickForAlwaysHidden = doubleClickForAlwaysHidden
    }
}

public enum SeparatorStyle: String, Codable, CaseIterable, Sendable {
    case pipe = "|"
    case dot = "•"
    case chevronLeft = "‹"
    case chevronRight = "›"
    case dash = "—"
    case space = " "

    public var displayName: String {
        switch self {
        case .pipe: "Pipe"
        case .dot: "Dot"
        case .chevronLeft: "Chevron ‹"
        case .chevronRight: "Chevron ›"
        case .dash: "Dash"
        case .space: "Invisible spacer"
        }
    }
}

public struct SeparatorSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var style: SeparatorStyle
    /// Glyph opacity in the bar (invisible spacers ignore it).
    public var opacity: Double
    /// Points of bar the invisible spacer takes up (drawn styles size
    /// themselves to their glyph and ignore it). The gap is the only thing a
    /// spacer has to offer, so it is the one control its chooser shows.
    public var width: Double

    public static let defaultWidth: Double = 14
    public static let widthRange: ClosedRange<Double> = 4...48

    public init(
        id: UUID = UUID(),
        style: SeparatorStyle,
        opacity: Double = 0.55,
        width: Double = SeparatorSpec.defaultWidth
    ) {
        self.id = id
        self.style = style
        self.opacity = opacity
        self.width = width
    }

    /// Stable ItemID title, the separator's twin of `ExtraItemSpec.itemTitle`.
    /// It was interpolated at four sites in SeparatorManager; a title the
    /// model keys on belongs with the spec that owns it.
    public var itemTitle: String { "Pelmet.Separator.\(id.uuidString)" }

    // Resilient decode: specs saved before `opacity` or `width` existed keep
    // the old look — a spacer from before the width control is still 14pt.
    private enum CodingKeys: String, CodingKey { case id, style, opacity, width }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        style = try c.decode(SeparatorStyle.self, forKey: .style)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.55
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? Self.defaultWidth
    }
}

public enum ExtraKind: String, Codable, CaseIterable, Sendable {
    case mediaControls
    case cameraMicIndicator
    case airdrop
    case shortcut
    /// A Pelmet-drawn icon for another app: click opens it. Made for apps
    /// whose own icon Pelmet can't hide (hosted by a bundle-less helper the
    /// assertion allowlist can never match — ChatGPT Classic, 2026-09-09)
    /// and, for everything else, a plain launcher.
    /// Raw value predates the 2026-09-10 rename (was "app stand-in") — kept
    /// so pre-release settings still decode.
    case appLauncher = "appStandIn"
    /// Pelmet's own countdown. macOS's timer is a Control Center Live
    /// Activity the assertion hides, and its state sits behind a private
    /// entitlement (2026-09-15) — a timer that stays in the bar has to be
    /// Pelmet's.
    case timer
    /// Fast user switching menu — the system one is collateral-hidden too.
    case userSwitching
    /// Time Machine status and Back Up Now. Apple's own is a SystemUIServer
    /// extra: the assertion hides that process as one bundle, so Siri and
    /// Time Machine could only ever hide together (#19). A Pelmet-drawn
    /// item is the only way each gets its own tile; adding one switches
    /// Apple's twin off in System Settings so the bar shows a single icon.
    case timeMachine
    /// Siri, same story as `timeMachine`.
    case siri
    /// The Focus indicator. Apple's is a Control Center extra the assertion
    /// hides with the Live Activities (#29), and donotdisturbd only talks to
    /// entitled clients — but it narrates every transition to the unified
    /// log with the mode's name and symbol in the clear (probed 2026-09-16),
    /// so a Pelmet-drawn twin can follow along.
    case focus
}

/// When an activity-driven item sits in the bar — System Settings' "Always
/// Show" / "Show When Active" for Pelmet's own items. What counts as active
/// is the kind's: a launcher's app running, audio playing, a backup running,
/// a Focus being on. Kinds with no such state (Siri, AirDrop, shortcuts,
/// fast user switching) have no rule; neither does the camera & mic
/// indicator (one that always showed would lie) nor the timer (idle and
/// hidden, it could never be started).
public enum ExtraShowRule: String, Codable, CaseIterable, Sendable {
    /// Present whether or not the thing is active. A launcher's default — a
    /// launcher you can't click when the app is closed isn't a launcher.
    case always
    /// Present only while active: mirrors the app's own icon, or Apple's
    /// Focus item. Raw value predates the 2026-09-16 generalisation from
    /// launchers — kept so saved settings still decode.
    case whenActive = "whileRunning"
}

public extension ExtraKind {
    /// What a spec with no saved rule does. Media comes and goes like
    /// Apple's; a launcher, Time Machine and Focus stay — the Focus item at
    /// rest is the button that opens the Focus panel, so it earns its slot
    /// (Gab, 2026-09-16), unlike Apple's own default.
    var defaultShowRule: ExtraShowRule {
        switch self {
        case .mediaControls, .cameraMicIndicator: .whenActive
        default: .always
        }
    }
}

/// How a Pelmet item draws its glyph: the SF Symbol still, or (media
/// controls only) natively drawn bars that wave while audio plays and
/// settle when it pauses. Nil on old blobs = static; other kinds ignore it.
public enum ExtraStyle: String, Codable, CaseIterable, Sendable {
    case `static`
    case animated
}

public struct ExtraItemSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ExtraKind
    /// Glyph style for the hardware-driven kinds (media, camera & mic,
    /// AirDrop); launchers and shortcuts ignore it. Nil reads as `.static`.
    public var style: ExtraStyle?
    /// Shortcuts-app shortcut name (kind == .shortcut).
    public var shortcutName: String?
    /// SF Symbol for shortcut items.
    public var symbol: String?
    /// App launchers: the app's bundle id — identity, icon, and what a click opens.
    public var bundleID: String?
    /// App launchers: display name captured at add time (the app may be quit).
    public var appName: String?
    /// The activity-driven kinds (launchers, media controls, Time Machine,
    /// Focus); nil reads as the kind's default (`ExtraKind.defaultShowRule`).
    public var showRule: ExtraShowRule?

    public init(
        id: UUID = UUID(),
        kind: ExtraKind,
        shortcutName: String? = nil,
        symbol: String? = nil,
        bundleID: String? = nil,
        appName: String? = nil,
        showRule: ExtraShowRule? = nil,
        style: ExtraStyle? = nil
    ) {
        self.id = id
        self.kind = kind
        self.style = style
        self.shortcutName = shortcutName
        self.symbol = symbol
        self.bundleID = bundleID
        self.appName = appName
        self.showRule = showRule
    }

    public var resolvedShowRule: ExtraShowRule { showRule ?? kind.defaultShowRule }
    public var resolvedStyle: ExtraStyle { style ?? .static }

    /// Stable ItemID title. Singleton kinds keep fixed titles (section
    /// assignments survive re-toggling); shortcut items key by UUID.
    public var itemTitle: String {
        switch kind {
        case .mediaControls: "Pelmet.MediaControls"
        case .cameraMicIndicator: "Pelmet.CameraMic"
        case .airdrop: "Pelmet.AirDrop"
        case .shortcut: "Pelmet.Shortcut.\(id.uuidString)"
        case .appLauncher: "Pelmet.App.\(id.uuidString)"
        case .timer: "Pelmet.Timer"
        case .userSwitching: "Pelmet.Users"
        case .timeMachine: "Pelmet.TimeMachine"
        case .siri: "Pelmet.Siri"
        case .focus: "Pelmet.Focus"
        }
    }
}

/// How concealed icons come back on reveal. Conceal always fades (the agent
/// pops items off with no animation; Pelmet's ghost overlay manufactures the
/// hide motion) — this only styles the reveal side.
/// Glyph for Pelmet's own menu bar icon. Each style has a concealed and a
/// revealed face so the icon keeps pointing at what a click will do.
public enum StatusIconStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case chevron, arrow, eye, dots, grid, panel

    public var id: String { rawValue }

    /// SF Symbol name for the current bar state.
    public func symbol(revealed: Bool) -> String {
        switch self {
        case .chevron: revealed ? "chevron.compact.right" : "chevron.compact.left"
        case .arrow: revealed ? "arrow.right" : "arrow.left"
        case .eye: revealed ? "eye" : "eye.slash"
        case .dots: "ellipsis"
        case .grid: "square.grid.2x2"
        case .panel: revealed ? "rectangle.righthalf.inset.filled" : "rectangle.lefthalf.inset.filled"
        }
    }
}

public enum RevealAnimation: String, Codable, CaseIterable, Sendable {
    /// No animation — icons appear in place once the swap lands.
    case instant
    /// The agent's own slide-in (the OS default).
    case smooth
    /// Fade in place — a cover over the strip fades away after the swap.
    case fade
}

/// Defaults shared beyond the store itself (the engine boots with the same
/// steady-extras state a fresh store carries).
public enum SettingsDefaults {
    public static let hideSystemExtras = true
}

public struct SettingsStore: Codable, Equatable, Sendable {
    public var onboardingCompleted: Bool = false
    public var launchAtLogin: Bool = false
    public var showStatusItem: Bool = true
    public var statusIconStyle: StatusIconStyle = .chevron
    /// Never off: a missing, null or unreadable value takes the default.
    public var hotkey: HotkeySpec? = .default
    public var settingsHotkey: HotkeySpec? = .settingsDefault

    public var revealTriggers = RevealTriggers()
    public var autoRehide: Bool = true
    public var rehideDelay: TimeInterval = 5
    public var rehideOnClickElsewhere: Bool = true

    public var revealAnimation: RevealAnimation = .smooth

    /// Hold the hide-assertion even while revealed (allowlist just widens).
    /// Keeps macOS's collateral extras (Now Playing, camera pill, AirDrop…)
    /// consistently hidden instead of jumping in and out on every transition.
    public var hideSystemExtras: Bool = SettingsDefaults.hideSystemExtras

    /// Right-clicking an empty spot on the menu bar opens Pelmet's menu.
    /// Off for people running an app that draws its own surface across the
    /// bar, where the two menus compete for the same click (issue #8).
    /// Read `barRightClickMenuActive`, never this — with the icon hidden the
    /// stored value does not apply.
    public var barRightClickMenu: Bool = true

    /// Clicking the clock opens Notification Center — except that macOS
    /// refuses the click while any icon is hidden, so Pelmet lets go of the
    /// hide for an instant and replays the click (ClockClickRelay). Under a
    /// picture of the bar that instant is invisible; without Screen
    /// Recording the hidden icons flash by (#37). Off, the clock click is
    /// left to macOS (dead while icons are hidden; the two-finger swipe from
    /// the trackpad's right edge still opens Notification Center).
    public var clockClickOpensNotificationCenter: Bool = true

    /// A found update posts a user notification instead of Sparkle's window
    /// interrupting whatever the user is doing. Off: only the About pane
    /// shows it. (Auto-download is Sparkle's own preference.)
    public var notifyOnUpdates: Bool = true

    /// Pelmet's own media-controls item (play/pause/next/prev via media keys).
    /// Superseded by `extraItems`; kept for migration of early builds.
    public var showMediaControls: Bool = false

    /// Pelmet-owned proxy items ("Pelmet items"): section-manageable replacements
    /// for the collateral-hidden system extras, plus user shortcut buttons.
    public var extraItems: [ExtraItemSpec] = []

    public var sectionModel = SectionModel()
    public var separators: [SeparatorSpec] = []

    /// Behavior template + per-display overrides, keyed by display UUID string.
    /// No UI writes the template yet — DisplaysPane edits only `displayOverrides`;
    /// the template is the fallback `behavior(forDisplayUUID:)` returns.
    public var displayTemplate: DisplayBehavior = .collapse
    public var displayOverrides: [String: DisplayBehavior] = [:]

    public var rehidePolicy: RehidePolicy {
        RehidePolicy(
            autoRehide: autoRehide,
            delay: rehideDelay,
            rehideOnClickElsewhere: rehideOnClickElsewhere
        )
    }

    /// Whether the bar's right-click menu actually opens. With the icon
    /// hidden it is the only way back into Settings, so it stays on whatever
    /// the stored preference says — a lockout the UI can merely discourage is
    /// one an old blob, or turning the icon off after disabling the menu,
    /// walks straight into. Turning the icon back on restores the choice.
    public var barRightClickMenuActive: Bool { barRightClickMenu || !showStatusItem }

    public func behavior(forDisplayUUID uuid: String?) -> DisplayBehavior {
        guard let uuid else { return displayTemplate }
        return displayOverrides[uuid] ?? displayTemplate
    }

    // MARK: - Codable (resilient: new fields fall back to defaults instead of
    // failing the whole decode and silently resetting the user's settings)

    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted, launchAtLogin, showStatusItem, hotkey, settingsHotkey
        case revealTriggers, autoRehide, rehideDelay, rehideOnClickElsewhere, revealAnimation
        case hideSystemExtras, showMediaControls, extraItems, sectionModel, separators
        case displayTemplate, displayOverrides
        case notifyOnUpdates, barRightClickMenu
        case statusIconStyle
        case clockClickOpensNotificationCenter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SettingsStore()
        // `try?` per field, not just decodeIfPresent: a present-but-invalid
        // value (unknown enum case after a downgrade, hand-edited blob) throws
        // out of decodeIfPresent, and one bad field must reset THAT field —
        // not silently nuke every preference via load()'s outer `try?`.
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
        }
        onboardingCompleted = field(Bool.self, .onboardingCompleted, defaults.onboardingCompleted)
        launchAtLogin = field(Bool.self, .launchAtLogin, defaults.launchAtLogin)
        showStatusItem = field(Bool.self, .showStatusItem, defaults.showStatusItem)
        hotkey = field(HotkeySpec?.self, .hotkey, defaults.hotkey) ?? defaults.hotkey
        settingsHotkey = field(HotkeySpec?.self, .settingsHotkey, defaults.settingsHotkey) ?? defaults.settingsHotkey
        revealTriggers = field(RevealTriggers.self, .revealTriggers, defaults.revealTriggers)
        autoRehide = field(Bool.self, .autoRehide, defaults.autoRehide)
        rehideDelay = field(TimeInterval.self, .rehideDelay, defaults.rehideDelay)
        rehideOnClickElsewhere = field(Bool.self, .rehideOnClickElsewhere, defaults.rehideOnClickElsewhere)
        revealAnimation = field(RevealAnimation.self, .revealAnimation, defaults.revealAnimation)
        hideSystemExtras = field(Bool.self, .hideSystemExtras, defaults.hideSystemExtras)
        showMediaControls = field(Bool.self, .showMediaControls, defaults.showMediaControls)
        extraItems = field([ExtraItemSpec].self, .extraItems, defaults.extraItems)
        sectionModel = field(SectionModel.self, .sectionModel, defaults.sectionModel)
        separators = field([SeparatorSpec].self, .separators, defaults.separators)
        displayTemplate = field(DisplayBehavior.self, .displayTemplate, defaults.displayTemplate)
        displayOverrides = field([String: DisplayBehavior].self, .displayOverrides, defaults.displayOverrides)
        notifyOnUpdates = field(Bool.self, .notifyOnUpdates, defaults.notifyOnUpdates)
        barRightClickMenu = field(Bool.self, .barRightClickMenu, defaults.barRightClickMenu)
        statusIconStyle = field(StatusIconStyle.self, .statusIconStyle, defaults.statusIconStyle)
        clockClickOpensNotificationCenter = field(Bool.self, .clockClickOpensNotificationCenter, defaults.clockClickOpensNotificationCenter)
    }

    // MARK: - Persistence

    private static let defaultsKey = "app.fif7y.Pelmet.settings.v1"

    public static func load(defaults: UserDefaults = .standard) -> SettingsStore {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let store = try? JSONDecoder().decode(SettingsStore.self, from: data)
        else { return SettingsStore() }
        return store
    }

    public func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public init() {}
}
