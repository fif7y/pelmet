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

    /// Ask for the grant: clear the stale TCC row (a Deny, or a row keyed to
    /// an older signature — toggling one of those in System Settings does
    /// nothing), re-register through the prompt API so the system dialog
    /// shows, and open the Accessibility pane behind it. Callers lower any
    /// floating window first: the tccd dialog comes up at normal level.
    /// The reset is keyed by BUNDLE ID, so it revokes every copy of Pelmet
    /// on the machine — harmless for one install, a trap for a dev running
    /// a second differently-signed copy (which also poisons the row on its
    /// own, 2026-09-06). Guarded to only ever run while NOT granted.
    static func request() {
        guard !isGranted else { return }
        Task.detached {
            await resetStaleRow()
            await MainActor.run {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                openSystemSettings()
            }
        }
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
