import AppKit
import ServiceManagement

/// The menu-bar icon: the only place where Islet has settings.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
        super.init()

        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Islet")?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuilt on every opening, so the checkmarks always reflect the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(header(version.map { "Islet \($0)" } ?? "Islet"))
        menu.addItem(.separator())

        menu.addItem(header(L10n.t("Activités", "Activities")))
        menu.addItem(toggle(L10n.t("Changement de titre", "Track Changes"), \.showTrackChanges))
        menu.addItem(toggle(L10n.t("Volume", "Volume"), \.showVolume))
        menu.addItem(toggle(L10n.t("Charge et batterie", "Charging & Battery"), \.showPower))
        menu.addItem(toggle(L10n.t("Sortie audio", "Audio Output"), \.showAudioOutput))
        menu.addItem(.separator())

        menu.addItem(toggle(L10n.t("Ouvrir au survol", "Expand on Hover"), \.expandOnHover))
        menu.addItem(toggle(L10n.t("Retour haptique", "Haptic Feedback"), \.haptics))

        let login = NSMenuItem(title: L10n.t("Lancer au démarrage", "Launch at Login"),
                               action: #selector(toggleLaunchAtLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
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

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Islet: could not change the login item: %@", error.localizedDescription)
            NSSound.beep()
        }
    }
}
