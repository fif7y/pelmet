// PelmetTimer.swift
// Pelmet's own countdown. macOS's timer item is a Control Center Live
// Activity: any assessment assertion hides it, and its state sits behind the
// private `com.apple.private.mobiletimerd` entitlement (probed 2026-09-15),
// so the only timer that can stay in a Pelmet-managed bar is one Pelmet runs
// itself. Durations from the item's menu, a countdown in the bar, a sound
// and a banner when it ends. The fire date persists so a relaunch keeps
// counting.

import AppKit
import PelmetEngine
import UserNotifications

@MainActor
final class PelmetTimer {
    enum State: Equatable {
        case idle
        case running(fireDate: Date)
        case paused(remaining: TimeInterval)
        /// Rang; stays in the bar until dismissed, like Apple's.
        case done
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { persist(); onChange() } }
    }
    /// State or displayed-second changes.
    var onChange: () -> Void = {}

    static let presets: [TimeInterval] = [60, 300, 600, 900, 1500, 1800, 2700, 3600]

    private var tick: Timer?
    private var ringer: Timer?
    private var rings = 0
    private static let fireDateKey = "pelmet.timer.fireDate"
    private static let pausedKey = "pelmet.timer.pausedRemaining"
    nonisolated private static let notificationID = "app.fif7y.Pelmet.timer"

    init() {
        restore()
    }

    var isActive: Bool { state != .idle }

    var remaining: TimeInterval? {
        switch state {
        case .idle: nil
        case .running(let fireDate): max(0, fireDate.timeIntervalSinceNow)
        case .paused(let remaining): remaining
        case .done: 0
        }
    }

    /// "12:34", "1:02:03" past the hour. Ceiling, so a fresh 5 min timer
    /// reads 5:00 and ends on 0:00.
    var display: String? {
        guard let remaining else { return nil }
        let total = Int(remaining.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func label(for duration: TimeInterval) -> String {
        let minutes = Int(duration / 60)
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? String(localized: "1 hour") : String(localized: "\(hours) hours")
        }
        return String(localized: "\(minutes) min")
    }

    func start(_ duration: TimeInterval) {
        stopRinging()
        state = .running(fireDate: Date().addingTimeInterval(duration))
        armTick()
        PelmetLog.log("timer: start \(Int(duration))s")
    }

    func pause() {
        guard case .running(let fireDate) = state else { return }
        state = .paused(remaining: max(0, fireDate.timeIntervalSinceNow))
        tick?.invalidate()
        tick = nil
    }

    func resume() {
        guard case .paused(let remaining) = state else { return }
        state = .running(fireDate: Date().addingTimeInterval(remaining))
        armTick()
    }

    func addMinute() {
        switch state {
        case .running(let fireDate): state = .running(fireDate: fireDate.addingTimeInterval(60))
        case .paused(let remaining): state = .paused(remaining: remaining + 60)
        case .idle, .done: break
        }
    }

    func cancel() {
        tick?.invalidate()
        tick = nil
        stopRinging()
        state = .idle
        PelmetLog.log("timer: cancelled")
    }

    /// Done → idle (a click on the ringing item).
    func dismiss() {
        guard state == .done else { return }
        stopRinging()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        state = .idle
    }

    // MARK: Clock

    private func armTick() {
        tick?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFired() }
        }
        // Common modes: the countdown keeps moving while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private var lastShown: String?

    private func tickFired() {
        guard case .running(let fireDate) = state else { return }
        if fireDate.timeIntervalSinceNow <= 0 {
            fire()
            return
        }
        let shown = display
        if shown != lastShown {
            lastShown = shown
            onChange()
        }
    }

    private func fire() {
        tick?.invalidate()
        tick = nil
        state = .done
        PelmetLog.log("timer: done")
        ring()
        rings = 1
        // Apple's timer rings until dismissed; Pelmet insists for a while,
        // then leaves the "0:00" in the bar as the reminder.
        let repeater = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .done else { return }
                self.rings += 1
                if self.rings > 8 { self.stopRinging(); return }
                self.ring()
            }
        }
        RunLoop.main.add(repeater, forMode: .common)
        ringer = repeater
        postNotification()
    }

    private func ring() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func stopRinging() {
        ringer?.invalidate()
        ringer = nil
        rings = 0
    }

    private func postNotification() {
        Task {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert])
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Timer done")
            content.body = String(localized: "Click the timer in the menu bar to dismiss it.")
            let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    // MARK: Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        switch state {
        case .running(let fireDate):
            defaults.set(fireDate.timeIntervalSince1970, forKey: Self.fireDateKey)
            defaults.removeObject(forKey: Self.pausedKey)
        case .paused(let remaining):
            defaults.set(remaining, forKey: Self.pausedKey)
            defaults.removeObject(forKey: Self.fireDateKey)
        case .idle, .done:
            defaults.removeObject(forKey: Self.fireDateKey)
            defaults.removeObject(forKey: Self.pausedKey)
        }
    }

    private func restore() {
        let defaults = UserDefaults.standard
        if let paused = defaults.object(forKey: Self.pausedKey) as? TimeInterval, paused > 0 {
            state = .paused(remaining: paused)
        } else if let stamp = defaults.object(forKey: Self.fireDateKey) as? TimeInterval {
            let fireDate = Date(timeIntervalSince1970: stamp)
            if fireDate.timeIntervalSinceNow > 0 {
                state = .running(fireDate: fireDate)
                armTick()
                PelmetLog.log("timer: restored, \(Int(fireDate.timeIntervalSinceNow))s left")
            } else {
                // Ended while Pelmet was away: no ring after the fact.
                defaults.removeObject(forKey: Self.fireDateKey)
            }
        }
    }
}
