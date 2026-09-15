// ShortcutRecorder.swift
// Click-to-record global shortcut. A local keyDown monitor inside our own
// settings window, so recording needs no extra permission. ⎋ cancels,
// ⌫ puts `fallback` back — a shortcut is never off (Gab, 2026-09-15).

import Carbon.HIToolbox
import PelmetCore
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var shortcut: HotkeySpec?
    /// What ⌫ restores.
    let fallback: HotkeySpec
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            Group {
                if recording {
                    Text("Type shortcut…")
                } else if let shortcut {
                    Text(verbatim: shortcut.display)
                } else {
                    Text("Record shortcut")
                }
            }
            .font(.callout.monospaced())
            .foregroundStyle(recording ? .secondary : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(.primary.opacity(recording ? 0.04 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(PelmetAccent.accent, lineWidth: recording ? 1.5 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Click, then press the new shortcut. ⎋ cancels, ⌫ restores \(fallback.display).")
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // NSEvent is not Sendable — pull the scalars out before hopping
            // into the actor. The monitor already fires on the main thread.
            let keyCode = Int(event.keyCode)
            let flags = event.modifierFlags
            let chars = event.charactersIgnoringModifiers
            let consumed = MainActor.assumeIsolated {
                handle(keyCode: keyCode, flags: flags, chars: chars)
            }
            return consumed ? nil : event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    /// True when the recorder consumed the event.
    private func handle(keyCode: Int, flags: NSEvent.ModifierFlags, chars: String?) -> Bool {
        switch keyCode {
        case kVK_Escape:
            stopRecording()
            return true
        case kVK_Delete:
            commit(fallback)
            return true
        default:
            break
        }
        let mods = Self.carbonModifiers(from: flags)
        // A bare key (or shift alone) would hijack typing in every app.
        guard mods & ~UInt32(shiftKey) != 0 else {
            NSSound.beep()
            return true
        }
        commit(HotkeySpec(
            keyCode: UInt32(keyCode),
            modifiers: mods,
            display: Self.symbols(flags) + Self.keyName(keyCode: keyCode, chars: chars)
        ))
        return true
    }

    private func commit(_ new: HotkeySpec) {
        shortcut = new
        stopRecording()
    }

    /// AppKit modifier flags → the Carbon mask RegisterEventHotKey wants.
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    private static func keyName(keyCode: Int, chars: String?) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[keyCode] { return name }
        return chars?.uppercased() ?? "?"
    }
}
