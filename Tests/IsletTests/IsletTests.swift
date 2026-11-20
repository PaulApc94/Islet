import AppKit
import SwiftUI
import Testing
@testable import Islet

// Tests for the logic that does not need a screen, a notch or a media player:
// the island's state machine, its geometry, and the playback clock.

private let notched = IslandMetrics(notchWidth: 185, notchHeight: 32, hasNotch: true)
private let notchless = IslandMetrics(notchWidth: 170, notchHeight: 24, hasNotch: false)

private func pause(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

private func song(_ title: String, playing: Bool) -> NowPlaying {
    NowPlaying(title: title, artist: "Artist", album: "Album",
               duration: 180, elapsedAtTimestamp: 0, timestamp: Date(),
               playbackRate: playing ? 1 : 0, isPlaying: playing,
               artwork: nil, artworkID: "", accent: nil, source: nil)
}

// MARK: - State machine

@Suite("Island state machine")
@MainActor
final class IslandModelTests {
    // A throwaway defaults domain: tests must never touch the real preferences.
    private let domain = "islet.tests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    // Qualified: SwiftUI also has a `Settings` type.
    private let settings: Islet.Settings
    private let model: IslandModel

    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        settings = Islet.Settings(defaults: defaults)
        settings.haptics = false
        // The services are created but never started: nothing touches the system.
        model = IslandModel(settings: settings)
        model.metrics = notched
    }

    deinit {
        defaults.removePersistentDomain(forName: domain)
    }

    @Test("The panel sits above the menu bar: any lower and the menu bar hides everything beside the notch")
    func panelSitsAboveTheMenuBar() {
        _ = NSApplication.shared
        let controller = IslandWindowController(model: model)
        #expect(controller.windowLevel == IslandWindowController.level)
        #expect(controller.windowLevel.rawValue > NSWindow.Level.mainMenu.rawValue)
        #expect(controller.windowLevel.rawValue > NSWindow.Level.statusBar.rawValue)
    }

    /// Opening the island dismisses any banner: a quick way to start from a clean slate.
    private func clearBanner() {
        model.setExpanded(true)
        model.setExpanded(false)
    }

    @Test("A track first reported paused is still announced when it starts playing")
    func trackFirstReportedPausedIsAnnounced() {
        model.receive(nowPlaying: song("A", playing: true))
        #expect(model.hud == .track)
        clearBanner()

        model.receive(nowPlaying: song("A", playing: false))
        model.receive(nowPlaying: song("B", playing: false))
        #expect(model.hud == nil)
        model.receive(nowPlaying: song("B", playing: true))
        #expect(model.hud == .track)
    }

    @Test("A player that briefly reports nothing does not get its track announced again")
    func sameTrackAfterAGapIsNotAnnouncedAgain() {
        model.receive(nowPlaying: song("A", playing: true))
        clearBanner()

        model.receive(nowPlaying: nil)
        model.receive(nowPlaying: song("A", playing: true))
        #expect(model.hud == nil)
        #expect(model.mode == .media)
    }

    @Test("With the music activity off the island stays behind the notch, and follows the switch live")
    func musicActivityCanBeTurnedOff() {
        settings.showNowPlaying = false
        model.receive(nowPlaying: song("A", playing: true))
        #expect(model.mode == .idle)
        #expect(model.hud == nil)
        #expect(model.layout.width == notched.notchWidth)

        settings.showNowPlaying = true
        #expect(model.mode == .media)
        #expect(model.hud == nil, "the track was already playing: it is not new")
        // The player's next update of the same track (a position refresh, the
        // cover arriving) must not announce it either.
        model.receive(nowPlaying: song("A", playing: true))
        #expect(model.hud == nil)

        settings.showNowPlaying = false
        #expect(model.mode == .idle)
    }

    @Test("Turning the music activity off withdraws a track announcement that is on screen")
    func turningMusicOffWithdrawsTheAnnouncement() {
        model.receive(nowPlaying: song("A", playing: true))
        #expect(model.hud == .track)

        settings.showNowPlaying = false
        #expect(model.hud == nil)
        #expect(model.mode == .idle)
        #expect(model.layout.width == notched.notchWidth)
    }

    @Test("Closed, only the notch counts as the island: the wings lie over the menu bar's own items")
    func wingsAreNotPartOfTheHitArea() {
        model.receive(nowPlaying: song("A", playing: true))
        clearBanner()
        #expect(model.mode == .media)
        #expect(model.layout.width > notched.notchWidth)
        #expect(model.hitSize.width == notched.notchWidth)
        #expect(model.hitSize.height == notched.notchHeight)
    }

    @Test("The island steps behind the notch when the pointer comes beside it, and returns after")
    func islandStepsAsideForThePointer() async {
        #expect(model.yieldZoneWidth == 0, "nothing sticks out of the notch at rest")

        model.receive(nowPlaying: song("A", playing: true))
        clearBanner()
        let zone = model.yieldZoneWidth
        #expect(zone > model.layout.width, "the zone covers the wings plus a margin")

        model.pointerMoved(inside: false, beside: true)
        #expect(model.mode == .media, "a pointer merely crossing must not make the island flinch")
        await pause(0.4)
        #expect(model.isYielding)
        #expect(model.mode == .idle)
        #expect(model.layout.width == notched.notchWidth)
        #expect(model.yieldZoneWidth == zone, "the zone must not vanish under the pointer")

        model.pointerMoved(inside: false, beside: false)
        await pause(0.15)
        #expect(model.isYielding, "it waits a moment in case the pointer comes back")
        #expect(model.mode == .idle)
        await pause(0.9)
        #expect(!model.isYielding)
        #expect(model.mode == .media)
    }

    @Test("Crossing the menu bar beside the notch quickly does not move the island")
    func crossingBesideDoesNotYield() async {
        model.receive(nowPlaying: song("A", playing: true))
        clearBanner()
        model.pointerMoved(inside: false, beside: true)
        // A real pointer takes a few milliseconds to cross: less than the dwell.
        await pause(0.03)
        #expect(!model.isYielding)
        model.pointerMoved(inside: false, beside: false)
        #expect(!model.isYielding)
        await pause(0.4)
        #expect(!model.isYielding)
        #expect(model.mode == .media)
    }

    @Test("Banners still show while the player has stepped aside: a low-battery warning comes only once")
    func bannersShowWhileSteppingAside() async {
        model.receive(nowPlaying: song("A", playing: true))
        clearBanner()
        model.pointerMoved(inside: false, beside: true)
        await pause(0.4)
        #expect(model.mode == .idle)

        let warning = IslandHUD.lowBattery(percent: 5)
        model.present(warning, for: 10)
        #expect(model.mode == .hud(warning))
    }

    @Test("Without a notch the pill is the island: it is all clickable and never hides from the pointer")
    func notchlessPillStaysPut() async {
        model.metrics = notchless
        model.receive(nowPlaying: song("A", playing: true))
        clearBanner()
        #expect(model.mode == .media)
        #expect(model.hitSize.width == model.layout.width)
        #expect(model.hitSize.height == notchless.notchHeight)
        #expect(model.yieldZoneWidth == 0)

        model.pointerMoved(inside: false, beside: true)
        await pause(0.4)
        #expect(!model.isYielding)
        #expect(model.mode == .media)
    }

    @Test("Fitted into the menu bar, the player takes only the sides where there is room")
    func playerFitsIntoTheFreeRoom() {
        settings.fitToMenuBar = true
        model.receive(nowPlaying: song("A", playing: true))
        clearBanner()
        let wing = IslandDesign.mediaWing, wide = IslandDesign.wideMediaWing

        model.receive(menuBarRoom: MenuBarRoom(left: 200, right: 200))
        #expect(model.layout.width == notched.notchWidth + 2 * wing)
        #expect(model.layout.offsetX == 0)

        // Something sits right next to the notch on the right: one wide wing on the left.
        model.receive(menuBarRoom: MenuBarRoom(left: 200, right: 10))
        #expect(model.mediaWings.left == wide && model.mediaWings.right == 0)
        #expect(model.layout.width == notched.notchWidth + wide)
        #expect(model.layout.offsetX == -wide / 2, "the island leans to the free side, its notch part stays put")

        // Room for the cover only.
        model.receive(menuBarRoom: MenuBarRoom(left: 10, right: 60))
        #expect(model.mediaWings.left == 0 && model.mediaWings.right == wing)
        #expect(model.layout.offsetX == wing / 2)

        // No room at all: the island stays behind the notch.
        model.receive(menuBarRoom: MenuBarRoom(left: 10, right: 10))
        #expect(model.mode == .idle)
        #expect(model.layout.width == notched.notchWidth)

        // Fitted, the player covers nothing: there is nothing to step aside from.
        model.receive(menuBarRoom: MenuBarRoom(left: 200, right: 200))
        #expect(model.yieldZoneWidth == 0)
    }

    @Test("A wing needs a gap from its neighbour, and the room is ignored when the option is off")
    func fittingEdges() {
        let wing = IslandDesign.mediaWing
        #expect(IslandDesign.fitWings(into: MenuBarRoom(left: wing + 3, right: wing + 4)).left == 0)
        #expect(IslandDesign.fitWings(into: MenuBarRoom(left: wing + 3, right: wing + 4)).right == wing)

        model.receive(nowPlaying: song("A", playing: true))
        model.receive(menuBarRoom: MenuBarRoom(left: 0, right: 0))
        #expect(model.mediaWings.left == wing && model.mediaWings.right == wing)
    }

    @Test("The track announcement needs both wings: it is skipped when one is missing")
    func noAnnouncementWithoutBothWings() {
        settings.fitToMenuBar = true
        model.receive(menuBarRoom: MenuBarRoom(left: 200, right: 10))
        model.receive(nowPlaying: song("A", playing: true))
        #expect(model.hud == nil)
        #expect(model.mode == .media)
    }

    @Test("A banner's caption, below the menu bar, never counts as the island")
    func captionIsNotPartOfTheHitArea() {
        model.present(.output(AudioOutput(name: "AirPods", symbolName: "airpods")), for: 10)
        #expect(model.layout.height > notched.notchHeight)
        #expect(model.hitSize.height == notched.notchHeight)
    }

    @Test("At rest the island is exactly as big as the notch")
    func restsBehindTheNotch() {
        #expect(model.mode == .idle)
        #expect(model.layout.width == notched.notchWidth)
        #expect(model.layout.height == notched.notchHeight)
    }

    @Test("On a notchless screen the island shows nothing at rest")
    func notchlessRestsInvisible() {
        model.metrics = notchless
        #expect(model.layout(for: .idle).height == 0)
        // …but it still offers a strip to aim at.
        #expect(model.hitSize.height > 0)
    }

    @Test("A banner takes over the island, and opening the island dismisses it")
    func bannerThenExpansion() {
        let banner = IslandHUD.volume(VolumeState(level: 0.5, isMuted: false))
        model.present(banner, for: 10)
        #expect(model.mode == .hud(banner))
        #expect(model.layout.width == notched.notchWidth + 2 * banner.wing)

        model.setExpanded(true)
        #expect(model.mode == .expanded)
        #expect(model.hud == nil)
    }

    @Test("Banners are ignored while the island is open")
    func bannersIgnoredWhileExpanded() {
        model.setExpanded(true)
        model.present(.charging(percent: 80), for: 10)
        #expect(model.hud == nil)
        #expect(model.mode == .expanded)
    }

    @Test("A banner dismisses itself")
    func bannerDismissesItself() async {
        model.present(.charging(percent: 80), for: 0.15)
        #expect(model.hud != nil)
        await pause(0.6)
        #expect(model.hud == nil)
        #expect(model.mode == .idle)
    }

    @Test("A newer banner replaces the previous one and restarts the countdown")
    func newerBannerWins() async {
        model.present(.charging(percent: 80), for: 0.2)
        await pause(0.1)
        let volume = IslandHUD.volume(VolumeState(level: 0.3, isMuted: false))
        model.present(volume, for: 0.5)
        await pause(0.25)
        // The first countdown has expired by now; the second banner must still be up.
        #expect(model.hud == volume)
    }

    @Test("Hovering opens the island after a short delay; leaving closes it")
    func hoverOpensAndCloses() async {
        model.pointerMoved(inside: true)
        #expect(model.isHovering)
        #expect(!model.isExpanded, "opening must wait for the pointer to settle")

        await pause(0.6)
        #expect(model.isExpanded)

        model.pointerMoved(inside: false)
        #expect(model.isExpanded, "closing is delayed so the pointer can come back")
        await pause(0.8)
        #expect(!model.isExpanded)
    }

    @Test("Crossing the notch quickly does not open the island")
    func passingThroughDoesNotOpen() async {
        model.pointerMoved(inside: true)
        model.pointerMoved(inside: false)
        await pause(0.6)
        #expect(!model.isExpanded)
    }

    @Test("Coming back before the island closes keeps it open")
    func returningPointerKeepsItOpen() async {
        model.setExpanded(true)
        model.pointerMoved(inside: true)
        model.pointerMoved(inside: false)
        model.pointerMoved(inside: true)
        await pause(0.8)
        #expect(model.isExpanded)
    }

    @Test("With hover-to-open disabled, only a click opens the island")
    func clickOpensWhenHoverIsDisabled() async {
        settings.expandOnHover = false
        model.pointerMoved(inside: true)
        await pause(0.6)
        #expect(!model.isExpanded)

        model.islandClicked()
        #expect(model.isExpanded)
    }

    @Test("The hit area is never smaller than the notch")
    func hitAreaCoversTheNotch() {
        #expect(model.hitSize.width >= notched.notchWidth)
        #expect(model.hitSize.height >= notched.notchHeight)

        model.setExpanded(true)
        #expect(model.hitSize.width > model.layout.width)
        #expect(model.hitSize.height > model.layout.height)
    }

    @Test("Every state fits in the panel, with room for its shadow",
          arguments: [notched, notchless])
    func everyLayoutFitsTheCanvas(metrics: IslandMetrics) {
        model.metrics = metrics
        let banners: [IslandHUD] = [
            .volume(VolumeState(level: 1, isMuted: false)),
            .charging(percent: 100),
            .lowBattery(percent: 5),
            .output(AudioOutput(name: "AirPods", symbolName: "airpods")),
            .track,
        ]
        let modes: [IslandMode] = [.idle, .media, .expanded] + banners.map { .hud($0) }

        for mode in modes {
            for hovering in [false, true] {
                let layout = model.layout(for: mode, hovering: hovering)
                #expect(layout.width >= metrics.notchWidth, "\(mode)")
                #expect(layout.height >= 0, "\(mode)")
                #expect(layout.topRadius >= 0 && layout.bottomRadius >= 0, "\(mode)")
                #expect(layout.width <= IslandDesign.canvasSize.width - 60, "\(mode)")
                #expect(layout.height <= IslandDesign.canvasSize.height - 40, "\(mode)")
            }
        }
    }
}

