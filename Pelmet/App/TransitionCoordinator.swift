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
    private let engine: EngineGoldenGate

    init(appState: AppState, engine: EngineGoldenGate) {
        self.appState = appState
        self.engine = engine
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
    private func rememberStrip(_ strip: CGRect?) {
        lastConcealedStripRect = strip
        guard let strip else { return }
        widestStripMinX = min(widestStripMinX ?? strip.minX, strip.minX)
    }

    func performReveal(_ sections: Set<PelmetCore.Section>) {
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
            if cover != nil, sections == [.hidden], revealedStripUsable {
                var picture: [ConcealGhostOverlay.BarSnapshot]? = revealedStripSnapshot
                if recipe.entrance.needsCutOut {
                    picture = ConcealGhostOverlay.iconsOnly(
                        revealedStripSnapshot, background: emptyBar, punch: chevronPunch,
                        keep: lastConcealedStripRect.map { ($0.minX - 6)...($0.maxX + 6) }
                    )
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
            PelmetLog.log("effect reveal \(sections) → engine (anim=\(style.rawValue), cover=\(cover != nil), finished=\(finished != nil))")
            await engine.reveal(sections)
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
                }
            }
            PelmetLog.log("effect reveal settled")
            onRevealSettled?()
            scheduleRevealedStripPrecapture()
        }
    }

    func performConceal() {
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
            rememberStrip(stripRect)
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
                    if let cut = ConcealGhostOverlay.iconsOnly(icons, background: emptyBar, punch: chevronPunch) {
                        cover = ConcealGhostOverlay.begin(from: emptyCover, safety: AppTiming.transitionCoverSafety)
                        strip = ConcealGhostOverlay.begin(from: cut, safety: AppTiming.transitionCoverSafety)
                    }
                }
            }
            PelmetLog.log("effect conceal → engine (anim=\(style.rawValue), cover=\(cover != nil), strip=\(strip != nil))")
            await engine.conceal()
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
                }
            }
            PelmetLog.log("effect conceal settled")
            onConcealSettled?()
            scheduleRevealCoverPrecapture()
        }
    }

    /// The empty-bar capture from the last conceal settle, if it is recent
    /// enough to stand in for the bar as it looks now (static wallpaper).
    private func freshEmptyBarSnapshots() -> [ConcealGhostOverlay.BarSnapshot] {
        guard let first = revealCoverSnapshot.first,
              Date().timeIntervalSince(first.takenAt) < AppTiming.revealCoverFreshness
        else { return [] }
        return revealCoverSnapshot
    }

    /// The chevron's columns, relative to the strip rect — its glyph flips
    /// between the two captures and would otherwise ride the cut-out.
    private var chevronPunch: [ClosedRange<CGFloat>] {
        guard let chevron = appState?.snapshot?.items.first(where: { $0.id == AppState.chevronItemID })?.frame
        else { return [] }
        return [chevron.minX...chevron.maxX]
    }

    private var precaptureTask: Task<Void, Never>?
    private var revealedPrecaptureTask: Task<Void, Never>?

    /// The strip as it looks revealed and at rest — the Instant/Fade reveal
    /// paints it at once. Taken at reveal settle; dropped when the engine
    /// reports the bar changed (an icon added, removed or reordered would
    /// paint a stale picture).
    private var revealedStripSnapshot: [ConcealGhostOverlay.BarSnapshot] = []
    /// What the picture shows: the hidden section's membership and order
    /// when it was taken. A reveal only paints it while that still holds
    /// (an editor move, an adopted drag or a new app changes the picture;
    /// the conceal's own item churn does not).
    private var revealedStripSignature: [ItemID] = []

    private var hiddenSectionSignature: [ItemID] {
        guard let model = appState?.settings.sectionModel else { return [] }
        let ordered = model.order[.hidden] ?? []
        let rest = model.assignments.filter { $0.value == .hidden }.map(\.key).filter { !ordered.contains($0) }
        return ordered + rest.sorted { $0.rawValue < $1.rawValue }
    }

    private var revealedStripUsable: Bool {
        guard let first = revealedStripSnapshot.first else {
            PelmetLog.log("finished: no picture")
            return false
        }
        guard Date().timeIntervalSince(first.takenAt) < AppTiming.revealedStripFreshness else {
            PelmetLog.log("finished: picture stale")
            return false
        }
        guard revealedStripSignature == hiddenSectionSignature else {
            PelmetLog.log("finished: hidden section changed since the picture — was \(revealedStripSignature.map(\.rawValue)) now \(hiddenSectionSignature.map(\.rawValue))")
            return false
        }
        return true
    }


    private func scheduleRevealedStripPrecapture() {
        revealedPrecaptureTask?.cancel()
        revealedPrecaptureTask = Task { @MainActor in
            guard let appState else { return }
            await appState.waitUntilQuiesced(interval: 0.5, deadline: 3, poll: .milliseconds(200))
            // No cover's fade may bake into the snapshot.
            try? await Task.sleep(for: AppTiming.precaptureGhostClearance)
            guard !Task.isCancelled, appState.currentRevealedSections == [.hidden],
                  !ConcealGhostOverlay.stripActive else { return }
            // The reveal cover's footprint, so the two pictures overlay
            // exactly (same rect, same padding).
            revealedStripSignature = hiddenSectionSignature
            revealedStripSnapshot = await ConcealGhostOverlay.snapshotSet(of: revealCoverRect)
            PelmetLog.log("finished: picture taken (\(revealedStripSnapshot.count) display(s), \(revealedStripSignature.count) hidden item(s))")
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
            revealCoverSnapshot = await ConcealGhostOverlay.snapshotSet(of: revealCoverRect)
        }
    }

    /// Union of the on-screen frames about to conceal (main-display band
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
        for item in snap.items {
            guard let frame = item.frame,
                  MenuBarGeometry.isInBand(frame),
                  appState.settings.sectionModel.section(of: item.id) != .visible
            else { continue }
            count += 1
            union = union.map { $0.union(frame) } ?? frame
        }
        PelmetLog.log("strip: \(count) items → \(union.map { "\(Int($0.minX))..\(Int($0.maxX))" } ?? "nil")")
        return union
    }
}
