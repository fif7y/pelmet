import CoreGraphics
import Testing
@testable import Pelmet

/// Notification Center's windows are told apart by their owner's pid. The
/// owner NAME is localized — "알림 센터" on a Korean Mac — so matching
/// "Notification Center" read the panel as closed everywhere but English:
/// the shortcut pressed again and closed a panel that had fully opened, and
/// the panel's windows counted as backdrop.
struct NotificationCenterWindowTests {
    let pid: pid_t = 512

    func window(owner: String, pid: pid_t) -> [String: Any] {
        [kCGWindowOwnerName as String: owner, kCGWindowOwnerPID as String: pid]
    }

    @Test func theEnglishNameIsFoundByPid() {
        #expect(ClockClickRelay.isNotificationCenterWindow(window(owner: "Notification Center", pid: pid), pid: pid))
    }

    @Test func aLocalizedNameIsFoundByPid() {
        #expect(ClockClickRelay.isNotificationCenterWindow(window(owner: "알림 센터", pid: pid), pid: pid))
        #expect(ClockClickRelay.isNotificationCenterWindow(window(owner: "Centre de notifications", pid: pid), pid: pid))
    }

    @Test func anotherProcessWithTheNameIsNot() {
        #expect(!ClockClickRelay.isNotificationCenterWindow(window(owner: "Notification Center", pid: 99), pid: pid))
    }

    @Test func withoutAPidTheEnglishNameStandsIn() {
        // The process not found: what was matched before, no worse.
        #expect(ClockClickRelay.isNotificationCenterWindow(window(owner: "Notification Center", pid: 99), pid: nil))
        #expect(!ClockClickRelay.isNotificationCenterWindow(window(owner: "알림 센터", pid: 99), pid: nil))
    }

    @Test func anEntryWithoutAnOwnerPidIsNot() {
        #expect(!ClockClickRelay.isNotificationCenterWindow([kCGWindowOwnerName as String: "알림 센터"], pid: pid))
    }
}
