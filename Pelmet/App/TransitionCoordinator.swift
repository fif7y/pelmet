// TransitionCoordinator.swift
// Reveal/conceal execution, extracted from AppState.dispatch: the overlay
// cover lifecycle (pre-captured reveal cover, conceal ghost, swap-quiet
// holds) around the engine transition. The rehide state machine stays in
// AppState — settle re-entry goes through the onSettled callbacks.

import AppKit
import PelmetCore
import PelmetEngine

/// A style is two moves performed by pictures over the covered bar. Adding a
/// style: a case in `RevealAnimation`, a recipe here, a picker entry.
struct AnimationRecipe {
    enum Move {
        /// There, or gone, in one frame.
        case pop
        /// Opacity only — the picture never moves, so the background under
        /// it never smears (an opaque strip is fine).
        case fade(CFTimeInterval)
        /// Toward/from the chevron by `dx` points with a fade — needs the
        /// icons cut out against the empty bar.
        case slide(dx: CGFloat, CFTimeInterval)

        var needsCutOut: Bool {
            if case .slide = self { return true }
            return false
        }
    }

    let entrance: Move
    let exit: Move

    static func recipe(for style: RevealAnimation) -> AnimationRecipe {
        switch style {
        case .instant: AnimationRecipe(entrance: .pop, exit: .pop)
        case .fade: AnimationRecipe(entrance: .fade(AppTiming.fadeRevealDuration), exit: .fade(AppTiming.fadeExitDuration))
        case .smooth: AnimationRecipe(entrance: .slide(dx: 96, AppTiming.smoothRevealDuration), exit: .slide(dx: 64, AppTiming.smoothExitDuration))
        }
    }
}

@MainActor
final class TransitionCoordinator {
    private weak var appState: AppState?
    private let engine: AgentBarEngine

    init(appState: AppState, engine: AgentBarEngine) {
        self.appState = appState
        self.engine = engine
        backdropWatch.start()
    }

    /// The bar is glass — a window parked under it tints the pictures, and
    /// a window that then moves leaves its edge baked into every reveal
    /// (#33). Checked off the reveal path, on the signals that end a
    /// window move; a changed backdrop drops the stale pictures. The
    /// empty-bar one is retaken on approach, not at once (#49): a window
    /// flickering in and out of the zone on every mouse-up retook it ~40
    /// times per reveal on a four-display Mac, every capture lighting the
    /// screen-recording indicator, while the picture is only ever read at
    /// a reveal. The pointer entering the hover zone is the first sign one
    /// is coming; the reveal itself starts the capture when nothing did.
    private lazy var backdropWatch = BackdropWatch { [weak self] in self?.backdropMayHaveChanged() }
    /// `ConcealGhostOverlay.backdropSignature` at the time each picture was taken.
    private var revealCoverBackdrop: [Int] = []
    private var revealedStripBackdrop: [Int] = []
    /// The cover was dropped for a changed backdrop and not retaken yet.
    private var revealCoverWanted = false
    private var precaptureInFlight = false
    /// The dropped cover, kept with the signature it was taken under. Most
    /// changes are one window in and out of the zone (#49's log: 9→8→9;
    /// Notification Center opening and closing under the clock): when the
    /// backdrop comes back exactly, the picture is true again, no capture.
    private var parkedCover: (snapshot: [ConcealGhostOverlay.BarSnapshot], backdrop: [Int], display: CGDirectDisplayID?, underPanel: Bool)?
    /// Notification Center's panel was under the bar when the idle picture
    /// was taken (its shade is in the pixels).
    private var revealCoverUnderPanel = false
    /// The bar as it looks under Notification Center's open panel, over the
    /// blink cover's span: taken once after an entrance blink (the panel is
    /// open, the bar quiet), kept while the backdrop, wallpaper and active
    /// display hold. The entrance blink swaps to it once the panel has slid
    /// in: from then on nothing moves under the bar, and a still of that
    /// state is exact (#51).

    private func backdropMayHaveChanged() {
        guard let appState, !revealCoverSnapshot.isEmpty || !revealedStripSnapshot.isEmpty || parkedCover != nil else { return }
        let list = ConcealGhostOverlay.onScreenWindows()
        let now = ConcealGhostOverlay.backdropSignature(of: precaptureRect, in: list) + ConcealGhostOverlay.surfaceSignature()
        if revealCoverSnapshot.isEmpty, let parked = parkedCover, parked.backdrop == now, appState.currentRevealedSections.isEmpty {
            revealCoverSnapshot = parked.snapshot
            revealCoverBackdrop = parked.backdrop
            revealCoverActiveDisplay = parked.display
            revealCoverUnderPanel = parked.underPanel
            parkedCover = nil
            revealCoverWanted = false
            PelmetLog.log("backdrop: back as it was (\((now.count - ConcealGhostOverlay.surfaceSignatureCount) / 5) window(s)) — cover restored, no capture")
        }
        let coverStale = !revealCoverSnapshot.isEmpty && now != revealCoverBackdrop
        let stripStale = !revealedStripSnapshot.isEmpty && revealedStripBackground.isEmpty && now != revealedStripBackdrop
        guard coverStale || stripStale else { return }
        let concealed = appState.currentRevealedSections.isEmpty
        // A stale picture is worse than none: the reveal captures live
        // instead. The cover returns at the next conceal settle if not
        // right now. The finished picture only returns at a reveal settle,
        // and every reveal until then paid the cover-only path (#35) — so
        // when the empty bar it was taken over is still here, keep both:
        // the icons cut out against that empty bar are true whatever moved
        // beneath, and the next reveal composites them over the fresh cover.
        let stripCutOut = stripStale && !revealCoverSnapshot.isEmpty && revealCoverBackdrop == revealedStripBackdrop
        let movers = ConcealGhostOverlay.backdropMovers(from: coverStale ? revealCoverBackdrop : revealedStripBackdrop, to: now, in: list)
        PelmetLog.log("backdrop: changed under the bar (\((now.count - ConcealGhostOverlay.surfaceSignatureCount) / 5) window(s): \(movers)) — cover \(coverStale ? (concealed ? "dropped, retake on approach" : "dropped") : "kept"), finished \(stripStale ? (stripCutOut ? "kept as a cut-out" : "dropped") : "kept")")
        if stripCutOut {
            revealedStripBackground = revealCoverSnapshot
        } else if stripStale {
            revealedStripSnapshot = []
        }
        if coverStale {
            parkedCover = concealed ? (revealCoverSnapshot, revealCoverBackdrop, revealCoverActiveDisplay, revealCoverUnderPanel) : nil
            revealCoverSnapshot = []
            revealCoverWanted = concealed
        }
    }


