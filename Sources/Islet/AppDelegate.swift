import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: IslandModel?
    private var windowController: IslandWindowController?
    private var statusItem: StatusItemController?
    private var debugObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two islands in the same notch would fight each other: the first one wins.
        if let identifier = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0 != NSRunningApplication.current }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        let model = IslandModel()
        let windowController = IslandWindowController(model: model)
        self.model = model
        self.windowController = windowController
        statusItem = StatusItemController(settings: model.settings)

        windowController.show()
        model.start()
        installDebugCommands(for: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
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
