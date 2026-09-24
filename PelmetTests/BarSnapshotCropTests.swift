import AppKit
import CoreGraphics
import Testing
@testable import Pelmet

/// The blink cuts its cover out of the picture the idle pre-capture already
/// holds instead of taking one at the click (#45, #46). Cutting the wrong
/// columns shows the round trip the cover exists to hide, so the geometry is
/// pinned here — `cropColumns` is the whole decision, display-free.
struct BarSnapshotCropTests {
    /// A 2x picture of the bar from x=1000 to x=1400.
    let frame = NSRect(x: 1000, y: 900, width: 400, height: 39)
    let imageWidth = 800

    @Test func spanInsideThePictureBecomesItsColumns() {
        let columns = ConcealGhostOverlay.cropColumns(span: 1100...1300, frame: frame, imageWidth: imageWidth)
        // The crop pads the way a capture of that span would have, so the
        // background stays continuous: 1100-6 → 1306+6, doubled.
        #expect(columns == 188..<612)
    }

    @Test func aSpanReachingBothEdgesKeepsTheWholePicture() {
        // capturePadding on each side is exactly what snapshotSet added, so
        // the picture reaches this span precisely — no slack to spare.
        let span = (frame.minX + ConcealGhostOverlay.capturePadding)...(frame.maxX - ConcealGhostOverlay.capturePadding)
        #expect(ConcealGhostOverlay.cropColumns(span: span, frame: frame, imageWidth: imageWidth) == 0..<imageWidth)
    }

    @Test func aPictureShortOnTheRightIsRefused() {
        // The trailing edge lands just short of the clock; a picture cut
        // before it would leave the clock uncovered.
        #expect(ConcealGhostOverlay.cropColumns(span: 1100...1400, frame: frame, imageWidth: imageWidth) == nil)
    }

    @Test func aSpanStartingOffThePictureIsClampedNotRefused() {
        // A cover rect that budgets for icons sliding in starts far left of
        // the bar — a blink cover measured -430 where the bar starts at 0.
        // `snapshotSet` clamps a live capture to the display edge in exactly
        // the same way, so the stored picture is not short, it is the same
        // picture. Take it from column 0.
        #expect(ConcealGhostOverlay.cropColumns(span: 500...1300, frame: frame, imageWidth: imageWidth) == 0..<612)
        #expect(ConcealGhostOverlay.cropColumns(span: 990...1300, frame: frame, imageWidth: imageWidth) == 0..<612)
    }

    @Test func halfAPointOfSlackKeepsAPictureThatJustReachesTheClock() {
        let span = 1100...(frame.maxX - ConcealGhostOverlay.capturePadding + 0.4)
        #expect(ConcealGhostOverlay.cropColumns(span: span, frame: frame, imageWidth: imageWidth) != nil)
        let tooFar = 1100...(frame.maxX - ConcealGhostOverlay.capturePadding + 0.6)
        #expect(ConcealGhostOverlay.cropColumns(span: tooFar, frame: frame, imageWidth: imageWidth) == nil)
    }

    @Test func aCropTooNarrowToFloatIsRefused() {
        // Padding alone is 12pt, so no span is narrow enough on a real
        // picture — the floor catches a picture too coarse to carry the
        // span instead: 10 columns over 400pt leaves 6 for a 212pt crop.
        #expect(ConcealGhostOverlay.cropColumns(span: 1100...1300, frame: frame, imageWidth: 10) == nil)
        // 20 columns over the same 400pt leaves 10, and the crop stands.
        #expect(ConcealGhostOverlay.cropColumns(span: 1100...1300, frame: frame, imageWidth: 20) == 5..<15)
    }

    @Test func anEmptyPictureIsRefusedRatherThanDividedBy() {
        #expect(ConcealGhostOverlay.cropColumns(span: 1100...1300, frame: .zero, imageWidth: imageWidth) == nil)
        #expect(ConcealGhostOverlay.cropColumns(span: 1100...1300, frame: frame, imageWidth: 0) == nil)
    }
}
