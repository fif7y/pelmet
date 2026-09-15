// HelperHosts.swift
// The main-app side of the section helpers (docs/HELPER-PROCESS-PLAN.md).
// One helper bundle per concealable section hosts that section's own items
// so the per-bundle hide assertion covers them like any third-party icon.
// This launches a helper lazily (first item wanted), hands it the full list
// to host, relaunches it if it dies, and routes its events to AppState.
//
// Adoption: the agent defers adopting a registration made while an
// assertion holds, so a helper's fresh items need an adoption window
// (`EngineGoldenGate.openAdoptionWindow`) when they arrive mid-session —
// same as a relaunched third-party app. At boot the engine waits for the
// helpers before its first converge (`waitUntilHosted`).

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class HelperHosts {
    private struct Host {
        let section: PelmetCore.Section
        let bundleID: String
        let appName: String
        /// Items wanted, keyed by the manager that wants them (separators,
        /// extras) — each manager owns its slice.
        var wanted: [String: [HostedItem]] = [:]
        var ready = false
        var hosted: Set<String> = []
        var running: NSRunningApplication?
        var launching = false
        var relaunches = 0

        var wantedItems: [HostedItem] { wanted.values.flatMap { $0 } }
        var wantsAnything: Bool { !wantedItems.isEmpty }
    }

    private var hosts: [PelmetCore.Section: Host] = [
        .hidden: Host(section: .hidden, bundleID: PelmetBundle.hiddenHostID, appName: "PelmetItems-Hidden"),
        .alwaysHidden: Host(section: .alwaysHidden, bundleID: PelmetBundle.alwaysHiddenHostID, appName: "PelmetItems-AlwaysHidden"),
    ]
    private var listener: MessagePortListener?
    private var terminationObserver: NSObjectProtocol?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        listener = MessagePortListener(name: PelmetBundle.mainLinkPort) { data in
            guard let event = HelperWire.decode(HelperEvent.self, from: data) else { return }
            Task { @MainActor in appState.helperHosts?.handle(event) }
        }
        if listener == nil {
            PelmetLog.log("helpers: link port \(PelmetBundle.mainLinkPort) taken — another Pelmet listening?")
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier, PelmetBundle.helperIDs.contains(bundle) else { return }
            Task { @MainActor [weak self] in self?.helperTerminated(bundle: bundle, pid: app.processIdentifier) }
        }
    }

    /// Bundle ids of helpers that host anything right now.
    var activeBundleIDs: Set<String> {
        Set(hosts.values.filter { $0.running != nil && $0.wantsAnything }.map(\.bundleID))
    }

    /// Replace `source`'s slice of `section`'s items. Idempotent: the helper
    /// diffs. An empty total quits the helper.
    func set(_ items: [HostedItem], for section: PelmetCore.Section, source: String) {
        guard var host = hosts[section] else { return }
        let before = host.wantedItems
        host.wanted[source] = items.isEmpty ? nil : items
        hosts[section] = host
        guard before != host.wantedItems else { return }
        push(section)
    }

    private func push(_ section: PelmetCore.Section) {
        guard let host = hosts[section] else { return }
        if !host.wantsAnything {
            if host.running != nil, let data = HelperWire.encode(HelperCommand.quit) {
                PelmetLog.log("helpers: \(host.appName) hosts nothing — quit")
                MessagePortLink.send(data, to: host.bundleID)
            }
            return
        }
        guard host.running != nil else { launch(section); return }
        guard host.ready, let data = HelperWire.encode(HelperCommand.sync(host.wantedItems)) else { return }
        PelmetLog.log("helpers: \(host.appName) ← sync \(host.wantedItems.count) item(s)")
        if !MessagePortLink.send(data, to: host.bundleID) {
            PelmetLog.log("helpers: \(host.appName) not answering — relaunch")
            hosts[section]?.ready = false
            hosts[section]?.running = nil
            launch(section)
        }
    }

    private func launch(_ section: PelmetCore.Section) {
        guard var host = hosts[section], !host.launching else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(host.appName).app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            PelmetLog.log("helpers: \(host.appName) missing at \(url.path)")
            return
        }
        host.launching = true
        host.ready = false
        host.hosted = []
        hosts[section] = host
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.environment = ["PELMET_PARENT_PID": "\(ProcessInfo.processInfo.processIdentifier)"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            Task { @MainActor [weak self] in
                guard let self, var host = self.hosts[section] else { return }
                host.launching = false
                if let error {
                    PelmetLog.log("helpers: \(host.appName) launch failed — \(error.localizedDescription)")
                } else {
                    host.running = app
                    PelmetLog.log("helpers: \(host.appName) launched pid=\(app?.processIdentifier ?? 0)")
                }
                self.hosts[section] = host
            }
        }
    }

    private func helperTerminated(bundle: String, pid: pid_t) {
        guard let section = hosts.first(where: { $0.value.bundleID == bundle })?.key,
              var host = hosts[section] else { return }
        guard host.running?.processIdentifier == pid || host.running == nil else { return }
        host.running = nil
        host.ready = false
        host.hosted = []
        hosts[section] = host
        guard host.wantsAnything else { return }
        host.relaunches += 1
        hosts[section] = host
        guard host.relaunches <= 3 else {
            PelmetLog.log("helpers: \(host.appName) died \(host.relaunches) times — giving up this session")
            return
        }
        PelmetLog.log("helpers: \(host.appName) died — relaunching")
        launch(section)
    }

    private func handle(_ event: HelperEvent) {
        switch event {
        case .ready(let bundle):
            guard let section = hosts.first(where: { $0.value.bundleID == bundle })?.key else { return }
            PelmetLog.log("helpers: \(hosts[section]?.appName ?? bundle) ready")
            hosts[section]?.ready = true
            if hosts[section]?.running == nil {
                hosts[section]?.running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            }
            push(section)
        case .hosted(let bundle, let title):
            guard let section = hosts.first(where: { $0.value.bundleID == bundle })?.key else { return }
            hosts[section]?.hosted.insert(title)
            PelmetLog.log("helpers: \(hosts[section]?.appName ?? bundle) hosts \(title)")
            appState?.helperHosted(title: title, bundle: bundle)
        case .clicked(_, let title, let rightButton, let x, let y):
            appState?.helperItemClicked(title: title, rightButton: rightButton, at: NSPoint(x: x, y: y))
        case .draggedOff(_, let title):
            appState?.helperItemDraggedOff(title: title)
        }
    }

    /// Boot: give the helpers a moment to register their items before the
    /// first converge asserts over them.
    func waitUntilHosted(deadline: TimeInterval = 3) async {
        let until = Date.now.addingTimeInterval(deadline)
        while Date.now < until {
            let pending = hosts.values.filter { host in
                host.wantsAnything && !Set(host.wantedItems.map(\.title)).isSubset(of: host.hosted)
            }
            if pending.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        PelmetLog.log("helpers: not every item hosted within \(Int(deadline))s — continuing")
    }
}
