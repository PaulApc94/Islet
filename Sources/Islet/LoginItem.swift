import Foundation
import ServiceManagement

/// "Launch at login" in one place: the default at first launch, the user's
/// choice afterwards, and what macOS has on record.
enum LoginItem {
    /// What the user wants. True until they turn the menu switch off.
    private static let wantedKey = "launchAtLoginWanted"
    /// The app location the login item was last set up for. macOS records a
    /// login item by path: an app that moved has to be registered again.
    private static let pathKey = "loginItemSetUpPath"

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// An island is meant to be there all the time, like the notch it lives
    /// in: an installed copy registers itself the first time it runs from a
    /// given location. It never overrides the user, neither after they turned
    /// the menu switch off, nor while macOS reports the item as disabled in
    /// System Settings.
    static func setUpIfNeeded(defaults: UserDefaults = .standard) {
        let path = Bundle.main.bundlePath
        // A development build would register its build folder instead of the app.
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return }
        guard defaults.string(forKey: pathKey) != path else { return }

        defaults.register(defaults: [wantedKey: true])
        if defaults.bool(forKey: wantedKey), status == .notRegistered || status == .notFound {
            do {
                try SMAppService.mainApp.register()
            } catch {
                // Not recorded as done: the next launch tries again.
                NSLog("Islet: could not turn launch at login on: %@", error.localizedDescription)
                return
            }
        }
        defaults.set(path, forKey: pathKey)
    }

    /// The menu switch: registers or withdraws the login item and remembers
    /// the choice, so that `setUpIfNeeded` respects it from then on.
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        defaults.set(enabled, forKey: wantedKey)
        defaults.set(Bundle.main.bundlePath, forKey: pathKey)
    }
}
