import AppKit
import ServiceManagement

/// The settings menu. It lives in the menu-bar icon, and also opens from the
/// island itself (right-click) or when the app is launched again: on a crowded
/// menu bar, macOS hides the icons that do not fit behind the notch.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: Settings
    private let menu = NSMenu()
    /// The app the user was working in before Islet's menu took the keyboard.
    private var lastOtherApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(settings: Settings) {
        self.settings = settings
        super.init()

        let current = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, front != current {
            lastOtherApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != current { self?.lastOtherApp = app }
            }
        }

        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Islet")?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
        }

        menu.delegate = self
        statusItem.menu = menu
    }

    /// Opens the settings menu at a point on screen (global coordinates).
    func showMenu(at location: NSPoint) {
        // Without this the menu would not take the keyboard (arrows, Escape).
        NSApp.activate()
        // Returns once the menu is closed.
        menu.popUp(positioning: nil, at: location, in: nil)
        // Islet has no window to type in: hand the keyboard back to the app
        // the user was in, or their next keystrokes would go nowhere.
        if NSApp.isActive {
            lastOtherApp?.activate()
        }
    }

    /// Opens the settings menu just below the notch: a place that is always on screen.
    func showMenuBelowNotch() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let menuBar = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NSStatusBar.system.thickness
        showMenu(at: NSPoint(x: screen.frame.midX - 100, y: screen.frame.maxY - menuBar - 6))
    }

    // Rebuilt on every opening, so the checkmarks always reflect the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(header(version.map { "Islet \($0)" } ?? "Islet"))
        menu.addItem(.separator())

        menu.addItem(header(L10n.t("Activités", "Activities")))
        menu.addItem(toggle(L10n.t("Musique en direct", "Live Music"), \.showNowPlaying))
        menu.addItem(toggle(L10n.t("Changement de titre", "Track Changes"), \.showTrackChanges))
        menu.addItem(toggle(L10n.t("Volume", "Volume"), \.showVolume))
        menu.addItem(toggle(L10n.t("Charge et batterie", "Charging & Battery"), \.showPower))
        menu.addItem(toggle(L10n.t("Sortie audio", "Audio Output"), \.showAudioOutput))
        menu.addItem(.separator())

        menu.addItem(fitItem())
        menu.addItem(toggle(L10n.t("Ouvrir au survol", "Expand on Hover"), \.expandOnHover))
        menu.addItem(toggle(L10n.t("Retour haptique", "Haptic Feedback"), \.haptics))
        menu.addItem(loginItem())
        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("Quitter Islet", "Quit Islet"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(_ title: String, _ keyPath: ReferenceWritableKeyPath<Settings, Bool>) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = keyPath
        item.state = settings[keyPath: keyPath] ? .on : .off
        return item
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let keyPath = sender.representedObject as? ReferenceWritableKeyPath<Settings, Bool> else { return }
        settings[keyPath: keyPath].toggle()
    }

    // MARK: Fitting into the menu bar

    /// On, off, or "on but macOS has not allowed it yet" (a dash): fitting the
    /// player into the free room needs the Accessibility permission.
    private func fitItem() -> NSMenuItem {
        let waiting = settings.fitToMenuBar && !MenuBarProbe.isTrusted
        let title = waiting
            ? L10n.t("Éviter les icônes de la barre des menus (à autoriser dans Réglages)…",
                     "Avoid Menu Bar Items (allow in System Settings)…")
            : L10n.t("Éviter les icônes de la barre des menus", "Avoid Menu Bar Items")
        let item = NSMenuItem(title: title, action: #selector(toggleFit), keyEquivalent: "")
        item.target = self
        item.state = settings.fitToMenuBar ? (waiting ? .mixed : .on) : .off
        return item
    }

    @objc private func toggleFit() {
        if settings.fitToMenuBar, !MenuBarProbe.isTrusted {
            // Already asked for: take the user to the switch itself.
            MenuBarProbe.openAccessibilitySettings()
            return
        }
        settings.fitToMenuBar.toggle()
        if settings.fitToMenuBar, !MenuBarProbe.isTrusted {
            MenuBarProbe.requestPermission()
        }
    }

    // MARK: Launch at login

    private func loginItem() -> NSMenuItem {
        let status = LoginItem.status
        // Turned off in System Settings: registering again would not turn it
        // back on, only the user can, so the item leads there instead.
        let needsApproval = status == .requiresApproval
        let title = needsApproval
            ? L10n.t("Lancer au démarrage (à autoriser dans Réglages)…",
                     "Launch at Login (allow in System Settings)…")
            : L10n.t("Lancer au démarrage", "Launch at Login")
        let item = NSMenuItem(title: title, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.target = self
        item.state = status == .enabled ? .on : (needsApproval ? .mixed : .off)
        return item
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch LoginItem.status {
            case .enabled:
                try LoginItem.setEnabled(false)
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try LoginItem.setEnabled(true)
                if LoginItem.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            NSLog("Islet: could not change the login item: %@", error.localizedDescription)
            if LoginItem.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                NSSound.beep()
            }
        }
    }
}
