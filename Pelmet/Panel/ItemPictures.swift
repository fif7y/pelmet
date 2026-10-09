// ItemPictures.swift
// One picture per item for the panel's tiles: the icon as the bar draws it,
// keyed out against the empty bar so it sits on glass with no bar around it
// (ported from the tray's TrayPictures). Memory only. Nothing here captures:
// the picture pass hands pictures in (TransitionCoordinator.picturePass).

import AppKit
import PelmetCore

@MainActor
final class ItemPictures {
    struct Picture {
        let image: CGImage
        /// Points on the display it was taken on.
        let size: CGSize
        let takenAt: Date
        /// One colour, as most bar glyphs are: the tile tints it for the
        /// panel's own appearance, since the bar it was taken on can be
        /// dark over a light panel or the other way round.
        let isMonochrome: Bool
    }

    /// Past this a picture is retaken on the next open: an app can redraw
    /// its icon (a badge, a new state) while it is hidden and nothing tells
    /// Pelmet. One pass every 15 minutes of use at most.
    static let maxAge: TimeInterval = 900

    private var pictures: [ItemID: Picture] = [:]

    func picture(for key: ItemID) -> Picture? {
        guard let picture = pictures[key], -picture.takenAt.timeIntervalSinceNow < Self.maxAge else { return nil }
        return picture
    }

    /// Keys with no fresh picture, in the order given.
    func missing(among keys: [ItemID]) -> [ItemID] { keys.filter { picture(for: $0) == nil } }

    func store(_ new: [ItemID: Picture]) {
        pictures.merge(new) { _, latest in latest }
    }

    func forgetAll() { pictures = [:] }

    /// `snap` is one item's column of a keyed-out strip, trimmed to the
    /// glyph's own pixels: an AX frame is not centred on what its item draws
    /// (Control Center's Sound sat left in its cell), and the tile centres
    /// the glyph itself. Nil when the column is blank.
    static func picture(from snap: ConcealGhostOverlay.BarSnapshot) -> Picture? {
        let image = snap.image
        guard snap.windowFrame.width > 0,
              let ink = inkBounds(of: image),
              let trimmed = image.cropping(to: ink.rect)
        else { return nil }
        let scale = CGFloat(image.width) / snap.windowFrame.width
        return Picture(
            image: trimmed,
            size: CGSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale),
            takenAt: snap.takenAt,
            isMonochrome: ink.monochrome)
    }

    /// The box around the item's own ink, padded by one pixel, and whether
    /// it is one flat colour. Ink is any pixel with alpha. A run of ink
    /// columns that touches the crop's edge and is see-through or narrow
    /// next to the widest run is a neighbour's capsule spilling over
    /// (Velja's, OpenClip's) and is left out. Nil when the picture is blank.
    private static func inkBounds(of image: CGImage) -> (rect: CGRect, monochrome: Bool)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func alpha(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4 + 3]) }

        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for x in 0...w {
            let inked = x < w && (0..<h).contains { alpha(x, $0) > 24 }
            if inked, start == nil { start = x }
            if !inked, let s = start { runs.append(s...(x - 1)); start = nil }
        }
        guard let widest = runs.map(\.count).max() else { return nil }
        let kept = runs.filter { run in
            guard runs.count > 1, run.lowerBound == 0 || run.upperBound == w - 1 else { return true }
            // A capsule's fill is see-through; a glyph has solid pixels.
            let solid = run.contains { x in (0..<h).contains { alpha(x, $0) > 160 } }
            return solid && run.count * 5 >= widest * 2
        }
        guard let minX = kept.first?.lowerBound, let maxX = kept.last?.upperBound else { return nil }

        var minY = h, maxY = -1
        // Flat colour: no tint, and one brightness. A white glyph on a grey
        // capsule is two brightnesses, and tinting it whole would fill the
        // capsule in.
        var solid = 0, tinted = 0, light = 0, dark = 0
        for y in 0..<h {
            for x in minX...maxX {
                let i = (y * w + x) * 4
                let a = Int(px[i + 3])
                guard a > 24 else { continue }
                minY = min(minY, y); maxY = max(maxY, y)
                // Colour only counts where the pixel is mostly opaque: an
                // antialiased edge blends with whatever the key left.
                guard a > 160 else { continue }
                solid += 1
                let r = Int(px[i]) * 255 / a, g = Int(px[i + 1]) * 255 / a, b = Int(px[i + 2]) * 255 / a
                if max(r, g, b) - min(r, g, b) > 40 { tinted += 1 }
                let luma = (r * 3 + g * 6 + b) / 10
                if luma > 170 { light += 1 } else if luma < 110 { dark += 1 }
            }
        }
        guard maxY >= minY else { return nil }
        let flat = tinted * 10 <= solid && (light * 10 >= solid * 9 || dark * 10 >= solid * 9)
        let lo = max(0, minX - 1), hi = min(w - 1, maxX + 1)
        // Rows are counted from the top here; CGImage cropping is too.
        let top = max(0, minY - 1), bottom = min(h - 1, maxY + 1)
        return (CGRect(x: lo, y: top, width: hi - lo + 1, height: bottom - top + 1), flat)
    }
}
