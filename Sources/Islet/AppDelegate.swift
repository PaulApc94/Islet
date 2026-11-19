import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: IslandModel?
    private var windowController: IslandWindowController?
    private var statusItem: StatusItemController?
    private var debugObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two islands in the same notch would fight each other: the first one wins.
        if let other = Self.otherRunningIslet() {
            NSLog("Islet: another Islet is already running (pid %d), quitting", other.processIdentifier)
            NSApp.terminate(nil)
            return
        }

        let model = IslandModel()
        let windowController = IslandWindowController(model: model)
        let statusItem = StatusItemController(settings: model.settings)
        self.model = model
        self.windowController = windowController
        self.statusItem = statusItem

        windowController.onSecondaryClick = { [weak statusItem] in
            statusItem?.showMenu(at: NSEvent.mouseLocation)
        }
        windowController.show()
        model.start()
        installDebugCommands(for: model)
    }

    /// Launching Islet again (Finder, Spotlight, Launchpad) opens the settings:
    /// the menu-bar icon may be hidden behind the notch on a crowded menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showMenuBelowNotch()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    /// Matches by bundle identifier, and also by executable name for runs
    /// outside the bundle (`swift run`), which have no identifier at all.
    private static func otherRunningIslet() -> NSRunningApplication? {
        let current = NSRunningApplication.current
        let identifier = Bundle.main.bundleIdentifier ?? "io.github.paulapc94.islet"
        return NSWorkspace.shared.runningApplications.first { app in
            app.processIdentifier != current.processIdentifier
                && (app.bundleIdentifier == identifier || app.executableURL?.lastPathComponent == "Islet")
        }
    }

    /// Development aid: with ISLET_DEBUG=1 the island obeys commands posted as
    /// distributed notifications (see scripts/dev/islet-debug.sh), which makes
    /// every state reachable without touching the mouse or the hardware.
    private func installDebugCommands(for model: IslandModel) {
        guard ProcessInfo.processInfo.environment["ISLET_DEBUG"] == "1" else { return }
        debugObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("io.github.paulapc94.islet.debug"),
            object: nil,
            queue: .main
        ) { [weak self, weak model] notification in
            let command = notification.object as? String ?? ""
            MainActor.assumeIsolated {
                // "snapshot:/path/to/file.png" draws the island into a PNG.
                if command.hasPrefix("snapshot:") {
                    let path = String(command.dropFirst("snapshot:".count))
                    self?.windowController?.writeSnapshot(to: URL(fileURLWithPath: path))
                } else {
                    model?.runDebugCommand(command)
                }
            }
        }
    }
}

extension IslandModel {
    func runDebugCommand(_ command: String) {
        switch command {
        case "expand": setExpanded(true)
        case "collapse": setExpanded(false)
        case "hover": pointerMoved(inside: true)
        case "unhover": pointerMoved(inside: false)
        case "volume": present(.volume(VolumeState(level: 0.62, isMuted: false)), for: 5)
        case "mute": present(.volume(VolumeState(level: 0.62, isMuted: true)), for: 5)
        case "charging": present(.charging(percent: 82), for: 5)
        case "low": present(.lowBattery(percent: 9), for: 5)
        case "output": present(.output(AudioOutput(name: "AirPods Pro", symbolName: "airpodspro")), for: 5)
        case "track": present(.track, for: 5)
        // The same calls as the player's buttons: they reach whatever is playing.
        case "toggle": togglePlayPause()
        case "next": nextTrack()
        case "previous": previousTrack()
        default: NSLog("Islet: unknown debug command '%@'", command)
        }
    }
}