    /// Notification Center was just dismissed from the clock: once its
    /// slide is over and its window has left the list (~0.6s), take the
    /// bare picture the next click or reveal will want.
    func precaptureAfterPanel() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard revealCoverSnapshot.isEmpty || revealCoverUnderPanel else { return }
            scheduleRevealCoverPrecapture(afterConceal: false)
        }
    }

    /// The pointer entered the hover zone: a reveal is likely within the
    /// hover delay or a click. Retake the dropped cover now so it is ready
    /// (~90ms on Gab's Mac, 150–466ms on #49's), and only now.
    func pointerApproachedBar() {
        guard revealCoverWanted, !precaptureInFlight, revealCoverSnapshot.isEmpty,
              appState?.currentRevealedSections.isEmpty == true else { return }
        PelmetLog.log("cover: retaking on approach")
        scheduleRevealCoverPrecapture(afterConceal: false)
    }

    /// A reveal with the cover still wanted: start the capture if nothing
    /// did (the same live capture the no-picture path pays, minus the
    /// Smooth exemption it keeps), then wait for whichever is in flight —
    /// bounded, so a slow capture degrades to the uncovered reveal it
    /// always was rather than holding the bar.
    private func awaitCoverRetake(style: RevealAnimation) async {
        guard revealCoverSnapshot.isEmpty, precaptureInFlight || (revealCoverWanted && style != .smooth) else { return }
        if !precaptureInFlight {
            PelmetLog.log("cover: retaking at the reveal")
            scheduleRevealCoverPrecapture(afterConceal: false)
        }
        let started = Date()
        while precaptureInFlight, Date().timeIntervalSince(started) < AppTiming.coverRetakeWait {
            try? await Task.sleep(for: .milliseconds(15))
        }
        PelmetLog.log("cover: waited \(Int(-started.timeIntervalSinceNow * 1000))ms for the retake — \(revealCoverSnapshot.isEmpty ? "not ready" : "ready")")
    }

    /// Settle re-entry into AppState (rehide machine, settle catch-up,
    /// placement flush / hover re-arm). Wired once at boot.
    var onRevealSettled: (() -> Void)?
    var onConcealSettled: (() -> Void)?

    /// Where the concealed strip last sat — icons reappear in the same spot,
    /// so this rect is the reveal cover's footprint (Instant/Fade styles).
    private var lastConcealedStripRect: CGRect?

    /// Empty-strip snapshot pre-captured while the bar idles concealed — the
    /// reveal path floats it synchronously instead of paying ~100ms+ of SCK
    /// capture before the swap can even start (snappiness).
    private var revealCoverSnapshot: [ConcealGhostOverlay.BarSnapshot] = []
    /// The active display (see `AppState.lastMouseDownDisplay`) when each
    /// picture was taken. macOS dims the bar on every other display, so a
    /// picture is only true while the same display stays active: a click
    /// on a dimmed bar activates it as the reveal starts, and the stale
    /// picture floated over it showed the dim bar going bright as it
    /// lifted — the whole bar blinking (Gab, 2026-09-16, three displays).
    private var revealCoverActiveDisplay: CGDirectDisplayID?
    private var revealedStripActiveDisplay: CGDirectDisplayID?

    /// The widest strip any conceal has measured (left edge only — the
    /// right edge is the same chevron/visible cluster every time). A
    /// hidden-only conceal remembers a short strip; the next full reveal
    /// then slid the always-hidden cluster in UNCOVERED left of it (Sconce's
    /// bar: cover 249px @1352, items landing from 1075 — 2026-09-05).
    private var widestStripMinX: CGFloat?
    /// Concealable items in the last engine snapshot — the floor for the
    /// cover's width before any full conceal has measured the real strip.
    private var concealableCount = 0
    /// Per-item width for that estimate: icons run ~30–36pt with padding,
    /// separators less. Over-covering is free — the cover is a snapshot of
    /// the empty bar floated over the empty bar.
    private static let estimatedItemWidth: CGFloat = 36
    /// The reveal cover's footprint: the remembered strip, widened to the
    /// widest strip ever measured (or the item-count estimate) and padded
    /// generously — left is the slide origin (empty bar, free to cover),
    /// right catches the visible cluster shifting. Strip width drifts
    /// between conceals.
    private var revealCoverRect: CGRect? {
        lastConcealedStripRect.map {
            let estimatedMinX = $0.maxX - CGFloat(concealableCount) * Self.estimatedItemWidth
            let minX = min($0.minX, widestStripMinX ?? $0.minX, estimatedMinX)
            return CGRect(x: minX - 120, y: $0.minY, width: ($0.maxX - minX) + 180, height: $0.height)
        }
    }
    /// What the idle capture actually takes: the reveal cover widened to the
    /// blink's footprint, so one picture serves both and the blink needs no
    /// capture at the click (#45, #46). A wider picture of a static bar is
    /// free — it is taken while the bar idles concealed, and each consumer
    /// crops back to its own rect.
    private var precaptureRect: CGRect? {
        // No strip known yet (no conceal since launch, or a boot that
        // could not seed one): the blink's own rect still serves every
        // clock click (#51: nothing was ever precaptured after a relaunch,
        // every entrance captured live, no under-panel picture existed).
        let blink = barCoverGeometry().map { barCoverRect($0) }
        guard let reveal = revealCoverRect else { return blink }
        guard let blink else { return reveal }
        return reveal.union(blink)
    }
    /// Strip and cover rects are primary-band geometry: an external's copy
    /// of an item stretched the strip across displays (`1278..4887`) and
    /// the blink cover to `-906..1676`, a capture spanning two bars.
    private var primaryMaxX: CGFloat { NSScreen.screens.first?.frame.maxX ?? .greatestFiniteMagnitude }

    /// Before the first click of the session the active display is
    /// unknown; the one under the pointer is the one macOS most likely
    /// draws bright, and the one the first click most likely lands on. A
    /// nil stamp made every boot picture unusable at the first reveal
    /// ("another active display (0 → 1)"), one reason the first reveal of
    /// a session was slow.
    private static var displayUnderPointer: CGDirectDisplayID? { NSScreen.underPointer?.directDisplayID }

    private func rememberStrip(_ strip: CGRect?) {
        lastConcealedStripRect = strip
        guard let strip else { return }
        widestStripMinX = min(widestStripMinX ?? strip.minX, strip.minX)
    }

    func performReveal(_ sections: Set<PelmetCore.Section>, trace: PerfTrace) {
        Task {
            guard let appState else { return }
            let style = appState.settings.revealAnimation
            let recipe = AnimationRecipe.recipe(for: style)
            // Two pictures make the style: the empty bar (hides the agent's
            // slide-in) and the strip as it looks revealed and at rest
            // (taken at the last reveal settle). The finished picture
            // performs the entrance over the cover; both lift once the real
            // icons are at rest beneath, which is invisible. Missing
            // pictures degrade: cover alone → the agent's slide is hidden
            // and the cover lifts with the exit-style move; nothing → the
            // agent's slide shows.
            var cover: ConcealGhostOverlay.GhostSet?
            var finished: ConcealGhostOverlay.GhostSet?
            // A wallpaper or appearance change between two mouse-ups has no
            // signal of its own: look once more before trusting the picture.
            backdropMayHaveChanged()
            await awaitCoverRetake(style: style)
            let emptyBar = freshEmptyBarSnapshots()
            let coverSource = !emptyBar.isEmpty ? "precaptured" : style != .smooth ? "live capture" : "none"
            if !emptyBar.isEmpty {
                // The still shows the collapsed glyph; a hole over the
                // glyph's core lets the live chevron (flipped at the swap)
                // show through without exposing a neighbor's edge.
                cover = ConcealGhostOverlay.begin(
                    from: punchedCover(emptyBar, columns: chevronPunch.map { ($0.lowerBound + 6)...($0.upperBound - 6) }),
                    safety: AppTiming.transitionCoverSafety
                )
            } else if style != .smooth {
                cover = await ConcealGhostOverlay.begin(over: revealCoverRect, safety: AppTiming.transitionCoverSafety)
            }
            trace.mark("cover", detail: coverSource)
            lastRevealedSections = sections
            if cover != nil, sections == [.hidden], revealedStripUsable {
                var picture: [ConcealGhostOverlay.BarSnapshot]? = revealedStripSnapshot
                let shift = revealedStripShift
                if shift != 0, let then = revealedStripChevronX {
                    // Cut out at the picture's own geometry (punch and keep
                    // in its coordinates: the hidden run is everything left
                    // of the chevron as it was), then float shifted.
                    let punch = chevronPunch.map { ($0.lowerBound - shift)...($0.upperBound - shift) }
                    let keep: ClosedRange<CGFloat>? = revealedStripSnapshot.first.map { ($0.windowFrame.minX)...(then - 1) }
                    picture = cutOutPicture(revealedStripSnapshot, background: emptyBar, punch: punch, keep: keep)?
                        .map { ConcealGhostOverlay.BarSnapshot(image: $0.image, windowFrame: $0.windowFrame.offsetBy(dx: shift, dy: 0), takenAt: $0.takenAt) }
                    PelmetLog.log("finished: chevron moved since the picture (\(then) → \(then + shift)) — \(picture == nil ? "cut-out failed, cover only" : "icons cut out and shifted \(Int(shift))pt")")
                } else if recipe.entrance.needsCutOut || revealedStripCutOut {
                    // Against the empty bar the picture was taken over: the
                    // fresh cover when nothing moved (and for the boot
                    // picture), the kept one when the backdrop changed
                    // since (see backdropMayHaveChanged).
                    picture = cutOutPicture(
                        revealedStripSnapshot, background: revealedStripBackground.isEmpty ? emptyBar : revealedStripBackground,
                        punch: chevronPunch(clearingFrom: lastConcealedStripRect?.maxX),
                        keep: revealedStripKeep ?? entranceKeep
                    )
                    if revealedStripCutOut {
                        PelmetLog.log("finished: \(picture == nil ? "cut-out failed, cover only" : "cut out over the fresh cover")\(revealedStripKeep == nil ? "" : " (boot picture)")")
                        // A failed cut-out against a kept background won't
                        // succeed next time either: let the next settle
                        // take a fresh picture. The boot picture only
                        // lacked a cover; it waits for one.
                        if picture == nil, !revealedStripBackground.isEmpty {
                            revealedStripSnapshot = []; revealedStripBackground = []; revealedStripKeep = nil
                        }
                    }
                }
                if let picture {
                    let startsHidden: Bool = { if case .pop = recipe.entrance { return false } else { return true } }()
                    finished = ConcealGhostOverlay.begin(
                        from: picture, safety: AppTiming.transitionCoverSafety, startHidden: startsHidden
                    )
                    finished?.animate(recipe.entrance, entering: true)
                }
            }
            if cover != nil, finished == nil, style == .smooth {
                // No finished picture: a Smooth cover would only hide the
                // agent's slide and pop — let the slide show instead.
                cover?.dismiss()
                cover = nil
            }
            if finished != nil { trace.mark("finished") }
            if cover == nil {
                // Nothing hides the agent's slide-in: own items join the
                // layout first so it animates around them.
                await appState.preattachOwnItems(revealing: sections)
                trace.mark("preattach")
            }
            PelmetLog.log("effect reveal \(sections) → engine (anim=\(style.rawValue), cover=\(cover != nil), finished=\(finished != nil))")
            await engine.reveal(sections)
            trace.mark("engine")
            trace.note(await engine.lastConvergeTiming)
            appState.updateSnapshot(await engine.snapshot())
            if let cover {
                // Hold until the engine is swap-quiet (under rapid hover
                // cycles the real swap can land AFTER the settle report)
                // AND until the agent's slide-in and the separators' attach
                // reflow are over — lifting on swap-quiet alone showed the
                // hidden icons jump a few points as the bar finished
                // settling beneath the picture (Gab, 2026-09-08).
                let liftAt = Date().addingTimeInterval(AppTiming.entranceCoverHold)
                Task { @MainActor in
                    await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                    let remaining = liftAt.timeIntervalSinceNow
                    if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                    if let finished {
                        finished.dismiss()
                        cover.dismiss()
                    } else if case .fade(let duration) = recipe.exit {
                        cover.fadeOut(duration: duration)
                    } else {
                        cover.dismiss()
                    }
                    trace.finish("lift")
                }
            }
            PelmetLog.log("effect reveal settled")
            onRevealSettled?()
            trace.mark("settled")
            if cover == nil { trace.finish("uncovered") }
            scheduleRevealedStripPrecapture()
        }
    }

    func performConceal(trace: PerfTrace) {
        Task {
            guard let appState else { return }
            let style = appState.settings.revealAnimation
            let recipe = AnimationRecipe.recipe(for: style)
            // Mirror of the reveal: the empty-bar picture over the strip
            // hides the agent's own fade, and a live capture of the icons
            // (opaque for a fade, cut out for a slide) performs the exit
            // from the moment the swap lands. Nothing to capture → the
            // agent's fade shows as is.
            let stripRect = await concealStripFrames()
            trace.mark("strip", detail: await engine.restSnapshot == nil ? "walked" : "mirror")
            rememberStrip(stripRect)
            // A reveal shorter than the settle precapture (~1s) never got
            // its finished picture, and every reveal after paid the
            // cover-only path — 0.6s from the click to the icons on each
            // toggle (#35). The strip is still up and at rest: take it now.
            if lastRevealedSections == [.hidden], let why = revealedStripProblem {
                await takeRevealedStripPicture(reason: "conceal (\(why))")
            }
            let emptyBar = freshEmptyBarSnapshots()
            var cover: ConcealGhostOverlay.GhostSet?
            var strip: ConcealGhostOverlay.GhostSet?
            // No chevron hole on the way out: the empty-bar still already
            // shows the collapsed glyph, and on a bar where the chevron
            // shifts as Pelmet's extras collapse the hole ended up over the
            // last hidden icon, showing a sliver of it fading (Gab).
            let emptyCover = emptyBar
            switch recipe.exit {
            case .pop:
                cover = ConcealGhostOverlay.begin(from: emptyCover, safety: AppTiming.transitionCoverSafety)
            case .fade:
                let icons = await ConcealGhostOverlay.snapshotSet(of: stripRect)
                strip = ConcealGhostOverlay.begin(from: icons, safety: AppTiming.transitionCoverSafety)
            case .slide:
                if !emptyBar.isEmpty {
                    let icons = await ConcealGhostOverlay.snapshotSet(of: stripRect)
                    if let cut = ConcealGhostOverlay.iconsOnly(icons, background: emptyBar, punch: chevronPunch(clearingFrom: stripRect?.maxX)) {
                        cover = ConcealGhostOverlay.begin(from: emptyCover, safety: AppTiming.transitionCoverSafety)
                        strip = ConcealGhostOverlay.begin(from: cut, safety: AppTiming.transitionCoverSafety)
                    }
                }
            }
            trace.mark("cover", detail: "\(emptyBar.isEmpty ? "none" : "precaptured")\(strip != nil ? ", strip captured live" : "")")
            PelmetLog.log("effect conceal → engine (anim=\(style.rawValue), cover=\(cover != nil), strip=\(strip != nil))")
            await engine.conceal()
            trace.mark("engine")
            trace.note(await engine.lastConvergeTiming)
            // The strip's move starts the moment the swap has landed — the
            // real icons fade beneath an opaque picture, nothing can bounce.
            // Before the snapshot walk: that AX pass alone is ~100ms.
            strip?.animate(recipe.exit, entering: false)
            appState.updateSnapshot(await engine.snapshot())
            // The empty-bar cover lifts on swap-quiet.
            if let cover {
                // The agent's own fade beneath runs ~300ms past the swap
                // (measured 2026-09-08) — lifting the cover on swap-quiet
                // alone (150ms) showed its tail. Hold for both.
                let liftAt = Date().addingTimeInterval(AppTiming.exitCoverHold)
                Task { @MainActor in
                    await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                    let remaining = liftAt.timeIntervalSinceNow
                    if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                    cover.dismiss()
                    trace.finish("lift")
                }
            }
            PelmetLog.log("effect conceal settled")
            onConcealSettled?()
            trace.mark("settled")
            if cover == nil { trace.finish("uncovered") }
            scheduleRevealCoverPrecapture()
        }
    }

    /// Covers a deliberate assertion drop. Two callers drop it and take it
    /// straight back: the clock blink (see AppState.clockClicked) and an
    /// adoption window (the agent refuses to attach a newly registered item
    /// while ANY assertion is held, so the only way in is to let go — #31).
    /// Until the re-acquire lands the agent slides every hidden icon in AND
    /// brings back the system extras the assertion keeps out (Now Playing
    /// lands in the visible cluster, shifting the chevron).
    /// A live picture of the bar from its leftmost item to the clock's left
    /// edge, floated before the drop, hides the whole round trip in either
    /// state — concealed or hover-revealed — since it is the bar as it
    /// looks right now. The clock stays uncovered (it never moves: the
    /// right zone is fixed) and the pre-captured empty-bar still is no use
    /// here: it stops at the strip, right where the extras reappear.
    /// Where a bar cover has to sit: from the leftmost place a dropped
    /// assertion can slide an icon into, to the clock's left edge.
    /// `beginBarCover` captures it; `scheduleRevealCoverPrecapture` widens
    /// the idle picture to hold it, so the blink can cut its cover out of
    /// that picture instead of paying a capture at the click.
    private struct BarCoverGeometry {
        let minX: CGFloat
        /// The clock's left edge: the cover runs to it. Ending at the
        /// leftmost live icon instead (tried 2026-09-22) let the visible
        /// cluster show its own change during the drop: Pelmet's own items
        /// trade places with the system's and the cluster shifts (Gab:
        /// "the icons change since the Pelmet icon goes away").
        let anchorMinX: CGFloat
        /// Where the cover ends: the display's right edge (less the
        /// capture's padding, which the crop adds back). Notification
        /// Center's panel shades the bar from ~410pt in to the edge; a
        /// cover that stopped at the clock left the real panel moving
        /// beside the picture's wipe (Gab, 2026-09-22 17:14).
        let endX: CGFloat
        let band: CGRect
    }

    private func barCoverGeometry() -> BarCoverGeometry? {
        let isClock: (ObservedItem) -> Bool = { $0.id.rawValue.hasSuffix("::com.apple.menuextra.clock") }
        let primaryMaxX = primaryMaxX
        guard let appState, let items = appState.snapshot?.items, !items.isEmpty,
              let clock = items.first(where: isClock)?.frame,
              case let frames = items.compactMap(\.frame).filter({ MenuBarGeometry.isInPrimaryBand($0, primaryMaxX: primaryMaxX) }),
              let leftmost = frames.map(\.minX).min(),
              let band = lastConcealedStripRect ?? frames.first
        else { return nil }
        // Whatever the assertion still hides slides in to the LEFT of the
        // leftmost live icon when it drops. Concealed, that is the hidden
        // section and `revealCoverRect` already spans it; revealed (the
        // editor holds the bar, a hover), it is the always-hidden icons
        // and the system extras, which no strip rect budgets for — the
        // blink flashed every icon with Settings open (Gab, 2026-09-19).
        // Budget the concealed count in; the capture clamps to the notch
        // and the display edge, and a wider picture of static bar is free.
        let concealedGrowth = CGFloat(appState.snapshot?.concealed.count ?? 0) * 40
        let minX = min(leftmost, revealCoverRect?.minX ?? leftmost) - 24 - concealedGrowth
        return BarCoverGeometry(minX: minX, anchorMinX: clock.minX, endX: primaryMaxX - ConcealGhostOverlay.capturePadding, band: band)
    }

    /// The capture pads 6pt past the rect on both sides (continuous
    /// background); the right edge must land short of the clock AFTER
    /// that padding or the picture eats the date's first letter.
    private func barCoverRect(_ geometry: BarCoverGeometry, anchorMinX: CGFloat? = nil) -> CGRect {
        let maxX = geometry.endX
        return CGRect(
            x: geometry.minX, y: geometry.band.minY,
            width: maxX - geometry.minX, height: geometry.band.height
        )
    }

    /// The blink cover and what it is made of, so the entrance can swap it
    /// for the under-panel picture once the panel has slid in.
    final class BlinkCover {
        fileprivate(set) var current: ConcealGhostOverlay.GhostSet
        /// Covers kept underneath the current one for the blink's life:
        /// the under-panel picture can start further right than the bare
        /// one (taken when the strip was shorter), and dropping the bare
        /// cover uncovered the hidden icons on its left (Gab, 17:24).
        fileprivate var beneath: [ConcealGhostOverlay.GhostSet] = []
        fileprivate let span: ClosedRange<CGFloat>
        fileprivate let safety: TimeInterval
        /// What the bare cover shows: the stand-in under-panel still is
        /// made from it when no real one exists yet.
        fileprivate var pictures: [ConcealGhostOverlay.BarSnapshot] = []
        fileprivate init(_ cover: ConcealGhostOverlay.GhostSet, span: ClosedRange<CGFloat>, safety: TimeInterval, pictures: [ConcealGhostOverlay.BarSnapshot] = []) {
            current = cover; self.span = span; self.safety = safety; self.pictures = pictures
        }
        func dismiss() {
            current.dismiss()
            for cover in beneath { cover.dismiss() }
        }
    }

    func beginBarCover(
        label: String = "clock",
        safety: TimeInterval = AppTiming.transitionCoverSafety
    ) async -> BlinkCover? {
        guard let appState, let geometry = barCoverGeometry() else { return nil }
        let isClock: (ObservedItem) -> Bool = { $0.id.rawValue.hasSuffix("::com.apple.menuextra.clock") }
        func liveAnchor(_ snap: EngineSnapshot) -> CGFloat? { snap.items.first(where: isClock)?.frame?.minX }
        func rect(anchorMinX: CGFloat) -> CGRect { barCoverRect(geometry, anchorMinX: anchorMinX) }
        let started = Date()
        // Debug: the blink with no cover at all, to film the real panel.
        if label == "clock", UserDefaults.standard.bool(forKey: "pelmet.debug.blinkNoCover") {
            PelmetLog.log("clock: debug — no cover")
            return nil
        }
        var spanEnd = geometry.endX
        var span = geometry.minX...spanEnd
        // The picture the idle pre-capture already holds spans this cover
        // (scheduleRevealCoverPrecapture widens it to), so cut the cover
        // out of it and take no picture at all. That is the whole point:
        // a capture here lights the screen-capture indicator at the moment
        // of the click and costs the walks below (#45, #46). Only while the
        // bar is concealed — the picture is of the empty bar, and a
        // hover-revealed bar does not look like it.
        backdropMayHaveChanged()
        if appState.currentRevealedSections.isEmpty {
            let whole = freshEmptyBarSnapshots(cropped: false)
            // Right after the panel has left, the clock sits 3pt right of
            // rest for a moment; a picture that short at the clock end
            // still serves (the cover ends in bare bar before the clock).
            if let last = whole.first?.windowFrame.maxX {
                let end = last - ConcealGhostOverlay.capturePadding
                if end < spanEnd, spanEnd - end <= 4 { spanEnd = end; span = geometry.minX...spanEnd }
            }
            let reusable = ConcealGhostOverlay.cropped(whole, toPrimaryX: span)
            if reusable.isEmpty, !whole.isEmpty {
                let have = whole.first.map { "\(Int($0.windowFrame.minX))..\(Int($0.windowFrame.maxX))" } ?? "none"
                PelmetLog.log("\(label): idle picture \(have) unusable for \(Int(span.lowerBound))..\(Int(span.upperBound)), capturing")
            }
            if let cover = ConcealGhostOverlay.begin(from: reusable, safety: safety) {
                PelmetLog.log("\(label): cover up from the idle picture, no capture — ready in \(Int(-started.timeIntervalSinceNow * 1000))ms")
                return BlinkCover(cover, span: span, safety: safety, pictures: reusable)
            }
        }
        // The capture itself lights the screen-capture indicator at the
        // bar's right end and the whole cluster shifts left to make room
        // (8pt, 2026-09-14; 3pt on 2026-09-16) — the first picture is stale
        // the moment it exists, and the anchor slid under the cover's edge.
        // Walk again until it has moved and retake the picture, so cover
        // and bar agree for the cover's life. Not when the indicator is
        // already lit from a recent picture: the bar sat shifted before
        // this capture, nothing will move, and the walks were pure delay.
        let indicatorLit = ConcealGhostOverlay.captureIndicatorLit
        var snaps = await ConcealGhostOverlay.snapshotSet(of: rect(anchorMinX: geometry.anchorMinX))
        guard !snaps.isEmpty else {
            PelmetLog.log("\(label): cover none — no picture, ready in \(Int(-started.timeIntervalSinceNow * 1000))ms")
            return nil
        }
        var anchorNow = geometry.anchorMinX
        var walks = 0
        while !indicatorLit, walks < 2 {
            walks += 1
            guard let now = liveAnchor(await appState.engine.freshSnapshot()) else { break }
            if now != geometry.anchorMinX { anchorNow = now; break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if anchorNow != geometry.anchorMinX {
            snaps = await ConcealGhostOverlay.snapshotSet(of: rect(anchorMinX: anchorNow))
        }
        let cover = ConcealGhostOverlay.begin(from: snaps, safety: safety)
        PelmetLog.log("\(label): cover \(cover == nil ? "none" : "up") \(Int(geometry.minX))..\(Int(geometry.endX)) anchor \(Int(geometry.anchorMinX))→\(Int(anchorNow)) after \(walks) walk(s)\(indicatorLit ? ", indicator lit" : ""), ready in \(Int(-started.timeIntervalSinceNow * 1000))ms")
        return cover.map { BlinkCover($0, span: geometry.minX...geometry.endX, safety: safety, pictures: snaps) }
    }

    /// Entrance blink, as Notification Center's panel slides in: the
    /// picture this cover shows (the bar as it is at this click) with the
    /// panel's measured shade over it, wiped in from the right on the
    /// panel's own trajectory. Always the click's own picture: a kept
    /// still of the bar under the panel painted over any icon that had
    /// changed since (Gab, 2026-09-22 18:00), and refreshing it cost a
    /// capture at every exit click.
    func swapBlinkCoverUnderPanel(_ cover: BlinkCover) {
        guard !cover.pictures.isEmpty, let shaded = ConcealGhostOverlay.begin(from: cover.pictures, safety: cover.safety) else {
            PelmetLog.log("clock: no picture to shade, bare cover stays")
            return
        }
        shaded.addPanelShade()
        wipe(shaded, over: cover, what: "shaded picture")
    }

    private func wipe(_ under: ConcealGhostOverlay.GhostSet, over cover: BlinkCover, what: String) {
        cover.beneath.append(cover.current)
        cover.current = under
        // The panel's own trajectory, frame by frame (inset of its leading
        // edge from the display's right edge at each 1/60s), from the
        // moment the relay's click is up. Overridable for tuning:
        // `pelmet.wipe.insets` (points), `pelmet.wipe.delayMs`, `pelmet.wipe.edge`.
        let defaults = UserDefaults.standard
        let insets = (defaults.array(forKey: "pelmet.wipe.insets") as? [Double]).map { $0.map { CGFloat($0) } } ?? AppTiming.panelEntranceInsets
        let delay = (defaults.object(forKey: "pelmet.wipe.delayMs") as? Double).map { $0 / 1000 } ?? AppTiming.panelEntranceDelay
        let edge = (defaults.object(forKey: "pelmet.wipe.edge") as? Double).map { CGFloat($0) } ?? AppTiming.panelEdgeSoftness
        under.wipeInFromRight(insets: insets, frame: 1.0 / 60, delay: delay, edge: edge)
        PelmetLog.log("clock: \(what) wiping in over the cover (\(insets.count) frames, delay \(Int(delay * 1000))ms)")
    }


    /// Lift the blink cover once the re-acquire has taken beneath it. Swap-
    /// quiet is not enough: the agent finishes the drop's reveal slide
    /// before it applies the re-acquire, so the concealed items were still
    /// fading out when a hold-only lift came (Gab, 2026-09-14: "all apps at
    /// the very end"). Poll a fresh AX walk until the concealed items have
    /// left the tree, then hold for the agent's fade.
    func endBarCover(_ cover: BlinkCover, label: String = "clock") {
        Task { @MainActor in
            guard let appState else { cover.dismiss(); return }
            let started = Date()
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            let deadline = Date().addingTimeInterval(AppTiming.clockBlinkCoverDeadline)
            while Date() < deadline, await appState.engine.concealedItemsStillVisible() {
                try? await Task.sleep(for: .milliseconds(60))
            }
            let gone = Int(-started.timeIntervalSinceNow * 1000)
            try? await Task.sleep(for: .seconds(AppTiming.clockBlinkLiftHold))
            cover.dismiss()
            PelmetLog.log("\(label): cover down — concealed gone at \(gone)ms, lifted at \(Int(-started.timeIntervalSinceNow * 1000))ms")
        }
    }

    /// The empty-bar capture from the last conceal settle, if it is recent
    /// enough to stand in for the bar as it looks now (static wallpaper).
    ///
    /// The stored picture spans `precaptureRect` — the reveal cover widened
    /// to the blink's footprint — so the reveal path takes it `cropped`
    /// back to its own rect and the blink cuts its own cover out of it.
    private func freshEmptyBarSnapshots(cropped: Bool = true) -> [ConcealGhostOverlay.BarSnapshot] {
        guard let first = revealCoverSnapshot.first,
              Date().timeIntervalSince(first.takenAt) < AppTiming.revealCoverFreshness
        else { return [] }
        guard revealCoverActiveDisplay == appState?.lastMouseDownDisplay else {
            PelmetLog.log("cover: picture from another active display (\(revealCoverActiveDisplay ?? 0) → \(appState?.lastMouseDownDisplay ?? 0)), not used")
            return []
        }
        // The panel is not in the backdrop signature: a picture taken under
        // it is only true while it is open, and the other way round.
        guard revealCoverUnderPanel == ClockClickRelay.notificationCenterIsOpen() else {
            PelmetLog.log("cover: picture taken with the panel \(revealCoverUnderPanel ? "open" : "closed"), not used")
            return []
        }
        guard cropped, let want = revealCoverRect, want != precaptureRect else { return revealCoverSnapshot }
        let narrowed = ConcealGhostOverlay.cropped(revealCoverSnapshot, toPrimaryX: want.minX...want.maxX)
        return narrowed.isEmpty ? revealCoverSnapshot : narrowed
    }

    /// The pixel passes over the pictures are pure functions of the
    /// pictures and the chevron's columns; between reveals nothing changes,
    /// and both ran on the main thread on every reveal (2026-09-21).
    /// Memoized on their inputs — a picture's `takenAt` is its identity.
    private var punchedCoverCache: (key: String, snaps: [ConcealGhostOverlay.BarSnapshot])?
    private var cutOutCache: (key: String, picture: [ConcealGhostOverlay.BarSnapshot])?

    private static func pictureKey(_ snaps: [ConcealGhostOverlay.BarSnapshot]) -> String {
        snaps.map { "\($0.takenAt.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
    }

    private func punchedCover(_ emptyBar: [ConcealGhostOverlay.BarSnapshot], columns: [ClosedRange<CGFloat>]) -> [ConcealGhostOverlay.BarSnapshot] {
        let key = Self.pictureKey(emptyBar) + "#" + columns.map { "\($0)" }.joined()
        if let cached = punchedCoverCache, cached.key == key { return cached.snaps }
        let snaps = ConcealGhostOverlay.clearing(emptyBar, columns: columns)
        punchedCoverCache = (key, snaps)
        return snaps
    }

    private func cutOutPicture(
        _ strips: [ConcealGhostOverlay.BarSnapshot], background: [ConcealGhostOverlay.BarSnapshot],
        punch: [ClosedRange<CGFloat>], keep: ClosedRange<CGFloat>?
    ) -> [ConcealGhostOverlay.BarSnapshot]? {
        let key = Self.pictureKey(strips) + "/" + Self.pictureKey(background) + "#" + punch.map { "\($0)" }.joined() + "#" + (keep.map { "\($0)" } ?? "")
        if let cached = cutOutCache, cached.key == key { return cached.picture }
        guard let picture = ConcealGhostOverlay.iconsOnly(strips, background: background, punch: punch, keep: keep) else { return nil }
        cutOutCache = (key, picture)
        return picture
    }

    /// The chevron's columns, relative to the strip rect — its glyph flips
    /// between the two captures and would otherwise ride the cut-out.
    private var chevronPunch: [ClosedRange<CGFloat>] { chevronPunch(clearingFrom: nil) }

    /// The chevron's columns, never starting left of `x`: its AX frame
    /// overlaps the neighboring icon by a few points, and a punch from the
    /// frame's edge clipped that icon before it moved (Gab, Smooth exit).
    private func chevronPunch(clearingFrom x: CGFloat?) -> [ClosedRange<CGFloat>] {
        guard let chevron = appState?.snapshot?.items.first(where: { $0.id == AppState.chevronItemID })?.frame
        else { return [] }
        let lower = max(chevron.minX, x ?? -.greatestFiniteMagnitude)
        guard lower < chevron.maxX else { return [] }
        return [lower...chevron.maxX]
    }

    /// The widest strip any conceal has measured: AX lists freshly revealed
    /// items progressively, and a short measurement left the leftmost icons
    /// outside the entrance picture — they popped in at lift instead of
    /// sliding (Gab: "sometimes not all icons slide").
    private var entranceKeep: ClosedRange<CGFloat>? {
        guard let strip = lastConcealedStripRect else { return nil }
        let minX = min(strip.minX, widestStripMinX ?? strip.minX)
        return (minX - 6)...(strip.maxX + 6)
    }

    private var precaptureTask: Task<Void, Never>?
    private var revealedPrecaptureTask: Task<Void, Never>?

    /// The strip as it looks revealed and at rest — the Instant/Fade reveal
    /// paints it at once. Taken at reveal settle; dropped when the engine
    /// reports the bar changed (an icon added, removed or reordered would
    /// paint a stale picture).
    private var revealedStripSnapshot: [ConcealGhostOverlay.BarSnapshot] = []
    /// Notification Center's panel was under the bar for the finished
    /// picture: only true while it still is, and the other way round (a
    /// picture from under the panel darkened reveals after it closed).
    private var revealedStripUnderPanel = false
    /// The empty-bar picture the finished picture sits on, kept only once
    /// the backdrop changed under both (see backdropMayHaveChanged): the
    /// reveal then cuts the icons out against it. Empty otherwise.
    private var revealedStripBackground: [ConcealGhostOverlay.BarSnapshot] = []
    /// The boot picture's hidden run (see takeBootPicture): cut out against
    /// the fresh cover, keeping these columns only. Nil for a picture of
    /// the revealed bar, which keeps `entranceKeep`.
    private var revealedStripKeep: ClosedRange<CGFloat>?
    /// The picture is icons over an empty bar it must be cut out against.
    private var revealedStripCutOut: Bool { !revealedStripBackground.isEmpty || revealedStripKeep != nil }
    /// What the last reveal showed — the state machine is already
    /// transitioning to conceal when performConceal runs.
    private var lastRevealedSections: Set<PelmetCore.Section> = []
    /// What the picture shows: the hidden section's membership and order
    /// when it was taken. A reveal only paints it while that still holds
    /// (an editor move, an adopted drag or a new app changes the picture;
    /// the conceal's own item churn does not).
    private var revealedStripSignature: [ItemID] = []
    /// The chevron's x when the picture was taken. A visible-section
    /// change (an indicator appearing, a placement drag) shifts the chevron,
    /// and a picture from before it paints the glyph at the old x next to
    /// the live one (two chevrons for a beat, #39 video at 18:45:56).
    private var revealedStripChevronX: CGFloat?
    private var liveChevronMinX: CGFloat? {
        appState?.snapshot?.items.first(where: { $0.id == AppState.chevronItemID })?.frame?.minX
    }

    private var hiddenSectionSignature: [ItemID] {
        guard let model = appState?.settings.sectionModel else { return [] }
        let ordered = model.order[.hidden] ?? []
        let rest = model.assignments.filter { $0.value == .hidden }.map(\.key).filter { !ordered.contains($0) }
        return ordered + rest.sorted { $0.rawValue < $1.rawValue }
    }

    private var revealedStripUsable: Bool {
        guard let why = revealedStripProblem else { return true }
        PelmetLog.log("finished: \(why)")
        return false
    }

    /// Why the finished picture can't be painted, nil when it can.
    private var revealedStripProblem: String? {
        guard let first = revealedStripSnapshot.first else { return "no picture" }
        guard Date().timeIntervalSince(first.takenAt) < AppTiming.revealedStripFreshness else { return "picture stale" }
        guard revealedStripSignature == hiddenSectionSignature else {
            return "hidden section changed since the picture — was \(revealedStripSignature.map(\.rawValue)) now \(hiddenSectionSignature.map(\.rawValue))"
        }
        guard revealedStripActiveDisplay == appState?.lastMouseDownDisplay else { return "picture from another active display" }
        guard revealedStripUnderPanel == ClockClickRelay.notificationCenterIsOpen() else {
            return "picture taken with the panel \(revealedStripUnderPanel ? "open" : "closed")"
        }
        if let then = revealedStripChevronX, let now = liveChevronMinX, abs(then - now) > 1, freshEmptyBarSnapshots().isEmpty {
            return "chevron moved since the picture (\(then) → \(now)) and no cover to cut out against"
        }
        return nil
    }

    /// How far the whole cluster has moved since the picture: the capture
    /// indicator shifts it ~16pt for ~3s after any capture, an extra
    /// showing or hiding shifts it by its width. The wallpaper stays put,
    /// so the picture still cuts out cleanly against the empty-bar cover
    /// at its own geometry; the icons are then floated shifted by this
    /// much and land where the bar puts them (2026-09-21 — before, every
    /// such reveal dropped the picture and ran cover-only).
    private var revealedStripShift: CGFloat {
        guard let then = revealedStripChevronX, let now = liveChevronMinX, abs(then - now) > 1 else { return 0 }
        return now - then
    }

    /// The strip as it looks now — revealed, at rest, no picture over it —
    /// becomes the finished picture. Callers check the reveal state.
    private func takeRevealedStripPicture(reason: String) async {
        guard let appState, !ConcealGhostOverlay.stripActive else { return }
        // The reveal cover's footprint, so the two pictures overlay
        // exactly (same rect, same padding).
        revealedStripSignature = hiddenSectionSignature
        revealedStripChevronX = liveChevronMinX
        revealedStripActiveDisplay = appState.lastMouseDownDisplay
        revealedStripBackdrop = ConcealGhostOverlay.backdropSignature(of: revealCoverRect) + ConcealGhostOverlay.surfaceSignature()
        revealedStripBackground = []
        revealedStripKeep = nil
        revealedStripUnderPanel = ClockClickRelay.notificationCenterIsOpen()
        revealedStripSnapshot = await ConcealGhostOverlay.snapshotSet(of: revealCoverRect)
        PelmetLog.log("finished: picture taken at \(reason) (\(revealedStripSnapshot.count) display(s), \(revealedStripSignature.count) hidden item(s))")
    }


    private func scheduleRevealedStripPrecapture() {
        revealedPrecaptureTask?.cancel()
        revealedPrecaptureTask = Task { @MainActor in
            guard let appState else { return }
            await appState.waitUntilQuiesced(interval: 0.5, deadline: 3, poll: .milliseconds(50))
            // The reveal's cover lifts at `entranceCoverHold` past settle:
            // wait for it rather than skip the picture (a skipped picture
            // costs the next conceal a live capture, #35). Only a Fade
            // lift has a tail that could bake in.
            let lifted = Date().addingTimeInterval(2)
            while ConcealGhostOverlay.stripActive, Date() < lifted, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
            }
            if appState.settings.revealAnimation == .fade {
                try? await Task.sleep(for: AppTiming.precaptureGhostClearance)
            }
            guard !Task.isCancelled, appState.currentRevealedSections == [.hidden] else { return }
            await takeRevealedStripPicture(reason: "settle")
        }
    }

    /// Once the bar has gone swap-quiet after a conceal, the strip region
    /// shows exactly the "empty bar" the next reveal wants to freeze — and
    /// the next conceal's cover/cut-out reference for every style — capture
    /// it now. One in flight at a time: rapid conceal cycles otherwise stack
    /// overlapping 3s polls, each ending in an SCK capture.
    /// `afterConceal` false: a retake of a bar long at rest (#49) — no fade
    /// to clear, and the pointer is already on its way.
    private func scheduleRevealCoverPrecapture(afterConceal: Bool = true) {
        precaptureTask?.cancel()
        precaptureInFlight = true
        precaptureTask = Task { @MainActor in
            defer { precaptureInFlight = false }
            guard let appState else { return }
            await appState.waitUntilQuiesced(interval: 0.5, deadline: 3, poll: .milliseconds(afterConceal ? 200 : 30))
            // The agent's own conceal fade must not bake into the snapshot.
            if afterConceal { try? await Task.sleep(for: AppTiming.precaptureGhostClearance) }
            guard !Task.isCancelled, appState.currentRevealedSections.isEmpty else { return }
            // Under Notification Center's panel the bar is not the bar a
            // reveal or a clock click will find: leave the bare picture
            // (or its absence) alone, the blink keeps its own picture of
            // the bar under the panel (#51).
            guard !ClockClickRelay.notificationCenterIsOpen() else {
                PelmetLog.log("cover: panel open, precapture skipped")
                return
            }
            revealCoverActiveDisplay = appState.lastMouseDownDisplay ?? Self.displayUnderPointer
            let rect = precaptureRect
            revealCoverBackdrop = ConcealGhostOverlay.backdropSignature(of: rect) + ConcealGhostOverlay.surfaceSignature()
            let underPanel = ClockClickRelay.notificationCenterIsOpen()
            revealCoverSnapshot = await ConcealGhostOverlay.snapshotSet(of: rect)
            revealCoverUnderPanel = underPanel
            revealCoverWanted = false
            parkedCover = nil
        }
    }

    /// Boot: the first conceal is the engine's own converge, not a
    /// `performConceal`, so nothing measured the strip and the first reveal
    /// of every launch ran without pictures (macOS's own slide showed).
    /// The launch snapshot was taken before any assertion — every hidden
    /// item still had a frame — so the strip is known from it; the empty-
    /// bar picture follows once the boot conceal has settled.
    func warmAfterBoot(from snap: EngineSnapshot) {
        guard seedStripAtBoot(from: snap) else { return }
        scheduleRevealCoverPrecapture()
    }

    /// Idempotent: the first call seeds, later ones return whether a strip
    /// is known.
    @discardableResult
    private func seedStripAtBoot(from snap: EngineSnapshot) -> Bool {
        guard lastConcealedStripRect == nil else { return true }
        guard let appState else { return false }
        var union: CGRect?
        var count = 0
        let primaryMaxX = primaryMaxX
        for item in snap.items {
            guard let frame = item.frame, MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX),
                  appState.settings.sectionModel.section(of: item.id) != .visible
            else { continue }
            count += 1
            union = union.map { $0.union(frame) } ?? frame
        }
        concealableCount = count
        guard let union else { return false }
        rememberStrip(union)
        PelmetLog.log("strip: seeded at boot from \(count) pre-assertion frame(s) → \(Int(union.minX))..\(Int(union.maxX))")
        return true
    }

    /// Boot, before the first converge: the bar is fully live, and the
    /// hidden section sits exactly where the first reveal will bring it
    /// back. A picture of it now, with the hidden run cut out against the
    /// empty bar the boot conceal leaves, makes the first reveal of the
    /// session as instant as the ones after it — it used to pay the
    /// cover-only path every launch (Gab, 2026-09-18). The always-hidden
    /// icons are live too, so only the hidden run is kept; an always-hidden
    /// icon sitting inside that run (untidy bar) would ride along, so the
    /// picture is skipped then.
    func takeBootPicture(from snap: EngineSnapshot) async {
        guard let appState, seedStripAtBoot(from: snap), let rect = revealCoverRect else { return }
        let model = appState.settings.sectionModel
        let primaryMaxX = primaryMaxX
        var hidden: CGRect?
        var alwaysHidden: [CGRect] = []
        for item in snap.items {
            guard let frame = item.frame, MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX) else { continue }
            switch model.section(of: item.id) {
            case .hidden: hidden = hidden.map { $0.union(frame) } ?? frame
            case .alwaysHidden: alwaysHidden.append(frame)
            default: break
            }
        }
        guard let hidden else { return }
        guard !alwaysHidden.contains(where: { $0.midX > hidden.minX && $0.midX < hidden.maxX }) else {
            PelmetLog.log("finished: boot picture skipped — an always-hidden icon sits inside the hidden run")
            return
        }
        revealedStripSignature = hiddenSectionSignature
        revealedStripChevronX = liveChevronMinX
        revealedStripActiveDisplay = appState.lastMouseDownDisplay ?? Self.displayUnderPointer
        revealedStripBackdrop = ConcealGhostOverlay.backdropSignature(of: rect) + ConcealGhostOverlay.surfaceSignature()
        revealedStripBackground = []
        revealedStripKeep = (hidden.minX - 6)...(hidden.maxX + 6)
        revealedStripUnderPanel = ClockClickRelay.notificationCenterIsOpen()
        revealedStripSnapshot = await ConcealGhostOverlay.snapshotSet(of: rect)
        PelmetLog.log("finished: boot picture taken (\(revealedStripSnapshot.count) display(s), \(revealedStripSignature.count) hidden item(s), keep \(Int(hidden.minX))..\(Int(hidden.maxX)))")
    }

    /// Union of the on-screen frames about to conceal (primary band
    /// only): everything assigned to a non-visible section that currently has
    /// a frame. Nil when nothing concealable is showing. Re-snapshots: AX
    /// lists freshly revealed items progressively, and the settle-time
    /// snapshot can be missing half the strip.
    private func concealStripFrames() async -> CGRect? {
        guard let appState else { return nil }
        // The rest walk behind the reveal swap listed the whole strip;
        // walking again here cost 70–130ms before every conceal swap.
        let snap: EngineSnapshot
        if let rest = await engine.restSnapshot { snap = rest } else { snap = await engine.snapshot() }
        var union: CGRect?
        var count = 0
        concealableCount = snap.items.filter {
            !$0.id.isSystemModule && appState.settings.sectionModel.section(of: $0.id) != .visible
        }.count
        let primaryMaxX = primaryMaxX
        for item in snap.items {
            guard let frame = item.frame,
                  MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX),
                  appState.settings.sectionModel.section(of: item.id) != .visible
            else { continue }
            count += 1
            union = union.map { $0.union(frame) } ?? frame
        }
        PelmetLog.log("strip: \(count) items → \(union.map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "nil")")
        return union
    }
}