// MARK: - Pointer geometry

@Suite("Pointer zones")
struct PointerZoneTests {
    // A 1512 x 982 screen with a 185 x 32 notch, and the compact player out:
    // 273 pt of island, hence a 301 pt strip in which it steps aside.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = CGSize(width: 185, height: 32)

    private func zone(x: CGFloat, fromTop: CGFloat, strip: CGFloat = 301) -> PointerZone {
        PointerZone.classify(location: CGPoint(x: screen.midX + x, y: screen.maxY - fromTop),
                             screenFrame: screen,
                             hitSize: notch,
                             yieldZoneWidth: strip,
                             stripHeight: notch.height)
    }

    @Test("The notch is the island, up to the very top edge where a pushed pointer rests")
    func notchIsInside() {
        #expect(zone(x: 0, fromTop: 16) == PointerZone(inside: true, beside: false))
        #expect(zone(x: 0, fromTop: 0).inside)
        #expect(zone(x: -92, fromTop: 16).inside)
    }

    @Test("The menu bar next to the notch is beside the island, not on it")
    func wingsAreBeside() {
        #expect(zone(x: 120, fromTop: 16) == PointerZone(inside: false, beside: true))
        #expect(zone(x: -120, fromTop: 16) == PointerZone(inside: false, beside: true))
        #expect(zone(x: 149, fromTop: 16).beside, "the margin around the wings counts")
    }

