import AppKit
import Combine
import ServiceManagement

/// The settings menu. It lives in the menu-bar icon, and also opens from the
/// island itself (right-click) or when the app is launched again: on a crowded
/// menu bar, macOS hides the icons that do not fit behind the notch, and the
/// user can hide Islet's own to leave its place beside the notch free.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings: Settings
    private let menu = NSMenu()
    /// The app the user was working in before Islet's menu took the keyboard.
    private var lastOtherApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var modeObservation: AnyCancellable?
    private var visibilityObservation: NSKeyValueObservation?
    private var iconImage: NSImage?

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
            iconImage = image
            button.image = image
        }

        menu.delegate = self
        statusItem.menu = menu

        applyMode(spacer: settings.pushMenuBarIcons, icon: settings.showMenuBarIcon)
        // `@Published` emits before storing the new value: use the ones emitted.
        modeObservation = settings.$pushMenuBarIcons.combineLatest(settings.$showMenuBarIcon)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] spacer, icon in
                MainActor.assumeIsolated { self?.applyMode(spacer: spacer, icon: icon) }
            }
        // The other way round: the icon can also be dragged out of the menu
        // bar (Command-drag). The setting follows, or the icon would be back
        // at the next launch. (Not the spacer: its coming and going is ours.)
        visibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard let visible = change.newValue else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isSpacer, self.settings.showMenuBarIcon != visible else { return }
                    self.settings.showMenuBarIcon = visible
                }
            }
        }
    }

    // MARK: Icon or spacer

    /// The item is either Islet's icon, or a spacer that pushes the icon on its
    /// left (see `MenuBarSpring`). The spacer still shows the capsule, as small
    /// as it is narrow: an item that takes room without showing anything looks
    /// like a hole in the menu bar, and gives nothing to click.
    private var isSpacer = false
    private var spacerTimer: Timer?
    /// What the item really has right now, in the middle of an animation too.
    private var shownLength: CGFloat?
    private(set) var spacerLength: CGFloat?
    private var pills: [Int: NSImage] = [:]

    /// Islet's capsule drawn to fit a spacer of this length; nothing when the
    /// spacer is too narrow to show a shape.
    private func pill(forLength length: CGFloat) -> NSImage? {
        let width = Int(min(length, 18) - 1)
        guard width >= 3 else { return nil }
        if let pill = pills[width] { return pill }
        let size = CGSize(width: CGFloat(width), height: max(2, (CGFloat(width) * 0.54).rounded()))
        let pill = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            return true
        }
        pill.isTemplate = true
        pill.accessibilityDescription = "Islet"
        pills[width] = pill
        return pill
    }

    private func applyMode(spacer: Bool, icon: Bool) {
        spacerTimer?.invalidate()
        spacerTimer = nil
        spacerLength = nil
        shownLength = nil
        isSpacer = spacer
        if spacer {
            // Out of the menu bar until the spring knows the room. Sized while
            // it is out: an item that appears with its old width is, for one
            // layout pass, too wide for its place.
            statusItem.isVisible = false
            statusItem.button?.image = nil
            statusItem.length = MenuBarSpring.minimumLength
        } else {
            statusItem.button?.image = iconImage
            statusItem.length = NSStatusItem.squareLength
            statusItem.isVisible = icon
        }
    }

    private func show(_ length: CGFloat?) {
        shownLength = length
        if let length {
            statusItem.button?.image = pill(forLength: length)
            // Length first, for the same reason as above.
            statusItem.length = length
            if !statusItem.isVisible { statusItem.isVisible = true }
        } else if statusItem.isVisible {
            statusItem.isVisible = false
        }
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
        menu.addItem(toggle(L10n.t("Icône dans la barre des menus", "Menu Bar Icon"), \.showMenuBarIcon))
        menu.addItem(pushItem())
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
        // Always a plain switch. While macOS has not allowed it, a click turns
        // the option back off: nobody should have to grant a permission to get
        // rid of it. Turning it on again asks again.
        settings.fitToMenuBar.toggle()
        if settings.fitToMenuBar, !MenuBarProbe.isTrusted {
            MenuBarProbe.requestPermission()
        }
    }

    // MARK: Pushing the neighbouring icon

    /// Like fitting, it needs to know where the menu bar's items are, hence the
    /// same three states.
    private func pushItem() -> NSMenuItem {
        let waiting = settings.pushMenuBarIcons && !MenuBarProbe.isTrusted
        let title = waiting
            ? L10n.t("Décaler l'icône voisine quand l'île sort (à autoriser dans Réglages)…",
                     "Move the Next Icon Aside (allow in System Settings)…")
            : L10n.t("Décaler l'icône voisine quand l'île sort", "Move the Next Icon Aside")
        let item = NSMenuItem(title: title, action: #selector(togglePush), keyEquivalent: "")
        item.target = self
        item.state = settings.pushMenuBarIcons ? (waiting ? .mixed : .on) : .off
        return item
    }

    @objc private func togglePush() {
        settings.pushMenuBarIcons.toggle()
        if settings.pushMenuBarIcons, !MenuBarProbe.isTrusted {
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

// MARK: - Spacer

extension StatusItemController: MenuBarSpacer {
    private static let spacerAnimation: TimeInterval = 0.25

    /// Only the length can be animated: the gap macOS adds beside the item
    /// comes and goes with it, in one step. So the spacer shrinks faster and
    /// faster and is then taken out, or is put in narrow and widens ever more
    /// slowly: the jump falls where the neighbour moves fastest.
    func setSpacer(length target: CGFloat?) {
        guard isSpacer else { return }
        spacerTimer?.invalidate()
        spacerLength = target
        let leaving = target == nil
        if shownLength == nil {
            guard !leaving else { return }
            show(MenuBarSpring.minimumLength)
        }
        let from = shownLength ?? MenuBarSpring.minimumLength
        let to = target ?? MenuBarSpring.minimumLength
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isSpacer else { return timer.invalidate() }
                let progress = min(1, (CACurrentMediaTime() - began) / Self.spacerAnimation)
                if progress >= 1 {
                    timer.invalidate()
                    self.show(target)
                } else {
                    let eased = leaving ? progress * progress : 1 - (1 - progress) * (1 - progress)
                    self.show(from + (to - from) * eased)
                }
            }
        }
        // Common modes: it must keep running while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        spacerTimer = timer
    }
}
