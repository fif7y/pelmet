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

    /// The floating bar hangs down from the bar edge and leaves the same
    /// way, exit shorter and eased in (Design Sense: exits are designed).
    static let trayEntrance: CFTimeInterval = 0.18
    static let trayExit: CFTimeInterval = 0.14
    /// A width change while the bar is open (an item joins or leaves).
    static let trayReflow: CFTimeInterval = 0.2
    /// Relay: after the press, how long an item gets to show a menu or
    /// panel before the section conceals again; and how long an open menu
    /// keeps the section revealed beneath the cover.
    static let trayRelayMenuWait: TimeInterval = 1.5
    static let trayRelayMenuCap: TimeInterval = 60
    /// When the only sign the press showed something is the app coming to
    /// the front, the item stays revealed at most this long.
    static let trayRelayFrontCap: TimeInterval = 3
    /// Relay: the items must be at rest before their pictures are taken —
    /// the agent's entrance draws a capsule behind an arriving item for
    /// ~450ms past the swap (three cells came out boxed at 120ms).
    static let trayRelaySettle: Duration = .milliseconds(520)
    /// The tray re-pictures its section on open once a picture is older
    /// than this (a badge, a temperature); a press never pictures.
    static let trayPictureFreshness: TimeInterval = 600
    /// The rehide countdown never runs shorter than this while the tray is
    /// up: the pointer has to leave the band to reach it.
    static let trayReachGrace: TimeInterval = 0.8
}
