// PelmetItems — M1 spike (docs/HELPER-PROCESS-PLAN.md).
// A bundle the assertion can exclude: hosts one hard-coded separator and
// nothing else. Exits when the parent (Pelmet) is gone; refuses to run
// twice.

import AppKit

let bundleID = Bundle.main.bundleIdentifier ?? "app.fif7y.Pelmet.items.hidden"
let me = ProcessInfo.processInfo.processIdentifier

// Single instance per helper bundle.
for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
where app.processIdentifier != me {
    app.forceTerminate()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Host: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?
    var parentWatch: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Pelmet.Separator.SPIKE"
        item.behavior = .removalAllowed
        item.button?.title = "|"
        item.button?.setAccessibilityTitle("Pelmet.Separator.SPIKE")
        item.isVisible = true
        self.item = item
        NSLog("PelmetItems: hosting Pelmet.Separator.SPIKE as %@ pid %d", bundleID, me)

        // Parent-exit watch: the launching Pelmet's pid, handed over at launch.
        let parent = ProcessInfo.processInfo.environment["PELMET_PARENT_PID"].flatMap(pid_t.init) ?? getppid()
        parentWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if kill(parent, 0) != 0 {
                NSLog("PelmetItems: parent %d gone — exiting", parent)
                NSApp.terminate(nil)
            }
        }
    }
}

let host = Host()
app.delegate = host
app.run()
