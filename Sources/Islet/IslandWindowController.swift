import AppKit
import SwiftUI

/// A panel that can sit in the menu bar area and never takes focus.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // AppKit pushes windows below the menu bar; the island belongs inside it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The app is never active, so without this the first click on a control
/// would be swallowed instead of pressing it.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the transparent panel pinned to the top centre of the screen and tells
/// the model when the pointer is over the island.
///
/// The panel has a fixed size, large enough for the expanded island and its
/// shadow. It ignores the mouse entirely, except while the pointer is inside
/// the island's hit area: clicks around the island always reach the apps below.
@MainActor
final class IslandWindowController {
    private let model: IslandModel
    private let panel: IslandPanel
    private var screenFrame: CGRect = .zero
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var hoverPoll: Timer?
    /// The left button went down on the island and has not been released yet.
    private var isPressingIsland = false

    /// A right-click (or control-click) on the island. It opens the settings
    /// menu, which must stay reachable even when macOS hides the menu-bar icon
    /// behind the notch.
    var onSecondaryClick: (() -> Void)?

    init(model: IslandModel) {
        self.model = model

        panel = IslandPanel(contentRect: CGRect(origin: .zero, size: IslandDesign.canvasSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // `.transient` rather than `.stationary`: the island still shows on every
        // Space and over full-screen apps, but steps aside while Mission Control
        // is open instead of covering (and taking the clicks of) the Spaces bar.
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        // Set last, and never alongside `isFloatingPanel`: that property resets
        // the level to `.floating`, which is *below* the menu bar. The menu bar
        // then covers the whole top strip and the island only shows under the
        // notch, never beside it.
        panel.level = Self.level

        let hostingView = IslandHostingView(rootView: IslandView(model: model))
        // The window drives the layout, never the other way round.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
    }

    /// Above the menu bar and its status items, so the island can grow out of
    /// the notch on both sides.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    /// The level the panel really has (AppKit can change it behind our back).
    var windowLevel: NSWindow.Level { panel.level }

    func show() {
        reposition()
        installPointerTracking()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    /// Development aid: draws the live island into a PNG, on a wallpaper-like
    /// backdrop with the notch painted in. The app draws its own view, so no
    /// screen-recording permission is involved.
    func writeSnapshot(to url: URL) {
        guard let view = panel.contentView else { return }
        let bounds = view.bounds
        let scale: CGFloat = 2

        func makeBitmap() -> NSBitmapImageRep? {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                          pixelsWide: Int(bounds.width * scale),
                                          pixelsHigh: Int(bounds.height * scale),
                                          bitsPerSample: 8,
                                          samplesPerPixel: 4,
                                          hasAlpha: true,
                                          isPlanar: false,
                                          colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0,
                                          bitsPerPixel: 0)
            bitmap?.size = bounds.size
            return bitmap
        }

        guard let island = makeBitmap(), let canvas = makeBitmap(),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        view.cacheDisplay(in: bounds, to: island)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.52, blue: 0.98, alpha: 1),
                   ending: NSColor(srgbRed: 0.62, green: 0.38, blue: 0.96, alpha: 1))?
            .draw(in: bounds, angle: -35)
        island.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        let metrics = model.metrics
        if metrics.hasNotch {
            // Taller than the notch and cut off by the top edge: only the bottom corners end up rounded.
            let notch = CGRect(x: bounds.midX - metrics.notchWidth / 2,
                               y: bounds.maxY - metrics.notchHeight,
                               width: metrics.notchWidth,
                               height: metrics.notchHeight + 20)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: notch, xRadius: 9, yRadius: 9).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = canvas.representation(using: .png, properties: [:]) else {
            NSLog("Islet: snapshot could not be encoded")
            return
        }
        do {
            try png.write(to: url)
        } catch {
            NSLog("Islet: snapshot failed: %@", error.localizedDescription)
        }
    }

    // MARK: Placement

    /// The built-in display with a notch when there is one, the primary display otherwise.
    private static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func reposition() {
        guard let screen = Self.preferredScreen() else { return }
        screenFrame = screen.frame

        var metrics = IslandMetrics(screen: screen)
        // Development aid: lay the island out as on a Mac without a notch.
        if ProcessInfo.processInfo.environment["ISLET_NOTCHLESS"] == "1" {
            metrics = IslandMetrics(notchWidth: 170, notchHeight: 24, hasNotch: false)
        }
        if model.metrics != metrics { model.metrics = metrics }

        let size = IslandDesign.canvasSize
        let frame = CGRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width,
                           height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: Pointer

    private func installPointerTracking() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

        // Global: the pointer moves over other apps (the usual case, since Islet is never active).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.pointerDidMove()
        }) {
            eventMonitors.append(monitor)
        }
        // Local: every event the app receives, clicks included. That covers the
        // island but also the menu-bar icon's own window, hence the window checks.
        let localMask = mask.union([.leftMouseDown, .leftMouseUp, .rightMouseDown])
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: localMask, handler: { [weak self] event in
            guard let self else { return event }
            let onIsland = event.window === self.panel
            switch event.type {
            case .leftMouseDown where onIsland && event.modifierFlags.contains(.control),
                 .rightMouseDown where onIsland:
                self.onSecondaryClick?()
                return nil
            case .leftMouseDown:
                // Only a press on the island itself: a click on the menu-bar
                // icon must open its menu, not the island.
                self.isPressingIsland = onIsland
            case .leftMouseUp:
                self.isPressingIsland = false
            default:
                break
            }
            self.pointerDidMove()
            return event
        }) {
            eventMonitors.append(monitor)
        }
    }

    private func pointerDidMove() {
        let location = NSEvent.mouseLocation
        let size = model.hitSize
        let hitArea = CGRect(x: screenFrame.midX - size.width / 2,
                             y: screenFrame.maxY - size.height,
                             width: size.width,
                             height: size.height)

        // A press that started on the island (scrubbing the progress bar) keeps
        // it open even when the pointer strays outside before the button is released.
        if isPressingIsland, NSEvent.pressedMouseButtons & 1 == 0 {
            isPressingIsland = false
        }
        // AppKit's mouse test includes the top edge, where a pointer pushed
        // against the top of the screen rests, and nothing above it: a display
        // arranged above this one never counts as the island.
        let inside = isPressingIsland || NSMouseInRect(location, hitArea, false)

        // The menu bar strip the closed island's wings cover, beside the notch.
        // The panel keeps ignoring the mouse there (clicks reach the menu bar);
        // the model makes the island step aside so what it covers can be seen.
        let zoneWidth = model.yieldZoneWidth
        let stripHeight = model.metrics.notchHeight
        let strip = CGRect(x: screenFrame.midX - zoneWidth / 2,
                           y: screenFrame.maxY - stripHeight,
                           width: zoneWidth,
                           height: stripHeight)
        let beside = !inside && zoneWidth > 0 && NSMouseInRect(location, strip, false)

        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        model.pointerMoved(inside: inside, beside: beside)
        setHoverPoll(active: inside)
    }

    /// While the pointer is on the island, re-check a few times per second: a
    /// missed mouse event must never leave the island stuck open.
    private func setHoverPoll(active: Bool) {
        if active, hoverPoll == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerDidMove() }
            }
            // Common modes: it must keep running while a menu is being tracked.
            RunLoop.main.add(timer, forMode: .common)
            hoverPoll = timer
        } else if !active, let timer = hoverPoll {
            timer.invalidate()
            hoverPoll = nil
        }
    }
}
