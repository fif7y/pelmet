// SparkleController.swift
// Sparkle 2 updater. Disabled until a real EdDSA public key lands in
// Info.plist (SUPublicEDKey) — starting the updater with the placeholder
// would surface signature errors on every automatic check.
//
// Hybrid update UI: availability renders INLINE in the About pane (silent
// probe via checkForUpdateInformation → observable `status`); Sparkle's
// standard windows handle only the actual install — download, extract,
// relaunch — the part not worth reimplementing.
//
// Scheduled checks are "gentle": a found update never pops Sparkle's window
// over the user's work. It posts a user notification (opt-out in About) and
// the About chip; clicking either brings the install window up.

import AppKit
import PelmetEngine
import Sparkle
import UserNotifications

@MainActor
@Observable
final class SparkleController: NSObject {
    static let shared = SparkleController()

    enum UpdateStatus: Equatable {
        case unknown
        case checking
        case upToDate
        case available(version: String)
    }

    /// What the About pane renders. Fed by the silent probe AND by Sparkle's
    /// scheduled automatic checks (same delegate).
    private(set) var status: UpdateStatus = .unknown {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    /// AppKit-side mirror (the chevron's update dot); SwiftUI observes
    /// `status` directly.
    @ObservationIgnored var onStatusChange: ((UpdateStatus) -> Void)?

    var availableVersion: String? {
        if case .available(let version) = status { return version }
        return nil
    }

    private var controller: SPUStandardUpdaterController?

    /// Auto-download staged an update to install on quit: Sparkle hands
    /// over an "install now" block and shows NO UI until quit or a long
    /// idle — so the banner, chip and menu line install through this.
    @ObservationIgnored private var installNow: (() -> Void)?

    /// Sparkle's own persisted preference (SUAutomaticallyUpdate): download
    /// and stage the update in the background, install on quit.
    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// About toggle — read at notification time, so flipping it mid-session
    /// takes effect on the next found update.
    @ObservationIgnored var notifyOnUpdates: () -> Bool = { true }

    /// True once Info.plist carries a real Sparkle public key. The About
    /// pane hides its update button entirely in unconfigured dev builds.
    var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty && !key.hasPrefix("REPLACE")
    }

    func start() {
        guard controller == nil else { return }
        guard isConfigured else {
            PelmetLog.log("sparkle: no EdDSA public key in Info.plist — updater disabled")
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        UNUserNotificationCenter.current().delegate = self
        // A banner posted by the previous run (the update it announced is
        // what just launched, or the process is gone) would only ever open
        // "Pelmet is not open anymore".
        clearUpdateNotification()
        PelmetLog.log("sparkle: updater started, feed=\(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "?")")
    }

    /// Silent availability probe — no UI, no download. About calls this on
    /// appear; the result lands in `status`.
    func probe() {
        start()
        guard let controller else { return }
        guard status != .checking else { return }
        // Already known, or an update session is live (found, staged for
        // quit): Sparkle ignores a probe mid-session and never calls back —
        // the pane sat on "Checking…" forever and the About chip and
        // sidebar badge lost their "available" (2026-09-06).
        guard availableVersion == nil, controller.updater.canCheckForUpdates else { return }
        // Sparkle throttles checkForUpdateInformation by the scheduled-check
        // interval; a fresh probe per About-open is what we want, so bypass
        // is not needed — an update found by ANY check updates status.
        status = .checking
        controller.updater.checkForUpdateInformation()
    }

    /// The install flow — Sparkle's standard windows take over from here.
    /// Also how a gently-reminded update is brought into focus.
    /// (No explicit lower here: the user-driver delegate below yields the
    /// settings window for EVERY Sparkle window, scheduled checks included.)
    func checkForUpdates() {
        start()
        guard let controller else { return }
        if let installNow {
            PelmetLog.log("sparkle: installing the staged update now")
            installNow()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - Update notification

    nonisolated private static let notificationID = "app.fif7y.Pelmet.update"

    private func postUpdateNotification(version: String, staged: Bool = false) {
        Task {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert])
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                PelmetLog.log("sparkle: notification not authorized — About chip only")
                return
            }
            let content = UNMutableNotificationContent()
            if staged {
                content.title = String(localized: "Pelmet \(version) is ready")
                content.body = String(localized: "Installs when you quit. Click to update now.")
            } else {
                content.title = String(localized: "Pelmet \(version) is available")
                content.body = String(localized: "A few seconds and a relaunch. Click to update.")
            }
            // Quiet app: a banner, no sound.
            let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
            try? await center.add(request)
            PelmetLog.log("sparkle: posted update notification for \(version)")
        }
    }

    func clearUpdateNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }
}

extension SparkleController: SPUStandardUserDriverDelegate {
    /// Gentle reminders: Sparkle asks before showing a SCHEDULED update, and
    /// we always take it — the window must never land over the user's work.
    /// User-initiated checks are never routed here.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// Sparkle's windows come up at normal level — the floating settings
    /// window buries them. This fires for every presentation path (manual
    /// check AND the scheduled automatic check, which bypasses
    /// checkForUpdates() entirely — the 0.1.2 lower-on-click fix missed it).
    /// With `handleShowingUpdate == false` (a scheduled find we claimed) the
    /// reminder is ours: the About chip is already lit by the updater
    /// delegate; add the notification unless the user turned it off.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        Task { @MainActor in
            if !handleShowingUpdate, notifyOnUpdates() {
                postUpdateNotification(version: version)
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in clearUpdateNotification() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in clearUpdateNotification() }
    }
}

extension SparkleController: UNUserNotificationCenterDelegate {
    /// Clicking the banner opens the install window.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == Self.notificationID else { return }
        await MainActor.run { checkForUpdates() }
    }

    /// Show the banner even while Pelmet is the active app (settings open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

extension SparkleController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.status = .available(version: version)
            PelmetLog.log("sparkle: update available \(version)")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.status = .upToDate
            self.installNow = nil
        }
    }

    /// Auto-download path: downloaded, verified, staged for quit. This is
    /// the only signal Sparkle gives before quit, so it carries the banner.
    /// Returns true: we own the reminder, so Sparkle keeps the driver alive
    /// for the install-now block (a Void signature never matched the
    /// selector and the hook silently never fired, 2026-09-06).
    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        // Sparkle's block is plain `() -> Void`; it is only ever invoked
        // from the main actor (checkForUpdates), which is where Sparkle's
        // standard driver runs anyway.
        nonisolated(unsafe) let install = immediateInstallationBlock
        Task { @MainActor in
            self.installNow = install
            self.status = .available(version: version)
            PelmetLog.log("sparkle: update \(version) staged for quit")
            if self.notifyOnUpdates() {
                self.postUpdateNotification(version: version, staged: true)
            }
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.installNow = nil
            self.clearUpdateNotification()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Offline / feed unreachable: don't claim up-to-date, just stop
        // showing "checking". (A found-update abort keeps its status.)
        Task { @MainActor in
            if self.status == .checking { self.status = .unknown }
        }
    }
}