    @Test("Further along the menu bar, below it, or on a display above: neither")
    func elsewhereIsNeither() {
        let nowhere = PointerZone(inside: false, beside: false)
        #expect(zone(x: 160, fromTop: 16) == nowhere)
        #expect(zone(x: 120, fromTop: 40) == nowhere)
        #expect(zone(x: 0, fromTop: 40) == nowhere)
        #expect(zone(x: 0, fromTop: -1) == nowhere)
    }

    @Test("With no player beside the notch there is nothing to step aside from")
    func noStripWithoutWings() {
        #expect(zone(x: 120, fromTop: 16, strip: 0) == PointerZone(inside: false, beside: false))
    }
}

// MARK: - Menu bar room

@Suite("Menu bar room")
struct MenuBarRoomTests {
    // Window-server space: y grows downwards from the top of the screen.
    private let notch = CGRect(x: 663.5, y: 0, width: 185, height: 32)

    private func room(_ items: [CGRect]) -> MenuBarRoom {
        MenuBarRoom.around(notch: notch, screenMinX: 0, screenMaxX: 1512, items: items)
    }

    private func item(from minX: CGFloat, to maxX: CGFloat, y: CGFloat = 0) -> CGRect {
        CGRect(x: minX, y: y, width: maxX - minX, height: 33)
    }

