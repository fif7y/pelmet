// AppTiming.swift
// App-layer waits and windows tuned live against the agent's restart/reflow
// behavior. Values are load-bearing — rename freely, never retune casually.

import Foundation

enum AppTiming {
    /// Reveal/conceal cover watchdog.
    static let transitionCoverSafety: TimeInterval = 2.5
    /// Clock blink: replayed click's down→up hold, and how long after the
    /// up to re-acquire the assertion. The re-acquire delay doesn't change
    /// the visible flash (the agent finishes its reveal animation first —
    /// R=0/100/250ms all measured ~0.5s); it only keeps the click ahead.
    static let clockReplayHold: TimeInterval = 0.06
    static let clockBlinkReacquire: Duration = .milliseconds(120)
    /// Adoption deferral while a transition is in flight.
    static let adoptDeferralDelay: Duration = .milliseconds(300)
    static let adoptMaxDeferrals = 10
    /// Precaptured reveal-cover freshness: an appearance/wallpaper change
    /// while idle would flash a stale background.
    static let revealCoverFreshness: TimeInterval = 900
    /// Style signatures (2026-09-08): the agent's own reveal slide is ~300ms
    /// and its conceal fade ~150–230ms; these sit clearly apart from both.
    /// Fade: the empty-bar cover's crossfade on reveal, the opaque strip's
    /// dissolve on hide. Smooth: the icons-only slide toward the chevron.
    static let fadeRevealDuration: CFTimeInterval = 0.26
    static let fadeExitDuration: CFTimeInterval = 0.34
    static let smoothExitDuration: CFTimeInterval = 0.24
    static let smoothRevealDuration: CFTimeInterval = 0.32
    /// Minimum time the reveal pictures stay up: the agent's slide-in is
    /// ~300ms and Pelmet's separators attach in the same reflow.
    static let entranceCoverHold: TimeInterval = 0.45
    /// Minimum time the empty-bar cover stays over a conceal: the agent's
    /// own fade of the concealed items runs ~300ms past the swap.
    static let exitCoverHold: TimeInterval = 0.42
    /// Revealed-strip snapshot (taken at reveal settle) painted at once on the
    /// next Instant/Fade reveal. Long-lived: engine item changes invalidate it
    /// explicitly; the cap only guards wallpaper/appearance drift.
    static let revealedStripFreshness: TimeInterval = 900
    /// Tidy waits for the full reveal to land before rebuilding.
    static let tidyRevealWait: Duration = .seconds(1.2)
    /// Newly toggled-on extras become hostable before placing.
    static let newExtraPlacementDelay: Duration = .milliseconds(600)
    /// Below ~100ms every swipe-through of the band reads as a hover
    /// (the fire-time live-pointer check catches the rest).
    static let hoverDelayFloor: TimeInterval = 0.1
    /// MenuBarAgent finalizes a ⌘-drag position before adoption reads it.
    static let dragAdoptDelay: TimeInterval = 0.35
    /// Rehide re-arm while deferred (pointer in band / elevated window).
    static let rehideDeferRearm: TimeInterval = 1.5
    /// Termination: max wait for engine.stop() before replying anyway.
    static let terminationStopDeadline: TimeInterval = 2
    /// Accessibility grant poll. A revoked grant only shows up as empty AX
    /// walks, so the app reads TCC directly; 2s keeps a flipped toggle in
    /// System Settings visible within a breath without a hot loop.
    static let accessibilityPoll: Duration = .seconds(2)
    /// Physical placement: pre-measure bar settle, then bounded lookup
    /// retries for a freshly-shown item, then post-drag reflow settle.
    static let placementPreSettle: Duration = .milliseconds(450)
    static let placementLookupRetries = 3
    static let placementLookupRetryDelay: Duration = .milliseconds(550)
    static let postDragSettle: Duration = .milliseconds(300)
    /// Precapture waits this long after quiesce so the ghost's fade never
    /// bakes into the snapshot.
    static let precaptureGhostClearance: Duration = .milliseconds(300)
    /// Camera/mic indicator activation edge → placement queue: the system
    /// camera pill often takes over within ~50ms and the indicator defers to
    /// it again — queuing before the flap settles queues a dead walk.
    static let cameraIndicatorPlaceDebounce: Duration = .milliseconds(500)
    /// Relaunched app → adoption window: first wait lets the app construct
    /// its status item; the retry covers slow bootstraps (Electron vault
    /// apps build their tray ~20s in).
    static let relaunchAdoptionDelay: Duration = .seconds(3)
    static let relaunchAdoptionRetry: Duration = .seconds(15)
    /// Rescue force-show → measure: the attach + fade + agent reflow must
    /// finish or the frame still reads as a phantom (burned attempt 1 live).
    static let rescueForceShowSettle: Duration = .milliseconds(600)
    /// « expansion → re-measure: the overflow items reflow into the bar.
    static let overflowExpandSettle: Duration = .milliseconds(700)
}
