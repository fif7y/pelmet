// TrayPictures.swift
// One picture per item for the floating bar, cut from the strip pictures the
// transitions already take (icons keyed out against the empty bar, so they
// sit on glass with no bar background around them). Keyed by the model key;
// sizes in points on the display the picture was taken on. Nothing here
// captures: the coordinator hands pictures in when it has them.

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class TrayPictures {
    struct Picture {
        let image: CGImage
        /// Points on the source display.
        let size: CGSize
        let takenAt: Date
    }

    private(set) var pictures: [ItemID: Picture] = [:]

    /// Cut every framed item out of the primary-display picture. Frames are
    /// AX global top-left in the primary band, the picture's window frame is
    /// Cocoa global: only x is needed, the band is the picture's height.
    /// `within` bounds the columns that were keyed against the empty bar; an
    /// item outside it would carry bar background and is left out. Returns
    /// how many pictures landed.
    @discardableResult
    func harvest(_ snaps: [ConcealGhostOverlay.BarSnapshot], items: [ObservedItem], within: ClosedRange<CGFloat>? = nil) -> Int {
        guard let primary = NSScreen.screens.first,
              let snap = snaps.first(where: { primary.frame.contains(NSPoint(x: $0.windowFrame.midX, y: primary.frame.midY)) })
        else { return 0 }
        let scale = CGFloat(snap.image.width) / snap.windowFrame.width
        var count = 0
        for item in items {
            guard let frame = item.frame, frame.width > 4,
                  frame.minX >= snap.windowFrame.minX - 0.5, frame.maxX <= snap.windowFrame.maxX + 0.5,
                  within.map({ $0.contains(frame.minX) && $0.contains(frame.maxX) }) ?? true
            else { continue }
            // Neighbouring AX frames overlap by a point or two: keep the
            // core so a neighbour's edge never rides along.
            let inset: CGFloat = 1
            let x = ((frame.minX + inset - snap.windowFrame.minX) * scale).rounded()
            let w = ((frame.width - 2 * inset) * scale).rounded()
            let rect = CGRect(x: x, y: 0, width: w, height: CGFloat(snap.image.height))
            guard w > 0, var cut = snap.image.cropping(to: rect) else { continue }
            // Trim to the glyph's own columns: an AX frame is not centred
            // on what its item draws (Control Center's Sound sat left in
            // its cell), and the cell pads every glyph evenly itself.
            if let bounds = Self.opaqueColumns(of: cut), bounds.width > 0,
               let trimmed = cut.cropping(to: CGRect(x: bounds.lowerBound, y: 0, width: bounds.width, height: CGFloat(cut.height))) {
                cut = trimmed
            }
            pictures[item.id.sectionKey] = Picture(
                image: cut,
                size: CGSize(width: CGFloat(cut.width) / scale, height: snap.windowFrame.height),
                takenAt: snap.takenAt
            )
            count += 1
        }
        return count
    }

    /// The leftmost and rightmost columns with any alpha, padded by one
    /// pixel; nil when the picture is blank.
    private static func opaqueColumns(of image: CGImage) -> (lowerBound: CGFloat, width: CGFloat)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var first = w, last = -1
        for x in 0..<w {
            var any = false
            for y in 0..<h where px[(y * w + x) * 4 + 3] > 24 { any = true; break }
            if any { first = min(first, x); last = max(last, x) }
        }
        guard last >= first else { return nil }
        let lo = max(0, first - 1), hi = min(w - 1, last + 1)
        return (CGFloat(lo), CGFloat(hi - lo + 1))
    }

    func picture(for key: ItemID) -> Picture? { pictures[key] }

    /// Keys with no picture yet, in the order given.
    func missing(among keys: [ItemID]) -> [ItemID] { keys.filter { pictures[$0] == nil } }

    func forget(_ key: ItemID) { pictures[key] = nil }
    func forgetAll() { pictures = [:] }
}
