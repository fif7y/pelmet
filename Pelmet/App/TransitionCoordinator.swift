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
    /// window move; a changed backdrop drops the stale pictures and retakes
    /// the empty-bar one at once when the bar is concealed and at rest.
    private lazy var backdropWatch = BackdropWatch { [weak self] in self?.backdropMayHaveChanged() }
    /// `ConcealGhostOverlay.backdropSignature` at the time each picture was taken.
    private var revealCoverBackdrop: [Int] = []
    private var revealedStripBackdrop: [Int] = []

    private func backdropMayHaveChanged() {
        guard let appState, !revealCoverSnapshot.isEmpty || !revealedStripSnapshot.isEmpty else { return }
        let now = ConcealGhostOverlay.backdropSignature(of: revealCoverRect)
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
        PelmetLog.log("backdrop: changed under the bar (\(now.count / 5) window(s)) — cover \(coverStale ? (concealed ? "dropped, retaking" : "dropped") : "kept"), finished \(stripStale ? (stripCutOut ? "kept as a cut-out" : "dropped") : "kept")")
        if stripCutOut {
            revealedStripBackground = revealCoverSnapshot
        } else if stripStale {
            revealedStripSnapshot = []
        }
        if coverStale {
            revealCoverSnapshot = []
            if concealed { scheduleRevealCoverPrecapture() }
        }
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
            let emptyBar = freshEmptyBarSnapshots()
            let coverSource = !emptyBar.isEmpty ? "precaptured" : style != .smooth ? "live capture" : "none"
            if !emptyBar.isEmpty {
                // The still shows the collapsed glyph; a hole over the
                // glyph's core lets the live chevron (flipped at the swap)
                // show through without exposing a neighbor's edge.
                cover = ConcealGhostOverlay.begin(
                    from: ConcealGhostOverlay.clearing(emptyBar, columns: chevronPunch.map { ($0.lowerBound + 6)...($0.upperBound - 6) }),
                    safety: AppTiming.transitionCoverSafety
                )
            } else if style != .smooth {
                cover = await ConcealGhostOverlay.begin(over: revealCoverRect, safety: AppTiming.transitionCoverSafety)
            }
            lastRevealedSections = sections
            if cover != nil, sections == [.hidden], revealedStripUsable {
                var picture: [ConcealGhostOverlay.BarSnapshot]? = revealedStripSnapshot
                if recipe.entrance.needsCutOut || revealedStripCutOut {
                    // Against the empty bar the picture was taken over: the
                    // fresh cover when nothing moved (and for the boot
                    // picture), the kept one when the backdrop changed
                    // since (see backdropMayHaveChanged).
                    picture = ConcealGhostOverlay.iconsOnly(
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
            trace.mark("cover", detail: "\(coverSource)\(finished != nil ? ", finished" : "")")
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
            trace.mark("strip walk")
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
    func beginBarCover(
        label: String = "clock",
        safety: TimeInterval = AppTiming.transitionCoverSafety
    ) async -> ConcealGhostOverlay.GhostSet? {
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
        // The capture pads 6pt past the rect on both sides (continuous
        // background); the right edge must land short of the clock AFTER
        // that padding or the picture eats the date's first letter.
        func rect(clockMinX: CGFloat) -> CGRect {
            let maxX = clockMinX - 2 - ConcealGhostOverlay.capturePadding
            return CGRect(x: minX, y: band.minY, width: maxX - minX, height: band.height)
        }
        let started = Date()
        // The capture itself lights the screen-capture indicator at the
        // bar's right end and the whole cluster shifts left to make room
        // (8pt, 2026-09-14; 3pt on 2026-09-16) — the first picture is stale
        // the moment it exists, and the clock slid under the cover's edge.
        // Walk again until the clock has moved and retake the picture, so
        // cover and bar agree for the cover's life. Not when the indicator
        // is already lit from a recent picture: the bar sat shifted before
        // this capture, nothing will move, and the walks were pure delay
        // (four of them, ~460ms between the click and its replay).
        let indicatorLit = ConcealGhostOverlay.captureIndicatorLit
        var snaps = await ConcealGhostOverlay.snapshotSet(of: rect(clockMinX: clock.minX))
        // No picture (Screen Recording not granted): nothing to retake, and
        // the walks below only delay the replayed click (~250ms on #27's
        // machine, four walks per click).
        guard !snaps.isEmpty else {
            PelmetLog.log("\(label): cover none — no picture, ready in \(Int(-started.timeIntervalSinceNow * 1000))ms")
            return nil
        }
        var clockNow = clock.minX
        var walks = 0
        while !indicatorLit, walks < 2 {
            walks += 1
            let fresh = await appState.engine.freshSnapshot()
            guard let now = fresh.items.first(where: isClock)?.frame?.minX else { break }
            if now != clock.minX { clockNow = now; break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if clockNow != clock.minX {
            snaps = await ConcealGhostOverlay.snapshotSet(of: rect(clockMinX: clockNow))
        }
        let cover = ConcealGhostOverlay.begin(from: snaps, safety: safety)
        PelmetLog.log("\(label): cover \(cover == nil ? "none" : "up") \(Int(minX))..\(Int(clockNow) - 2 - Int(ConcealGhostOverlay.capturePadding)) clock \(Int(clock.minX))→\(Int(clockNow)) after \(walks) walk(s)\(indicatorLit ? ", indicator lit" : ""), ready in \(Int(-started.timeIntervalSinceNow * 1000))ms")
        return cover
    }

    /// Lift the blink cover once the re-acquire has taken beneath it. Swap-
    /// quiet is not enough: the agent finishes the drop's reveal slide
    /// before it applies the re-acquire, so the concealed items were still
    /// fading out when a hold-only lift came (Gab, 2026-09-14: "all apps at
    /// the very end"). Poll a fresh AX walk until the concealed items have
    /// left the tree, then hold for the agent's fade.
    func endBarCover(_ cover: ConcealGhostOverlay.GhostSet, label: String = "clock") {
        Task { @MainActor in
            guard let appState else { cover.dismiss(); return }
            let started = Date()
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            let deadline = Date().addingTimeInterval(AppTiming.clockBlinkCoverDeadline)
            while Date() < deadline, await appState.engine.concealedItemsStillVisible() {
                try? await Task.sleep(for: .milliseconds(60))
            }
            let gone = Int(-started.timeIntervalSinceNow * 1000)
            try? await Task.sleep(for: .seconds(AppTiming.exitCoverHold))
            cover.dismiss()
            PelmetLog.log("\(label): cover down — concealed gone at \(gone)ms, lifted at \(Int(-started.timeIntervalSinceNow * 1000))ms")
        }
    }

    /// The empty-bar capture from the last conceal settle, if it is recent
    /// enough to stand in for the bar as it looks now (static wallpaper).
    private func freshEmptyBarSnapshots() -> [ConcealGhostOverlay.BarSnapshot] {
        guard let first = revealCoverSnapshot.first,
              Date().timeIntervalSince(first.takenAt) < AppTiming.revealCoverFreshness
        else { return [] }
        guard revealCoverActiveDisplay == appState?.lastMouseDownDisplay else {
            PelmetLog.log("cover: picture from another active display (\(revealCoverActiveDisplay ?? 0) → \(appState?.lastMouseDownDisplay ?? 0)), not used")
            return []
        }
        return revealCoverSnapshot
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
        if let then = revealedStripChevronX, let now = liveChevronMinX, abs(then - now) > 1 {
            return "chevron moved since the picture (\(then) → \(now))"
        }
        return nil
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
        revealedStripBackdrop = ConcealGhostOverlay.backdropSignature(of: revealCoverRect)
        revealedStripBackground = []
        revealedStripKeep = nil
        revealedStripSnapshot = await ConcealGhostOverlay.snapshotSet(of: revealCoverRect)
        PelmetLog.log("finished: picture taken at \(reason) (\(revealedStripSnapshot.count) display(s), \(revealedStripSignature.count) hidden item(s))")
    }


    private func scheduleRevealedStripPrecapture() {
        revealedPrecaptureTask?.cancel()
        revealedPrecaptureTask = Task { @MainActor in
            guard let appState else { return }
            await appState.waitUntilQuiesced(interval: 0.5, deadline: 3, poll: .milliseconds(200))
            // No cover's fade may bake into the snapshot.
            try? await Task.sleep(for: AppTiming.precaptureGhostClearance)
            guard !Task.isCancelled, appState.currentRevealedSections == [.hidden] else { return }
            await takeRevealedStripPicture(reason: "settle")
        }
    }

    /// Once the bar has gone swap-quiet after a conceal, the strip region
    /// shows exactly the "empty bar" the next reveal wants to freeze — and
    /// the next conceal's cover/cut-out reference for every style — capture
    /// it now. One in flight at a time: rapid conceal cycles otherwise stack
    /// overlapping 3s polls, each ending in an SCK capture.
    private func scheduleRevealCoverPrecapture() {
        precaptureTask?.cancel()
        precaptureTask = Task { @MainActor in
            guard let appState else { return }
            await appState.waitUntilQuiesced(interval: 0.5, deadline: 3, poll: .milliseconds(200))
            // The agent's own conceal fade must not bake into the snapshot.
            try? await Task.sleep(for: AppTiming.precaptureGhostClearance)
            guard !Task.isCancelled, appState.currentRevealedSections.isEmpty else { return }
            revealCoverActiveDisplay = appState.lastMouseDownDisplay ?? Self.displayUnderPointer
            revealCoverBackdrop = ConcealGhostOverlay.backdropSignature(of: revealCoverRect)
            revealCoverSnapshot = await ConcealGhostOverlay.snapshotSet(of: revealCoverRect)
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
        revealedStripBackdrop = ConcealGhostOverlay.backdropSignature(of: rect)
        revealedStripBackground = []
        revealedStripKeep = (hidden.minX - 6)...(hidden.maxX + 6)
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
        let snap = await engine.snapshot()
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
