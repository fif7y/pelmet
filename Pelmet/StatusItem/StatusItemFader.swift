// StatusItemFader.swift
// The one home for the Pelmet-owned status item show/hide choreography.
// SeparatorManager and ExtrasManager previously carried verbatim copies of
// this (identical constants, identical ghost code) — the timings here were
// hard-won against the agent's reflow behavior; change them in ONE place.
//
// Three-phase hide: the glyph goes first (alpha 0, a ghost copy fades at its
// old position, exactly how the agent fades third-party conceals in place),
// the width collapses only once that fade is over — collapsing at swap time
// shifted every still-fading neighbor to its left by the item's width, the
// "dot slides" of issue #5 (frame-burst 2026-09-08) — and after that reflow
// settles the item leaves layout entirely: zero-length items still reserve
// their built-in spacing, which reads as a dead gap next to the chevron.

import AppKit

@MainActor
enum StatusItemFader {
    /// Delay before the show fade starts — in step with the agent fading in
    /// assertion-revealed items during its reflow.
    private static let attachDelay: TimeInterval = 0.08
    /// Fade duration, symmetric for show and hide (matched to the agent's).
    private static let fadeDuration: TimeInterval = 0.22
    /// When the width collapses: after the agent's own conceal fade (~10
    /// frames, measured 0.19s) so nothing visible is left of the item to
    /// shift. Also after this fader's ghost, which the collapse would
    /// otherwise pull a real-item reflow under.
    private static let collapseDelay: TimeInterval = 0.26
    /// When the collapsed item leaves layout (after that reflow settles).
    private static let layoutDropDelay: TimeInterval = 0.7
    /// Ease-out for entrances.
    private static let showCurve: (Float, Float, Float, Float) = (0.16, 1, 0.3, 1)
    /// Ease-IN for exits (hold, then accelerate away) — the show curve dumped
    /// the alpha in the first frames and the hide read as a pop.
    private static let hideCurve: (Float, Float, Float, Float) = (0.55, 0, 0.8, 0.4)

    /// Apply visibility with the standard choreography. `stillCurrent` guards
    /// the delayed phases: it must return true only while `visible` is still
    /// the desired state for this item (a quick reversal must cancel them).
    static func setVisible(
        _ visible: Bool,
        item: NSStatusItem,
        shownLength: CGFloat,
        shownAlpha: CGFloat,
        stillCurrent: @escaping @MainActor () -> Bool
    ) {
        if visible {
            attach(item, shownLength: shownLength)
            fadeIn(item, shownAlpha: shownAlpha, stillCurrent: stillCurrent)
        } else {
            showFadingGhost(for: item)
            item.button?.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay) { [weak item] in
                guard stillCurrent() else { return }
                item?.length = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + layoutDropDelay) { [weak item] in
                guard stillCurrent() else { return }
                item?.isVisible = false
            }
        }
    }

    /// Attach silently at FULL width — Pelmet items are pinned leftmost in
    /// their section, so the width lands in empty left-edge space and
    /// displaces nothing. Normally at companion time; an UNCOVERED reveal
    /// runs it a beat before the swap instead (`preattach` on the managers).
    /// An assertion swap alone fades the revealed icons in place (~130ms);
    /// an item joining the layout in the same pass turns it into an animated
    /// layout pass, and every revealed icon slides in from the chevron
    /// (~200ms) and drifts another ~300ms — the choppy uncovered reveal
    /// (60fps burst, 2026-09-11). Attached ahead, the swap changes no layout.
    static func attach(_ item: NSStatusItem, shownLength: CGFloat) {
        item.isVisible = true
        item.length = shownLength
        item.button?.alphaValue = 0
    }

    /// The show fade, in step with the agent fading in the revealed items.
    static func fadeIn(
        _ item: NSStatusItem, shownAlpha: CGFloat, stillCurrent: @escaping @MainActor () -> Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + attachDelay) { [weak item] in
            guard stillCurrent(), let button = item?.button else { return }
            AlphaFade.run(button, to: shownAlpha, duration: fadeDuration, controlPoints: showCurve) {
                button.alphaValue = shownAlpha  // re-sync the view property
            }
        }
    }

    /// The show fade for an item attached AHEAD of the swap: it was placed
    /// against the collapsed section (right by the chevron) and the swap
    /// glides it 33pt to its real slot on the agent's side over ~250ms, from
    /// under the neighbor that un-concealed there; the client-side frame
    /// reads final within 120ms, so the settle cannot be polled (60fps
    /// burst, 2026-09-11). Fade only once the glide is over, so the icon
    /// appears in place, a beat after the third-party icons. A stand-in
    /// picture fading at the slot in step with them was tried and dropped:
    /// the cached button draws its glyph ~17% larger than the bar does, so
    /// the handover popped.
    static func fadeInAfterGlide(
        _ item: NSStatusItem, shownAlpha: CGFloat, stillCurrent: @escaping @MainActor () -> Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + glideDelay) { [weak item] in
            guard stillCurrent(), let button = item?.button else { return }
            AlphaFade.run(button, to: shownAlpha, duration: fadeDuration, controlPoints: showCurve) {
                button.alphaValue = shownAlpha
            }
        }
    }
    /// The agent's glide of an attached-ahead item is over by ~250ms.
    private static let glideDelay: TimeInterval = 0.3

    /// Snapshot the button and fade the snapshot at its old screen position.
    static func showFadingGhost(for item: NSStatusItem) {
        guard
            !ConcealGhostOverlay.stripActive,  // the strip already shows this glyph
            let button = item.button,
            let buttonWindow = button.window,
            let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds)
        else { return }
        button.cacheDisplay(in: button.bounds, to: rep)
        let image = NSImage(size: button.bounds.size)
        image.addRepresentation(rep)

        let screenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let ghost = NSWindow(
            contentRect: screenRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.level = .statusBar
        ghost.ignoresMouseEvents = true
        ghost.hasShadow = false
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: screenRect.size)
        imageView.wantsLayer = true
        ghost.contentView = imageView
        ghost.orderFrontRegardless()
        AlphaFade.run(imageView, to: 0, duration: fadeDuration, controlPoints: hideCurve) {
            ghost.orderOut(nil)
        }
    }
}
