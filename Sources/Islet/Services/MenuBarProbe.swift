import AppKit
import ApplicationServices

/// How much empty menu bar there is next to the notch, on each side, in points.
struct MenuBarRoom: Equatable {
    var left: CGFloat
    var right: CGFloat

    /// The room around `notch`, given the frames of everything that sits in
    /// the menu bar (menu titles and status icons), all in the same space.
    static func around(notch: CGRect, screenMinX: CGFloat, screenMaxX: CGFloat, items: [CGRect]) -> MenuBarRoom {
        var leftEdge = screenMinX
        var rightEdge = screenMaxX
        for item in items where item.width > 0
            && item.maxY > notch.minY && item.minY < notch.maxY
            && item.maxX > screenMinX && item.minX < screenMaxX {
            // Clamped to the notch: an item macOS tucked behind it leaves no room at all.
            if item.midX < notch.midX {
                leftEdge = max(leftEdge, min(item.maxX, notch.minX))
            } else {
                rightEdge = min(rightEdge, max(item.minX, notch.maxX))
            }
        }
        return MenuBarRoom(left: notch.minX - leftEdge, right: rightEdge - notch.maxX)
    }
}

/// Measures the free room beside the notch, so the island can extend only
/// where nothing is in the way.
///
/// macOS has no API for this. The only way to learn where the menu titles and
/// the status icons are is the Accessibility API, which the user has to allow
/// in System Settings. Without that permission the probe reports nothing and
/// the island behaves as it does by default.
@MainActor
final class MenuBarProbe {
    /// `nil` when the room is unknown (no permission, no notch).
    var onChange: ((MenuBarRoom?) -> Void)?
    private(set) var room: MenuBarRoom?

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var wasTrusted = false
    private var isMeasuring = false
    private var needsAnotherPass = false
    private let queue = DispatchQueue(label: "islet.menu-bar-probe", qos: .utility)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog that leads to System Settings > Accessibility.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func start() {
        guard timer == nil else { return }
        // The menu bar changes when another app comes to the front (its menus)
        // and when apps start or quit (their icons).
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            })
        }
        // A slow safety net for what sends no notification (an icon that
        // appears, a menu that changes), and a quick check for the moment the
        // user grants the permission.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        timer?.invalidate()
        timer = nil
        publish(nil)
    }

    private func tick() {
        // Every tick: a pass costs a couple of milliseconds in the background,
        // and an icon can appear beside the notch without any notification.
        refresh()
    }

    /// The menu bar is redrawn a moment after the notification.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    func refresh() {
        wasTrusted = Self.isTrusted
        guard wasTrusted, timer != nil, let geometry = Self.notchGeometry() else {
            publish(nil)
            return
        }
        guard !isMeasuring else {
            needsAnotherPass = true
            return
        }
        isMeasuring = true

        // Islet itself is never asked through Accessibility: such a query is
        // answered in-process, on the calling thread, and would run AppKit off
        // the main thread. Its own icon is read right here instead.
        let me = ProcessInfo.processInfo.processIdentifier
        let menuOwner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        let owner = menuOwner == me ? nil : menuOwner
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { $0 != me }
        let ownIcons = NSApp.windows.filter { $0.className.contains("StatusBar") }.map { window in
            CGRect(x: window.frame.minX, y: geometry.primaryMaxY - window.frame.maxY,
                   width: window.frame.width, height: window.frame.height)
        }
        // Off the main thread: every app is asked, and a busy one may take a while to answer.
        queue.async {
            let items = Self.menuBarItems(owner: owner, pids: pids)
            let room = MenuBarRoom.around(notch: geometry.notch,
                                          screenMinX: geometry.minX,
                                          screenMaxX: geometry.maxX,
                                          items: items.frames + ownIcons)
            DispatchQueue.main.async {
                self.isMeasuring = false
                guard self.timer != nil else { return }

                if items.ownerFailed, self.failedReads < Self.maxRetries {
                    // An app that just came to the front may not answer yet
                    // (seen with the Finder). Its menus are unknown: assume
                    // there is no room rather than draw over them, and ask
                    // again in a moment instead of waiting for the timer.
                    self.failedReads += 1
                    self.publish(MenuBarRoom(left: 0, right: 0))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
                } else {
                    // After the retries, an app that never answers is taken to
                    // have no menus: better than hiding the player for good.
                    if !items.ownerFailed { self.failedReads = 0 }
                    self.publish(room)
                }
                if self.needsAnotherPass {
                    self.needsAnotherPass = false
                    self.refresh()
                }
            }
        }
    }

    private var failedReads = 0
    private static let maxRetries = 4

    private func publish(_ newRoom: MenuBarRoom?) {
        guard newRoom != room else { return }
        room = newRoom
        // Readable with `defaults read io.github.paulapc94.islet lastMenuBarRoom`:
        // the quickest way to see what Islet sees when the island looks wrong.
        let description = newRoom.map { "left=\(Int($0.left)) right=\(Int($0.right))" } ?? "unknown"
        UserDefaults.standard.set(description, forKey: "lastMenuBarRoom")
        onChange?(newRoom)
    }

    // MARK: Geometry

    /// The notch in the window server's space, the one Accessibility speaks:
    /// origin at the top-left corner of the primary display, y downwards.
    private static func notchGeometry() -> (notch: CGRect, minX: CGFloat, maxX: CGFloat, primaryMaxY: CGFloat)? {
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let notch = CGRect(x: screen.frame.minX + left.width,
                           y: primary.frame.maxY - screen.frame.maxY,
                           width: screen.frame.width - left.width - right.width,
                           height: screen.safeAreaInsets.top)
        return (notch, screen.frame.minX, screen.frame.maxX, primary.frame.maxY)
    }

    // MARK: Accessibility

    /// Frames of the frontmost app's menu titles and of every app's status icons.
    nonisolated private static func menuBarItems(owner: pid_t?, pids: [pid_t]) -> (frames: [CGRect], ownerFailed: Bool) {
        var frames: [CGRect] = []
        var ownerFailed = false
        if let owner {
            // The one answer that matters most: give it more time.
            let titles = itemFrames(of: owner, bar: kAXMenuBarAttribute, timeout: 1)
            // Every app has at least the Apple menu and its own: none at all
            // means the app did not answer.
            ownerFailed = titles.isEmpty
            frames += titles
        }
        for pid in pids {
            frames += itemFrames(of: pid, bar: kAXExtrasMenuBarAttribute, timeout: 0.25)
        }
        return (frames, ownerFailed)
    }

    nonisolated private static func itemFrames(of pid: pid_t, bar attribute: String, timeout: Float) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        // An app that does not answer must not hold the whole measurement up.
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let bar = value(of: app, attribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let children = value(of: bar as! AXUIElement, kAXChildrenAttribute) as? [AnyObject] else { return [] }
        return children.compactMap { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return frame(of: child as! AXUIElement)
        }
    }

    nonisolated private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(of: element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(of: element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
