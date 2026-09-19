// MenuBarPolicy.swift
// Identity and policy tables shared by the engine and the app UI. These lived
// as statics on the engine actor, which made the UI import engine internals
// and left ConvergePlan depending on the actor type it is meant to be
// independent of.

import CoreGraphics
import Foundation

public enum PelmetBundle {
    /// Pelmet's bundle id where Bundle.main has none (unit tests, probes).
    public static let fallbackID = "app.fif7y.Pelmet"
    public static let agentID = "com.apple.MenuBarAgent"
    public static let textInputAgentID = "com.apple.TextInputMenuAgent"
    /// SystemUIServer hosts the legacy menu extras (Siri, Time Machine,
    /// VPN…) as one bundle: the assertion hides them together or not at all.
    public static let systemUIServerID = "com.apple.systemuiserver"
    /// The one canonical "Pelmet's own bundle id" (A10): Bundle.main's, with
    /// the fallback for hosts that have none. Use this — never hand-roll the
    /// `??` (or forget it, as one comparison site did).
    public static let mainID = Bundle.main.bundleIdentifier ?? fallbackID
    /// Helper bundles hosting the concealable sections' own items, so the
    /// per-bundle assertion can hide them (docs/HELPER-PROCESS-PLAN.md).
    /// One host per section: the main app hosts Visible.
    public static let hiddenHostID = "app.fif7y.Pelmet.items.hidden"
    public static let alwaysHiddenHostID = "app.fif7y.Pelmet.items.alwaysHidden"
    public static let helperIDs: Set<String> = [hiddenHostID, alwaysHiddenHostID]
    /// Every process that hosts a Pelmet-owned item.
    public static var ownIDs: Set<String> { helperIDs.union([mainID, fallbackID]) }
    /// Mach port name the main app listens on for helper events.
    public static let mainLinkPort = "app.fif7y.Pelmet.link"

    public static func host(for section: Section) -> String {
        switch section {
        case .visible: mainID
        case .hidden: hiddenHostID
        case .alwaysHidden: alwaysHiddenHostID
        }
    }
}

/// The 9 system items macOS 27's assessment configuration can individually
/// allow (raw MBSystemItemIdentifier values). Anything not allowed is hidden
/// while an assertion is active.
public enum SystemItem: Int, CaseIterable, Sendable {
    case battery = 0
    case bluetooth = 1
    case clock = 2
    case displays = 3
    case keyboard = 4
    case volume = 5
    case wifi = 6
    case screenMirroring = 7
    /// Control Center ("bento box" is its internal name). Deliberately
    /// unmapped in systemItem(for:) — the agent keeps Control Center visible
    /// under any assertion regardless of allowlist (verified fc3f64c: the
    /// identifier space truly stops at 8; CC-pinned modules collateral-hide,
    /// CC itself never does). Kept to document the raw MBSystemItemIdentifier
    /// range, not to be produced.
    case primaryBentoBox = 8
}

public enum MenuBarPolicy {
    /// Core system items ARE controllable via the assertion's system-item
    /// allowlist — map their menuextra identifiers to MBSystemItemIdentifier.
    public static func systemItem(for id: ItemID) -> SystemItem? {
        // The input menu is hosted separately and titled with the active
        // input source (e.g. 微信输入法), not a com.apple.menuextra identifier.
        if id.bundleID == PelmetBundle.textInputAgentID { return .keyboard }
        let raw = id.rawValue
        guard raw.contains("::com.apple.menuextra.") else { return nil }
        if raw.hasSuffix(".sound") { return .volume }
        if raw.hasSuffix(".battery") { return .battery }
        if raw.hasSuffix(".wifi") { return .wifi }
        if raw.hasSuffix(".clock") { return .clock }
        if raw.hasSuffix(".bluetooth") { return .bluetooth }
        if raw.hasSuffix(".display") || raw.hasSuffix(".displays") { return .displays }
        if raw.hasSuffix(".textinput") || raw.hasSuffix(".keyboard") { return .keyboard }
        if raw.hasSuffix(".screen-mirroring") { return .screenMirroring }
        return nil
    }

    /// Bundles whose items legitimately mix live and hidden — never subject
    /// to tag-drift pruning (Pelmet's own items; the agent's per-identifier
    /// system items).
    public static func identityExemptBundles(pelmetBundleID: String) -> Set<String> {
        PelmetBundle.helperIDs.union([pelmetBundleID, PelmetBundle.agentID])
    }

    /// True for Pelmet-owned proxy/extra items (NOT the chevron): they're
    /// section-manageable through their own visibility. Separators included —
    /// they live in sections and hide with them, extras-style.
    public static func isPelmetExtraID(_ id: ItemID) -> Bool {
        guard let item = id.pelmetItem else { return false }
        return item != .chevron
    }

    /// Pelmet's chevron itself. Two call sites reconstructed this from
    /// `isPelmetExtraID` plus a `contains("Separator")` clause that could
    /// never fire (separators ARE extras, so the first clause already
    /// excluded them) — one predicate, one meaning.
    public static func isChevronID(_ id: ItemID, pelmetBundleID: String) -> Bool {
        id.bundleID == pelmetBundleID && id.isPelmetChevron
    }

