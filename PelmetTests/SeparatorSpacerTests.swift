// SeparatorSpacerTests.swift
// The invisible spacer's width is the only thing it has to offer, so it has
// to reach the bar: the helper-hosted item takes it as its length, drawn
// styles still size themselves to their glyph, and a spec saved before the
// width control existed keeps the 14pt it had.

import Foundation
import Testing
import PelmetCore
@testable import Pelmet

struct SeparatorSpacerTests {
    @Test func spacerCarriesItsWidthAsTheItemLength() {
        let spec = SeparatorSpec(style: .space, width: 32)
        let hosted = SeparatorManager.hostedItem(for: spec)
        #expect(hosted.length == 32)
        #expect(hosted.text == "")
        #expect(hosted.alpha == 0)
    }

    @Test func drawnStylesSizeToTheirGlyphAndKeepTheirOpacity() {
        let spec = SeparatorSpec(style: .pipe, opacity: 0.4, width: 32)
        let hosted = SeparatorManager.hostedItem(for: spec)
        // nil length = NSStatusItem.variableLength: the glyph decides.
        #expect(hosted.length == nil)
        #expect(hosted.text == "|")
        #expect(hosted.alpha == 0.4)
    }

    @Test func specsSavedBeforeTheWidthControlKeepFourteenPoints() throws {
        let old = #"{"id":"B0798AD6-3A23-40D4-BEC1-15D93744288A","style":" ","opacity":0.55}"#
        let spec = try JSONDecoder().decode(SeparatorSpec.self, from: Data(old.utf8))
        #expect(spec.width == SeparatorSpec.defaultWidth)
        #expect(spec.width == 14)
    }

    @Test func widthSurvivesARoundTrip() throws {
        let spec = SeparatorSpec(style: .space, width: 26)
        let data = try JSONEncoder().encode(spec)
        let back = try JSONDecoder().decode(SeparatorSpec.self, from: data)
        #expect(back.width == 26)
    }
}
