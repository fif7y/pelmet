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
    /// the glyph itself. `raw` and `background` are the same column as
    /// filmed and on the empty bar: a one-colour glyph is un-blended from
    /// them into a mask the tile tints (the keyed column keeps each
    /// antialiased edge whole, in the bar's colour: a dark fringe on light
    /// glass). Nil when the column is blank.
    static func picture(from snap: ConcealGhostOverlay.BarSnapshot, raw: CGImage?, background: CGImage?) -> Picture? {
        let image = snap.image
        guard snap.windowFrame.width > 0, let ink = inkBounds(of: image) else { return nil }
        let mask = raw.flatMap { raw in background.flatMap { flatMask(raw: raw, background: $0) } }
        guard let trimmed = (mask ?? image).cropping(to: ink) else { return nil }
        let scale = CGFloat(image.width) / snap.windowFrame.width
        return Picture(
            image: trimmed,
            size: CGSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale),
            takenAt: snap.takenAt,
            isMonochrome: mask != nil)
    }

    /// The box around the item's own ink, padded by one pixel. Ink is any
    /// pixel with alpha. A run of ink columns that touches the crop's edge
    /// and is see-through or narrow next to the widest run is a neighbour's
    /// capsule spilling over (Velja's, OpenClip's) and is left out. Nil when
    /// the picture is blank.
    private static func inkBounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let bitmap = rgba(image, width: w, height: h) else { return nil }
        defer { withExtendedLifetime(bitmap.context) {} }
        let px = bitmap.pixels
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
        for y in 0..<h where (minX...maxX).contains(where: { alpha($0, y) > 24 }) {
            minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxY >= minY else { return nil }
        let lo = max(0, minX - 1), hi = min(w - 1, maxX + 1)
        // Rows are counted from the top here; CGImage cropping is too.
        let top = max(0, minY - 1), bottom = min(h - 1, maxY + 1)
        return CGRect(x: lo, y: top, width: hi - lo + 1, height: bottom - top + 1)
    }

    /// A one-colour glyph as a white mask, or nil when it is not one: every
    /// changed pixel lighter than the bar (or every one darker), barely any
    /// colour. Each pixel's alpha is how far it is from the bar, over how
    /// far the glyph's core is: antialiased edges come out partial, not in
    /// the bar's colour, and a grey capsule comes out as a faint fill.
    private static func flatMask(raw: CGImage, background: CGImage) -> CGImage? {
        let w = raw.width, h = raw.height
        guard w > 0, h > 0, background.width == w, background.height == h,
              let rawBitmap = rgba(raw, width: w, height: h), let barBitmap = rgba(background, width: w, height: h)
        else { return nil }
        defer { withExtendedLifetime((rawBitmap.context, barBitmap.context)) {} }
        let s = rawBitmap.pixels, b = barBitmap.pixels
        func luma(_ p: UnsafeMutablePointer<UInt8>, _ i: Int) -> Int { (Int(p[i]) * 3 + Int(p[i + 1]) * 6 + Int(p[i + 2])) / 10 }
        var changed = 0, strong = 0, tinted = 0, lighter = 0, darker = 0
        var spread = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let d = max(abs(Int(s[i]) - Int(b[i])), abs(Int(s[i + 1]) - Int(b[i + 1])), abs(Int(s[i + 2]) - Int(b[i + 2])))
            guard d > 6 else { continue }
            changed += 1
            let dl = luma(s, i) - luma(b, i)
            if dl > 0 { lighter += 1 } else if dl < 0 { darker += 1 }
            guard d >= 26 else { continue }
            strong += 1
            spread[min(255, abs(dl))] += 1
            if Int(max(s[i], s[i + 1], s[i + 2])) - Int(min(s[i], s[i + 1], s[i + 2])) > 40 { tinted += 1 }
        }
        let sign = lighter * 20 >= changed * 19 ? 1 : darker * 20 >= changed * 19 ? -1 : 0
        guard strong > 0, sign != 0, tinted * 10 <= strong else { return nil }
        // The core's distance from the bar: the strong pixels' 90th
        // percentile, so a stray pixel does not set it.
        var seen = 0, peak = 255
        for level in 0...255 {
            seen += spread[level]
            if seen * 10 >= strong * 9 { peak = level; break }
        }
        guard peak >= 40 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        let out = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let dl = (luma(s, i) - luma(b, i)) * sign
            let a = UInt8(clamping: max(0, min(255, dl * 255 / peak)))
            out[i] = a; out[i + 1] = a; out[i + 2] = a; out[i + 3] = a
        }
        return ctx.makeImage()
    }

    /// RGBA8 premultiplied, top row first. The context owns the pixels:
    /// keep it while reading them.
    private static func rgba(_ image: CGImage, width w: Int, height h: Int) -> (context: CGContext, pixels: UnsafeMutablePointer<UInt8>)? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (ctx, data.bindMemory(to: UInt8.self, capacity: w * h * 4))
    }
}
