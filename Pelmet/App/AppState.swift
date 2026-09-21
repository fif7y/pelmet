// AppState.swift
// Root composition: owns the engine, the rehide state machine, settings, and
// the status item. All UI-facing state is @Observable.

import AppKit
import PelmetCore
import PelmetEngine
import SwiftUI

@Observable
final class AppState {
    let engine = AgentBarEngine()
    var settings = SettingsStore.load()
    private(set) var snapshot: EngineSnapshot?
    private(set) var accessibilityGranted = AccessibilityAccess.isGranted
    /// Optional grant behind the hide/reveal covers; re-read while the
    /// General tab is up (no watcher — nothing in the app depends on it).
    private(set) var screenRecordingGranted = ScreenRecordingAccess.isGranted
    private(set) var engineCanHide = true
    /// Settings window tab. Owned here (not view @State) so every window
    /// open can reset it to General — reopening straight onto the Menu Bar
    /// tab fired its full-reveal preview unprompted.
    var settingsTab: SettingsTab = .general
    /// While the settings window is open, auto-rehide is fully suppressed —
    /// the user is mid-workflow between the editor and the bar, and nothing
    /// should collapse under them. Closing the window re-conceals.
    /// Only the layout editor holds the bar open: it previews the full bar
    /// and drags there must stay in sync with it. On any other tab (or with
    /// the window closed) hover-rehide behaves normally (Gab, 2026-09-02).
    /// Sets core: the editor no longer shows the bar, so it holds it only
    /// for the span of an Apply pass.
    var editorHoldsBar: Bool {
        settingsWindowVisible && settingsTab == .menuBar && (!CoreMode.setsOnly || applying)
    }

    /// The shortcut in settings could not be registered (another app holds
    /// it) — the General row says so beside the recorder.
    private(set) var hotkeyConflict = false
    private(set) var settingsHotkeyConflict = false

    var settingsWindowVisible = false {
        didSet {
            guard oldValue != settingsWindowVisible else { return }
            if !settingsWindowVisible {
                applyPointerDisplayPolicyAfterDismissal()
            }
        }
    }

    /// Per-display behavior is "the display the pointer is on wins" — this is
    /// that display's setting. Every path that could conceal the bar must
    /// consult it; reveal-side crossings live in MenuBarBandMonitor.
    var pointerDisplayBehavior: DisplayBehavior {
        settings.behavior(forDisplayUUID: NSScreen.underPointer?.displayUUIDString)
    }

    @ObservationIgnored private lazy var placement = PlacementController(appState: self, engine: engine)
    @ObservationIgnored private lazy var transitions = TransitionCoordinator(appState: self, engine: engine)
    private var rehide = RehideStateMachine()
    private var rehideTimer: Timer?
    /// One "rehide: deferred" line per armed countdown, not one per re-arm.
    private var rehideDeferLogged = false
    private var statusItem: PelmetStatusItem?
    private var separators: SeparatorManager?
    private(set) var helperHosts: HelperHosts?
    /// Set once the first converge has run: helper registrations before it
    /// are covered by the boot wait, later ones need an adoption window.
    private var engineStarted = false
    private var extras: ExtrasManager?
    private var bandMonitor: MenuBarBandMonitor?
    private var clockRelay: ClockClickRelay?
    /// See `ClockClickRelay.lastMouseDownDisplay`: the display whose bar
    /// macOS draws active. nil until the first click after launch.
    var lastMouseDownDisplay: CGDirectDisplayID? { clockRelay?.lastMouseDownDisplay }
    private var hotkey: HotkeyManager?
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored private lazy var accessibility = AccessibilityMonitor { [weak self] granted in
        self?.accessibilityChanged(granted)
    }

    // MARK: - Lifecycle

    /// Boot sequence. ORDER IS LOAD-BEARING:
    /// migrations → policy/updater → onboarding gate → bar items (separators
    /// before extras; extras sync reads the media-controls migration) →
    /// monitors → event pump → async engine boot. Inside the engine boot:
    /// `waitForOwnItemAdoption` runs BEFORE `engine.start` (items registering
    /// under an active assertion park offscreen), `registerNewItems` before
    /// `setModel` (routing must precede the first converge),
    /// `flushPendingPlacements` after `setModel`, and the launch conceal
    /// precedes the display-policy reveal so the policy lands on a settled bar.
    func start() {
        wireTransitionSettleCallbacks()
        runOneShotMigrations()
        applyPolicyAndStartUpdater()
        presentOnboardingIfNeeded()
        buildBarItems()
        startMonitors()
        startEngineEventPump()
        bootEngine()
    }

    private func wireTransitionSettleCallbacks() {
        transitions.onRevealSettled = { [weak self] in
            guard let self else { return }
            dispatch(rehide.handle(.transitionSettled))
            settleCatchUp()
            // Newcomers routed into a then-concealed section finally
            // have measurable neighbors — walk them to their slot.
            placement.flushPendingPlacements()
            placeOwnItemsAwaitingReveal()
            // Order supervisor: with the hidden cluster materialized, any
            // item on the wrong side of the chevron is corrected now, under
            // this reveal, from a fresh measurement.
            Task { [weak self] in
                guard let self else { return }
                await placement.correctDrift()
                placement.flushPendingPlacements()
            }
            // Swipe-through hover: the pointer can be long gone by the
            // time the reveal settles — armIfNeeded gave the FULL delay.
            // Re-arm as a pointer-out so an accidental hover self-heals
            // on the short clock. HOVER ONLY: deliberate reveals (click,
            // hotkey) with the pointer elsewhere must keep the floor,
            // not conceal instantly at rehideDelay 0.
            if case .revealed(_, .hover) = rehide.state,
               bandMonitor?.pointerCurrentlyInBand == false {
                pointerLeftBand()
            }
        }
        transitions.onConcealSettled = { [weak self] in
            guard let self else { return }
            dispatch(rehide.handle(.transitionSettled))
            settleCatchUp()
            // The bar just de-crowded — items trapped in the native
            // overflow now have real frames. Walk any queued rescues.
            placement.flushPendingRescues()
            // Rapid hover out-in: if the pointer is back in the band by the
            // time this conceal lands, its entry edge is spent — re-arm the
            // hover reveal so the bar doesn't stay shut under the pointer.
            if case .concealed = rehide.state {
                bandMonitor?.rearmHoverAfterConceal()
            }
        }
    }

    private func runOneShotMigrations() {
        // One-shot: snappier hover default (0.2 → 0.1) for stores saved
        // before the default changed.
        if !UserDefaults.standard.bool(forKey: "pelmet.migratedHoverDelay01"),
           abs(settings.revealTriggers.hoverDelay - 0.2) < 0.011 {
            settings.revealTriggers.hoverDelay = 0.1
            settings.save()
        }
        UserDefaults.standard.set(true, forKey: "pelmet.migratedHoverDelay01")

        // Sliders are stepped now (hover 0.1–0.5, rehide 0–5): snap stores
        // saved under the old free ranges onto the grid.
        settings.revealTriggers.hoverDelay = (min(max(settings.revealTriggers.hoverDelay, 0.1), 0.5) * 10).rounded() / 10
        settings.rehideDelay = (min(max(settings.rehideDelay, 0), 5) * 2).rounded() / 2

        // Migrate the model to canonical (bundle-level) keys — collapses any
        // title-variant twin entries left by older builds.
        settings.sectionModel.canonicalize()
        settings.save()
        if CoreMode.setsOnly {
            PelmetLog.log("core: sets only — membership hides, no placement path starts a drag")
        }
    }

    private func applyPolicyAndStartUpdater() {
        rehide.policy = settings.rehidePolicy
        engineCanHide = engine.capabilities.canHide
        PelmetLog.log("start: axTrusted=\(accessibilityGranted) canHide=\(engineCanHide) assignments=\(settings.sectionModel.assignments.count)")
        SparkleController.shared.notifyOnUpdates = { [weak self] in self?.settings.notifyOnUpdates ?? true }
        SparkleController.shared.onStatusChange = { [weak self] status in
            if case .available = status {
                self?.statusItem?.showUpdateDot(true)
            } else {
                self?.statusItem?.showUpdateDot(false)
            }
        }
        SparkleController.shared.start()
    }

    /// First run gets the intro. A finished install that lost its grant
    /// (an update re-signed the bundle, the toggle was flipped) gets the
    /// one-step recovery instead of the whole intro again.
    private func presentOnboardingIfNeeded() {
        if !settings.onboardingCompleted {
            OnboardingController.shared.present(appState: self, mode: .intro)
        } else if !accessibilityGranted {
            OnboardingController.shared.present(appState: self, mode: .accessRecovery)
        }
    }

    private func buildBarItems() {
        if settings.showStatusItem {
            statusItem = PelmetStatusItem(appState: self)
        }
        ConcealGhostOverlay.prewarmDisplay()
        helperHosts = HelperHosts(appState: self)
        separators = SeparatorManager(appState: self)
        separators?.sync(with: settings.separators)
        // Migration: early builds had a bare media-controls bool.
        if settings.showMediaControls, !settings.extraItems.contains(where: { $0.kind == .mediaControls }) {
            settings.showMediaControls = false
            addExtra(ExtraItemSpec(kind: .mediaControls))
        }
        // Repair: blobs written by builds that appended a spec without an
        // order slot (#13). Every extra gets one where the model already
        // places it — nothing moves.
        var repaired = false
        for spec in settings.extraItems {
            repaired = settings.sectionModel.enroll(ExtrasManager.itemID(for: spec).sectionKey) || repaired
        }
        // The other side of the invariant: a removed extra left its order
        // key behind (twenty dead launcher keys in one blob). Separators
        // have their own manager and stay.
        let liveExtraKeys = Set(settings.extraItems.map { ExtrasManager.itemID(for: $0).sectionKey })
        for (section, order) in settings.sectionModel.order {
            let kept = order.filter {
                !MenuBarPolicy.isPelmetExtraID($0) || $0.isPelmetSeparator || liveExtraKeys.contains($0)
            }
            if kept.count != order.count {
                settings.sectionModel.order[section] = kept
                for key in order where !kept.contains(key) {
                    settings.sectionModel.assignments.removeValue(forKey: key)
                }
                repaired = true
            }
        }
        if repaired {
            PelmetLog.log("extras: order slots repaired")
            settings.save()
        }
        extras = ExtrasManager(appState: self)
        extras?.sync(with: settings.extraItems)
    }

