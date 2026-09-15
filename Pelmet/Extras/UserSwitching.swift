// UserSwitching.swift
// The fast user switching menu, Pelmet's version. macOS's own is a Control
// Center extra the assessment assertion hides. The session moves come from
// the private login.framework (`SACSwitchToLoginWindow`,
// `SACLockScreenImmediate`, `SACSwitchToUser`), the same calls the system
// menu makes; the account list comes from Open Directory's local node.

import AppKit
import OpenDirectory
import PelmetEngine

enum UserSwitching {
    struct Account: Equatable {
        let name: String
        let fullName: String
        let uid: uid_t
    }

    static var current: Account {
        Account(name: NSUserName(), fullName: NSFullUserName(), uid: getuid())
    }

    /// Other login-capable local accounts: uid ≥ 500, not a service account.
    static func otherAccounts() -> [Account] {
        guard let session = ODSession.default(),
              let node = try? ODNode(session: session, type: ODNodeType(kODNodeTypeLocalNodes)),
              let query = try? ODQuery(
                node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeUniqueID,
                matchType: ODMatchType(kODMatchAny), queryValues: nil,
                returnAttributes: [kODAttributeTypeUniqueID, kODAttributeTypeFullName, kODAttributeTypeRecordName],
                maximumResults: 0
              ),
              let records = try? query.resultsAllowingPartial(false) as? [ODRecord]
        else { return [] }
        let me = getuid()
        var accounts: [Account] = []
        for record in records {
            guard let name = record.recordName,
                  !name.hasPrefix("_"),
                  let uidString = (try? record.values(forAttribute: kODAttributeTypeUniqueID))?.first as? String,
                  let uid = uid_t(uidString), uid >= 500, uid != me
            else { continue }
            let fullName = ((try? record.values(forAttribute: kODAttributeTypeFullName))?.first as? String) ?? name
            accounts.append(Account(name: name, fullName: fullName, uid: uid))
        }
        return accounts.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    // MARK: login.framework

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    typealias NoArgCall = @convention(c) () -> Int32
    typealias NameCall = @convention(c) (CFString) -> Int32

    @discardableResult
    static func switchToLoginWindow() -> Bool {
        guard let call = symbol("SACSwitchToLoginWindow", as: NoArgCall.self) else { return false }
        let result = call()
        PelmetLog.log("users: login window → \(result)")
        return result == 0
    }

    @discardableResult
    static func lockScreen() -> Bool {
        guard let call = symbol("SACLockScreenImmediate", as: NoArgCall.self) else { return false }
        let result = call()
        PelmetLog.log("users: lock screen → \(result)")
        return result == 0
    }

    /// Straight to that account's login screen. The call takes the record
    /// name (disassembled 2026-09-15: a retained object handed to the session
    /// agent proxy); a refusal falls back to the plain login window.
    static func switchTo(_ account: Account) {
        if let call = symbol("SACSwitchToUser", as: NameCall.self) {
            let result = call(account.name as CFString)
            PelmetLog.log("users: switch to \(account.name) → \(result)")
            if result == 0 { return }
        }
        switchToLoginWindow()
    }

    static func openUsersSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")!)
    }
}
