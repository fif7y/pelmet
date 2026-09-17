// MediaControls.swift — Pelmet items ("extras"): Pelmet-owned proxies for the
// system extras that macOS collateral-hides under any assertion, user
// shortcut buttons, and app launchers (a Pelmet icon that opens an app).
// Because Pelmet owns these NSStatusItems, hiding is plain `isVisible` per
// assigned section — no assertion involvement (asserting away Pelmet's bundle
// would take the chevron too).

import AppKit
import AVFoundation
import CoreAudio
import CoreMediaIO
import PelmetCore
import PelmetEngine
import UniformTypeIdentifiers

// MARK: - Media keys

enum MediaKey: Int32 {
    case playPause = 16  // NX_KEYTYPE_PLAY
    case next = 17       // NX_KEYTYPE_NEXT
    case previous = 18   // NX_KEYTYPE_PREVIOUS

    /// Posts the system-defined media key (down+up), same as the keyboard key.
    func send() {
        for down in [true, false] {
            let flags: UInt = down ? 0xA00 : 0xB00
            let data1 = Int((Int(self.rawValue) << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Manager

@MainActor
final class ExtrasManager {
    private weak var appState: AppState?
    private var items: [UUID: NSStatusItem] = [:]
    private var specs: [UUID: ExtraItemSpec] = [:]
    private var lastVisible: [UUID: Bool] = [:]
    /// Every extra allows the native ⌘-drag off the bar; AppKit reports it
    /// as an `isVisible` flip (see `observeRemoval`).
    private var removalObservations: [UUID: NSKeyValueObservation] = [:]
    /// Attached ahead of an uncovered swap (see `preattach`): the companion's
    /// show only fades them, and a pending layout drop must leave them be.
    private var preattached: Set<UUID> = []
    private var cameraMicMonitor: CameraMicMonitor?
    /// Pelmet's own countdown, alive while a timer item exists.
    private var pelmetTimer: PelmetTimer?
    private var lastTimerActive = false
    /// Time Machine's state, alive while a Time Machine item exists.
    private var timeMachine: TimeMachineBackup?
    private var lastBackupRunning = false
    /// Which Focus is on, alive while a Focus item exists.
    private var focusStatus: FocusStatus?
    private var lastFocusActive = false
    /// One clock per media item drawing the animated bars (see ExtraGlyphs).
    private var animators: [UUID: ExtraAnimator] = [:]
    /// Play/pause state the media glyph shows. Click intent drives it (players
    /// keep the output device open while paused, so DeviceIsRunningSomewhere
    /// alone can't see a pause); real audio EDGES reconcile it when they do
    /// arrive — start means playing, device release means stopped.
    private var mediaPlaying = false
    private var lastAudioOutputActive = false
    /// Edge tracking for the camera/mic indicator's placement walk.
    private var lastCameraIndicatorVisible = false
    /// Debounces the activation edge before queuing the placement walk.
    private var cameraPlacementDebounce: Task<Void, Never>?
    /// App launchers with the "while running" rule: the running edge (not the
    /// section reveal edge) is what re-enters layout and needs a placement.
    private var lastRunning: [UUID: Bool] = [:]
    /// Menu-bar agent apps post no launch notification; KVO on the running
    /// list sees every activation policy (same lesson as AppState's relaunch
    /// observer, 2026-09-09).
    private var runningAppsObservation: NSKeyValueObservation?

    init(appState: AppState) {
        self.appState = appState
    }

    static func itemID(for spec: ExtraItemSpec) -> ItemID {
        .status(
            bundle: PelmetBundle.mainID,
            title: spec.itemTitle
        )
    }

    /// All ItemIDs the editor should represent even when invisible.
    var managedItemIDs: [ItemID] {
        specs.values.map(Self.itemID(for:))
    }

    /// Whether this extra is actually in the bar right now. The hardware-gated
    /// kinds sit in a section but only appear while their hardware is live
    /// (media controls with audio playing, the camera indicator with a camera
    /// on), so a caller that needs a real AX item — the boot adoption wait —
    /// has to ask rather than infer it from the section.
    func isShowing(_ id: ItemID) -> Bool {
        specs.contains { lastVisible[$0.key] == true && Self.itemID(for: $0.value) == id }
    }

    func sync(with newSpecs: [ExtraItemSpec]) {
        Self.iconCache.removeAll(keepingCapacity: true)
        let wanted = Set(newSpecs.map(\.id))
        for (id, item) in items where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            items.removeValue(forKey: id)
            specs.removeValue(forKey: id)
            lastVisible.removeValue(forKey: id)
            lastRunning.removeValue(forKey: id)
            removalObservations.removeValue(forKey: id)
            animators[id]?.tearDown()
            animators.removeValue(forKey: id)
        }
        for spec in newSpecs {
            let styleChanged = specs[spec.id].map { $0.style != spec.style } ?? false
            specs[spec.id] = spec
            if items[spec.id] == nil {
                items[spec.id] = makeItem(for: spec)
            }
            // The editor board shows the real glyph: the drawn AirDrop mark
            // always, the bars when media is animated, the symbol otherwise.
            if spec.kind == .appLauncher, spec.symbol == nil,
               let icon = Self.appIcon(for: spec, size: 20) {
                ItemImageCache.registerPelmetItem(title: spec.itemTitle, image: icon)
            } else if spec.kind == .airdrop {
                ItemImageCache.registerPelmetItem(
                    title: spec.itemTitle, image: ExtraGlyph.airdrop
                )
            } else if spec.kind == .mediaControls, spec.resolvedStyle == .animated {
                ItemImageCache.registerPelmetItem(
                    title: spec.itemTitle, image: ExtraGlyph.mediaBars(t: 0, level: 1, animated: false)
                )
            } else {
                ItemImageCache.unregisterPelmetItemImage(title: spec.itemTitle)
                ItemImageCache.registerPelmetItem(
                    title: spec.itemTitle, symbol: Self.symbol(for: spec)
                )
            }
            if styleChanged, let item = items[spec.id] {
                animators[spec.id]?.tearDown()
                animators.removeValue(forKey: spec.id)
                refreshGlyph(item, spec: spec)
            }
            // The glyph is editable (launcher icon picker), so refresh the
            // existing button too — sync only builds the item once.
            if spec.kind == .appLauncher, let button = items[spec.id]?.button {
                button.image = Self.launcherImage(for: spec, size: 18)
            }
        }
        // Only a "while running" launcher depends on the running list; an
        // "always" launcher hides purely by section. This KVO fires for
        // every app launch and quit on the machine, so don't hold it for
        // launchers that would ignore it.
        let needsRunningObserver = newSpecs.contains {
            $0.kind == .appLauncher && $0.resolvedShowRule == .whenActive
        }
        if needsRunningObserver, runningAppsObservation == nil {
            runningAppsObservation = NSWorkspace.shared.observe(
                \.runningApplications, options: [.new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.applyCurrent() }
            }
        } else if !needsRunningObserver {
            runningAppsObservation = nil
        }
        if newSpecs.contains(where: { $0.kind == .timer }) {
            if pelmetTimer == nil {
                let timer = PelmetTimer()
                timer.onChange = { [weak self] in self?.timerChanged() }
                pelmetTimer = timer
            }
        } else if let timer = pelmetTimer {
            timer.cancel()
            pelmetTimer = nil
        }
        if newSpecs.contains(where: { $0.kind == .timeMachine }) {
            if timeMachine == nil {
                let backup = TimeMachineBackup()
                backup.onChange = { [weak self] in self?.timeMachineChanged() }
                timeMachine = backup
                backup.start()
            }
        } else if let backup = timeMachine {
            backup.stop()
            timeMachine = nil
        }
        if newSpecs.contains(where: { $0.kind == .focus }) {
            if focusStatus == nil {
                let status = FocusStatus()
                status.onChange = { [weak self] in self?.focusChanged() }
                focusStatus = status
                status.start()
            }
        } else if let status = focusStatus {
            status.stop()
            focusStatus = nil
        }
        let needsCameraMonitor = newSpecs.contains {
            $0.kind == .cameraMicIndicator || $0.kind == .mediaControls
        }
        if needsCameraMonitor, cameraMicMonitor == nil {
            cameraMicMonitor = CameraMicMonitor { [weak self] in
                self?.applyCurrent()
            }
        } else if !needsCameraMonitor {
            cameraMicMonitor?.stop()
            cameraMicMonitor = nil
        }
        applyCurrent()
    }

    /// Applies section visibility. Hiding collapses the item's LENGTH instead
    /// of toggling isVisible — isVisible plays its own slide animation on a
    /// different clock than the assertion reflow; a width collapse rides the
    /// same bar reflow and reads as one motion. The camera/mic indicator
    /// overrides its section while hardware is live — an indicator that hides
    /// when active would be lying.
    func apply(
        model: SectionModel,
        revealed: Set<PelmetCore.Section>,
        systemCameraPillVisible: Bool
    ) {
        for (id, item) in items {
            guard let spec = specs[id] else { continue }
            let section = model.section(of: Self.itemID(for: spec))
            var visible = section == .visible || revealed.contains(section)
            switch spec.kind {
            case .cameraMicIndicator:
                // Pure indicator, like Apple's: exists ONLY while hardware is
                // live (section decides where it appears, not whether). Defers
                // to the system pill when that one is on screen.
                let active = cameraMicMonitor?.isActive ?? false
                visible = active && !systemCameraPillVisible
                updateCameraSymbol(item, spec: spec)
                // Re-entering layout (isVisible flip) parks the item wherever
                // the agent decides, not at its model slot. Never drag here:
                // the activation is app-driven (Sconce opening the camera,
                // 2026-08-31) and the synthetic ⌘-drag hijacked the pointer
                // mid-task. Debounce the edge — the system pill takes over
                // within ~50ms and hides us again — then queue the walk for
                // the next reveal settle.
                let itemID = Self.itemID(for: spec)
                if visible, !lastCameraIndicatorVisible {
                    cameraPlacementDebounce?.cancel()
                    cameraPlacementDebounce = Task { [weak self] in
                        try? await Task.sleep(for: AppTiming.cameraIndicatorPlaceDebounce)
                        guard let self, !Task.isCancelled,
                              self.lastCameraIndicatorVisible else { return }
                        self.appState?.queueDynamicExtraPlacement(itemID)
                    }
                } else if !visible, lastCameraIndicatorVisible {
                    cameraPlacementDebounce?.cancel()
                    appState?.cancelDynamicExtraPlacement(itemID)
                }
                lastCameraIndicatorVisible = visible
            case .mediaControls:
                let audioActive = cameraMicMonitor?.audioOutputActive ?? false
                if audioActive != lastAudioOutputActive {
                    lastAudioOutputActive = audioActive
                    mediaPlaying = audioActive
                }
                updateMediaSymbol(item, spec: spec)
                // "Always": a play/pause button that rides its section like
                // AirDrop. "When active": section-governed AND
                // media-relevant — playing, or within the post-playback
                // linger so pause doesn't swallow resume.
                if spec.resolvedShowRule == .whenActive {
                    visible = visible && (cameraMicMonitor?.mediaRelevant ?? true)
                    // Same re-entry hazard as the camera pill: audio
                    // starting (or the linger expiring and resuming) puts
                    // the item back in layout at the agent's slot, not the
                    // model's.
                    let itemID = Self.itemID(for: spec)
                    if visible, lastVisible[id] != true {
                        appState?.queueDynamicExtraPlacement(itemID)
                    } else if !visible, lastVisible[id] == true {
                        appState?.cancelDynamicExtraPlacement(itemID)
                    }
                }
            case .appLauncher:
                // "While running" mirrors the app's own icon; "Always" is a
                // launcher and hides purely by section, like AirDrop.
                let running = Self.isRunning(spec)
                if spec.resolvedShowRule == .whenActive {
                    visible = visible && running
                    // The running edge re-enters layout at the agent's slot,
                    // not the model's — same hazard as the media button.
                    // Visible right now (section revealed): place at once,
                    // the user launched the app and is looking at the bar.
                    // Concealed: the next reveal settle places it. Section
                    // reveals themselves don't queue: those ride the reflow.
                    let itemID = Self.itemID(for: spec)
                    if running, lastRunning[id] != true {
                        if visible {
                            appState?.placeOwnItemSoon(itemID)
                        } else {
                            appState?.queueDynamicExtraPlacement(itemID)
                        }
                    } else if !running, lastRunning[id] == true {
                        appState?.cancelDynamicExtraPlacement(itemID)
                    }
                }
                lastRunning[id] = running
            case .airdrop:
                updateAirDropGlyph(item, spec: spec)
            case .timer:
                // Section-governed while idle; a counting (or ringing) timer
                // is an indicator and stays in the bar whatever its section.
                let active = pelmetTimer?.isActive ?? false
                let sectionVisible = visible
                visible = visible || active
                updateTimerGlyph(item, spec: spec)
                let itemID = Self.itemID(for: spec)
                if active, !lastTimerActive {
                    // The user just clicked it: the section reveal isn't
                    // what put it in layout, so place it now if the bar is
                    // looking, else on the next reveal settle.
                    if sectionVisible {
                        appState?.placeOwnItemSoon(itemID)
                    } else {
                        appState?.queueDynamicExtraPlacement(itemID)
                    }
                } else if !active, lastTimerActive {
                    appState?.cancelDynamicExtraPlacement(itemID)
                }
                lastTimerActive = active
            case .timeMachine:
                updateTimeMachineGlyph(item, spec: spec)
                // "When active": only while a backup runs, the running edge
                // placed like a while-running launcher.
                if spec.resolvedShowRule == .whenActive {
                    let running = timeMachine?.status.running ?? false
                    let sectionVisible = visible
                    visible = visible && running
                    let itemID = Self.itemID(for: spec)
                    if running, !lastBackupRunning {
                        if sectionVisible {
                            appState?.placeOwnItemSoon(itemID)
                        } else {
                            appState?.queueDynamicExtraPlacement(itemID)
                        }
                    } else if !running, lastBackupRunning {
                        appState?.cancelDynamicExtraPlacement(itemID)
                    }
                    lastBackupRunning = running
                }
            case .focus:
                // An indicator like the camera pill: a Focus that is on shows
                // whatever the section says (Apple's own does, and one that
                // hid would be lying). Off, the rule decides — gone like
                // Apple's default, or in its section as a moon that opens the
                // Focus panel.
                let active = focusStatus?.active != nil
                let sectionVisible = visible
                visible = active || (spec.resolvedShowRule == .always && sectionVisible)
                updateFocusGlyph(item, spec: spec)
                let itemID = Self.itemID(for: spec)
                if active, !lastFocusActive {
                    // Same re-entry hazard as the timer: the switch put it in
                    // layout at the agent's slot, not the model's.
                    if sectionVisible {
                        appState?.placeOwnItemSoon(itemID)
                    } else {
                        appState?.queueDynamicExtraPlacement(itemID)
                    }
                } else if !active, lastFocusActive {
                    appState?.cancelDynamicExtraPlacement(itemID)
                }
                lastFocusActive = active
            case .shortcut, .userSwitching, .siri:
                break
            }
            setVisible(visible, for: id, item: item)
            // A hidden glyph keeps its last frame and stops ticking.
            animators[id]?.paused = !visible
        }
    }

    /// Section-governed items about to be revealed UNCOVERED join the layout
    /// now, invisible, so the swap changes no layout and the third-party
    /// icons fade in place (see `StatusItemFader.attach`). The companion's
    /// `apply` then only runs their fade. Returns what it attached so the
    /// caller can wait for the agent to place them.
    func preattach(model: SectionModel, revealing: Set<PelmetCore.Section>) -> [NSStatusItem] {
        var attached: [NSStatusItem] = []
        for (id, item) in items {
            guard let spec = specs[id], lastVisible[id] != true else { continue }
            switch spec.kind {
            case .airdrop, .shortcut, .userSwitching, .siri: break
            case .timer:
                // Counting: already in the bar on its own.
                guard !(pelmetTimer?.isActive ?? false) else { continue }
            case .focus:
                // Only an always-shown, currently off Focus rides the section.
                guard spec.resolvedShowRule == .always else { continue }
            case .appLauncher:
                // The running edge has its own placement walk; only a plain
                // launcher (or one already running) rides the section.
                guard spec.resolvedShowRule != .whenActive || Self.isRunning(spec) else { continue }
            case .timeMachine:
                guard spec.resolvedShowRule != .whenActive || timeMachine?.status.running == true else { continue }
            case .mediaControls:
                // Audio-driven unless it always shows.
                guard spec.resolvedShowRule == .always else { continue }
            case .cameraMicIndicator: continue  // hardware-driven
            }
            guard revealing.contains(model.section(of: Self.itemID(for: spec))) else { continue }
            StatusItemFader.attach(item, shownLength: Self.shownLength(for: spec))
            preattached.insert(id)
            attached.append(item)
        }
        return attached
    }

    /// Two-phase hide: width-collapse rides the same bar reflow as the
    /// assertion (matched animation), then after the reflow settles the item
    /// leaves layout entirely — zero-length items still reserve their built-in
    /// spacing, which reads as a dead gap next to the chevron.
    private func setVisible(_ visible: Bool, for id: UUID, item: NSStatusItem) {
        if !visible, lastVisible[id] != true, preattached.remove(id) != nil {
            // Attached ahead of a reveal that never came: leave layout again, unseen.
            item.isVisible = false
            return
        }
        guard lastVisible[id] != visible else { return }
        lastVisible[id] = visible
        let wasPreattached = preattached.remove(id) != nil
        PelmetLog.log("extras: \(specs[id]?.itemTitle ?? "?") → \(visible ? (wasPreattached ? "fade (attached ahead)" : "show") : "hide (ghost)")")
        // Runs as the engine's reflow companion, so timing coincides with the
        // assertion swap — choreography and constants live in StatusItemFader.
        let stillCurrent: @MainActor () -> Bool = { [weak self] in
            self?.lastVisible[id] == visible && self?.preattached.contains(id) != true
        }
        if visible, wasPreattached {
            StatusItemFader.fadeInAfterGlide(item, shownAlpha: 1, stillCurrent: stillCurrent)
            return
        }
        StatusItemFader.setVisible(
            visible,
            item: item,
            shownLength: specs[id].map(Self.shownLength(for:)) ?? NSStatusItem.squareLength,
            shownAlpha: 1,
            stillCurrent: stillCurrent
        )
    }

    private func applyCurrent() {
        guard let appState else { return }
        apply(
            model: appState.settings.sectionModel,
            revealed: appState.revealedSectionsForExtras,
            systemCameraPillVisible: appState.systemCameraPillVisible
        )
    }

    // MARK: Item construction

    /// Square for glyph-only items; the timer grows with its countdown.
    private static func shownLength(for spec: ExtraItemSpec) -> CGFloat {
        spec.kind == .timer ? NSStatusItem.variableLength : NSStatusItem.squareLength
    }

    private func makeItem(for spec: ExtraItemSpec) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Self.shownLength(for: spec))
        item.autosaveName = spec.itemTitle
        if let button = item.button {
            if spec.kind == .appLauncher, let icon = Self.launcherImage(for: spec, size: 18) {
                button.image = icon
            } else if spec.kind == .airdrop {
                button.image = ExtraGlyph.airdrop
            } else {
                button.image = NSImage(
                    systemSymbolName: Self.symbol(for: spec),
                    accessibilityDescription: spec.itemTitle
                )
            }
            // The menu bar is TALLER on the built-in (notched) display than
            // on an external one, and AppKit clips an oversized status image
            // instead of fitting it — a launcher's app icon rendered as a
            // cropped square on Gab's LG (2026-09-10). Let the button shrink
            // it to whatever box that screen's bar gives us.
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Explicit AX title = the engine's item identity. Without it the
            // enumerator falls back to "Item-0" and every Pelmet item collides.
            button.setAccessibilityTitle(spec.itemTitle)
        }
        // Every extra may be dragged off the bar, and that drag must be a
        // per-item removal: without `.removalAllowed`, macOS 27 answers a
        // drag-out by disallowing the whole app in "Allow in the Menu Bar"
        // (2026-09-14), and a Focus item dropped short of that just slid to
        // the far left (2026-09-16).
        item.behavior = .removalAllowed
        observeRemoval(of: item, for: spec)
        return item
    }

    /// The native ⌘-drag off the bar: AppKit hides the item (`isVisible`
    /// false) and persists that under its autosave name — with nothing
    /// listening the launcher stayed in Settings and healed back on the next
    /// reveal (Comet, 2026-09-14). Pelmet's own hides flip `lastVisible`
    /// first, so a false arriving while it still reads true is the user's
    /// hand: drop the spec — the launcher's Remove, the toggle off for a
    /// singleton kind.
    private func observeRemoval(of item: NSStatusItem, for spec: ExtraItemSpec) {
        removalObservations[spec.id] = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let item = self.items[spec.id], !item.isVisible,
                      self.lastVisible[spec.id] == true,
                      let appState = self.appState else { return }
                PelmetLog.log("extras: \(spec.itemTitle) dragged off the bar → off")
                appState.settings.extraItems.removeAll { $0.id == spec.id }
                appState.settingsChanged()
            }
        }
    }