    private func startMonitors() {
        accessibility.start()
        let bandMonitor = MenuBarBandMonitor(appState: self)
        bandMonitor.start()
        self.bandMonitor = bandMonitor

        let clockRelay = ClockClickRelay { [weak self] point, pointer in
            self?.clockClicked(at: point, pointer: pointer)
        }
        // The tap always runs (it is also the active-display observer);
        // the setting only decides whether a clock click is relayed.
        clockRelay.setEnabled(settings.clockClickOpensNotificationCenter)
        self.clockRelay = clockRelay

        let hotkey = HotkeyManager { [weak self] slot in
            switch slot {
            case .toggle: self?.toggle(reason: .hotkey)
            case .settings: self?.openSettings()
            }
        }
        hotkeyConflict = !hotkey.register(settings.hotkey, slot: .toggle)
        settingsHotkeyConflict = !hotkey.register(settings.settingsHotkey, slot: .settings)
        registeredHotkey = settings.hotkey
        registeredSettingsHotkey = settings.settingsHotkey
        self.hotkey = hotkey

        // A relaunched app's status item is a FRESH registration — the agent
        // parks it wherever it likes, not at the model slot (plist seeds are
        // unreliable: Bitwarden relaunched into the middle of the always-hidden
        // cluster, 2026-08-31), and the misplaced live frame then poisons
        // neighbor targeting for every later placement near it. Queue its
        // items for a re-slot; the flush places them at the next reveal
        // settle (or right away for the visible section).
        let agents = Self.systemAgentBundles(in: NSWorkspace.shared.runningApplications)
        MenuBarPolicy.registerSystemAgents(agents)
        PelmetLog.log("policy: \(agents.count) system agent(s) registered from \(MenuBarPolicy.systemAgentLocation)")
        relaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MenuBarPolicy.registerSystemAgents(Self.systemAgentBundles(in: [app]))
            guard let bundle = app.bundleIdentifier, Self.isBundleMainProcess(app) else { return }
            MainActor.assumeIsolated { self?.queueRelaunchedBundlePlacement(bundle) }
        }
        observeRunningApplications()
    }

    /// The process is the app itself, not a child LaunchServices filed
    /// under its parent's bundle: an `osascript` or `open` spawned by an
    /// app runs as that app's bundle id with its own executable. Claude
    /// Desktop's tool runs spawn one every few seconds, and each read as a
    /// relaunch — an adoption window per spawn, the assertion dropped and
    /// every hidden icon flashed under a cover (2026-09-18).
    /// Bundle ids of the processes that live where macOS keeps its menu bar
    /// agents (`MenuBarPolicy.systemAgentLocation`).
    nonisolated static func systemAgentBundles(in apps: [NSRunningApplication]) -> Set<String> {
        Set(apps.compactMap { app in
            guard let id = app.bundleIdentifier, let path = app.bundleURL?.standardizedFileURL.path,
                  MenuBarPolicy.isSystemAgentLocation(path) else { return nil }
            return id
        })
    }

    nonisolated static func isBundleMainProcess(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL, let exe = app.executableURL,
              let own = Bundle(url: bundleURL)?.executableURL else { return true }
        return own.standardizedFileURL.path == exe.standardizedFileURL.path
    }

    private var relaunchObserver: NSObjectProtocol?
    private var runningAppsObservation: NSKeyValueObservation?
    private var lastRelaunchQueue: [String: Date] = [:]
    private var siblingLaunchLogged: Set<String> = []

    /// Menu-bar agent apps (LSUIElement / background-only) post no launch
    /// notification — Snib, OpenClip and Sconce relaunched all afternoon
    /// without a single re-slot (2026-09-09). KVO on runningApplications
    /// sees every activation policy; both paths feed the same queue.
    private func observeRunningApplications() {
        runningAppsObservation = NSWorkspace.shared.observe(
            \.runningApplications, options: [.old, .new]
        ) { [weak self] _, change in
            let before = Set((change.oldValue ?? []).compactMap(\.bundleIdentifier))
            let appeared = (change.newValue ?? [])
                .filter { Self.isBundleMainProcess($0) }
                .compactMap(\.bundleIdentifier)
                .filter { !before.contains($0) }
            guard !appeared.isEmpty else { return }
            Task { @MainActor [weak self] in
                for bundle in appeared { self?.queueRelaunchedBundlePlacement(bundle) }
            }
        }
    }

    /// A known item that is in the model but absent from the bar even when
    /// its section is revealed has re-registered under the assertion and
    /// parked (ChatGPT Classic re-creates its status item at runtime, 2026-09-09;
    /// the icon showed for a moment and never came back). Same remedy as a
    /// relaunch: a brief adoption window, then place it.
    /// An adoption window drops the assertion outright — the agent refuses to
    /// attach a newly registered item while ANY assertion is held, allowlist
    /// or not — so for its whole life (up to 2.5s) every hidden AND
    /// always-hidden icon is back in the bar. Float the same picture the
    /// clock blink uses over the strip for the round trip. #31: a relaunched
    /// always-hidden app showed its icon "for a second" on the next hover —
    /// the hover was a coincidence, the retry window was the flash.
    private func coveringAdoption(_ body: () async -> Bool) async -> Bool {
        guard await engine.holdsAssertion else { return await body() }
        let cover = await transitions.beginBarCover(
            label: "adopt", safety: AppTiming.adoptionCoverSafety
        )
        let adopted = await body()
        if let cover { transitions.endBarCover(cover, label: "adopt") }
        return adopted
    }

    func reopenAdoption(for bundle: String) async {
        let keys = settings.sectionModel.assignments.keys.filter { $0.bundleID == bundle }
        placement.queuePlacements(keys)
        if await coveringAdoption({ await engine.openAdoptionWindow(for: bundle) }) {
            absentBundles.remove(bundle)
            updateSnapshot(await engine.snapshot())
            placement.flushPendingPlacements()
        } else {
            // Running, assigned, and still no registration with the
            // assertion dropped: the app has no bar icon right now (its
            // "show in menu bar" is off — the launcher flow's last step).
            // The editor's no-flash guard must not keep a ghost tile for it.
            absentBundles.insert(bundle)
            PelmetLog.log("editor: \(bundle) has no menu bar item — off the board")
        }
    }

    static func relaunchPlacementKeys(for bundle: String, model: SectionModel) -> [ItemID] {
        // A system host may restart before any registration pass has folded
        // it into knownBundles (the input menu switched on, then its agent
        // relaunched). Its assignment is the proof the user manages it.
        guard MenuBarPolicy.isUnmanagedAppleBundle(bundle) || model.knownBundles.contains(bundle) else { return [] }
        return registrationCandidates(model.assignments.keys.filter { $0.bundleID == bundle })
    }

    static func registrationCandidates(_ items: [ItemID]) -> [ItemID] {
        items.filter {
            guard let bundle = $0.bundleID else { return false }
            return !PelmetBundle.ownIDs.contains(bundle) && MenuBarPolicy.isSectionManageable($0)
        }
    }

    /// Bundles that are running but proven icon-less (an adoption window
    /// found no registration). Cleared the moment an item of theirs shows.
    private var absentBundles: Set<String> = []
    /// When each canonical identity was last live or concealed. The editor
    /// keeps a stored item's stand-in tile through a snapshot gap only while
    /// this is fresh; a host with no registration never gets one.
    private var lastSeenAt: [ItemID: Date] = [:]
    private static let storedTileGrace: TimeInterval = 15
    /// The process that last owned each bundle's live item. A launch
    /// notification names a bundle, not a process: while this pid still
    /// runs, the item it owns is merely concealed and the "relaunch" is a
    /// sibling reusing the id.
    private var lastSeenPID: [String: pid_t] = [:]

    private func queueRelaunchedBundlePlacement(_ bundle: String) {
        let keys = Self.relaunchPlacementKeys(for: bundle, model: settings.sectionModel)
        guard !keys.isEmpty else { return }
        // The notification and the KVO path can both report one launch.
        if let last = lastRelaunchQueue[bundle], Date.now.timeIntervalSince(last) < 3 { return }
        lastRelaunchQueue[bundle] = .now
        let queuedAt = Date.now
        placement.queuePlacements(keys)
        if !CoreMode.setsOnly {
            PelmetLog.log("place: \(bundle) relaunched — queued \(keys.count) item(s) for re-slot")
        }
        // The relaunched item registers UNDER an active assertion and parks
        // offscreen — it never enters the bar or the AX tree on its own (so
        // no itemsChanged fires, and the editor can't see it either). Open
        // an explicit adoption window once the app has had time to build its
        // item; retry once for slow bootstraps (Electron vault apps take
        // ~20s). Skipped when the item is already observable.
        Task { [weak self] in
            for delay in [AppTiming.relaunchAdoptionDelay, AppTiming.relaunchAdoptionRetry] {
                try? await Task.sleep(for: delay)
                guard let self else { return }
                // LIVE AX presence only — the engine's carried concealed set
                // still lists the OLD registration (a concealed item's quit
                // fires no AX event, so nothing pruned it) and would mask the
                // parked NEW one. A relaunched item is parked, never
                // genuinely concealed, until an assertion-free gap adopts it.
                let snap = await self.engine.snapshot()
                let observable = snap.items.contains { $0.id.bundleID == bundle }
                if observable { return }
                // The owner of the bundle's item is still running, so the
                // item is concealed, not parked: nothing relaunched. Proton
                // Drive ships a launchd KeepAlive agent that respawns a
                // second "Proton Drive" every 10s which quits on sight of
                // the first — each spawn dropped the assertion and flashed
                // every hidden icon (issue #12). Checked after the delay,
                // not at queue time: a self-relaunching app's old process
                // can outlive its successor's launch notification.
                if let pid = self.lastSeenPID[bundle], kill(pid, 0) == 0 {
                    if self.siblingLaunchLogged.insert(bundle).inserted {
                        PelmetLog.log("adoptWindow: \(bundle) owner pid=\(pid) still running — sibling launch, nothing to adopt (logged once)")
                    }
                    return
                }
                // No owner pid on record (an item Pelmet only ever saw
                // through the agent's tree — Electron apps with AX off):
                // an instance of the app older than this launch is still
                // up, so the item is concealed, not parked.
                if self.lastSeenPID[bundle] == nil,
                   NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: {
                       Self.isBundleMainProcess($0) && ($0.launchDate ?? .now) < queuedAt.addingTimeInterval(-1)
                   }) {
                    if self.siblingLaunchLogged.insert(bundle).inserted {
                        PelmetLog.log("adoptWindow: \(bundle) an older instance is still running — sibling launch, nothing to adopt (logged once)")
                    }
                    return
                }
                // A system host (the input menu's agent) registers through
                // the agent's own path the moment it has an item — it never
                // parks and never bootstraps slowly. After the first wait it
                // is either registered and already concealed (placement
                // waits for a reveal) or it restarted without an item (the
                // menu switched off in System Settings). Neither needs the
                // assertion dropped, let alone twice (2026-09-10). The
                // pinned hosts get nothing from a window either: the slot
                // they come back to is the one macOS gives them. Apple's
                // ordinary helpers DO park, and fall through like any app.
                if MenuBarPolicy.isPositionPinnedAppleBundle(bundle) {
                    let held = snap.concealed.contains { $0.bundleID == bundle }
                    PelmetLog.log("adoptWindow: \(bundle) \(held ? "registered and concealed" : "restarted without its item") — nothing to adopt")
                    return
                }
                if await self.coveringAdoption({ await self.engine.openAdoptionWindow(for: bundle) }) {
                    self.updateSnapshot(await self.engine.snapshot())
                    self.placement.flushPendingPlacements()
                    return
                }
            }
            PelmetLog.log("adoptWindow: \(bundle) never registered — giving up")
        }
    }

    private func startEngineEventPump() {
        eventTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await event in events {
                self?.handle(engineEvent: event)
            }
        }
    }

    private func bootEngine() {
        Task {
            // The agent DEFERS adopting newly registered status items while
            // an assessment assertion is active (verified live 2026-08-21: a
            // fresh item parks offscreen until no assertion holds, then lands
            // instantly). Pelmet's own items re-register at every launch, and
            // the first converge would assert before adoption lands — parking
            // them for the whole session.
            await helperHosts?.waitUntilHosted()
            await waitForOwnItemAdoption()
            await engine.start()
            engineStarted = true
            // Extras change size inside the same agent reflow as assertion
            // swaps — the only way their motion matches everything else's.
            await engine.setReflowCompanion { [weak self] revealed in
                guard let self else { return }
                PelmetLog.log("companion: fired revealed=\(revealed.map(\.rawValue).sorted())")
                self.extras?.apply(
                    model: self.settings.sectionModel,
                    revealed: revealed,
                    systemCameraPillVisible: self.systemCameraPillVisible
                )
                self.separators?.apply(
                    model: self.settings.sectionModel,
                    revealed: revealed
                )
            }
            await engine.setSteadyExtras(settings.effectiveHideSystemExtras)
            if !settings.hideSystemExtras, settings.replacesCollateralExtras {
                PelmetLog.log("extras: system extras held hidden — a Pelmet item replaces one")
            }
            // Apps that first appeared while Pelmet wasn't running route to the
            // new-items section before the first converge. VISIBLE newcomers
            // get their placement drag now (still live-framed); concealed
            // destinations queue until a reveal makes them measurable.
            let launchSnapshot = await engine.snapshot()
            let launchNewItems = registerNewItems(from: launchSnapshot)
            placement.queuePlacements(launchNewItems)
            // Pelmet's own extras and separators are fresh registrations on
            // every relaunch — the agent seeds their slot, not the model
            // (the media control landed in the hidden zone, 2026-09-02).
            // Nothing else walks own items back, so queue the ones that are
            // actually in layout; `alreadyPlaced` short-circuits the ones
            // that landed right. Out-of-layout ones (camera pill idle,
            // width-collapsed hidden separators) have no frame to drag and
            // would just requeue and log on every reveal settle.
            let liveKeys = Set(
                launchSnapshot.items
                    .filter { $0.frame.map(MenuBarGeometry.isInBand) == true }
                    .map(\.id.sectionKey)
            )
            let ownItems = (extras?.managedItemIDs ?? []) + (separators?.managedItemIDs ?? [])
            placement.queuePlacements(ownItems.filter { liveKeys.contains($0.sectionKey) })
            // The chevron's slot is the hidden cluster's right edge, only
            // measurable while that cluster is live — and right now, before
            // the first converge, everything is. Walk it HERE: doing it at a
            // later hover grabbed the cursor for two seconds mid-hover
            // (2026-09-06). Already-in-order skips without a drag.
            if settings.showStatusItem {
                await placement.physicallyPlace(Self.chevronItemID, in: .visible)
            }
            // Last look at the fully live bar: the first reveal's picture
            // (see TransitionCoordinator.takeBootPicture). A fresh walk,
            // the chevron drag above may have shifted the run. The converge
            // below is what conceals.
            await transitions.takeBootPicture(from: await engine.snapshot())
            await engine.setModel(settings.sectionModel)
            // Visible-destined newcomers place right away (the flush filter
            // passes them without a reveal); concealed ones wait for one.
            placement.flushPendingPlacements()
            updateSnapshot(await engine.snapshot())
            // Startup state: everything the model says is hidden, is hidden.
            dispatch(rehide.handle(.concealRequested))
            transitions.warmAfterBoot(from: launchSnapshot)
            // Launch baseline: the band monitor only applies display behavior
            // on crossings, so the display Pelmet launches under gets its
            // policy applied here (queued behind the conceal's settle).
            if pointerDisplayBehavior == .alwaysShowAll {
                reveal([.hidden], reason: .displayPolicy)
            }
        }
    }

    /// Async teardown for app termination: dropping the assertion restores
    /// the user's menubar. Caller returned .terminateLater — this replies
    /// when the engine has stopped, or at the deadline, whichever first
    /// (formerly a main-actor-blocking semaphore).
    private var terminationReplied = false
    func beginTermination() {
        rehideTimer?.invalidate()
        eventTask?.cancel()
        SparkleController.shared.clearUpdateNotification()
        Task { [engine] in
            await engine.stop()
            self.replyTerminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AppTiming.terminationStopDeadline) { [weak self] in
            self?.replyTerminate()
        }
    }

    private func replyTerminate() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - Intents (UI + monitors call these)

    func toggle(reason: RevealReason) {
        // A click landing in the first moments of a hover reveal: the
        // pointer reached the chevron, the hover fired ~100ms later, and
        // the click was already on its way. The machine's rule for a
        // toggle mid-transition (the opposite of where we're heading)
        // read it as "close" — open, shut, then the hover on the chevron
        // opened it again (2026-09-18). Take it as the same reveal, now
        // the click's.
        let hoverSections: Set<PelmetCore.Section>? = {
            switch rehide.state {
            case .transitioning(target: .reveal(let sections, .hover), queued: nil): sections
            case .revealed(let sections, .hover): sections
            default: nil
            }
        }()
        if let hoverSections, let started = hoverRevealStartedAt,
           Date().timeIntervalSince(started) < AppTiming.hoverRevealClickGrace {
            PelmetLog.log("toggle(\(reason)) \(Int(Date().timeIntervalSince(started) * 1000))ms into a hover reveal — taken as the same reveal")
            dispatch(rehide.handle(.revealRequested(hoverSections, reason)))
            return
        }
        let effects = rehide.handle(.toggleRequested([.hidden], reason))
        PelmetLog.log("toggle(\(reason)) state=\(rehide.state) effects=\(effects)")
        dispatch(effects)
        // A deliberate conceal under a hovering pointer must STAY concealed:
        // the pointer is in the band by definition (it just clicked there),
        // and the conceal-settle hover re-arm would reopen the bar at once —
        // every chevron click read as a dead click (2026-09-06).
        if effects.contains(.conceal) {
            bandMonitor?.suppressHoverUntilPointerLeaves()
        }
    }

    func reveal(_ sections: Set<PelmetCore.Section>, reason: RevealReason) {
        dispatch(rehide.handle(.revealRequested(sections, reason)))
    }

    /// When the last hover reveal's effect started — the earliest the user
    /// could see the bar open (see `toggle`).
    private var hoverRevealStartedAt: Date?

    func concealNow() {
        PelmetLog.log("concealNow state=\(rehide.state)")
        dispatch(rehide.handle(.concealRequested))
    }

    func rehideTriggered(_ trigger: RehideTrigger) {
        PelmetLog.log("rehideTrigger(\(trigger)) state=\(rehide.state)")
        dispatch(rehide.handle(.trigger(trigger)))
    }

    func pointerReturnedToBand() {
        dispatch(rehide.handle(.pointerReturned))
    }

    func pointerLeftBand() {
        dispatch(rehide.handle(.pointerLeft))
    }

    var isRevealed: Bool {
        if case .revealed = rehide.state { return true }
        return false
    }

    /// Revealed OR heading there — what the chevron should show.
    private var isRevealedOrRevealing: Bool {
        switch rehide.state {
        case .revealed: return true
        case .transitioning(_, queued: .reveal): return true
        case .transitioning(target: .reveal, queued: nil): return true
        default: return false
        }
    }

    /// Bounded poll until the engine reports swap-quiet for `interval` — the
    /// agent animates each swap, so quiet means the bar has stopped moving.
    /// Uncovered reveal: put the sections' own items (launchers, separators)
    /// into the layout before the swap, invisible, and give the agent a beat
    /// to place them — so its slide-in animates the third-party icons into
    /// slots around them instead of shifting everything once more when they
    /// settle later (see `StatusItemFader.attach`).
    /// Apply pass: idle extras join the layout invisibly so they can be
    /// dragged (ExtrasManager.attachForApply). Returns what joined.
    func attachIdleExtrasForApply() -> [ItemID] { extras?.attachForApply() ?? [] }
    func detachIdleExtrasAfterApply() { extras?.detachAfterApply() }

    func preattachOwnItems(revealing sections: Set<PelmetCore.Section>) async {
        let model = settings.sectionModel
        var attached = extras?.preattach(model: model, revealing: sections) ?? []
        attached += separators?.preattach(model: model, revealing: sections) ?? []
        guard !attached.isEmpty else { return }
        try? await Task.sleep(for: AppTiming.ownItemAttachLead)
        PelmetLog.log("preattach: \(attached.count) own item(s) in layout ahead of the swap")
    }

    func waitUntilQuiesced(
        interval: TimeInterval, deadline: TimeInterval, poll: Duration
    ) async {
        let by = Date().addingTimeInterval(deadline)
        while Date() < by, await !engine.quiesced(for: interval) {
            try? await Task.sleep(for: poll)
        }
    }

    /// Post-settle catch-up: re-run the companion apply so anything that
    /// changed DURING the transition (media presence, camera pill, a converge
    /// that no-opped and never fired the companion) lands now. lastVisible
    /// guards make this a no-op when the companion already got it right.
    private func settleCatchUp() {
        extras?.apply(
            model: settings.sectionModel,
            revealed: currentRevealedSections,
            systemCameraPillVisible: systemCameraPillVisible
        )
        separators?.apply(model: settings.sectionModel, revealed: currentRevealedSections)
    }

    func openSettings(tab: SettingsTab = .general) {
        SettingsWindowController.shared.show(appState: self, tab: tab)
    }

    func refreshAccessibility() {
        accessibility.refresh()
    }

    func refreshScreenRecording() {
        let granted = ScreenRecordingAccess.isGranted
        guard granted != screenRecordingGranted else { return }
        screenRecordingGranted = granted
        PelmetLog.log("screen: recording granted=\(granted)")
    }

    /// Grant arrived: the engine's walks were empty until now, and the clock
    /// relay's tap never came up — re-read the bar, retry the tap, and
    /// re-apply the model. Grant lost: nothing to tear down (walks just go
    /// empty), but the status item and settings show the warning.
    private func accessibilityChanged(_ granted: Bool) {
        accessibilityGranted = granted
        PelmetLog.log("ax: trusted=\(granted)")
        statusItem?.updateAccessibilityWarning(granted: granted)
        guard granted else { return }
        clockRelay?.setEnabled(settings.clockClickOpensNotificationCenter)
        Task {
            updateSnapshot(await engine.snapshot())
            await engine.setModel(settings.sectionModel)
            dispatch(rehide.handle(.concealRequested))
        }
    }

    private var settingsApplyWork: Task<Void, Never>?
    private var registeredHotkey: HotkeySpec?
    private var registeredSettingsHotkey: HotkeySpec?

    /// Persist + apply a changed settings store. Cheap, latency-sensitive
    /// bits apply immediately; the save and the engine converge are debounced
    /// — slider drags call this per tick, and each un-debounced tick paid a
    /// JSON save plus a full AX-walking converge that concluded "no-op".
    /// Clock blink (see ClockClickRelay): cover the strip, drop the
    /// assertion, replay the swallowed click, re-acquire, lift the cover once
    /// the bar is quiet beneath it. With nothing held the click just replays.
    private func clockClicked(at point: CGPoint, pointer: CGPoint) {
        Task { @MainActor in
            // Dot zone (target ≠ where the click landed): press the clock
            // through AX so the pointer never moves; the click is the
            // fallback. The element is resolved now, on a static bar.
            let clockElement = point == pointer ? nil : ClockClickRelay.clockElement(at: point)
            let cover = await transitions.beginBarCover()
            let blinked = await engine.beginClockBlink()
            if let clockElement {
                // Only once the physical button is up: pressed while the
                // finger is still down (the tap swallows the up ~80ms
                // later), the clock merely highlighted. Then let the agent
                // apply the drop (the queued click got that latency for
                // free), and press once more if Notification Center has
                // not shown — the first press missed about one time in two
                // and the second always took (Gab, 2026-09-19).
                await ClockClickRelay.waitForButtonRelease()
                try? await Task.sleep(for: AppTiming.clockPressSettle)
                var opened = false
                for attempt in 1...2 where !opened {
                    let pressed = ClockClickRelay.press(clockElement)
                    try? await Task.sleep(for: AppTiming.clockPressVerify)
                    opened = ClockClickRelay.notificationCenterIsOpen()
                    PelmetLog.log("clock: dot press \(attempt) \(pressed ? "sent" : "refused") - NC \(opened ? "open" : "not open")")
                }
                if !opened { ClockClickRelay.postClick(at: point, pointer: pointer) }
            } else {
                if point != pointer { PelmetLog.log("clock: dot click - no clock element under the target, replaying the click") }
                ClockClickRelay.postClick(at: point, pointer: pointer)
            }
            guard blinked else { cover?.dismiss(); return }
            try? await Task.sleep(for: AppTiming.clockBlinkReacquire)
            await engine.endClockBlink()
            if let cover { transitions.endBarCover(cover) }
        }
    }

    // MARK: - Section helper events (HelperHosts)

    /// A helper registered an item. Mid-session that registration sits
    /// under an active assertion, which defers its adoption — open the
    /// window the way a relaunched app gets one, and queue its placement.
    func helperHosted(title: String, bundle: String) {
        let id = ItemID.status(bundle: PelmetBundle.mainID, title: title)
        guard engineStarted else { return }
        placement.queuePlacement(id)
        Task {
            // Wait for THIS registration: the helper's other items were
            // adopted long ago and would satisfy a bundle-level check at
            // the first walk, closing the window before the new one lands.
            let live = ItemID.status(bundle: bundle, title: title)
            if await engine.openAdoptionWindow(for: bundle, expecting: live) {
                updateSnapshot(await engine.snapshot())
            }
            placement.flushPendingPlacements()
        }
    }

    func helperItemClicked(title: String, rightButton: Bool, at point: NSPoint) {
        guard rightButton || separators?.spec(titled: title) != nil else { return }
        // Separators: either button opens Pelmet's menu (an always-available
        // settings entry point in iconless mode).
        let menu = PelmetStatusItem.contextMenu(appState: self)
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    func helperItemDraggedOff(title: String) {
        if let spec = separators?.spec(titled: title) {
            PelmetLog.log("separator: \(spec.style.displayName) dragged off the bar → remove")
            settings.separators.removeAll { $0.id == spec.id }
            settingsChanged()
        }
    }

    /// Pelmet's own chevron in the engine's id grammar.
    static let chevronItemID = ItemID(rawValue: "status:\(PelmetBundle.mainID)::Pelmet.StatusItem")

    /// A new separator lands where new icons land — the section the "New"
    /// chip sits in, at its front — instead of falling into Visible as an
    /// unassigned item (it showed up at the end of Visible, 2026-09-20).
    func addSeparator() {
        let spec = SeparatorSpec(style: .dot)
        settings.separators.append(spec)
        var model = settings.sectionModel
        let home = model.newItemsDestination
        if home != .visible {
            let id = SeparatorManager.itemID(for: spec).sectionKey
            model.assignments[id] = home
            model.order[home, default: []].insert(id, at: 0)
            settings.sectionModel = model
        }
        settingsChanged()
    }

    func settingsChanged() {
        rehide.policy = settings.rehidePolicy
        var newOwnIDs: Set<ItemID> = []
        if settings.showStatusItem, statusItem == nil {
            statusItem = PelmetStatusItem(appState: self)
            // A chevron switched on mid-session is a fresh registration the
            // agent hosts wherever it likes — it landed INSIDE the hidden
            // cluster (Snib and the pipe right of it, 2026-09-06), then
            // drifted with every reveal reflow. Walk it to the boundary NOW,
            // under a deliberate reveal (its slot needs the hidden cluster
            // live), while the user is looking at the toggle they just
            // flipped — never at a later hover.
            Task {
                try? await Task.sleep(for: AppTiming.newExtraPlacementDelay)
                reveal([.hidden], reason: .settingsPreview)
                try? await Task.sleep(for: AppTiming.tidyRevealWait)
                if await placement.physicallyPlace(Self.chevronItemID, in: .visible) {
                    // Seed the next fresh registration's slot.
                    await engine.writeOrderHint()
                }
                if !settingsWindowVisible {
                    applyPointerDisplayPolicyAfterDismissal()
                }
            }
        } else if !settings.showStatusItem {
            statusItem?.remove()
            statusItem = nil
        } else {
            statusItem?.updateSymbol(revealed: isRevealedOrRevealing)
        }
        // Re-registering unregisters first — a per-tick re-register left the
        // shortcut momentarily dead. Only touch it when it actually changed.
        if settings.hotkey != registeredHotkey {
            hotkeyConflict = !(hotkey?.register(settings.hotkey, slot: .toggle) ?? true)
            registeredHotkey = settings.hotkey
        }
        if settings.settingsHotkey != registeredSettingsHotkey {
            settingsHotkeyConflict = !(hotkey?.register(settings.settingsHotkey, slot: .settings) ?? true)
            registeredSettingsHotkey = settings.settingsHotkey
        }
        // Newly created separators and toggled-on extras get hosted wherever
        // macOS pleases (left end of the trailing area — or straight into the
        // overflow notch on a crowded bar) — physically place them into their
        // section like any editor move would. A trapped newcomer queues for
        // the conceal-settle overflow rescue instead.
        let previousSeparatorIDs = Set(separators?.managedItemIDs ?? [])
        separators?.sync(with: settings.separators)
        let newSeparatorIDs = Set(separators?.managedItemIDs ?? []).subtracting(previousSeparatorIDs)
        let previousExtraIDs = Set(extras?.managedItemIDs ?? [])
        extras?.sync(with: settings.extraItems)
        let newExtraIDs = Set(extras?.managedItemIDs ?? []).subtracting(previousExtraIDs)
        newOwnIDs.formUnion(newSeparatorIDs.union(newExtraIDs))
        pruneOrderEditsForRemovedOwnItems()
        if !newOwnIDs.isEmpty {
            Task {
                try? await Task.sleep(for: AppTiming.newExtraPlacementDelay)
                for id in newOwnIDs {
                    await placement.physicallyPlace(id, in: settings.sectionModel.section(of: id))
                }
            }
        }
        clockRelay?.setEnabled(settings.clockClickOpensNotificationCenter)
        settingsApplyWork?.cancel()
        settingsApplyWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.settings.save()
            await self.engine.setSteadyExtras(self.settings.effectiveHideSystemExtras)
            await self.engine.setModel(self.settings.sectionModel)
        }
    }

    /// Settings-window close, tidy end, editor-tab close: the pointer
    /// display's policy decides between conceal and reveal — an unconditional
    /// conceal here collapsed the bar even on "always show everything"
    /// displays.
    func applyPointerDisplayPolicyAfterDismissal() {
        if pointerDisplayBehavior == .alwaysShowAll {
            reveal([.hidden], reason: .displayPolicy)
        } else {
            concealNow()
        }
    }

    /// A Displays-tab picker changed: apply the pointer display's new policy
    /// live. Only the reveal side acts here — while the settings window is
    /// open nothing collapses under the user (existing rule); the collapse
    /// side lands on window close or the next display crossing.
    func displayBehaviorEdited() {
        PelmetLog.log("displays: behavior edited, pointer display=\(pointerDisplayBehavior)")
        if pointerDisplayBehavior == .alwaysShowAll {
            reveal([.hidden], reason: .displayPolicy)
        }
    }

    // MARK: - Layout editor intents

    /// Move an item to `section`, inserted before `beforeID` (nil = append).
    /// Updates assignment + explicit order, then physically places the icon
    /// via a synthetic ⌘-drag (no agent restart).
    /// Bundles with an icon on the editor board (live or concealed) that
    /// Pelmet can actually manage — a launcher would be a duplicate. Icons
    /// marked incompatible are NOT here: those are exactly what launchers
    /// are for, and the user picks them before turning the original off.
    var manageableBarBundles: Set<String> {
        guard let snapshot else { return [] }
        let ids = snapshot.items.map(\.id) + Array(snapshot.concealed)
        return Set(
            ids.compactMap { id -> String? in
                guard let bundle = id.bundleID,
                      !PelmetBundle.ownIDs.contains(bundle),
                      !MenuBarPolicy.isUnmanagedAppleBundle(bundle),
                      // Apple's own hosts never get a launcher offer either.
                      !MenuBarPolicy.isBundleHideableAppleHost(bundle),
                      !unhideableKeys.contains(id.sectionKey),
                      !bundlelessHosts.contains(bundle)
                else { return nil }
                return bundle
            }
        )
    }

    /// A third-party item whose app the user gave a launcher.
    func hasAppLauncher(for id: ItemID) -> Bool {
        guard let bundle = id.bundleID, !PelmetBundle.ownIDs.contains(bundle) else { return false }
        return settings.extraItems.contains { $0.kind == .appLauncher && $0.bundleID == bundle }
    }

    /// Adds a Pelmet launcher for an app, one per bundle. `section` pre-assigns
    /// it (the editor's "Add a launcher" puts it where the user put the icon it
    /// replaces); nil routes it like any new menu bar icon — it is one.
    @discardableResult
    func addAppLauncher(bundleID: String, name: String, in section: PelmetCore.Section? = nil) -> Bool {
        guard !settings.extraItems.contains(where: { $0.kind == .appLauncher && $0.bundleID == bundleID })
        else { return false }
        let spec = ExtraItemSpec(kind: .appLauncher, bundleID: bundleID, appName: name)
        addExtra(spec, in: section ?? settings.sectionModel.newItemsDestination)
        settingsChanged()
        return true
    }

    /// The one way to add a Pelmet item: the spec AND its model slot
    /// together (`SectionModel.enroll`). `section` nil keeps the model's
    /// word for the key — visible by default. Callers still call
    /// `settingsChanged()`; the boot migration runs before it exists.
    func addExtra(_ spec: ExtraItemSpec, in section: PelmetCore.Section? = nil) {
        settings.extraItems.append(spec)
        let key = ExtrasManager.itemID(for: spec).sectionKey
        settings.sectionModel.enroll(key, in: section)
        PelmetLog.log("extras: add \(spec.itemTitle) → \(settings.sectionModel.section(of: key))")
        settings.save()
        retireAppleTwin(of: spec.kind)
    }

    /// The singleton kinds' toggle going off. Siri and Time Machine also
    /// hand Apple's icon back.
    func removeExtras(of kind: ExtraKind) {
        settings.extraItems.removeAll { $0.kind == kind }
        restoreAppleTwin(of: kind)
    }

    /// The pinned SystemUIServer tile's one action: turn on whichever of
    /// Pelmet's Siri and Time Machine is still off. Each `addExtra` retires
    /// Apple's twin, so once both are on SystemUIServer has no extras left
    /// and the tile that offered this goes away on its own.
    func useAppleExtraReplacements() {
        let missing = missingAppleReplacements
        guard !missing.isEmpty else { return }
        for kind in missing { addExtra(ExtraItemSpec(kind: kind)) }
        settingsChanged()
    }

    /// Which of Apple's pinned pair Pelmet has not replaced yet — what the
    /// pinned card offers, and what its copy names.
    var missingAppleReplacements: [ExtraKind] {
        let kinds = Set(settings.extraItems.map(\.kind))
        return [ExtraKind.siri, .timeMachine].filter { !kinds.contains($0) }
    }

    /// Siri and Time Machine: Apple's own icon switches off in System
    /// Settings the moment Pelmet's switches on (otherwise the bar shows
    /// two), and comes back when Pelmet's goes off — only if Pelmet was the
    /// one that switched it off. Nothing runs at launch: once off, the
    /// System Settings switch stays off on its own, and a user who ticks it
    /// back by hand is not fought.
    private func retireAppleTwin(of kind: ExtraKind) {
        guard let twin = AppleMenuExtra(kind), twin.isShown else { return }
        guard twin.setShown(false) else { return }
        UserDefaults.standard.set(true, forKey: twin.restoreKey)
        // SystemUIServer tears the icon down over a few hundred ms, so the
        // walk its own settings change triggers still sees it and the editor
        // kept showing a tile for an icon already gone. Re-read until it is,
        // rather than once on a fixed delay — a single late look made the
        // tile linger for the whole delay even though the icon went in ~300ms.
        Task {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(250))
                let snap = await engine.snapshot()
                updateSnapshot(snap)
                let stillThere = snap.items.contains {
                    $0.id.bundleID == PelmetBundle.systemUIServerID && $0.frame != nil
                }
                if !stillThere { return }
            }
        }
    }

    /// SystemUIServer's slot once BOTH its icons are Pelmet's. Nothing else
    /// prunes it: the editor draws a tile for any stored key whose process
    /// runs, the order-slot repair only touches Pelmet's own extras, and
    /// SystemUIServer never quits — so the pinned tile outlived the icons it
    /// stood for (2026-09-16). Guarded on both replacements being on, so a
    /// half-replaced pair keeps the tile the remaining icon still needs.
    /// Cheap no-op once the slot is gone, which is the steady state.
    private func pruneRetiredAppleHostSlot(_ snap: EngineSnapshot) {
        let key = ItemID(rawValue: "bundle:\(PelmetBundle.systemUIServerID)")
        guard settings.sectionModel.assignments[key] != nil
                || settings.sectionModel.order.values.contains(where: { $0.contains(key) })
        else { return }
        let kinds = Set(settings.extraItems.map(\.kind))
        guard kinds.contains(.siri), kinds.contains(.timeMachine) else { return }
        guard !snap.items.contains(where: { $0.id.bundleID == PelmetBundle.systemUIServerID })
        else { return }
        forgetRetiredHost(PelmetBundle.systemUIServerID)
    }

    /// Where the host sat before Pelmet retired it, so turning the Pelmet
    /// items back off puts the returning icons where the user had them
    /// rather than treating them as newcomers.
    private static let retiredSlotKey = "pelmet.appleExtra.systemuiserver.slot"

    private func forgetRetiredHost(_ bundle: String) {
        let key = ItemID(rawValue: "bundle:\(bundle)")
        var slot: [String: Any] = [:]
        // `.visible` is the absence of an assignment, so record the section
        // that way round too — an empty section means visible.
        if let section = settings.sectionModel.assignments[key] {
            slot["section"] = section.rawValue
        }
        for (section, order) in settings.sectionModel.order {
            if let index = order.firstIndex(of: key) {
                slot["orderSection"] = section.rawValue
                slot["index"] = index
                break
            }
        }
        var changed = settings.sectionModel.assignments.removeValue(forKey: key) != nil
        for section in settings.sectionModel.order.keys {
            let before = settings.sectionModel.order[section]?.count
            settings.sectionModel.order[section]?.removeAll { $0 == key }
            if settings.sectionModel.order[section]?.count != before { changed = true }
        }
        lastSeenAt.removeValue(forKey: key)
        guard changed else { return }
        UserDefaults.standard.set(slot, forKey: Self.retiredSlotKey)
        PelmetLog.log("apple extras: dropped dead slot \(key.rawValue) (remembered \(slot))")
        settings.save()
    }

    /// Puts the host back where it was before Pelmet retired it. Runs the
    /// moment a Pelmet replacement is switched off, before the returning
    /// icon re-registers, so `registerNewItems` finds it already placed and
    /// routes nothing.
    private func restoreRetiredHostSlot() {
        guard let slot = UserDefaults.standard.dictionary(forKey: Self.retiredSlotKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.retiredSlotKey)
        let key = ItemID(rawValue: "bundle:\(PelmetBundle.systemUIServerID)")
        if let raw = slot["section"] as? String, let section = PelmetCore.Section(rawValue: raw) {
            settings.sectionModel.assignments[key] = section
        }
        if let raw = slot["orderSection"] as? String,
           let section = PelmetCore.Section(rawValue: raw) {
            var order = settings.sectionModel.order[section] ?? []
            order.removeAll { $0 == key }
            let index = min(max(slot["index"] as? Int ?? order.count, 0), order.count)
            order.insert(key, at: index)
            settings.sectionModel.order[section] = order
        }
        PelmetLog.log("apple extras: restored slot \(key.rawValue) → \(settings.sectionModel.section(of: key))")
        settings.save()
    }

    private func restoreAppleTwin(of kind: ExtraKind) {
        guard let twin = AppleMenuExtra(kind), UserDefaults.standard.bool(forKey: twin.restoreKey) else { return }
        UserDefaults.standard.removeObject(forKey: twin.restoreKey)
        restoreRetiredHostSlot()
        twin.setShown(true)
    }

    func moveItem(_ id: ItemID, to section: PelmetCore.Section, before beforeID: ItemID?) {
        // The model keys on canonical IDs; `id` arrives as a real bar item
        // (drag payload) and may be any title-variant of its bundle.
        let key = id.sectionKey
        var model = settings.sectionModel
        if section == .visible {
            model.assignments.removeValue(forKey: key)
        } else {
            model.assignments[key] = section
        }
        for sectionKey in model.order.keys {
            model.order[sectionKey]?.removeAll { $0 == key }
        }
        var order = model.order[section] ?? currentOrder(in: section)
        order.removeAll { $0 == key }
        if let beforeKey = beforeID?.sectionKey, let index = order.firstIndex(of: beforeKey) {
            order.insert(key, at: index)
        } else {
            order.append(key)
        }
        model.order[section] = order
        settings.sectionModel = model
        // Sets core: the drop is a drawing, the bar moves at Apply. A
        // between-section drop changes membership now and the destination's
        // drawn order is what Apply will lay down, across the chevron too.
        if CoreMode.setsOnly {
            // The key leaves every other section's edit too: a stale entry
            // put Siri in two tidy runs at once and MovePlan trapped on the
            // duplicate key (crash 2026-09-20 17:29).
            for edited in settings.orderEdits.order.keys where edited != section {
                settings.orderEdits.order[edited]?.removeAll { $0 == key }
            }
            settings.orderEdits.order[section] = order
            applyReport = nil
        }
        settings.save()
        // A section move is a re-host for a separator (main ↔ helper bundle);
        // `sync` is idempotent and a no-op for every other item. Without it
        // the separator kept its old host until the next settings change and
        // the placement below read it under the helper's bundle (log,
        // 2026-09-14 23:52).
        separators?.sync(with: settings.separators)
        // A deliberate editor drop supersedes any queued newcomer placement.
        placement.dropPlacement(id)
        PelmetLog.log("editor: move \(id.rawValue) → \(section) before=\(beforeID?.rawValue ?? "end")")
        // Extras visibility applies via the engine's reflow companion during
        // the converge below — same reflow, same motion as everything else.
        Task {
            await engine.setModel(model)
            // EVERY item moves via the synthetic ⌘-drag — the only mover the
            // agent honors. Live third-party order lives in the client
            // processes' own registrations (proven 2026-08-21: plist rebuilds
            // + agent restarts + conceal/reveal cycles never re-slot a live
            // item; a real ⌘-drag survives restarts with no disk record).
            // The plist hint still seeds slots for FUTURE fresh
            // registrations (app relaunches, brand-new items).
            await engine.writeOrderHint()
            await placement.physicallyPlace(id, in: section)
        }
    }

    /// Dynamic extras (camera/mic indicator) re-enter layout when their
    /// hardware activates, parked wherever the agent decides. QUEUE the walk
    /// back to the model slot instead of dragging right away: the activation
    /// is app-driven (another app opened the camera), and an uninitiated
    /// synthetic ⌘-drag warps the pointer mid-task — same rule as the «
    /// expansion. The next reveal settle places it, riding motion the user
    /// started. Editor drops still place immediately via moveItem.
    func queueDynamicExtraPlacement(_ id: ItemID, zoneOnly: Bool = false) {
        placement.queuePlacement(id, zoneOnly: zoneOnly)
    }

    /// An own item that just (re-)entered a REVEALED bar sits at the agent's
    /// slot, not the model's — a launcher whose app launched mid-reveal
    /// surfaced at the end of Always Hidden (ChatGPT Classic, 2026-09-09).
    /// Place it now, same beat as a freshly added extra; the reveal-settle
    /// queue would only catch the next reveal.
    /// Own extras that entered the bar while their section was concealed:
    /// no neighbour to measure, so they wait for the next reveal that shows
    /// their section (`onRevealSettled`) and go through the door then.
    private var ownItemsAwaitingReveal: Set<ItemID> = []

    /// Sets core: an own extra entering a concealed section.
    func placeOwnItemAtNextReveal(_ id: ItemID) {
        guard CoreMode.setsOnly else { queueDynamicExtraPlacement(id); return }
        ownItemsAwaitingReveal.insert(id)
    }

    func cancelOwnItemPlacement(_ id: ItemID) {
        ownItemsAwaitingReveal.remove(id)
        cancelDynamicExtraPlacement(id)
    }

    private func placeOwnItemsAwaitingReveal() {
        // A pass reveals too; leave the queue for a user reveal then.
        guard CoreMode.setsOnly, !applying, !ownItemsAwaitingReveal.isEmpty else { return }
        let revealed = currentRevealedSections
        let due = ownItemsAwaitingReveal.filter { revealed.contains(settings.sectionModel.section(of: $0)) }
        guard !due.isEmpty else { return }
        ownItemsAwaitingReveal.subtract(due)
        Task {
            for id in due { await placeOwnItemNow(id) }
        }
    }

    func placeOwnItemSoon(_ id: ItemID) {
        placement.dropPlacement(id)
        Task {
            try? await Task.sleep(for: AppTiming.newExtraPlacementDelay)
            if CoreMode.setsOnly {
                await placeOwnItemNow(id)
            } else {
                await placement.physicallyPlace(id, in: settings.sectionModel.section(of: id))
            }
        }
    }

    /// Sets core: one own item through the Apply door (`ApplyPass.Scope.
    /// ownItem`). Never overlaps a running pass; a whole-bar pass covers it.
    private func placeOwnItemNow(_ id: ItemID) async {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        let report = await ApplyPass.run(appState: self, scope: .ownItem(id))
        PelmetLog.log("apply: own \(id.rawValue) applied=\(report.applied.count) failed=\(report.failed.count) skipped=\(report.skipped.count)")
        if !report.applied.isEmpty { await engine.writeOrderHint() }
    }

    /// Deactivation edge: a queued-but-never-placed indicator left in the
    /// queue would retry (and log) a frameless placement on every reveal
    /// settle after it left layout.
    func cancelDynamicExtraPlacement(_ id: ItemID) {
        placement.dropPlacement(id)
    }

    /// Overflow rescue shims (PlacementController → SeparatorManager): expand
    /// one hidden separator so its trapped registration becomes draggable,
    /// then restore model-derived visibility.
    func forceShowSeparator(_ id: ItemID) -> Bool {
        separators?.forceShow(id) ?? false
    }

    func restoreSeparatorVisibility() {
        separators?.restoreVisibility()
    }

    /// Pelmet's chevron item in a snapshot — the visible/hidden boundary marker
    /// (never an extra or separator).
    func pelmetChevronItem(in snap: EngineSnapshot) -> ObservedItem? {
        let pelmetBundle = PelmetBundle.mainID
        let copies = snap.items.filter {
            MenuBarPolicy.isChevronID($0.id, pelmetBundleID: pelmetBundle)
        }
        // The chevron registers once per display; only the main-band copy
        // is a boundary anything can be measured against.
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        return copies.first(where: {
            $0.frame.map { MenuBarGeometry.isInBand($0) && $0.midX > 0 && $0.midX < primaryMaxX } == true
        }) ?? copies.first
    }

    /// The on-screen left-to-right order of a section right now (fallback when
    /// no explicit order exists yet).
    func currentOrder(in section: PelmetCore.Section) -> [ItemID] {
        // Order arrays hold canonical keys; tiles carry real item IDs.
        editorItems(in: section).map(\.id.sectionKey)
    }

    /// One-shot physical tidy: reveal everything, then walk the sections
    /// left→right and drag every out-of-place icon into its slot so the bar's
    /// physical order matches the sections ([always-hidden][hidden][visible]).
    /// Contiguity is what makes hide/reveal animations uniform — an icon that
    /// toggles mid-bar displaces its neighbors and reads as sliding.
    private(set) var tidying = false

    // MARK: - Apply (sets core, docs/CORE-SETS.md M1)

    /// One pass at a time; the button reads these.
    private(set) var applying = false
    private(set) var applyReport: ApplyReport?

    /// Moves the bar needs to match the editor as it stands: drawn edits
    /// plus any icon on the wrong side of the chevron (0 with nothing on
    /// screen to move).
    var pendingMoveCount: Int {
        guard let snapshot else { return 0 }
        return ApplyPass.plan(for: self, snapshot: snapshot, remembered: true).moves.count
    }

    /// Last primary-band frame per item, kept across conceals so the Apply
    /// count can judge a concealed icon's side without a reveal
    /// (ApplyPass.rememberedFrames). Refreshed from every snapshot.
    private(set) var rememberedFrames: [ItemID: CGRect] = [:]

    /// Apply has something to do: a drawing not yet applied, or the bar
    /// disagreeing with the sections.
    var applyPending: Bool {
        !settings.orderEdits.isEmpty || pendingMoveCount > 0 || (separators?.needsRehost ?? false)
    }

    /// Apply pass: separators drawn in another section move host now.
    func rehostSeparatorsForApply() -> Bool { separators?.rehostToModel() ?? false }

    /// The Apply button: reveal what needs measuring, plan, drag each move
    /// through the one shielded door, verify, report. Failed moves keep the
    /// edits pending so the button offers Retry.
    func applyOrderEdits() {
        guard !applying, applyPending else { return }
        applying = true
        applyReport = nil
        PelmetLog.log("apply: starting")
        Task {
            let report = await ApplyPass.run(appState: self)
            PelmetLog.log("apply: done applied=\(report.applied.count) failed=\(report.failed.count) skipped=\(report.skipped.count)")
            if report.failed.isEmpty {
                settings.orderEdits = OrderEdits()
                settings.save()
            }
            // Seed future fresh registrations with the order just laid down —
            // after ANY move, not only a clean pass: a Camera moved at 18:35
            // went back to its old slot on relaunch because every later pass
            // failed on another item and never reseeded (2026-09-20).
            if !report.applied.isEmpty {
                await engine.writeOrderHint()
            }
            applyReport = report
            applying = false
            if !settingsWindowVisible {
                applyPointerDisplayPolicyAfterDismissal()
            }
        }
    }

    /// A removed separator or extra leaves its drawn slot behind in the
    /// pending edits, and every pass then skips it as not on screen (the Dot
    /// removed at 20:43, 2026-09-20). Own items only: a third-party icon that
    /// quit is still a member and comes back.
    private func pruneOrderEditsForRemovedOwnItems() {
        guard !settings.orderEdits.isEmpty else { return }
        let managed = Set(((extras?.managedItemIDs ?? []) + (separators?.managedItemIDs ?? [])).map(\.sectionKey))
        var edits = settings.orderEdits
        var dropped = 0
        for (section, order) in edits.order {
            let kept = order.filter { id in
                guard let bundle = id.bundleID, PelmetBundle.ownIDs.contains(bundle),
                      !id.isPelmetChevron else { return true }
                return managed.contains(id.sectionKey)
            }
            dropped += order.count - kept.count
            edits.order[section] = kept
        }
        guard dropped > 0 else { return }
        settings.orderEdits = edits
        settings.save()
        PelmetLog.log("apply: \(dropped) pending edit(s) for removed own item(s) dropped")
    }

    /// Drops the pending edits; the editor goes back to drawing the bar's
    /// real order for those sections.
    func discardOrderEdits() {
        guard !applying else { return }
        var model = settings.sectionModel
        // Back to the bar's order where the bar can be read; a concealed
        // section keeps its drawing until the next reveal reconciles it.
        // Clearing the order outright left the board reshuffling (2026-09-20).
        if let snapshot {
            let frames = ApplyPass.primaryFrames(snapshot)
            for section in settings.orderEdits.order.keys {
                let members = editorItems(in: section).map(\.id.sectionKey)
                guard members.allSatisfy({ frames[$0] != nil }) else { continue }
                model.order[section] = members.sorted { frames[$0]!.minX < frames[$1]!.minX }
            }
        }
        settings.sectionModel = model
        settings.orderEdits = OrderEdits()
        applyReport = nil
        settings.save()
        PelmetLog.log("apply: edits discarded")
        Task { await engine.setModel(model) }
    }

    /// The icon's physical side disagrees with its section (an editor drop
    /// between sections hides it at once but leaves it where it was): the
    /// tile says so until Apply relocates it. Needs the chevron
    /// and the item both on screen to tell.
    func isOutOfPlace(_ id: ItemID) -> Bool {
        guard CoreMode.setsOnly, let snapshot,
              let chevron = pelmetChevronItem(in: snapshot)?.frame else { return false }
        let frames = ApplyPass.primaryFrames(snapshot)
        guard let frame = frames[id.sectionKey] else { return false }
        let wantsLeft = settings.sectionModel.section(of: id) != .visible
        return wantsLeft ? frame.midX > chevron.midX : frame.midX < chevron.midX
    }

    func tidyBar() {
        guard !tidying else { return }
        tidying = true
        PelmetLog.log("tidy: starting")
        reveal([.hidden, .alwaysHidden], reason: .settingsPreview)
        Task {
            try? await Task.sleep(for: AppTiming.tidyRevealWait)
            // Drag walk, left→right through the desired global order — the
            // synthetic ⌘-drag is the only mover the agent honors for live
            // items (see moveItem). Already-placed items skip cheaply; each
            // drag measures against the items the walk just settled.
            await engine.writeOrderHint()
            for section in [PelmetCore.Section.alwaysHidden, .hidden, .visible] {
                for item in editorItems(in: section) {
                    await placement.physicallyPlace(item.id, in: section)
                }
            }
            PelmetLog.log("tidy: done")
            tidying = false
            if !settingsWindowVisible {
                applyPointerDisplayPolicyAfterDismissal()
            }
        }
    }

    // (Alias healing removed: the model keys on ItemID.sectionKey — bundle-
    // level for third parties — so AX title drift can no longer strand
    // assignments or order entries under stale tags.)

    /// The layout editor's board for a section — see EditorItemsBuilder.
    /// Running-app lookups are memoized per call: the builder consults them
    /// per concealed/stored item, and each LaunchServices query is expensive.
    func editorItems(in section: PelmetCore.Section) -> [ObservedItem] {
        var memo: [String: NSRunningApplication?] = [:]
        func app(_ bundle: String) -> NSRunningApplication? {
            if let cached = memo[bundle] { return cached }
            let found = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            memo[bundle] = found
            return found
        }
        return EditorItemsBuilder.build(
            section: section,
            snapshotItems: snapshot?.items ?? [],
            concealed: snapshot?.concealed ?? [],
            extraItems: settings.extraItems,
            separators: settings.separators,
            model: settings.sectionModel,
            pelmetBundleID: PelmetBundle.mainID,
            isRunning: { app($0) != nil && !absentBundles.contains($0) },
            appName: { app($0)?.localizedName },
            recentlySeen: { Date.now.timeIntervalSince(lastSeenAt[$0.sectionKey] ?? .distantPast) < Self.storedTileGrace },
            destroyed: destroyedKeys
        )
    }

    /// An icon the bar took down although Pelmet allowed it — the editor
    /// badges it exactly like one that refused to hide: either way Pelmet
    /// can't manage it, and a launcher is the way out. See CollateralTracker.
    func isDestroyedHost(_ id: ItemID) -> Bool {
        destroyedKeys.contains(id.sectionKey)
    }

    // MARK: - Effects

    /// Pelmet-owned items hide by their OWN visibility, not the assertion —
    /// asserting away Pelmet's bundle would take the chevron too.
    var revealedSectionsForExtras: Set<PelmetCore.Section> { currentRevealedSections }

    /// macOS force-shows its camera pill through the assertion while the
    /// camera is live; Pelmet's indicator defers to it to avoid duplication.
    var systemCameraPillVisible: Bool {
        (snapshot?.items ?? []).contains {
            $0.id.rawValue.contains("menuextra.audiovideo") && $0.frame != nil
        }
    }

    var currentRevealedSections: Set<PelmetCore.Section> {
        switch rehide.state {
        case .revealed(let sections, _):
            return sections
        case .transitioning(target: .reveal(let sections, _), _):
            // Track the transition's destination so Pelmet-owned items appear
            // in the same swap as the assertion-managed ones.
            return sections
        default:
            return []
        }
    }

    private func dispatch(_ effects: [RehideEffect]) {
        // Extras are NOT applied here: the engine's reflow companion applies
        // them inside the converge so their size change shares the assertion
        // swap's reflow. Applying pre-reflow here put them on a second clock.
        // The chevron flips at transition START — settle-time flips read as an
        // unacknowledged click.
        defer { statusItem?.updateSymbol(revealed: isRevealedOrRevealing) }
        for effect in effects {
            switch effect {
            case .none:
                break
            case .reveal(let sections):
                if case .transitioning(target: .reveal(_, .hover), _) = rehide.state { hoverRevealStartedAt = .now }
                transitions.performReveal(sections)
            case .conceal:
                transitions.performConceal()
            case .armTimer(let deadline):
                rehideDeferLogged = false
                scheduleRehideTimer(at: deadline)
            case .cancelTimer:
                rehideTimer?.invalidate()
                rehideTimer = nil
            }
        }
    }

    /// Rehide fires only when the user has actually moved on: while the
    /// pointer is in the menubar band or over an elevated window (an open
    /// status-item menu or popover), the countdown quietly re-arms.
    private func scheduleRehideTimer(at deadline: Date) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(
            withTimeInterval: max(0, deadline.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A synthetic placement drag needs the frames it measured
                // to stay put: a rehide mid-drag collapsed the hidden
                // cluster under the chevron's walk, and it landed in the
                // concealed gap again (2026-09-06 01:17).
                if self.editorHoldsBar
                    || self.pointerDisplayBehavior == .alwaysShowAll
                    || self.syntheticDragInFlight
                    || self.bandMonitor?.shouldDeferRehide() == true {
                    if !self.rehideDeferLogged {
                        self.rehideDeferLogged = true
                        PelmetLog.log("rehide: deferred — editor=\(self.editorHoldsBar) policy=\(self.pointerDisplayBehavior) drag=\(self.syntheticDragInFlight) \(self.bandMonitor?.deferReason() ?? "band=?")")
                    }
                    self.scheduleRehideTimer(at: Date().addingTimeInterval(AppTiming.rehideDeferRearm))
                } else {
                    self.rehideTriggered(.delayExpired)
                }
            }
        }
    }

    /// Menubar-positional sections: Pelmet's own chevron is the visible/hidden
    /// boundary. Anything sitting LEFT of it (smaller AX x) is adopted into
    /// Hidden; right of it back to Visible. Uses live AX frames — NOT the
    /// agent's positions plist, which lists new items only lazily (M1 finding).
    /// Always-Hidden has no physical marker of its own; its live cluster IS
    /// the boundary — an item dropped among/left of always-hidden members
    /// (only visible during a full reveal) adopts in, one dropped among the
    /// hidden cluster adopts out.
    /// One adoption chain at a time — an externalOrderChange burst otherwise
    /// spawns N concurrent retry chains, each pulling its own snapshot.
    private var adoptionInFlight = false
    /// A drag-end request that arrived while a chain was running: the
    /// user's drop x is evidence that must not be dropped with it (ChatGPT
    /// ⌘-dragged into Hidden while the 10s pass ran — the drop was lost and
    /// the item never adopted, 2026-09-08). Replayed when the chain ends.
    private var queuedDragEndX: CGFloat?

    /// When the band monitor last saw a user ⌘-drag end. The order
    /// supervisor stays out of the way while that adoption lands.
    private(set) var lastUserDragEndedAt: Date?

    func adoptSectionsFromBar(retry: Int = 0, dragEndX: CGFloat? = nil) {
        if retry == 0, dragEndX != nil { lastUserDragEndedAt = .now }
        if retry == 0 {
            guard !adoptionInFlight else {
                if let dragEndX { queuedDragEndX = dragEndX }
                return
            }
            adoptionInFlight = true
        }
        Task {
            // Mid-transition bars give false frames — defer briefly. (Only
            // in-flight transitions block; a settled bar has stable frames.
            // The old post-settle quiet window starved adoption entirely.)
            // Synthetic placements/rescues also block: a rescue force-shows
            // a hidden separator mid-conceal — separators pass isPelmetExtraID,
            // so the pass would read that as a zone change, and the order
            // fold-in would re-sort toward the position being corrected.
            if isTransitioning || syntheticDragInFlight {
                guard retry < AppTiming.adoptMaxDeferrals else {
                    PelmetLog.log("adopt: gave up after \(retry) deferrals")
                    adoptionInFlight = false
                    if let queued = queuedDragEndX {
                        queuedDragEndX = nil
                        adoptSectionsFromBar(dragEndX: queued)
                    }
                    return
                }
                try? await Task.sleep(for: AppTiming.adoptDeferralDelay)
                adoptSectionsFromBar(retry: retry + 1, dragEndX: dragEndX)
                return
            }
            let snap = await engine.snapshot()
            // A transiently empty AX walk (the agent rebuilding mid-reflow —
            // 22 empty passes in one afternoon's log) is not a bar to
            // reconcile against: the drag-end pass read 0 items and the
            // user's ⌘-drag evidence (dragEndX) was lost for good
            // (2026-09-02, Sconce right of media never folded in). Defer
            // like a transition instead of consuming the pass.
            if snap.items.isEmpty, retry < AppTiming.adoptMaxDeferrals {
                PelmetLog.log("adopt: empty snapshot — deferring (retry=\(retry))")
                try? await Task.sleep(for: AppTiming.adoptDeferralDelay)
                adoptSectionsFromBar(retry: retry + 1, dragEndX: dragEndX)
                return
            }
            defer {
                adoptionInFlight = false
                if let queued = queuedDragEndX {
                    queuedDragEndX = nil
                    PelmetLog.log("adopt: replaying queued drop x=\(Int(queued))")
                    adoptSectionsFromBar(dragEndX: queued)
                }
            }
            updateSnapshot(snap)
            PelmetLog.log("adopt: pass (retry=\(retry), items=\(snap.items.count))")
            adopt(from: snap, dragEndX: dragEndX)
        }
    }

    /// Which zone each item sat in at the last pass. Reflows shift every
    /// frame but never an item's relative position — only a real user drag
    /// does. That makes zone-CHANGE the safe adoption trigger: a
    /// settings-assigned item still sitting in its old zone is never
    /// "corrected" back.
    private var lastAdoptionZones: [String: PelmetCore.Section] = [:]
    /// The chevron's x at the last pass — a moved boundary re-baselines
    /// instead of adopting (see BarAdoption.reconcile).
    private var lastAdoptionChevronX: CGFloat?
    private var lastAdoptionPositions: [String: CGFloat] = [:]
    private var lastAdoptionPending: [String: PelmetCore.Section] = [:]

    var isTransitioning: Bool {
        if case .transitioning = rehide.state { return true }
        return false
    }

    /// The band monitor skips drag-end adoption for Pelmet's own synthetic
    /// drags — see PlacementController.syntheticDragInFlight.
    /// Apply's drags count too: the band monitor adopted one as a user
    /// ⌘-drag and reconciled the hidden order from the bar mid-pass, which
    /// snapped the editor's drawing back (Sound, 2026-09-20 16:56).
    var syntheticDragInFlight: Bool { placement.syntheticDragInFlight || applying }

    /// The one write path for the engine snapshot mirror (PlacementController
    /// and engine-event handling route through here). Content-gated: every
    /// assignment fires @Observable invalidation (re-running the editor
    /// pipeline while settings is open), and most snapshots differ only by
    /// `takenAt`.
    private var lastBundlelessIDs: [String] = []
    private var unhideableTracker = UnhideableTracker()
    /// Canonical keys of icons the bar kept showing after Pelmet concealed
    /// them — the editor's "can't hide" badge. See UnhideableTracker.
    private(set) var unhideableKeys: Set<ItemID> = []
    private var collateralTracker = CollateralTracker()
    /// Canonical keys of icons the bar destroyed although the allowlist
    /// protects them (#30) — same badge, and the editor keeps their tile
    /// instead of losing them to every section at once. See CollateralTracker.
    private(set) var destroyedKeys: Set<ItemID> = []
    /// Bundles whose bar item is hosted by a bundle-less process (ChatGPT
    /// Classic's helper): the assertion allowlist can't key on such a
    /// process, so Pelmet can't hide the icon reliably — the editor shows it
    /// inactive and offers a launcher without waiting for a failed conceal.
    private(set) var bundlelessHosts: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: AppState.bundlelessKey) ?? []
    ).subtracting(PelmetBundle.ownIDs)
    private static let bundlelessKey = "pelmet.bundlelessHosts"
    /// Bundles whose bar item swallows synthetic ⌘-drags: every placement
    /// landed back where it started (Kap's Electron tray, #15). Left where
    /// the app put it instead of dragged on every reveal; the editor says
    /// so and offers a launcher. Sticky across launches — the item bounces
    /// the same way every time, and re-learning it costs three visible
    /// drags per session. Cleared by a verified move (a user's own ⌘-drag).
    private(set) var immovableBundles: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: AppState.immovableKey) ?? []
    ).subtracting(PelmetBundle.ownIDs)
    private static let immovableKey = "pelmet.immovableBundles"

    /// Learned (bounced drags) or known (the agent pins SystemUIServer).
    func isImmovable(_ id: ItemID) -> Bool {
        guard let bundle = id.bundleID else { return false }
        return immovableBundles.contains(bundle) || MenuBarPolicy.isPinnedAppleHost(bundle)
    }

    /// See PlacementController.noteBounce — Apply reports through the same
    /// budget, so a tray that swallows drags stops being retried every pass.
    @discardableResult
    func noteBounce(_ id: ItemID, at x: CGFloat) -> Bool { placement.noteBounce(id, at: x) }

    func setImmovable(_ bundle: String, _ immovable: Bool) {
        guard !PelmetBundle.ownIDs.contains(bundle),
              immovableBundles.contains(bundle) != immovable else { return }
        if immovable { immovableBundles.insert(bundle) } else { immovableBundles.remove(bundle) }
        UserDefaults.standard.set(Array(immovableBundles), forKey: Self.immovableKey)
        PelmetLog.log("editor: immovable \(immovableBundles.sorted())")
    }
    /// Consecutive snapshots a host must read the same (dis)agreeing way
    /// before the sticky mark flips.
    private static let bundlelessConfirmations = 3
    private var bundlelessStreak: [String: Int] = [:]

    func isBundlelessHost(_ id: ItemID) -> Bool {
        id.bundleID.map { bundlelessHosts.contains($0) } ?? false
    }

    /// Items the native « holds on the primary band, from the latest
    /// snapshot (`PlacementGeometry.overflowTrappedCount`). While non-zero
    /// the bar is full: the « decides who is on screen, every synthetic
    /// drag is undone by the next reflow, and a frameless item is trapped,
    /// not missing. Drift corrections, rescues, background placements and
    /// adoption windows all wait for room (#42: 23 drags, 3 « clicks and
    /// an adoption window every 2 minutes on a 28-icon 14" bar).
    private(set) var overflowTrappedCount = 0
    private var lastOverflowRead = 0
    var barOverflows: Bool { overflowTrappedCount > 0 }

    private func noteOverflow(in snap: EngineSnapshot) {
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        let trapped = PlacementGeometry.overflowTrappedCount(
            snap.items.compactMap { item in
                guard let f = item.frame, f.width > 4,
                      PlacementGeometry.isPrimary(f, screenMaxX: primaryMaxX) else { return nil }
                return f.minX
            }
        )
        // Two consecutive reads to enter (a mid-attach walk at boot read two
        // items at one x for 200ms), one to leave.
        defer { lastOverflowRead = trapped }
        if trapped > 0, overflowTrappedCount == 0, lastOverflowRead == 0 { return }
        guard trapped != overflowTrappedCount else { return }
        if (trapped > 0) != (overflowTrappedCount > 0) {
            PelmetLog.log(trapped > 0
                ? "overflow: \(trapped) icon(s) behind the native « — placements and corrections wait for room"
                : "overflow: cleared")
        }
        overflowTrappedCount = trapped
    }

    func updateSnapshot(_ snap: EngineSnapshot) {
        let now = Date.now
        noteOverflow(in: snap)
        for (key, frame) in ApplyPass.primaryFrames(snap) { rememberedFrames[key] = frame }
        for item in snap.items {
            lastSeenAt[item.id.sectionKey] = now
            if item.pid > 0, let bundle = item.id.bundleID { lastSeenPID[bundle] = item.pid }
        }
        for id in snap.concealed { lastSeenAt[id.sectionKey] = now }
        pruneRetiredAppleHostSlot(snap)
        guard snapshot?.contentEquals(snap) != true else { return }
        let bundleless = snap.items.filter(\.hostIsBundleless).map(\.id.rawValue)
        if bundleless != lastBundlelessIDs {
            lastBundlelessIDs = bundleless
            PelmetLog.log("snapshot: bundle-less hosts \(bundleless)")
        }
        // Remembered per bundle: the item drops out of AX while concealed
        // and the editor must not flicker between states across reveals.
        // Sticky and persisted: the same icon is hosted by the helper on one
        // pass and by the main app on the next (ChatGPT Classic re-registers
        // at runtime), and the item is invisible to AX while concealed — a
        // mark that came and went with the reveal state was worse than none.
        // An app that EVER draws its bar icon from a bundle-less helper can't
        // be hidden reliably; the user clears it by fixing the app.
        for item in snap.items {
            if let bundle = item.id.bundleID { absentBundles.remove(bundle) }
        }
        // One sighting is not evidence: a walk that lands mid-relaunch finds
        // a pid LaunchServices has no record of yet and reads a perfectly
        // normal app as bundle-less (Sconce and a Pelmet launcher, both
        // 2026-09-14; the read cleared 75ms later). A real bundle-less host
        // (ChatGPT Classic's helper) reads that way on every walk. So: mark
        // after `bundlelessConfirmations` consecutive live sightings, and
        // unmark a host that reads fine that many times in a row — the
        // "fix the app" recovery happens on its own. Never Pelmet's bundles.
        var readings: [String: Bool] = [:]
        for item in snap.items where item.frame != nil {
            guard let bundle = item.id.bundleID, !PelmetBundle.ownIDs.contains(bundle) else { continue }
            readings[bundle] = (readings[bundle] ?? false) || item.hostIsBundleless
        }
        var changed = false
        for (bundle, bundleless) in readings {
            let marked = bundlelessHosts.contains(bundle)
            guard bundleless != marked else { bundlelessStreak.removeValue(forKey: bundle); continue }
            let streak = (bundlelessStreak[bundle] ?? 0) + 1
            bundlelessStreak[bundle] = streak
            guard streak >= Self.bundlelessConfirmations else { continue }
            bundlelessStreak.removeValue(forKey: bundle)
            if bundleless { bundlelessHosts.insert(bundle) } else { bundlelessHosts.remove(bundle) }
            changed = true
        }
        if changed {
            UserDefaults.standard.set(Array(bundlelessHosts), forKey: Self.bundlelessKey)
            PelmetLog.log("editor: bundle-less hosts \(bundlelessHosts.sorted())")
        }
        unhideableTracker.observe(
            live: Set(snap.items.filter { $0.frame != nil }.map(\.id.sectionKey)),
            concealed: Set(snap.concealed.map(\.sectionKey))
        )
        if unhideableTracker.confirmed != unhideableKeys {
            unhideableKeys = unhideableTracker.confirmed
            PelmetLog.log("snapshot: unhideable \(unhideableKeys.map(\.rawValue))")
        }
        // Third-party keys only: Apple's modules come and go with the
        // assertion's system flags, not with an allowlist the agent can fail
        // to match, and Pelmet's own items are never collateral.
        collateralTracker.observe(
            live: Set(
                snap.items
                    .filter { $0.frame != nil && !$0.id.isSystemModule }
                    .map(\.id.sectionKey)
                    .filter { $0.bundleID.map { !PelmetBundle.ownIDs.contains($0) } ?? false }
            ),
            concealing: Set(snap.concealed.compactMap(\.bundleID)),
            running: { NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty == false }
        )
        if collateralTracker.confirmed != destroyedKeys {
            destroyedKeys = collateralTracker.confirmed
            PelmetLog.log("snapshot: destroyed by the bar \(destroyedKeys.map(\.rawValue))")
        }
        snapshot = snap
        clockRelay?.updateClockFrame(
            snap.items.first { $0.id.rawValue.hasSuffix("::com.apple.menuextra.clock") }?.frame
        )
        bundleCounts = snap.items.reduce(into: [:]) { counts, item in
            guard let bundle = item.id.bundleID else { return }
            counts[bundle, default: 0] += 1
        }
    }

    /// Live items per bundle — the editor's sibling badge reads this instead
    /// of scanning the whole snapshot per tile.
    private(set) var bundleCounts: [String: Int] = [:]

    /// New-app routing: any third-party bundle never seen before gets its
    /// items assigned to `newItemsDestination`. Runs BEFORE converge so the
    /// engine never shows a new icon the user asked to have hidden. The very
    /// first pass (empty known set) is a silent baseline — nothing moves.
    /// Returns the new items (empty on baseline) so callers can physically
    /// slot them: macOS spawns new icons at the far left of the status area —
    /// inside the hidden/always-hidden zone — so without a placement drag a
    /// model-visible newcomer flaps sides of the chevron on every reveal.
    @discardableResult
    private func registerNewItems(from snap: EngineSnapshot) -> [ItemID] {
        let candidates = Self.registrationCandidates(snap.items.map(\.id))
        var model = settings.sectionModel
        let before = model.knownBundles
        let hosts = Self.foldSystemHosts(into: &model, candidates: candidates)
        let registered = model.registerObservedItems(candidates)
        guard registered || !hosts.isEmpty else { return [] }
        if !hosts.isEmpty {
            PelmetLog.log("register: system host(s) \(hosts.sorted().joined(separator: ", ")) known — not routed")
        }
        let added = model.knownBundles.subtracting(before).subtracting(hosts)
        if registered {
            PelmetLog.log(
                before.isEmpty
                    ? "register: baseline \(model.knownBundles.count) bundle(s)"
                    : "register: new \(added.sorted().joined(separator: ", ")) → \(model.newItemsDestination.rawValue)"
            )
        }
        settings.sectionModel = model
        settings.save()
        guard registered, !before.isEmpty else { return [] }
        return candidates.filter {
            $0.bundleID.map(added.contains) == true
        }
    }

    /// Apple hosts (the input menu, MenuBarAgent's Sound / Battery / Clock)
    /// were in the bar before Pelmet could manage them, so an existing install
    /// meets them as "unknown", never as newly installed. They join
    /// `knownBundles` as baseline instead of routing to `newItemsDestination`;
    /// the relaunch re-slot only needs them known. A fresh install (empty set)
    /// already baselines everything in `registerObservedItems`.
    static func foldSystemHosts(into model: inout SectionModel, candidates: [ItemID]) -> Set<String> {
        guard !model.knownBundles.isEmpty else { return [] }
        let hosts = Set(candidates.compactMap(\.bundleID).filter(MenuBarPolicy.isUnmanagedAppleBundle))
            .subtracting(model.knownBundles)
        model.knownBundles.formUnion(hosts)
        return hosts
    }

    private func adopt(from snap: EngineSnapshot, dragEndX: CGFloat? = nil) {
        // No showStatusItem guard: with the Pelmet icon hidden reconcile
        // falls back to cluster-edge boundaries, where zone adoption applies
        // only to the item the user just dragged — identified here by the
        // drop x (the dragged item lands under the cursor; x is
        // origin-agnostic, so no Cocoa→AX y-flip needed).
        // adoptSectionsFromBar defers while transitioning/settling; this is
        // the last line of defense if called on a stale path.
        guard !isTransitioning else { return }
        // Primary-band frames only. The AX walk carries other displays' bars
        // too (Sconce at x=-265 AND x=1535 in one snapshot, 2026-09-02), and
        // the order fold-in keys "leftmost frame wins" — a left-display copy
        // pinned Sconce to the front of Visible no matter where the user
        // dropped it. Off-band copies read as unmeasured.
        let primaryMaxX = NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude
        let items: [ObservedItem] = snap.items.map { item in
            guard let frame = item.frame,
                  MenuBarGeometry.isInBand(frame),
                  frame.midX > 0, frame.midX < primaryMaxX
            else { return ObservedItem(id: item.id, frame: nil, appName: item.appName, hostIsBundleless: item.hostIsBundleless) }
            return item
        }
        let draggedID: ItemID? = dragEndX.flatMap { x in
            let hit = items
                .compactMap { item -> (id: ItemID, distance: CGFloat)? in
                    guard let frame = item.frame else { return nil }
                    guard frame.minX - 8 <= x, x <= frame.maxX + 8 else { return nil }
                    return (item.id, abs(frame.midX - x))
                }
                .min { $0.distance < $1.distance }
            if let hit { PelmetLog.log("adopt: dragged=\(hit.id.rawValue)") }
            return hit?.id
        }
        // The user just moved it by hand: whatever swallowed Pelmet's drags
        // before, the mark no longer describes the item.
        if let draggedID, let bundle = draggedID.bundleID { setImmovable(bundle, false) }
        guard let result = BarAdoption.reconcile(
            items: items.map { (id: $0.id, minX: $0.frame?.minX) },
            model: settings.sectionModel,
            previousZones: lastAdoptionZones,
            previousChevronX: lastAdoptionChevronX,
            previousPositions: lastAdoptionPositions,
            pendingZones: lastAdoptionPending,
            userDragged: dragEndX != nil,
            pelmetBundleID: PelmetBundle.mainID,
            draggedID: draggedID
        ) else { return }
        for line in result.log { PelmetLog.log(line) }
        // Visible-section live order vs model order — the fold-in's inputs.
        let liveVisible = items
            .filter { settings.sectionModel.section(of: $0.id) == .visible && $0.frame != nil }
            .sorted { $0.frame!.minX < $1.frame!.minX }
            .map { "\($0.id.sectionKey)@\(Int($0.frame!.minX))" }
        PelmetLog.log("adopt: visible live=\(liveVisible) model=\((settings.sectionModel.order[.visible] ?? []).map(\.rawValue))")
        lastAdoptionZones = result.zones
        lastAdoptionChevronX = result.chevronX
        lastAdoptionPositions = result.positions
        lastAdoptionPending = result.pendingZones
        if result.changed {
            var model = result.model
            // Sets core: the editor's drawing outranks the bar until Apply.
            // The periodic pass reconciled the hidden order from the bar
            // between two drops and every tile jumped back (2026-09-20 17:28).
            if CoreMode.setsOnly {
                for section in settings.orderEdits.order.keys {
                    model.order[section] = settings.sectionModel.order[section]
                }
            }
            settings.sectionModel = model
            settings.save()
            // A ⌘-drag across the chevron can move a separator between
            // sections; its host follows the section (see `moveItem`).
            separators?.sync(with: settings.separators)
            Task {
                await engine.setModel(result.model)
                // M2 (docs/CORE-SETS.md): a user drag or membership change
                // is what goes stale in the own-item order hint — the media
                // replica re-registered inside the hidden run after two
                // drags of it (2026-09-20 15:41) while the camera indicator,
                // whose hint was fresh, came back at its slot. Reseed now so
                // the next fresh registration lands where the bar says.
                if CoreMode.setsOnly { await engine.writeOrderHint() }
            }
        }
    }

    /// Bounded wait for Pelmet's own separators/extras to appear in the agent's
    /// AX tree before the engine may assert (see launch Task). All items are
    /// still isVisible at this point — hiding happens via the reflow
    /// companion after the engine starts.
    private func waitForOwnItemAdoption() async {
        // Only visible-section items count: hidden-section separators/extras
        // are width-collapsed at first apply and never enter the AX tree, so
        // expecting them would guarantee the timeout.
        var expected = Set(
            settings.separators.map { SeparatorManager.itemID(for: $0) }
                .filter { settings.sectionModel.section(of: $0) == .visible }
        )
        // Media controls are a visible-section item that is only IN the bar
        // while audio plays; with nothing playing it is width-collapsed and
        // never enters the AX tree, so expecting it burned the full 8s on
        // every silent launch (2026-09-16). Wait for it only when it shows.
        for spec in settings.extraItems where spec.kind == .mediaControls {
            let id = ExtrasManager.itemID(for: spec)
            if settings.sectionModel.section(of: id) == .visible, extras?.isShowing(id) == true {
                expected.insert(id)
            }
        }
        // Helper-hosted items hide through the assertion, not a collapsed
        // width, so before the first converge every one the helpers have
        // registered sits in band — and the first converge would park a
        // registration the agent hasn't adopted yet, same as a visible one.
        for id in helperHosts?.hostedLiveIDs ?? [] { expected.insert(id) }
        guard !expected.isEmpty else { return }
        let deadline = Date.now.addingTimeInterval(8)
        var missing = expected
        var lastWalk: [ItemID: CGRect?] = [:]
        while Date.now < deadline {
            // In-band frames only: a registration made while the PREVIOUS
            // instance's assertion still held (relaunch overlap) is present
            // in AX but parked offscreen (x=4800, 2026-09-02) — counting it
            // as adopted let the first converge assert over it, parking the
            // media control in the wrong zone for the whole session.
            let snap = await engine.snapshot()
            lastWalk = Dictionary(
                snap.items.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a }
            )
            let observed = Set(
                snap.items
                    .filter { $0.frame.map(MenuBarGeometry.isInBand) == true }
                    .map(\.id)
            )
            if expected.subtracting(observed).isEmpty {
                PelmetLog.log("start: own items adopted (\(expected.count))")
                return
            }
            missing = expected.subtracting(observed)
            try? await Task.sleep(for: .milliseconds(500))
        }
        let detail = missing.sorted { $0.rawValue < $1.rawValue }.map { id -> String in
            guard let frame = lastWalk[id] else { return "\(id.rawValue) absent-from-AX" }
            guard let frame else { return "\(id.rawValue) no-frame" }
            return "\(id.rawValue) parked x=\(Int(frame.minX)) y=\(Int(frame.minY))"
        }
        PelmetLog.log("start: own-item adoption timeout — continuing without \(detail)")
    }

    private func handle(engineEvent: EngineEvent) {
        switch engineEvent {
        case .externalOrderChange:
            adoptSectionsFromBar()
            Task { updateSnapshot(await engine.snapshot()) }
        case .itemsChanged:
            // Not before the first converge. `waitForOwnItemAdoption` polls
            // the engine every 500ms, and any id that flips mid-boot (an
            // item still without a frame, SystemUIServer's title resolving
            // on the second walk) makes one of those polls emit
            // itemsChanged. Converging on it asserts over the helpers whose
            // adoption the wait is still waiting for, so the wait could
            // never finish and burned its full 8s (2026-09-16). Nothing is
            // lost: the boot sequence runs registerNewItems + setModel
            // itself, straight after the wait.
            guard engineStarted else { return }
            // Route never-seen bundles to the configured new-items section,
            // then re-converge so the change (or a known bundle rejoining the
            // allowlist) takes effect.
            Task {
                let newItems = registerNewItems(from: await engine.snapshot())
                placement.queuePlacements(newItems)
                await engine.setModel(settings.sectionModel)
                // Visible-destined newcomers place right away; concealed
                // destinations stay queued until a full reveal makes their
                // slot deterministic.
                placement.flushPendingPlacements()
                updateSnapshot(await engine.snapshot())
                // The system camera pill appearing/vanishing is an
                // itemsChanged — Pelmet's indicator defers to it live. But NOT
                // mid-transition: every reveal/conceal fires itemsChanged
                // (concealed items drop out of AX), and applying here would
                // animate extras on a second clock. The settle catch-up in
                // dispatch covers the transition case.
                guard !isTransitioning else { return }
                extras?.apply(model: settings.sectionModel, revealed: currentRevealedSections, systemCameraPillVisible: systemCameraPillVisible)
                separators?.apply(model: settings.sectionModel, revealed: currentRevealedSections)
            }
        case .assertionTornDown:
            unhideableTracker.assertionLost()
            collateralTracker.assertionLost()
            // Recovery: force a real converge. (A `.concealRequested` through
            // the rehide machine was a no-op from `.concealed` — the exact
            // state an external teardown usually finds us in.)
            Task { await engine.setModel(settings.sectionModel) }
        case .availabilityChanged(let available):
            engineCanHide = available
        case .convergeFailed:
            // Surfaced in Settings as a banner; never silently retried in a loop.
            break
        }
    }
}
