// GlassPanel.swift
// The surface Pelmet's floating panels share: a borderless, non-activating
// glass panel that hangs under the menu bar. Non-activating, so the app you
// were in stays in front. It draws no border of its own: the rounded glass
// is the edge, with the system shadow re-derived whenever the glass changes
// (an earlier panel's edge read as a heavy near-black ring that ignored the
// corners, and a shadow taken before the glass had its shape is the suspect).
//
// The window can be made as tall as the glass will ever get, with the glass
// in it pinned to the top (`setGlassHeight`): resizing the window itself
// waits on the window server, ~5–30ms a keystroke live (2026-10-04), and the
// glass inside it can change height without that.

import AppKit

@MainActor
class GlassPanel: NSPanel {
    static let cornerRadius: CGFloat = 12
    /// The system's shadow follows the rounded glass once it is re-derived
    /// (see `setGlassHeight`). If a live look still shows a dark ring at the edge,
    /// this is the one switch: the glass reads fine without a shadow.
    static let usesSystemShadow = true
    static let gapBelowBar: CGFloat = 4
    static let edgeMargin: CGFloat = 8

    /// `content` fills the glass; it is the caller's to size and lay out.
    init(content: NSView, cornerRadius: CGFloat = GlassPanel.cornerRadius) {
        content.translatesAutoresizingMaskIntoConstraints = false
        let host: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            host = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            host = effect
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                content.topAnchor.constraint(equalTo: effect.topAnchor),
                content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
        }
        let clear = NSView(frame: .zero)
        // Nothing a SwiftUI layer draws past the glass may reach the window's
        // shadow: with a window taller than the glass it drew a hard ring 17pt
        // below the glass (harness screenshots, 2026-10-04).
        host.clipsToBounds = true
        host.frame = clear.bounds
        host.autoresizingMask = [.width, .minYMargin]
        clear.addSubview(host)
        glass = host
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = Self.usesSystemShadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Its size is its content's: no edge resize, no drag of the surface.
        styleMask.remove(.resizable)
        isMovable = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = clear
    }

    /// The glass inside the window, as tall as `setGlassHeight` last said.
    private let glass: NSView

    var glassHeight: CGFloat { glass.frame.height }

    /// Clear room left of the glass, for `edgeAccessory` to reach past its
    /// edge. The window is this much wider than the glass.
    var leadingMargin: CGFloat = 0 {
        didSet { setGlassHeight(glass.frame.height) }
    }

    /// Laid over the glass's left edge, half in `leadingMargin`, as tall as
    /// the glass: the panel's column grip. Set once.
    var edgeAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let edgeAccessory { contentView?.addSubview(edgeAccessory) }
            layoutAccessory()
        }
    }

    /// Where the glass is on screen; below it the window is clear.
    var glassScreenFrame: NSRect {
        NSRect(x: frame.minX + leadingMargin, y: frame.maxY - glass.frame.height,
               width: frame.width - leadingMargin, height: glass.frame.height)
    }

    /// Move or resize the window, then re-derive the shadow from what is on
    /// screen.
    func place(_ frame: NSRect, display: Bool = true) {
        setFrame(frame, display: display)
        glass.frame.size.height = min(glass.frame.height, frame.height)
        layoutAccessory()
        invalidateShadow()
    }

    /// Change the glass's height inside the window, its top edge staying
    /// put; the window is not resized. Below the glass the window is clear.
    func setGlassHeight(_ height: CGFloat) {
        let bounds = contentView?.bounds ?? .zero
        let height = min(height, bounds.height)
        glass.frame = NSRect(x: leadingMargin, y: bounds.height - height,
                             width: max(bounds.width - leadingMargin, 0), height: height)
        layoutAccessory()
        invalidateShadow()
    }

    private func layoutAccessory() {
        guard let edgeAccessory else { return }
        edgeAccessory.frame = NSRect(x: 0, y: glass.frame.minY, width: 2 * leadingMargin, height: glass.frame.height)
    }

    /// The bar's own height on `screen`: the visibleFrame band, falling
    /// back to the safe area under a full-screen app.
    static func barHeight(of screen: NSScreen) -> CGFloat {
        let safeBand = screen.safeAreaInsets.top
        let visibleBand = screen.frame.maxY - screen.visibleFrame.maxY
        let band = visibleBand > 0 && (safeBand == 0 || visibleBand <= safeBand + 2) ? visibleBand : safeBand
        return band > 0 ? band : 24
    }

    /// Top edge of a panel hung under the bar on `screen` (Cocoa y).
    static func topUnderBar(of screen: NSScreen) -> CGFloat {
        screen.frame.maxY - barHeight(of: screen) - gapBelowBar
    }
}

/// A glass panel that can take keyboard focus (a text field in it types)
/// without activating the app or becoming its main window.
final class KeyableGlassPanel: GlassPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