    @Test("An empty menu bar is free up to the screen edges")
    func emptyBar() {
        #expect(room([]) == MenuBarRoom(left: 663.5, right: 663.5))
    }

    @Test("The nearest menu title on the left and the nearest item on the right set the room")
    func nearestItemsCount() {
        let measured = room([item(from: 0, to: 300), item(from: 540, to: 600),
                             item(from: 860, to: 915), item(from: 1200, to: 1512)])
        #expect(measured == MenuBarRoom(left: 63.5, right: 11.5))
    }

    @Test("An item macOS tucked behind the notch leaves no room; items elsewhere do not count")
    func hiddenAndForeignItems() {
        #expect(room([item(from: 800, to: 870)]).right == 0)
        // On another display (far right), or in a window below the menu bar.
        #expect(room([item(from: 1600, to: 1700), item(from: 700, to: 900, y: 200)]) == room([]))
    }
}

// MARK: - Playback clock

@Suite("Playback clock")
struct NowPlayingTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func track(isPlaying: Bool,
                       elapsed: TimeInterval = 10,
                       duration: TimeInterval = 100,
                       rate: Double = 1,
                       title: String = "Title",
                       artwork: NSImage? = nil) -> NowPlaying {
        NowPlaying(title: title,
                   artist: "Artist",
                   album: "Album",
                   duration: duration,
                   elapsedAtTimestamp: elapsed,
                   timestamp: start,
                   playbackRate: rate,
                   isPlaying: isPlaying,
                   artwork: artwork,
                   artworkID: "cover",
                   accent: nil,
                   source: nil)
    }

    @Test func positionAdvancesWhilePlaying() {
        #expect(track(isPlaying: true).elapsed(at: start.addingTimeInterval(5)) == 15)
    }

    @Test func positionIsFrozenWhilePaused() {
        #expect(track(isPlaying: false).elapsed(at: start.addingTimeInterval(5)) == 10)
    }

    @Test func positionFollowsThePlaybackRate() {
        #expect(track(isPlaying: true, rate: 2).elapsed(at: start.addingTimeInterval(5)) == 20)
    }

    @Test("Players that report a rate of zero while playing still advance in real time")
    func zeroRateFallsBackToRealTime() {
        #expect(track(isPlaying: true, rate: 0).elapsed(at: start.addingTimeInterval(5)) == 15)
    }

    @Test func positionNeverPassesTheEnd() {
        #expect(track(isPlaying: true).elapsed(at: start.addingTimeInterval(500)) == 100)
    }

    @Test func positionIsNeverNegative() {
        #expect(track(isPlaying: true).elapsed(at: start.addingTimeInterval(-60)) == 0)
    }

    @Test("Live streams have no duration and must not be clamped to zero")
    func unknownDurationKeepsCounting() {
        #expect(track(isPlaying: true, duration: 0).elapsed(at: start.addingTimeInterval(500)) == 510)
    }

    @Test func trackIdentityIgnoresPlaybackState() {
        #expect(track(isPlaying: true).trackID == track(isPlaying: false, elapsed: 42).trackID)
        #expect(track(isPlaying: true).trackID != track(isPlaying: true, title: "Other").trackID)
    }

    @Test("Two snapshots with the same artwork identifier are equal, whatever the image object")
    func equalityIgnoresTheImageObject() {
        let first = track(isPlaying: true, artwork: NSImage(size: CGSize(width: 1, height: 1)))
        let second = track(isPlaying: true, artwork: NSImage(size: CGSize(width: 1, height: 1)))
        #expect(first == second)
        #expect(first != track(isPlaying: false))
    }
}

