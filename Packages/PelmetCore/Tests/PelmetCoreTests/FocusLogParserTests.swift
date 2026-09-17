// FocusLogParserTests.swift
// Fixtures are real donotdisturbd lines from macOS 27 (2026-09-16), cut at
// os_log's 1 KB cap exactly as the log hands them out — the previous state
// is what gets truncated, the active one must still read.

import Testing
@testable import PelmetCore

struct FocusLogParserTests {
    static let on = "Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x7733529bf0; reason: user action; source: local; options: <none>; state: <DNDState: 0x773619d080; suppressionState: while UI locked; startDate: 2026-09-17 00:43:05 +0000; userVisibleTransitionDate: 4001-01-01 00:00:00 +0000; userVisibleTransitionLifetimeType: schedule; activeModeConfiguration: <DNDMutableModeConfiguration: 0x7732851700; mode: <DNDMode: 0x7734d2d0e0; name: Do Not Disturb; modeIdentifier: com.apple.donotdisturb.mode.default; symbolImageName: moon.fill; tintColorName: systemIndigoColor; symbolDescriptor: (null); semanticType: 0; visibility: 0; identifier: 17F98D64-A2D2-4178-A928-224C3ACCE520; isPlaceHolder: NO>; impactsAvailability: enabled; dimsLockScreen: default>; activeModeIdentifier: com.apple.donotdisturb.mode.default>; previousState: <DNDState: 0x77352adf80; suppressionState: inactive; startDate: 2026-09-16 20:32:37 +0000; userVisibleTransitionDate: 4001-01-01 00:00:00 +0000; userVisibleTransitionLifetimeType: none; activeModeConfiguration: (null); activeModeIde"
    static let off = "Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x773364e2b0; reason: user action; source: local; options: <none>; state: <DNDState: 0x773619d980; suppressionState: inactive; startDate: 2026-09-17 00:48:30 +0000; userVisibleTransitionDate: 4001-01-01 00:00:00 +0000; userVisibleTransitionLifetimeType: none; activeModeConfiguration: (null); activeModeIdentifier: (null)>; previousState: <DNDState: 0x773619da40; suppressionState: while UI locked; startDate: 2026-09-17 00:43:05 +0000; userVisibleTransitionDate: 4001-01-01 00:00:00 +0000; userVisibleTransitionLifetimeType: schedule; activeModeConfiguration: <DNDMutableModeConfiguration: 0x7732853780; mode: <DNDMode: 0x7734d2e0d0; name: Do Not Disturb; modeIdentifier: com.apple.donotdisturb.mode.default; symbolImageName: moon.fill; tintColorName: systemIndigoColor; symbolDescriptor: (null); semanticType: 0; visibility: 0; identifier: 17F98D64-A2D2-4178-A928-224C3ACCE520; isPlaceHolder: NO>; impactsAvailability: enabled; dimsLockScreen: default>; activeModeIdentifier: com.apple.donotdistu"

    @Test func onReadsTheActiveModeNotThePreviousOne() {
        #expect(FocusLogParser.activeMode(in: Self.on) == FocusMode(
            identifier: "com.apple.donotdisturb.mode.default",
            name: "Do Not Disturb",
            symbol: "moon.fill"
        ))
    }

    @Test func offReadsNoModeEvenThoughThePreviousStateNamesOne() {
        #expect(Self.off.contains("moon.fill"))
        #expect(FocusLogParser.activeMode(in: Self.off) == nil)
    }

    @Test func customModeWithoutSymbolFallsBackToTheMoon() {
        let line = "Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x1; state: <DNDState: 0x2; activeModeConfiguration: <DNDMutableModeConfiguration: 0x3; mode: <DNDMode: 0x4; name: Deep Work; modeIdentifier: 5E1F; symbolDescriptor: (null)>>; activeModeIdentifier: 5E1F>; previousState: <DNDState: 0x6; activeModeIdentifier: (null)>>"
        #expect(FocusLogParser.activeMode(in: line) == FocusMode(identifier: "5E1F", name: "Deep Work", symbol: "moon.fill"))
    }

    @Test func aLineCutBeforeActiveModeIdentifierStillReadsTheModeBlock() {
        let cut = String(Self.on.prefix(upTo: Self.on.range(of: "; activeModeIdentifier:")!.lowerBound))
        #expect(FocusLogParser.activeMode(in: cut)?.identifier == "com.apple.donotdisturb.mode.default")
    }
}