    /// An Apple process whose bar items are the system's, not its own — the
    /// only Apple bundles Pelmet leaves alone as apps: never placed, never
    /// zone-adopted, never routed as newly installed, only the menuextra →
    /// SystemItem allowlist can touch their items (or nothing can). The
    /// agent hosts the menuextras, the input menu agent is
    /// `SystemItem.keyboard`, Control Center never hides. Until 2026-09-19
    /// this was every `com.apple.` bundle, and each Apple app with an item
    /// of its own (Kerberos #24, Passwords #34, Weather #36) needed a patch
    /// by name to become hideable and could never be moved.
    public static func isUnmanagedAppleBundle(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return systemItemHosts.contains(bundle)
    }

    /// Apple processes whose bar items are the system's, not theirs.
    static let systemItemHosts: Set<String> = [
        PelmetBundle.agentID, PelmetBundle.textInputAgentID, controlCenterID,
    ]
    public static let controlCenterID = "com.apple.controlcenter"

    /// An Apple process with an item of its own — SystemUIServer (Siri,
    /// Time Machine, #19), the Kerberos ticket extra (#24, a standalone
    /// `KerberosMenuExtra.app` under AppSSOKerberos.framework), the login
    /// items inside Passwords.app (#34) and Weather.app (#36), and whatever
    /// Apple ships next. The assertion hides it through the BUNDLE
    /// allowlist like a third-party app, and a ⌘-drag moves it like one
    /// (Weather and Passwords both moved under a real ⌘-drag, 2026-09-19;
    /// the earlier "pinned" reading of Passwords was a synthetic drag that
    /// landed mid-walk). The only difference from a third-party app is the
    /// tile name (the shipping app's) and no launcher offer. Where macOS
    /// really does pin one, `pinnedAppleHosts` says so up front and the
    /// bounce ledger catches the rest.
    /// SystemUIServer's items key by bundle (see `ItemID.sectionKey`); the
    /// others show a single stably titled item, so the status key already
    /// is the tile.
    public static func isBundleHideableAppleHost(_ bundle: String?) -> Bool {
        guard let bundle, bundle.hasPrefix("com.apple.") else { return false }
        return !systemItemHosts.contains(bundle)
    }

    /// Apple hosts macOS keeps in their own spot whatever is dragged:
    /// SystemUIServer's legacy extras (verified 2026-08-21). Hideable, not
    /// movable — the editor says so instead of dragging them around, and a
    /// zone crossing is never their user's intent.
    public static let pinnedAppleHosts: Set<String> = [PelmetBundle.systemUIServerID]
    public static func isPinnedAppleHost(_ bundle: String?) -> Bool {
        bundle.map(pinnedAppleHosts.contains) ?? false
    }

    /// macOS owns this item's slot, one way or the other: the system-item
    /// hosts (the agent draws them) and the pinned Apple hosts (the agent
    /// refuses to move them). Geometry never reads their x as a user's
    /// intent — the trailing clamp, readopt and the adoption window skip
    /// them (mr-steveryan, PR #38).
    public static func isPositionPinnedAppleBundle(_ bundle: String?) -> Bool {
        isUnmanagedAppleBundle(bundle) || isPinnedAppleHost(bundle)
    }

    /// Eligible for a section: third-party bundles, Apple hosts with items
    /// of their own, and the individually allowlisted system items.
    public static func isSectionManageable(_ id: ItemID) -> Bool {
        guard let bundle = id.bundleID else { return false }
        if !isUnmanagedAppleBundle(bundle) { return true }
        return systemItem(for: id) != nil
    }

    /// True when a bar ⌘-drag of this item may change its section: third-party
    /// items, Apple hosts with items of their own, Pelmet's own
    /// extras/separators, and the core system extras the assertion can
    /// individually allow (Sound, battery, Wi-Fi…). The system items with no
    /// allowlist entry, the pinned Apple hosts and the chevron itself are
    /// never adopted. Mirrors the editor's tile filter — Sound dragged right
    /// of the chevron stayed "hidden" because adoption skipped every
    /// `com.apple.` bundle (2026-09-08).
    public static func isZoneAdoptable(_ id: ItemID, pelmetBundleID: String) -> Bool {
        guard let bundle = id.bundleID, !id.isSystemModule else { return false }
        if bundle == pelmetBundleID { return isPelmetExtraID(id) }
        if isUnmanagedAppleBundle(bundle) { return systemItem(for: id) != nil }
        return !isPinnedAppleHost(bundle)
    }
}

/// Menubar band geometry in CG top-left global coordinates.
public enum MenuBarGeometry {
    public static let bandTopInset: CGFloat = -5
    public static let bandBottomLimit: CGFloat = 50

    /// True when a frame sits in the main display's menubar band. Frames from
    /// other displays carry their own coordinate origins and fall outside.
    public static func isInBand(_ frame: CGRect) -> Bool {
        frame.minY > bandTopInset && frame.minY < bandBottomLimit
    }

    /// In the band AND on the primary display. A display parked beside the
    /// primary with its top aligned puts its bar in the band too, and an
    /// item that overflows on a notched built-in has only those copies in
    /// the walk (its main copy sits in the overflow menu).
    public static func isInPrimaryBand(_ frame: CGRect, primaryMaxX: CGFloat) -> Bool {
        isInBand(frame) && frame.midX > 0 && frame.midX < primaryMaxX
    }
}