    static func symbol(for spec: ExtraItemSpec) -> String {
        switch spec.kind {
        case .mediaControls: "playpause.fill"
        case .cameraMicIndicator: "video.fill"
        case .airdrop: Self.airdropSymbol
        case .shortcut: spec.symbol ?? "bolt.fill"
        case .appLauncher: spec.symbol ?? "app.dashed"
        case .timer: "timer"
        case .userSwitching: "person.crop.circle"
        case .timeMachine: ExtraGlyph.timeMachineSymbol
        case .siri: "siri"
        case .focus: "moon.fill"
        }
    }

    // MARK: App launchers

    /// A launcher's bar glyph: the SF Symbol the user picked (template, so
    /// the bar tints it like any other icon), else the app's own icon.
    /// Symbols draw a couple of points smaller than the app-icon box — a
    /// glyph fills its frame edge to edge where an app icon has its own
    /// padding, so equal box sizes read as a bigger icon (Gab, 2026-09-09).
    static func launcherImage(for spec: ExtraItemSpec, size: CGFloat) -> NSImage? {
        if let symbol = spec.symbol {
            let image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: spec.appName
            )?.withSymbolConfiguration(.init(pointSize: size * 0.82, weight: .regular))
            image?.isTemplate = true
            return image
        }
        return appIcon(for: spec, size: size)
    }

    /// Glyphs offered by the launcher icon picker, filtered to what this
    /// system can actually draw (a missing symbol would render an empty
    /// cell). Ordered loosely by kind — neutral shapes first, then objects.
    static let launcherSymbols: [String] = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "sparkles", "moon.fill",
        "sun.max.fill", "cloud.fill", "drop.fill", "leaf.fill", "circle.fill", "square.fill",
        "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill", "app.fill", "capsule.fill",
        "bell.fill", "flag.fill", "tag.fill", "bookmark.fill", "pin.fill", "paperclip",
        "link", "key.fill", "lock.fill", "shield.fill", "gearshape.fill", "hammer.fill",
        "wrench.and.screwdriver.fill", "slider.horizontal.3", "terminal.fill", "cpu", "network", "wifi",
        "antenna.radiowaves.left.and.right", "globe", "message.fill", "envelope.fill", "phone.fill", "video.fill",
        "camera.fill", "mic.fill", "headphones", "music.note", "play.fill", "waveform",
        "folder.fill", "doc.fill", "tray.fill", "archivebox.fill", "externaldrive.fill", "cart.fill",
        "creditcard.fill", "chart.bar.fill", "calendar", "clock.fill", "eye.fill", "magnifyingglass",
        "person.fill", "brain.head.profile", "paintbrush.fill", "paintpalette.fill", "wand.and.stars", "scissors",
        "pencil", "checkmark.circle.fill", "command", "option",
    ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    /// Rendered app icons, keyed by bundle id and point size. Both the
    /// launcher row and every cell of the icon picker ask for one from a
    /// SwiftUI body, and each miss was a LaunchServices lookup plus a
    /// disk-backed icon read — per render, not per change. Cleared by
    /// `sync`, so an edit still re-reads at the same granularity as before.
    private static var iconCache: [String: NSImage] = [:]

    /// The app's real icon (installed copy, running or not), sized for the
    /// bar or the editor tile. nil when the app is gone — the dashed-app
    /// symbol stands in for it.
    static func appIcon(for spec: ExtraItemSpec, size: CGFloat) -> NSImage? {
        guard let bundleID = spec.bundleID else { return nil }
        let key = "\(bundleID)@\(size)"
        if let cached = iconCache[key] { return cached }
        guard let url = appURL(for: spec) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        // Never resize the returned instance in place: AppKit hands back a
        // shared image for a path, and the size is a property of the object.
        guard let sized = icon.copy() as? NSImage else { return nil }
        sized.size = NSSize(width: size, height: size)
        sized.isTemplate = false
        iconCache[key] = sized
        return sized
    }

    static func appURL(for spec: ExtraItemSpec) -> URL? {
        guard let bundleID = spec.bundleID else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let url = running.bundleURL {
            return url
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func isRunning(_ spec: ExtraItemSpec) -> Bool {
        guard let bundleID = spec.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Open = what clicking the app's own icon or Dock tile does: launches a
    /// quit app, activates and reopens a running one.
    private func openApp(_ spec: ExtraItemSpec) {
        guard let url = Self.appURL(for: spec) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    /// A pickable app: running, user-facing (a regular app or a menu-bar
    /// agent the user installed), not Pelmet itself.
    struct PickableApp: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage
        var id: String { bundleID }
    }

    /// Running apps for the "+ App" picker, by name. Menu-bar-only agents
    /// (`.accessory`) are the whole point — that's where the icons Pelmet
    /// can't hide come from — and they must stay pickable AFTER the user
    /// turns the app's own icon off (the flow the card asks for), so the
    /// filter is "an app the user installed": regular apps, anything that
    /// owns a bar icon, or an agent living in /Applications. Background
    /// agents elsewhere (an updater, a sync helper) are noise.
    static func pickableRunningApps(barBundles: Set<String>) -> [PickableApp] {
        var seen: Set<String> = []
        var apps: [PickableApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != PelmetBundle.mainID,
                  !seen.contains(bundleID),
                  let url = app.bundleURL, isUserFacingApp(url),
                  app.activationPolicy == .regular
                    || barBundles.contains(bundleID)
                    || isInstalledApp(url),
                  let name = app.localizedName, !name.isEmpty,
                  let icon = app.icon?.copy() as? NSImage
            else { continue }
            seen.insert(bundleID)
            icon.size = NSSize(width: 16, height: 16)
            apps.append(PickableApp(bundleID: bundleID, name: name, icon: icon))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func isInstalledApp(_ url: URL) -> Bool {
        let path = url.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private static func isUserFacingApp(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        let path = url.path
        // /System/Library holds the OS's own agents; /System/Applications
        // holds Music, Notes… which are fair launchers.
        if path.hasPrefix("/System/Library/") { return false }
        // Nested inside another app bundle = a helper, not an app.
        return !url.deletingLastPathComponent().path.contains(".app/")
    }

    /// The "+ App" picker as an AppKit menu: the running apps under one
    /// section label, then the open panel. Icons are set but macOS 27 b8 draws no NSMenuItem images
    /// at all (verified standalone, SF Symbols included).
    static func appPickerMenu(
        barBundles: Set<String>,
        excluding added: Set<String>,
        onPick: @escaping (PickableApp) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        let apps = pickableRunningApps(barBundles: barBundles).filter { !added.contains($0.bundleID) }
        func add(_ app: PickableApp) {
            let item = NSMenuItem(title: app.name, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.image = app.icon
            let action = MenuAction { onPick(app) }
            item.representedObject = action
            item.target = action
            menu.addItem(item)
        }
        if !apps.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Active applications")))
        }
        apps.forEach(add)
        if !apps.isEmpty { menu.addItem(.separator()) }
        let choose = NSMenuItem(title: String(localized: "Choose an app…"), action: #selector(MenuAction.fire), keyEquivalent: "")
        let chooseAction = MenuAction {
            if let app = pickInstalledApp() { onPick(app) }
        }
        choose.representedObject = chooseAction
        choose.target = chooseAction
        menu.addItem(choose)
        return menu
    }

    /// Closure target for NSMenuItems (retained via `representedObject`).
    private final class MenuAction: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func fire() { body() }
    }

    /// Any installed app, via the open panel — for apps that aren't running
    /// right now (an "Always" launcher).
    static func pickInstalledApp() -> PickableApp? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = String(localized: "Choose an app to launch")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier
        else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return PickableApp(bundleID: bundleID, name: name, icon: icon)
    }

    /// SF Symbols has a real "airdrop" glyph on current systems; fall back to
    /// the radiating-waves look everywhere else.
    static let airdropSymbol: String = {
        NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil) != nil
            ? "airdrop"
            : "dot.radiowaves.left.and.right"
    }()

    /// Reduce Motion: the animated set renders one still "live" frame.
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func animator(for spec: ExtraItemSpec, button: NSStatusBarButton) -> ExtraAnimator {
        if let animator = animators[spec.id] { return animator }
        let animator = ExtraAnimator(button: button)
        animators[spec.id] = animator
        return animator
    }

    /// Redraws one item's glyph for its current style and state; no
    /// placement side effects, safe from `sync`.
    private func refreshGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        switch spec.kind {
        case .mediaControls: updateMediaSymbol(item, spec: spec)
        case .cameraMicIndicator: updateCameraSymbol(item, spec: spec)
        case .airdrop: updateAirDropGlyph(item, spec: spec)
        case .timer: updateTimerGlyph(item, spec: spec)
        case .timeMachine: updateTimeMachineGlyph(item, spec: spec)
        case .focus: updateFocusGlyph(item, spec: spec)
        case .shortcut, .appLauncher, .userSwitching, .siri: break
        }
    }

    /// The active mode's own symbol (macOS names it in the log line); an
    /// outlined moon while off, the way Apple's always-shown item rests.
    private func updateFocusGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        guard let button = item.button else { return }
        let symbol = focusStatus?.active?.symbol ?? "moon"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: spec.itemTitle)
            ?? NSImage(systemSymbolName: "moon.fill", accessibilityDescription: spec.itemTitle)
    }

    private func focusChanged() {
        guard let spec = specs.values.first(where: { $0.kind == .focus }),
              let item = items[spec.id] else { return }
        let active = focusStatus?.active != nil
        if active != lastFocusActive {
            applyCurrent()  // the visibility edge
        } else {
            updateFocusGlyph(item, spec: spec)  // one mode to another
        }
    }

    /// The countdown beside the glyph while a timer runs; glyph only when
    /// idle. Monospaced digits so the width holds from second to second.
    private func updateTimerGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        guard let button = item.button else { return }
        let text = pelmetTimer?.display
        let done = pelmetTimer?.state == .done
        button.image = NSImage(
            systemSymbolName: done ? "bell.fill" : "timer",
            accessibilityDescription: spec.itemTitle
        )
        if let text {
            let size = NSFont.menuBarFont(ofSize: 0).pointSize
            button.attributedTitle = NSAttributedString(
                string: " " + text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
            )
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func timerChanged() {
        guard let spec = specs.values.first(where: { $0.kind == .timer }),
              let item = items[spec.id] else { return }
        let active = pelmetTimer?.isActive ?? false
        if active != lastTimerActive {
            applyCurrent()  // the visibility override edge
        } else {
            updateTimerGlyph(item, spec: spec)
        }
    }

    /// Static: play when idle (click plays), pause while audio is running
    /// (click pauses) — the button shows the action a click will take.
    /// Animated: the bars wave while playing and settle to a resting stack
    /// when paused, Sconce's tell.
    private func updateMediaSymbol(_ item: NSStatusItem, spec: ExtraItemSpec) {
        guard let button = item.button else { return }
        if spec.resolvedStyle == .animated {
            let animator = animator(for: spec, button: button)
            animator.targetLevel = mediaPlaying ? 1 : 0
            if Self.reduceMotion {
                animator.stop()
                button.image = ExtraGlyph.mediaBars(t: 0, level: mediaPlaying ? 1 : 0, animated: false)
            } else {
                animator.run(tag: "bars", fps: ExtraGlyph.barsFPS) { t, level in
                    ExtraGlyph.mediaBars(t: t, level: level, animated: true)
                }
            }
            return
        }
        animators[spec.id]?.stop()
        button.image = NSImage(
            systemSymbolName: mediaPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: spec.itemTitle
        )
    }

    /// The drawn AirDrop mark.
    private func updateAirDropGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        item.button?.image = ExtraGlyph.airdrop
    }

    /// Apple's own faces: the clock while idle, the arrows while a backup
    /// runs, the exclamation after a failed one. Same image object each
    /// time so an unchanged state costs no replicant redraw.
    private func updateTimeMachineGlyph(_ item: NSStatusItem, spec: ExtraItemSpec) {
        let status = timeMachine?.status ?? .init()
        let image = status.running ? ExtraGlyph.timeMachineBackingUp
            : status.failed ? ExtraGlyph.timeMachineFailed
            : ExtraGlyph.timeMachineIdle
        if item.button?.image !== image { item.button?.image = image }
    }

    private func timeMachineChanged() {
        let running = timeMachine?.status.running ?? false
        if running != lastBackupRunning,
           specs.values.contains(where: { $0.kind == .timeMachine && $0.resolvedShowRule == .whenActive }) {
            applyCurrent()  // the visibility edge
            return
        }
        for (id, item) in items {
            guard let spec = specs[id], spec.kind == .timeMachine else { continue }
            updateTimeMachineGlyph(item, spec: spec)
        }
    }

    private func updateCameraSymbol(_ item: NSStatusItem, spec: ExtraItemSpec) {
        let monitor = cameraMicMonitor
        let camera = monitor?.cameraActive ?? false
        let mic = monitor?.micActive ?? false
        let symbol = camera ? "video.fill" : (mic ? "mic.fill" : "video.fill")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: String(localized: "Camera & Mic"))
        if camera || mic {
            image?.isTemplate = false
            item.button?.contentTintColor = camera ? .systemGreen : .systemOrange
        } else {
            item.button?.contentTintColor = nil
        }
        item.button?.image = image
    }

    // MARK: Actions

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard
            let statusItem = items.first(where: { $0.value.button === sender }),
            let spec = specs[statusItem.key]
        else { return }
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp

        switch spec.kind {
        case .mediaControls:
            if rightClick {
                let menu = NSMenu()
                let previous = NSMenuItem(title: String(localized: "Previous Track"), action: #selector(previousTrack), keyEquivalent: "")
                let next = NSMenuItem(title: String(localized: "Next Track"), action: #selector(nextTrack), keyEquivalent: "")
                for menuItem in [previous, next] { menuItem.target = self }
                menu.items = [previous, next]
                popUp(menu, on: statusItem.value)
            } else {
                MediaKey.playPause.send()
                mediaPlaying.toggle()
                updateMediaSymbol(statusItem.value, spec: spec)
            }
        case .cameraMicIndicator:
            // Informational; click opens Privacy settings for a quick audit.
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
            )
        case .airdrop:
            openAirDrop()
        case .shortcut:
            if let name = spec.shortcutName {
                runShortcut(named: name)
            }
        case .timer:
            guard let timer = pelmetTimer else { return }
            if timer.state == .done, !rightClick {
                timer.dismiss()
            } else {
                popUp(timerMenu(timer), on: statusItem.value)
            }
        case .userSwitching:
            popUp(usersMenu(), on: statusItem.value)
        case .timeMachine:
            // Fresh for the next open; this one shows what the poll last saw.
            timeMachine?.refresh()
            popUp(timeMachineMenu(), on: statusItem.value)
        case .siri:
            if rightClick {
                let menu = NSMenu()
                let settings = NSMenuItem(title: String(localized: "Siri Settings…"), action: #selector(siriSettings), keyEquivalent: "")
                settings.target = self
                menu.items = [settings]
                popUp(menu, on: statusItem.value)
            } else {
                Siri.activate()
            }
        case .focus:
            if rightClick {
                let menu = NSMenu()
                let settings = NSMenuItem(title: String(localized: "Focus Settings…"), action: #selector(focusSettings), keyEquivalent: "")
                settings.target = self
                menu.items = [settings]
                popUp(menu, on: statusItem.value)
            } else {
                ControlCenterFocus.toggle()
            }
        case .appLauncher:
            if rightClick, Self.isRunning(spec), let bundleID = spec.bundleID {
                let menu = NSMenu()
                let quit = NSMenuItem(
                    title: String(localized: "Quit \(spec.appName ?? bundleID)"),
                    action: #selector(quitApp(_:)),
                    keyEquivalent: ""
                )
                quit.target = self
                quit.representedObject = bundleID
                menu.items = [quit]
                popUp(menu, on: statusItem.value)
            } else {
                openApp(spec)
            }
        }
    }

    private func popUp(_ menu: NSMenu, on item: NSStatusItem) {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func previousTrack() { MediaKey.previous.send() }
    @objc private func nextTrack() { MediaKey.next.send() }

    // MARK: Timer menu

    private func timerMenu(_ timer: PelmetTimer) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, tag: Int = 0) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.tag = tag
            menu.addItem(entry)
        }
        switch timer.state {
        case .idle:
            for duration in PelmetTimer.presets {
                add(PelmetTimer.label(for: duration), #selector(startTimer(_:)), tag: Int(duration))
            }
            menu.addItem(.separator())
            add(String(localized: "Custom…"), #selector(customTimer))
        case .running, .paused:
            if let display = timer.display {
                let header = NSMenuItem(title: String(localized: "\(display) left"), action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                menu.addItem(.separator())
            }
            if case .running = timer.state {
                add(String(localized: "Pause"), #selector(pauseTimer))
            } else {
                add(String(localized: "Resume"), #selector(resumeTimer))
            }
            add(String(localized: "Add a minute"), #selector(addTimerMinute))
            menu.addItem(.separator())
            add(String(localized: "Cancel timer"), #selector(cancelTimer))
        case .done:
            add(String(localized: "Dismiss"), #selector(dismissTimer))
        }
        return menu
    }

    @objc private func startTimer(_ sender: NSMenuItem) {
        pelmetTimer?.start(TimeInterval(sender.tag))
    }

    @objc private func customTimer() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Timer")
        alert.informativeText = String(localized: "Minutes")
        alert.addButton(withTitle: String(localized: "Start"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.placeholderString = "10"
        field.alignment = .center
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let minutes = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard minutes > 0 else { return }
        pelmetTimer?.start(minutes * 60)
    }

    @objc private func pauseTimer() { pelmetTimer?.pause() }
    @objc private func resumeTimer() { pelmetTimer?.resume() }
    @objc private func addTimerMinute() { pelmetTimer?.addMinute() }
    @objc private func cancelTimer() { pelmetTimer?.cancel() }
    @objc private func dismissTimer() { pelmetTimer?.dismiss() }

    // MARK: Users menu

    private func usersMenu() -> NSMenu {
        let menu = NSMenu()
        let me = NSMenuItem(title: UserSwitching.current.fullName, action: nil, keyEquivalent: "")
        me.isEnabled = false
        menu.addItem(me)
        let others = UserSwitching.otherAccounts()
        if !others.isEmpty {
            menu.addItem(.separator())
            for account in others {
                let entry = NSMenuItem(title: account.fullName, action: #selector(switchUser(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = account.name
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        for (title, action) in [
            (String(localized: "Login Window…"), #selector(loginWindow)),
            (String(localized: "Lock Screen"), #selector(lockScreen)),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Users & Groups Settings…"), action: #selector(usersSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func switchUser(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let account = UserSwitching.otherAccounts().first(where: { $0.name == name }) else { return }
        UserSwitching.switchTo(account)
    }

    @objc private func loginWindow() { UserSwitching.switchToLoginWindow() }
    @objc private func lockScreen() { UserSwitching.lockScreen() }
    @objc private func usersSettings() { UserSwitching.openUsersSettings() }

    // MARK: Time Machine menu

    /// Apple's menu, line for line: the state on top, then the verbs.
    private func timeMachineMenu() -> NSMenu {
        let menu = NSMenu()
        func label(_ title: String) {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        func verb(_ title: String, _ action: Selector) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        let status = timeMachine?.status ?? .init()
        if status.running {
            if status.stopping {
                label(String(localized: "Stopping Backup…"))
            } else if let percent = status.percent {
                label(String(localized: "Backing Up: \(Int((percent * 100).rounded()))%"))
            } else if status.phase == "Finishing" || status.phase?.hasPrefix("Thinning") == true {
                label(String(localized: "Finishing Backup…"))
            } else {
                label(String(localized: "Preparing Backup…"))
            }
        } else if let destination = TimeMachineBackup.destination() {
            if let latest = destination.latestBackup {
                label(String(localized: "Latest Backup to “\(destination.name)”"))
                label(Self.backupDateFormatter.string(from: latest))
            } else {
                label(String(localized: "Waiting to Complete First Backup"))
            }
            if destination.failed {
                label(String(localized: "Backup Failed…"))
            }
        } else {
            label(String(localized: "No Backup Disk Selected"))
        }
        menu.addItem(.separator())
        if status.running, !status.stopping {
            verb(String(localized: "Skip This Backup"), #selector(skipBackup))
        } else {
            verb(String(localized: "Back Up Now"), #selector(backUpNow))
        }
        menu.addItem(.separator())
        verb(String(localized: "Browse Time Machine Backups"), #selector(browseBackups))
        menu.addItem(.separator())
        verb(String(localized: "Open Time Machine Settings…"), #selector(timeMachineSettings))
        return menu
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    @objc private func backUpNow() { timeMachine?.backUpNow() }
    @objc private func skipBackup() { timeMachine?.skipBackup() }
    @objc private func browseBackups() { TimeMachineBackup.browseBackups() }
    @objc private func timeMachineSettings() { TimeMachineBackup.openSettings() }
    @objc private func siriSettings() { Siri.openSettings() }
    @objc private func focusSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
    }

    private func openAirDrop() {
        // Finder's AirDrop view via its keyboard shortcut (⇧⌘R) — the only
        // stable public entry point. The chord is posted globally, so ONLY
        // post it once Finder actually owns the keyboard: on a slow
        // activation the chord would land in whatever is frontmost instead
        // (⇧⌘R is Reply-All in Mail, Reader in Safari…). Retry briefly, then
        // give up silently.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        postAirDropChordWhenFinderFrontmost(attempt: 0)
    }

    private func postAirDropChordWhenFinderFrontmost(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
                if attempt < 4 {
                    self.postAirDropChordWhenFinderFrontmost(attempt: attempt + 1)
                }
                return
            }
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 15 /* R */, keyDown: down)
                event?.flags = [.maskCommand, .maskShift]
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func runShortcut(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        try? process.run()
    }

    /// Names from the user's Shortcuts library (for the picker).
    nonisolated static func availableShortcuts() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        // Read BEFORE waiting: with output past the 64KB pipe buffer, the
        // child blocks on write and waitUntilExit never returns.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Camera / mic activity

/// "Is any camera/mic in use" via public CoreMediaIO / CoreAudio properties
/// (the OverSight approach) — EVENT-DRIVEN: `DeviceIsRunningSomewhere`
/// property listeners per device (plus device-list listeners for hot-plug)
/// re-poll on change, and a slow 30s fallback timer covers the media-linger
/// expiry and any listener the OS fails to deliver. The original 2s poll was
/// Pelmet's only steady idle wakeup.
final class CameraMicMonitor {
    private(set) var cameraActive = false
    private(set) var micActive = false
    /// Any audio OUTPUT device running — the "something is playing" signal.
    private(set) var audioOutputActive = false
    private(set) var lastAudioActiveAt: Date = .distantPast
    private var timer: Timer?
    private let onChange: () -> Void
    // nonisolated(unsafe): mutated only on the main actor (install/remove),
    // but deinit must read them to unhook the HAL — Swift 6 bars isolated
    // property access from deinitializers.
    private nonisolated(unsafe) var audioListenerDevices: [AudioObjectID] = []
    private nonisolated(unsafe) var cmioListenerDevices: [CMIOObjectID] = []
    // C-function-pointer listeners, NOT the *ListenerBlock variants: the HAL
    // matches removals by block identity, and Swift re-bridges a closure to a
    // fresh block object on every call — so block removals never matched,
    // listeners accumulated across reinstalls, and each device event fanned
    // out into a main-thread reinstall storm (the 2026-08-21 beachball).
    // Function pointer + clientData compare reliably. Callbacks arrive on a
    // HAL thread; hop to main before touching state.
    private nonisolated static let audioListenerProc: AudioObjectPropertyListenerProc = { _, count, addresses, clientData in
        guard let clientData else { return noErr }
        let monitor = Unmanaged<CameraMicMonitor>.fromOpaque(clientData).takeUnretainedValue()
        let listChanged = UnsafeBufferPointer(start: addresses, count: Int(count))
            .contains { $0.mSelector == kAudioHardwarePropertyDevices }
        DispatchQueue.main.async {
            listChanged ? monitor.deviceListChanged() : monitor.poll()
        }
        return noErr
    }
    private nonisolated static let cmioListenerProc: CMIOObjectPropertyListenerProc = { _, count, addresses, clientData in
        guard let clientData else { return noErr }
        let monitor = Unmanaged<CameraMicMonitor>.fromOpaque(clientData).takeUnretainedValue()
        let listChanged = UnsafeBufferPointer(start: addresses, count: Int(count))
            .contains { $0.mSelector == CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices) }
        DispatchQueue.main.async {
            listChanged ? monitor.deviceListChanged() : monitor.poll()
        }
        return noErr
    }

    var isActive: Bool { cameraActive || micActive }

    /// Playing now, or within the linger window — so pausing music doesn't
    /// swallow the resume button. (Apple keeps Now Playing for the paused
    /// session via private API; the linger is the honest approximation.)
    var mediaRelevant: Bool {
        audioOutputActive || Date().timeIntervalSince(lastAudioActiveAt) < 300
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Fallback only: catches the media-linger window expiring (a pure
        // wall-clock transition no listener fires for) and any missed
        // listener delivery. Generous tolerance = coalesced wakeups.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 5
        installListeners()
        poll()
    }

    // stop() is the normal teardown (ExtrasManager removes the entry);
    // deinit is the guard rail — a release without stop() would leave the
    // HAL dispatching to a dangling clientData pointer. The timer is left
    // to its weak-self no-op (invalidating cross-thread from deinit is
    // unsafe); the HAL pointer is the real hazard.
    deinit {
        Self.removeCListeners(
            selfPtr: Unmanaged.passUnretained(self).toOpaque(),
            audioDevices: audioListenerDevices,
            cmioDevices: cmioListenerDevices
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removeListeners()
    }

    /// Device topology changed (hot-plug) — re-install the per-device
    /// listeners. Running-state changes skip this and go straight to poll().
    private func deviceListChanged() {
        removeListeners()
        installListeners()
        poll()
    }

    private func installListeners() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // System object: device list changes (hot-plug).
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, Self.audioListenerProc, selfPtr
        )
        for deviceID in Self.allAudioDeviceIDs() {
            if AudioObjectAddPropertyListener(deviceID, &runningAddress, Self.audioListenerProc, selfPtr) == noErr {
                audioListenerDevices.append(deviceID)
            }
        }

        var cmioRunning = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var cmioDevices = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectAddPropertyListener(
            CMIOObjectID(kCMIOObjectSystemObject), &cmioDevices, Self.cmioListenerProc, selfPtr
        )
        for deviceID in Self.allCMIODeviceIDs() {
            if CMIOObjectAddPropertyListener(deviceID, &cmioRunning, Self.cmioListenerProc, selfPtr) == noErr {
                cmioListenerDevices.append(deviceID)
            }
        }
    }

    private func removeListeners() {
        Self.removeCListeners(
            selfPtr: Unmanaged.passUnretained(self).toOpaque(),
            audioDevices: audioListenerDevices,
            cmioDevices: cmioListenerDevices
        )
        audioListenerDevices = []
        cmioListenerDevices = []
    }

    /// Static + nonisolated so deinit can reach it: removal matches by
    /// (proc, clientData) identity, so it needs only the pointer and the
    /// device lists — not isolated state access.
    private nonisolated static func removeCListeners(
        selfPtr: UnsafeMutableRawPointer,
        audioDevices: [AudioObjectID],
        cmioDevices cmioDeviceList: [CMIOObjectID]
    ) {
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, Self.audioListenerProc, selfPtr
        )
        for deviceID in audioDevices {
            AudioObjectRemovePropertyListener(deviceID, &runningAddress, Self.audioListenerProc, selfPtr)
        }

        var cmioRunning = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var cmioDevices = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectRemovePropertyListener(
            CMIOObjectID(kCMIOObjectSystemObject), &cmioDevices, Self.cmioListenerProc, selfPtr
        )
        for deviceID in cmioDeviceList {
            CMIOObjectRemovePropertyListener(deviceID, &cmioRunning, Self.cmioListenerProc, selfPtr)
        }
    }

    private static func allAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }
        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }
        return deviceIDs
    }

    private static func allCMIODeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }
        var deviceIDs = [CMIOObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &dataUsed, &deviceIDs
        ) == noErr else { return [] }
        return deviceIDs
    }

    private func poll() {
        let camera = Self.anyCameraRunning()
        let mic = Self.anyMicRunning()
        let audio = Self.anyOutputRunning()
        if audio { lastAudioActiveAt = Date() }
        let relevantNow = mediaRelevant
        if camera != cameraActive || mic != micActive || audio != audioOutputActive
            || relevantNow != lastMediaRelevant {
            cameraActive = camera
            micActive = mic
            audioOutputActive = audio
            lastMediaRelevant = relevantNow
            onChange()
        }
    }

    private var lastMediaRelevant = true

    private static func anyOutputRunning() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return false }
        for deviceID in deviceIDs {
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    private static func anyCameraRunning() -> Bool {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataUsed, &deviceIDs
        ) == noErr else { return false }

        var runningAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        for deviceID in deviceIDs {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(deviceID, &runningAddress, 0, nil, size, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    private static func anyMicRunning() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return false }

        for deviceID in deviceIDs {
            // Input side only.
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { continue }

            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}
