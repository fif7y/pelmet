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
    /// Dot-zone clicks press the clock through AX after the drop: give the
    /// agent this long to apply the drop first, then this long for
    /// Notification Center's panel to show before pressing again.
    static let clockPressSettle: Duration = .milliseconds(120)
    static let clockPressVerify: TimeInterval = 0.3
    /// Longest the blink cover waits for the concealed items to leave the
    /// AX tree after the re-acquire before lifting anyway.
    static let clockBlinkCoverDeadline: TimeInterval = 1.5
    /// Notification Center's panel slides in over ~100ms from Pelmet's
    /// press; the blink cover crossfades from the bare still to the
    /// under-panel one over that slide, starting at the press.
    static let panelSlideIn: Duration = .milliseconds(0)
    static let panelSlideInFade: CFTimeInterval = 0.22
    /// Notification Center's leading edge, points in from the display's
    /// right edge, at each 1/60s of its entrance: filmed at 60fps with the
    /// blink uncovered, three runs averaged (Gab's built-in, 2026-09-22
    /// 17:17). The edge is where the bar's shade reaches half its depth.
    static let panelEntranceInsets: [CGFloat] = [0, 16, 40, 130, 215, 255, 288, 316, 336, 352, 364, 374, 380, 382]
    /// From the relay's click being up to the panel's first frame (~100ms
    /// after the replayed mouse-down, which is held 60ms).
    static let panelEntranceDelay: CFTimeInterval = 0.035
    /// Where the panel's leading edge comes to rest, in from the display's
    /// right edge, as the bar's shade shows it (1390pt on an 1800pt bar).
    static let panelShadeInset: CGFloat = 410
    /// The panel's leading edge as the glass shows it: a ~70pt ramp
    /// (60fps profile, 2026-09-22 14:28).
    static let panelEdgeSoftness: CGFloat = 75
    /// The under-panel picture shows the visible cluster too, and that
    /// cluster drifts (battery, Wi-Fi, third-party glyphs): short-lived,
    /// and dropped outright when an own item redraws.
    static let underPanelPictureFreshness: TimeInterval = 120
    /// At the click that closes the panel, a kept picture older than this
    /// is retaken: the panel's content under the glass may have changed.
    static let underPanelPictureRefreshAtExit: TimeInterval = 10
    /// How long the blink cover stays after the concealed items have left
    /// the AX tree. Was `exitCoverHold` (0.42s) — the picture sat 1.0–1.5s
    /// on every clock click (#46). Measured 2026-09-21 at 60fps: lifting
    /// the moment they are gone shows no tail, the agent's fade is done by
    /// then. Kept as a knob at 0.
    static let clockBlinkLiftHold: TimeInterval = 0
    /// Adoption-window cover watchdog. The window itself runs up to
    /// `EngineTiming.adoptionWindowDeadline` (2.5s) and the converge that
    /// re-asserts follows it, so the blink's 2.5s would lift the picture
    /// mid-drop and show the very flash it is there to hide (#31).
    static let adoptionCoverSafety: TimeInterval = 6
    /// How long after a capture the bar is taken to be in its indicator-
    /// shifted place (see `ConcealGhostOverlay.captureIndicatorLit`): the
    /// indicator lasts ~3s, half a second is kept back for the edge.
    static let captureIndicatorHold: TimeInterval = 2.5
    /// Adoption deferral while a transition is in flight.
    static let adoptDeferralDelay: Duration = .milliseconds(300)
    static let adoptMaxDeferrals = 10
    /// Precaptured reveal-cover freshness: an appearance/wallpaper change
    /// while idle would flash a stale background.
    static let revealCoverFreshness: TimeInterval = 900
    /// How long a reveal waits for a cover retake still in flight (#49):
    /// a capture runs ~90ms here, up to ~470ms on a four-display Mac.
    static let coverRetakeWait: TimeInterval = 0.6
    /// Backdrop check delay after an animated window move (tiling key,
    /// activation, Space switch): a Space switch animates ~0.5s. A mouse-up
    /// is checked at once — the window is already where the drag left it.
    static let backdropSettle: TimeInterval = 0.6
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
    /// Uncovered reveal: own items attach this long before the swap so the
    /// agent has laid them out by the time it runs the reveal (measured
    /// 2026-09-11: placed within a frame of the attach; the lead only needs
    /// to clear that).
    static let ownItemAttachLead: Duration = .milliseconds(50)
    /// Minimum time the empty-bar cover stays over a conceal: the agent's
    /// own fade of the concealed items runs ~300ms past the swap.
    static let exitCoverHold: TimeInterval = 0.42
    /// Revealed-strip snapshot (taken at reveal settle) painted at once on the
    /// next Instant/Fade reveal. Long-lived: engine item changes invalidate it
    /// explicitly; the cap only guards wallpaper/appearance drift.
    static let revealedStripFreshness: TimeInterval = 900
    /// Apply waits for the full reveal to land before measuring.
    static let tidyRevealWait: Duration = .seconds(1.2)
    /// An own extra entering the bar is hosted before its one-item pass.
    static let newExtraPlacementDelay: Duration = .milliseconds(600)
    /// The boot own-item passes wait this long after the own items were
    /// adopted: 235ms after adoption the bar is still attaching (frames
    /// overlap, the chevron reads as trapped) and the pass planned on it —
    /// Media landed left of the chevron at 13:45 and was skipped as
    /// notOnScreen at 14:04, 2026-09-21. The post-swap and rest walks land
    /// within ~400ms of adoption.
    static let bootOwnItemLead: Duration = .seconds(2)
    /// Apply: a separator re-hosted onto a helper needs the helper up and
    /// its item registered before the bar is measured (launch → ready →
    /// hosts ≈ 100ms at boot; a cold launch takes longer).
    static let applyRehostWait: Duration = .milliseconds(1200)
    /// Below ~100ms every swipe-through of the band reads as a hover
    /// (the fire-time live-pointer check catches the rest).
    static let hoverDelayFloor: TimeInterval = 0.1
    /// A chevron click this soon after a hover reveal was dispatched was
    /// decided before the user could see the bar open (the picture is up
    /// ~100–200ms after dispatch, a reaction takes ~250ms more): it means
    /// "open", not "the opposite of where we're heading". Measured 2026-09-18:
    /// a click 95ms after the picture flashed open-shut-open, 350ms after
    /// it read as a close.
    static let hoverRevealClickGrace: TimeInterval = 0.5
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
    /// Apply (docs/CORE-SETS.md): the pass borrows the pointer only after
    /// this much quiet, bounded so a restless pointer still gets the
    /// shielded drag rather than a pass that never starts.
    static let applyIdleGap: TimeInterval = 1.5
    static let applyIdleMaxWait: TimeInterval = 8
    /// Post-drag read: the agent animates the drop (~300ms slide, measured
    /// 2026-09-08) and a single fixed-delay read judged mid-flight frames as
    /// misses. Wait the floor, then re-read every poll until the dragged
    /// item's frame repeats `quiesceMatches` times, bounded by the cap.
    static let postDragSettleFloor: Duration = .milliseconds(150)
    static let postDragQuiescePoll: Duration = .milliseconds(45)
    static let postDragQuiesceMatches = 2
    static let postDragQuiesceCap: Duration = .milliseconds(900)
    /// Precapture waits this long after quiesce so the ghost's fade never
    /// bakes into the snapshot.
    static let precaptureGhostClearance: Duration = .milliseconds(300)
    /// Camera/mic indicator activation edge → one-item pass: the system
    /// camera pill often takes over within ~50ms and the indicator defers to
    /// it again — queuing before the flap settles queues a dead walk.
    static let cameraIndicatorPlaceDebounce: Duration = .milliseconds(500)
    /// Relaunched app → adoption window: first wait lets the app construct
    /// its status item; the retry covers slow bootstraps (Electron vault
    /// apps build their tray ~20s in).
    static let relaunchAdoptionDelay: Duration = .seconds(3)
    static let relaunchAdoptionRetry: Duration = .seconds(15)
    /// « expansion → re-measure: the trapped items reflow in left of the
    /// notch and the visible run shifts (~38pt) before frames are true.
    static let overflowExpandSettle: Duration = .milliseconds(700)
}
