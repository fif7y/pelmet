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
        HStack(spacing: 6) {
            chip
            // A custom combo gets a way back to the default without knowing
            // about ⌫ — the × only exists while there is something to undo.
            if !recording, let shortcut, shortcut != fallback {
                Button {
                    commit(fallback)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Restore \(fallback.display)")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: shortcut == fallback)
        .onDisappear(perform: stopRecording)
    }

    private var chip: some View {
        Button {
            recording ? stopRecording() : startRecording()
        } label: {
            // The chip keeps the width of its widest label at rest. A
            // click grew "⌥⌘N" into "Type shortcut…", the row's ViewThatFits
            // flipped to its vertical candidate, and the recorder there was
            // a fresh view with `recording` false again — the click did
            // nothing (#54, Korean, the Notification Center row).
            ZStack {
                Text("Type shortcut…").hidden()
                if recording {
                    Text("Type shortcut…")
                } else if let shortcut {
                    Text(verbatim: shortcut.display)
                } else {
                    Text("Record shortcut")
                }
            }
            .fixedSize()
            // System font, not monospaced: mono shrinks ⇧⌥⌘ to specks. Apple's
            // menus draw modifier glyphs this size with a touch of tracking.
            .font(.system(size: 13, weight: .medium))
            .kerning(1.5)
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
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
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

    /// The key's name for display. `chars` is `charactersIgnoringModifiers`,
    /// which follows the ACTIVE input source: recording ⌥A with Korean input
    /// on named the shortcut `⌥ㅁ`, and it stayed that way after switching
    /// back to Roman. The registration is by key code and fired on the A key
    /// the whole time — only the label was wrong. macOS names shortcuts from
    /// the Roman layout, so ask that layout first and keep `chars` as the
    /// fallback for a key it cannot translate.
    static func keyName(
        keyCode: Int,
        chars: String?,
        romanKey: @MainActor (Int) -> String? = romanKeyName
    ) -> String {
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
        if let roman = romanKey(keyCode), !roman.isEmpty { return roman.uppercased() }
        return chars?.uppercased() ?? "?"
    }

    /// What `keyCode` types on the current ASCII-capable layout, unmodified.
    /// Nil when there is no such layout or the key does not produce a
    /// character on it (a dead key, a keypad code some layouts omit).
    static func romanKeyName(keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// macOS's own shortcuts (System Settings › Keyboard › Keyboard Shortcuts).
/// `RegisterEventHotKey` accepts a combination the system already holds
/// and the system then consumes the key first, so the handler never runs
/// and the registration's return says nothing (#55: ⌥A, Show Notification
/// Center, recorded fine and never fired). The list lives in
/// `com.apple.symbolichotkeys`, each entry `enabled` + `value.parameters`
/// = [character, keyCode, AppKit modifier mask].
enum SystemShortcuts {
    static func owns(_ spec: HotkeySpec) -> Bool {
        guard let table = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys") else { return false }
        let wanted = appKitMask(fromCarbon: spec.modifiers)
        return table.values.contains { entry in
            guard let entry = entry as? [String: Any],
                  (entry["enabled"] as? Bool ?? (entry["enabled"] as? Int == 1)),
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any], parameters.count >= 3,
                  let keyCode = (parameters[1] as? NSNumber)?.uint32Value,
                  let mask = (parameters[2] as? NSNumber)?.uint32Value else { return false }
            return keyCode == spec.keyCode && mask & Self.allModifiers == wanted
        }
    }

    private static let allModifiers = UInt32(NSEvent.ModifierFlags([.shift, .control, .option, .command]).rawValue)

    private static func appKitMask(fromCarbon mods: UInt32) -> UInt32 {
        var flags: NSEvent.ModifierFlags = []
        if mods & UInt32(controlKey) != 0 { flags.insert(.control) }
        if mods & UInt32(optionKey) != 0 { flags.insert(.option) }
        if mods & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if mods & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return UInt32(flags.rawValue)
    }
}
