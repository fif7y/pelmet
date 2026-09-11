// AccessibilityAccess.swift
// Accessibility (TCC) grant: the one thing Pelmet cannot work without.
// Polls the grant so a toggle flipped in System Settings, or a permission
// dropped by an update with a new signature, surfaces in the app instead of
// leaving an engine that silently walks an empty AX tree. Also owns the
// grant request, which clears any stale TCC row first so the system prompt
// comes back even after an earlier Deny.

import AppKit
import ApplicationServices
import PelmetEngine

@MainActor
final class AccessibilityMonitor {
    private(set) var granted: Bool
    private let onChange: (Bool) -> Void
    private var task: Task<Void, Never>?

    init(onChange: @escaping (Bool) -> Void) {
        granted = AccessibilityAccess.isGranted
        self.onChange = onChange
    }

    /// `interval` is the resting cadence; `refresh()` forces a read (the
    /// onboarding and settings screens call it faster while they're up).
    func start(interval: Duration = AppTiming.accessibilityPoll) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.refresh()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refresh() {
        let now = AccessibilityAccess.isGranted
        guard now != granted else { return }
        granted = now
        onChange(now)
    }
}

enum AccessibilityAccess {
    /// Direct TCC read, never the in-process cache.
    static var isGranted: Bool { AXIsProcessTrustedWithOptions(nil) }

    /// Ask for the grant. The first press per launch is the plain path:
    /// register through the prompt API (which is what makes tccd add the
    /// row, toggled off) and open the Accessibility pane behind it. Only a
    /// repeat press while still ungranted clears the row first — a Deny, or
    /// a row keyed to an older signature, which toggling in System Settings
    /// does nothing about. The reset used to run unconditionally *before*
    /// the prompt; `tccutil` returns before tccd commits the delete, so the
    /// prompt's insert could land first and get wiped, leaving no row at all
    /// (issue #3, macOS 27 b8). Callers lower any floating window first:
    /// the tccd dialog comes up at normal level.
    /// The reset is keyed by BUNDLE ID, so it revokes every copy of Pelmet
    /// on the machine — harmless for one install, a trap for a dev running
    /// a second differently-signed copy (which also poisons the row on its
    /// own, 2026-09-06). Guarded to only ever run while NOT granted.
    @MainActor private static var requestCount = 0

    @MainActor static func request() {
        guard !isGranted else { return }
        requestCount += 1
        let repeatPress = requestCount > 1
        if isTranslocated {
            PelmetLog.log("ax: running translocated from \(Bundle.main.bundleURL.path) — grant will not stick")
        }
        Task.detached {
            if repeatPress {
                await resetStaleRow()
                // Let tccd commit the delete before re-registering.
                try? await Task.sleep(for: .milliseconds(500))
            }
            await MainActor.run {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                PelmetLog.log("ax: prompt requested (press \(requestCount), reset=\(repeatPress))")
                openSystemSettings()
            }
        }
    }

    /// True when Gatekeeper is running us from a randomized read-only copy
    /// (launched straight from the DMG or a quarantined Downloads folder).
    /// A TCC row recorded against that path dies with the mount.
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!)
    }

    private static func resetStaleRow() async {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            PelmetLog.log("ax: tccutil reset status=\(process.terminationStatus)")
        } catch {
            PelmetLog.log("ax: tccutil reset failed — \(error.localizedDescription)")
        }
    }
}

/// Screen Recording is optional: it feeds the hide/reveal covers (icons fade
/// and slide instead of popping). The cover path asks in passing ONCE, ever:
/// a dismissed dialog is an answer, and the pre-capture wants a cover at every
/// launch, so a per-launch ask nags at each start. Only a BUTTON press
/// escalates to the Screen & System Audio Recording pane: someone who said no
/// must not get System Settings thrown at them on every reveal (issue #11 —
/// it opened on each hover after the first prompt).
enum ScreenRecordingAccess {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    private static let promptedKey = "pelmet.screenRecordingPrompted"
    @MainActor private static var prompted: Bool {
        get { UserDefaults.standard.bool(forKey: promptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: promptedKey) }
    }

    /// Contextual ask, from the cover path: the system dialog once, then
    /// silence (the General tab's row stays for a change of mind).
    @MainActor
    static func promptOnce() {
        guard !isGranted, !prompted else { return }
        prompted = true
        CGRequestScreenCaptureAccess()
        PelmetLog.log("screen: recording access prompted (grant needs a relaunch)")
    }

    /// Explicit ask, from a Grant button: the system dialog if it never
    /// showed, otherwise the Settings pane. True when this call raised the
    /// system dialog (vs. opening Settings).
    @MainActor @discardableResult
    static func request() -> Bool {
        guard !isGranted else { return false }
        if !prompted {
            promptOnce()
            return true
        }
        openSystemSettings()
        return false
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )!)
    }
}
