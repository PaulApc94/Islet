import AppKit
import Combine

/// How Islet's own menu bar item pushes the icon on its left.
///
/// macOS will not move another app's icon for anyone, but it lays the status
/// items out from the right edge of the screen: when one of them gets wider,
/// those on its left slide towards the notch. Islet's item, shrunk to a small
/// capsule, is that one. At rest it is wide, so its neighbour sits near the notch; when the
/// island comes out it is taken away, and the neighbour slides to the right,
/// out of the island's way. The travel is short: macOS hides an icon that
/// comes too close to the notch.
///
/// The figures below are measured on macOS 27 (a 14" MacBook Pro); none is
/// documented. The controller corrects itself from what the menu bar really
/// shows, so different figures elsewhere cost a moment, not the icon.
enum MenuBarSpring {
    /// Kept between the notch and the pushed icon. An icon that comes closer
    /// than 27 points to the notch is put behind macOS's overflow button, which
    /// takes its place (seen at 26.5, not at 27.5); the rest is slack for an
    /// item further along that grows by a few points (a temperature gaining a
    /// digit moved the whole row by 6).
    static let margin: CGFloat = 33
    /// An item pushes its neighbour by its own length plus the gap macOS
    /// keeps between two items (14.5 to 16.5 points, as it rounds). The gap
    /// comes and goes with the item: that part of the move is a jump.
    static let gap: CGFloat = 15.5
    static let minimumLength: CGFloat = 0.5

    /// How far a spacer of this length pushes its neighbour (`nil`: no spacer).
    static func shift(forLength length: CGFloat?) -> CGFloat {
        length.map { gap + $0 } ?? 0
    }

    /// The spacer to rest at, given the free room beside the notch when there
    /// is no spacer; `nil` when the room is not worth one. `failure` is a
    /// length that turned out too wide for a given room: stay under it while
    /// the room is the same.
    static func restLength(room: CGFloat, failure: (room: CGFloat, length: CGFloat)? = nil) -> CGFloat? {
        let wanted = room - margin
        guard wanted >= gap + minimumLength else { return nil }
        var length = wanted - gap
        if let failure, abs(failure.room - room) <= 3 {
            length = min(length, failure.length - 4)
        }
        return length >= minimumLength ? length : nil
    }
}

/// Islet's item in the menu bar, as the spring drives it.
@MainActor
protocol MenuBarSpacer: AnyObject {
    /// The length the spacer has, or is animating to; `nil` when it is out of
    /// the menu bar.
    var spacerLength: CGFloat? { get }
    func setSpacer(length: CGFloat?)
}

/// Decides how wide the spacer is: wide while the island rests behind the
/// notch, gone while it is out. It needs to know the free room beside the
/// notch, which only the Accessibility permission gives (see `MenuBarProbe`);
/// without it the spacer stays out and nothing moves.
@MainActor
final class MenuBarSpringController {
    private let model: IslandModel
    private weak var spacer: MenuBarSpacer?
    private let settleDelay: TimeInterval
    private let animationTime: TimeInterval

    private var observations: Set<AnyCancellable> = []
    private let settle = DelayedAction()
    private let recheck = DelayedAction()
    /// The free room right of the notch when there is no spacer: read
    /// directly while the spacer is out, worked back from its length otherwise.
    private var roomWithoutSpacer: CGFloat?
    private var failure: (room: CGFloat, length: CGFloat)?
    private var lastTransition: TimeInterval = 0

    /// - Parameters:
    ///   - settleDelay: how long a measurement has to hold before it counts.
    ///   - animationTime: how long the spacer takes to reach a new length.
    init(model: IslandModel, spacer: MenuBarSpacer, settleDelay: TimeInterval = 0.7, animationTime: TimeInterval = 0.45) {
        self.model = model
        self.spacer = spacer
        self.settleDelay = settleDelay
        self.animationTime = animationTime

        // Both announce a change before it is made: look once it is.
        for publisher in [model.objectWillChange, model.settings.objectWillChange] {
            publisher
                .sink { [weak self] in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
                }
                .store(in: &observations)
        }
        model.$menuBarRoom
            .sink { [weak self] room in
                MainActor.assumeIsolated { self?.receive(room, at: CACurrentMediaTime()) }
            }
            .store(in: &observations)
    }

    private var isEnabled: Bool { model.settings.pushMenuBarIcons && model.metrics.hasNotch }

    private func receive(_ reading: MenuBarRoom?, at time: TimeInterval) {
        guard isEnabled else { return }
        guard let reading else {
            // No permission, or nothing measured yet: nothing to go by.
            settle.cancel()
            roomWithoutSpacer = nil
            update()
            return
        }
        if reading.crowded {
            // macOS has put an icon behind its overflow button: there is no
            // room to push anything into. Out at once, and out for as long as
            // it lasts (with the spacer gone, the next measurement tells
            // whether the spacer was the cause).
            settle.cancel()
            if let length = spacer?.spacerLength, let room = roomWithoutSpacer,
               time - lastTransition < animationTime + 2 {
                // Right after the spacer moved, it is the spacer's doing (later,
                // it is the menu bar that changed: another app's menus, an
                // icon that grew).
                failure = (room, length)
            }
            roomWithoutSpacer = nil
            update()
            return
        }
        // One bad read (an app that has not answered yet) must not make the
        // icon jump: the measurement counts once it has held for a moment.
        settle.schedule(after: settleDelay) { [weak self] in self?.accept(reading, readAt: time) }
    }

    private func accept(_ reading: MenuBarRoom, readAt time: TimeInterval) {
        guard isEnabled else { return }
        // Read while the spacer was still moving: it says nothing. The
        // measurement asked for after the move brings a good one.
        guard time - lastTransition >= animationTime else { return }
        roomWithoutSpacer = reading.right + MenuBarSpring.shift(forLength: spacer?.spacerLength)
        update()
    }

    private func update() {
        guard let spacer else { return }
        var target: CGFloat?
        if isEnabled, !model.wantsMenuBarRoom, let room = roomWithoutSpacer {
            target = MenuBarSpring.restLength(room: room, failure: failure)
        }
        let current = spacer.spacerLength
        if target == nil, current == nil { return }
        // A correction too small to see is not worth a twitch (and the gap
        // itself is only known to a point).
        if let target, let current, abs(target - current) <= 2 { return }

        lastTransition = CACurrentMediaTime()
        spacer.setSpacer(length: target)
        // See what the menu bar made of it.
        recheck.schedule(after: animationTime + 0.1) { [weak self] in self?.model.measureMenuBarRoom() }
    }
}
