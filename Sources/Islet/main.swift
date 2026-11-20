import AppKit
import ServiceManagement

// `Islet --unregister-login-item` is what uninstall.sh runs before deleting the
// app: only the app itself can withdraw its "launch at login" registration, and
// a deleted app would otherwise leave a dead entry in System Settings.
if CommandLine.arguments.contains("--unregister-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

// `Islet --login-item-status` says whether macOS will launch Islet at login:
// handy to check an installation from a terminal.
if CommandLine.arguments.contains("--login-item-status") {
    switch SMAppService.mainApp.status {
    case .enabled: print("enabled")
    case .requiresApproval: print("requiresApproval")
    case .notRegistered: print("notRegistered")
    case .notFound: print("notFound")
    @unknown default: print("unknown")
    }
    exit(0)
}

// Islet is a menu-bar agent: no Dock icon and no regular window. Everything
// lives in a borderless panel pinned to the notch (see IslandWindowController).
MainActor.assumeIsolated {
    let application = NSApplication.shared
    // `NSApplication.delegate` is weak: this local keeps the delegate alive for
    // as long as `run()` does not return, which is the lifetime of the process.
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
