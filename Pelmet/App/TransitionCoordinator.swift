// TransitionCoordinator.swift
// Reveal/conceal execution, extracted from AppState.dispatch: the overlay
// cover lifecycle (pre-captured reveal cover, conceal ghost, swap-quiet
// holds) around the engine transition. The rehide state machine stays in
// AppState — settle re-entry goes through the onSettled callbacks.

import AppKit
import PelmetCore
import PelmetEngine

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
            // Instant/Fade styles: the agent's slide-in is the only
            // reveal animation the OS offers — a snapshot of the
            // still-empty strip covers the slide, then pops (Instant)
            // or fades (Fade) away once the swap lands. The strip rect
            // is remembered from the last conceal (icons reappear
            // where they left); no memory yet → the slide shows.
            var cover: ConcealGhostOverlay.GhostSet?
            if appState.settings.revealAnimation != .smooth {
                // Pre-captured snapshots float synchronously; only
                // fall back to a live capture when none is cached.
                // Freshness cap: an appearance/wallpaper change
                // while idle would flash a stale background.
                if let first = revealCoverSnapshot.first,
                   Date().timeIntervalSince(first.takenAt) < AppTiming.revealCoverFreshness {
                    cover = ConcealGhostOverlay.begin(from: revealCoverSnapshot, safety: AppTiming.transitionCoverSafety)
                } else {
                    cover = await ConcealGhostOverlay.begin(
                        over: revealCoverRect, safety: AppTiming.transitionCoverSafety
                    )
                }
                revealCoverSnapshot = []
            }
            PelmetLog.log("effect reveal \(sections) → engine (anim=\(appState.settings.revealAnimation.rawValue), cover=\(cover != nil))")
            await engine.reveal(sections)
            appState.updateSnapshot(await engine.snapshot())
            if let cover {
                // Hold until the engine is swap-quiet: under rapid
                // hover cycles the real swap can land AFTER the settle
                // report (epoch-guard race), and the agent animates
                // each swap — a timed grace popped the cover mid-slide.
                let fade = appState.settings.revealAnimation == .fade
                Task { @MainActor in
                    await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
                    if fade { cover.fadeOut() } else { cover.dismiss() }
                }
            }
            PelmetLog.log("effect reveal settled")
            onRevealSettled?()
        }
    }

    func performConceal() {
        Task {
            guard let appState else { return }
            // No cover on the way out. The agent fades concealed items in
            // place on its own (~100ms, frame-burst 2026-09-08 on 27.0 b8,
            // Instant/Fade/Smooth alike); the manufactured strip that used
            // to float here was built against an earlier build that popped
            // them, and by 0.2.13 it only added artifacts — the Smooth slide
            // dragged the wallpaper along (issue #5), a pre-captured strip
            // one reflow stale made the chevron jump when it faded, and a
            // cut-out variant showed two sets of icons. The strip rect is
            // still measured: it is the reveal cover's footprint.
            rememberStrip(await concealStripFrames())
            PelmetLog.log("effect conceal → engine")
            await engine.conceal()
            appState.updateSnapshot(await engine.snapshot())
            PelmetLog.log("effect conceal settled")
            onConcealSettled?()
            scheduleRevealCoverPrecapture()
        }
    }

    private var precaptureTask: Task<Void, Never>?

    /// Once the bar has gone swap-quiet after a conceal, the strip region
    /// shows exactly the "empty bar" the next reveal wants to freeze —
    /// capture it now so the reveal floats it instantly. Smooth never floats
    /// a cover. One in flight at a time: rapid conceal cycles otherwise stack
    /// overlapping 3s polls, each ending in an SCK capture.
    private func scheduleRevealCoverPrecapture() {
        guard appState?.settings.revealAnimation != .smooth else { return }
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