// MARK: - Drawing

@Suite("Notch shape")
struct NotchShapeTests {
    @Test func staysInsideItsFrame() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        let bounds = NotchShape(topRadius: 10, bottomRadius: 30).path(in: frame).boundingRect
        #expect(frame.insetBy(dx: -0.01, dy: -0.01).contains(bounds))
        #expect(abs(bounds.width - frame.width) < 0.01)
        #expect(abs(bounds.height - frame.height) < 0.01)
    }

    @Test("Springs overshoot: radii larger than the frame must not break the path",
          arguments: [CGSize(width: 185, height: 2), CGSize(width: 12, height: 32), CGSize(width: 1, height: 1)])
    func survivesTinyFrames(size: CGSize) {
        let frame = CGRect(origin: .zero, size: size)
        let bounds = NotchShape(topRadius: 10, bottomRadius: 30).path(in: frame).boundingRect
        #expect(bounds.width.isFinite && bounds.height.isFinite)
        #expect(frame.insetBy(dx: -0.01, dy: -0.01).contains(bounds))
    }

    @Test func emptyFrameDrawsNothing() {
        #expect(NotchShape(topRadius: 6, bottomRadius: 10).path(in: .zero).isEmpty)
    }
}

@Suite("Artwork accent colour")
struct AccentColourTests {
    private func swatch(_ colour: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            colour.setFill()
            rect.fill()
            return true
        }
    }

    private func hue(of colour: NSColor) -> CGFloat {
        colour.usingColorSpace(.sRGB)?.hueComponent ?? -1
    }

    @Test func followsTheDominantColour() throws {
        let accent = try #require(swatch(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)).islandAccentColor())
        #expect(abs(hue(of: accent) - 2.0 / 3.0) < 0.03)
    }

    @Test("Dark covers still give a colour that reads on black")
    func staysReadableOnBlack() throws {
        let accent = try #require(swatch(NSColor(srgbRed: 0.2, green: 0.02, blue: 0.02, alpha: 1)).islandAccentColor())
        #expect((accent.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) >= 0.84)
    }
}
