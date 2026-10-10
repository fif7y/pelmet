// PanelDragGhost.swift
// The tile in the air while it is dragged between sections (docs/PANEL-PLAN.md
// D1): its well and glyph at 1.08 scale on a small glass of their own, under
// the pointer. A window apart from the panel, above the menu bar's level, so it
// can travel up over the bar to drop on it. It takes no mouse events and
// carries no pasteboard: nothing else can accept the drop.

import AppKit
import PelmetCore
import SwiftUI

@MainActor
final class PanelDragGhost {
    static let scale: CGFloat = 1.08
    /// The mock's landing: 200ms on its enter curve; ours is a touch quicker.
    static let landing: TimeInterval = 0.18

    private let window: GlassPanel

    /// `appearance` is the panel's, so the ghost reads in the same mode.
    init(art: PanelTileArt, grid: PanelGrid, appearance: NSAppearance?) {
        let well = grid.metrics.wellSize
        let size = CGSize(width: (well.width * Self.scale).rounded(.up), height: (well.height * Self.scale).rounded(.up))
        let radius: CGFloat = (grid.layout == .row ? 8 : 13) * Self.scale
        let hosting = NSHostingView(rootView: Face(art: art, grid: grid, scale: Self.scale))
        hosting.sizingOptions = []
        window = GlassPanel(content: hosting, cornerRadius: radius)
        // Above the menu bar, and the panel's own level.
        window.level = .popUpMenu
        window.ignoresMouseEvents = true
        window.appearance = appearance
        window.alphaValue = 0
        window.place(NSRect(origin: .zero, size: size))
        window.setGlassHeight(size.height)
    }

    var size: CGSize { window.frame.size }

    /// Centred on `point`, a screen point (y up).
    func move(toCenter point: CGPoint) {
        window.setFrameOrigin(NSPoint(x: (point.x - size.width / 2).rounded(), y: (point.y - size.height / 2).rounded()))
    }

    func show(at point: CGPoint) {
        move(toCenter: point)
        window.orderFrontRegardless()
        window.alphaValue = 1
    }

    /// Back to the tile it came from, then gone: a cancelled drag. With no
    /// tile to go back to (the panel closed), or Reduce Motion, it only fades.
    func slideBack(toCenter point: CGPoint?, reduceMotion: Bool) {
        let target = point.map {
            NSRect(x: ($0.x - size.width / 2).rounded(), y: ($0.y - size.height / 2).rounded(),
                   width: size.width, height: size.height)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.landing
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            if let target, !reduceMotion { window.animator().setFrame(target, display: true) }
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            Task { @MainActor in window.orderOut(nil) }
        })
    }

    /// Dropped on a section: the tile is there now, the ghost lets go.
    func release() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            Task { @MainActor in window.orderOut(nil) }
        })
    }

    private struct Face: View {
        let art: PanelTileArt
        let grid: PanelGrid
        let scale: CGFloat
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let ink = PanelInk(scheme: scheme)
            let well = grid.metrics.wellSize
            ZStack {
                RoundedRectangle(cornerRadius: grid.layout == .row ? 8 : 13, style: .continuous)
                    .fill(ink.wellHover)
                PanelTileLabel(art: art, grid: grid, ink: ink, glyphOnly: true)
            }
            .frame(width: well.width, height: well.height)
            .scaleEffect(scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
