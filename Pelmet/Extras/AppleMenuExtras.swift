// AppleMenuExtras.swift
// Apple's own Siri and Time Machine menu bar icons, the two switches behind
// System Settings › Menu Bar. SystemUIServer hosts both and the assessment
// assertion hides that process as one bundle, so the only way Pelmet can
// manage them one by one is to draw its own (`ExtraKind.timeMachine`,
// `.siri`) and switch Apple's twin off — through the same private calls the
// Settings pane makes (traced 2026-09-16: `CoreMenuExtra*` in
// SystemUIPlugin.framework for menu extras, `SRFUserDefaultsController` in
// SiriFoundation for Siri). Both persist like a click on the checkbox, and
// SystemUIServer reacts at once; writing the defaults keys by hand does
// neither.

import AppKit
import PelmetCore
import PelmetEngine

enum AppleMenuExtra: String, CaseIterable {
    case timeMachine
    case siri

    /// The Apple icon a Pelmet item stands in for, if any.
    init?(_ kind: ExtraKind) {
        switch kind {
        case .timeMachine: self = .timeMachine
        case .siri: self = .siri
        default: return nil
        }
    }

    /// Set while Pelmet is the one that switched Apple's icon off, so
    /// removing the Pelmet item gives it back.
    var restoreKey: String { "pelmet.appleExtra.\(rawValue).restore" }

    /// Whether Apple's icon is currently switched on in System Settings.
    var isShown: Bool {
        switch self {
        case .timeMachine: Self.timeMachineHandle() != nil
        case .siri: Self.siriVisible() ?? false
        }
    }

    /// Flips the System Settings switch. Returns false when the private
    /// call is missing on this OS build (nothing changed).
    @discardableResult
    func setShown(_ shown: Bool) -> Bool {
        let done: Bool
        switch self {
        case .timeMachine:
            if shown {
                guard let add = Self.symbol("CoreMenuExtraAddMenuExtra", in: Self.systemUIPlugin, as: AddMenuExtra.self)
                else { done = false; break }
                done = add(Self.timeMachineURL as CFURL, 0, 0, 0, 0, 0) == 0
            } else {
                guard let handle = Self.timeMachineHandle() else { done = true; break }
                guard let remove = Self.symbol("CoreMenuExtraRemoveMenuExtra", in: Self.systemUIPlugin, as: RemoveMenuExtra.self)
                else { done = false; break }
                done = remove(handle, 0) == 0
            }
        case .siri:
            done = Self.setSiriVisible(shown)
        }
        PelmetLog.log("apple extras: \(rawValue) → \(shown ? "shown" : "hidden") \(done ? "ok" : "FAILED (call missing)")")
        return done
    }

    // MARK: Time Machine — SystemUIPlugin.framework

    private typealias GetMenuExtra = @convention(c) (CFString, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias AddMenuExtra = @convention(c) (CFURL, Int32, Int32, Int32, Int32, Int32) -> Int32
    private typealias RemoveMenuExtra = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32

    private static let timeMachineID = "com.apple.menuextra.TimeMachine"
    private static let timeMachineURL = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/TimeMachine.menu")

    private static let systemUIPlugin = dlopen(
        "/System/Library/PrivateFrameworks/SystemUIPlugin.framework/SystemUIPlugin", RTLD_LAZY
    )

    /// SystemUIServer's handle for the loaded extra; nil when it isn't loaded
    /// (the switch is off).
    private static func timeMachineHandle() -> UnsafeMutableRawPointer? {
        guard let get = symbol("CoreMenuExtraGetMenuExtra", in: systemUIPlugin, as: GetMenuExtra.self) else { return nil }
        var handle: UnsafeMutableRawPointer?
        guard get(timeMachineID as CFString, &handle) == 0 else { return nil }
        return handle
    }

    // MARK: Siri — SiriFoundation.framework

    private static let siriFoundation = dlopen(
        "/System/Library/PrivateFrameworks/SiriFoundation.framework/SiriFoundation", RTLD_LAZY
    )

    private static func siriDefaults() -> NSObject? {
        _ = siriFoundation
        guard let cls = NSClassFromString("SRFUserDefaultsController") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("sharedUserDefaultsController"))
        else { return nil }
        return cls.perform(NSSelectorFromString("sharedUserDefaultsController"))?.takeUnretainedValue() as? NSObject
    }

    private static func siriVisible() -> Bool? {
        let selector = NSSelectorFromString("isStatusMenuVisible")
        guard let defaults = siriDefaults(), defaults.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(defaults.method(for: selector), to: Getter.self)(defaults, selector)
    }

    private static func setSiriVisible(_ visible: Bool) -> Bool {
        let selector = NSSelectorFromString("setStatusMenuVisible:")
        guard let defaults = siriDefaults(), defaults.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(defaults.method(for: selector), to: Setter.self)(defaults, selector, visible)
        return true
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }
}

enum Siri {
    /// What a click on Apple's icon does: bring up Siri.
    static func activate() {
        let url = URL(fileURLWithPath: "/System/Applications/Siri.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { PelmetLog.log("siri: open failed — \(error.localizedDescription)") }
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
    }
}
