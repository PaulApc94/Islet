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

    init(model: IslandModel) {
        self.model = model

        panel = IslandPanel(contentRect: CGRect(origin: .zero, size: IslandDesign.canvasSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar and its status items, so the island can grow out of the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        let hostingView = IslandHostingView(rootView: IslandView(model: model))
        // The window drives the layout, never the other way round.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
    }

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
        // Local: events aimed at the island itself, clicks included.
        let localMask = mask.union([.leftMouseDown, .leftMouseUp])
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: localMask, handler: { [weak self] event in
            switch event.type {
            case .leftMouseDown: self?.isPressingIsland = true
            case .leftMouseUp: self?.isPressingIsland = false
            default: break
            }
            self?.pointerDidMove()
            return event
        }) {
            eventMonitors.append(monitor)
        }
    }

    private func pointerDidMove() {
        let location = NSEvent.mouseLocation
        let size = model.hitSize
        // A few extra points above the screen edge: the pointer rests exactly on it.
        let hitArea = CGRect(x: screenFrame.midX - size.width / 2,
                             y: screenFrame.maxY - size.height,
                             width: size.width,
                             height: size.height + 4)

        // A press that started on the island (scrubbing the progress bar) keeps
        // it open even when the pointer strays outside before the button is released.
        if isPressingIsland, NSEvent.pressedMouseButtons & 1 == 0 {
            isPressingIsland = false
        }
        let inside = isPressingIsland || hitArea.contains(location)

        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        model.pointerMoved(inside: inside)
        setHoverPoll(active: inside)
    }

    /// While the pointer is on the island, re-check a few times per second: a
    /// missed mouse event must never leave the island stuck open.
    private func setHoverPoll(active: Bool) {
        if active, hoverPoll == nil {
            hoverPoll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerDidMove() }
            }
        } else if !active, let timer = hoverPoll {
            timer.invalidate()
            hoverPoll = nil
        }
    }
}
