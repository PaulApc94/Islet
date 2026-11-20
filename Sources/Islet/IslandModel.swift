import AppKit
import Combine
import SwiftUI

// MARK: - Geometry

/// What the island needs to know about the screen it lives on.
struct IslandMetrics: Equatable {
    /// Width of the camera housing, or of a virtual one on notchless screens.
    var notchWidth: CGFloat
    /// Height of the notch, or of the menu bar on notchless screens.
    var notchHeight: CGFloat
    var hasNotch: Bool

    static let placeholder = IslandMetrics(notchWidth: 185, notchHeight: 32, hasNotch: true)
}

extension IslandMetrics {
    init(screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            self.init(notchWidth: max(120, screen.frame.width - left.width - right.width),
                      notchHeight: inset,
                      hasNotch: true)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            self.init(notchWidth: 170, notchHeight: min(max(menuBar, 24), 40), hasNotch: false)
        }
    }
}

/// The silhouette of the island for one state. The frame is anchored to the top
/// centre of the screen; `width` includes the two ears.
struct IslandLayout: Equatable {
    var width: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
}

enum IslandDesign {
    /// The transparent panel never resizes: only the shape drawn inside it animates.
    static let canvasSize = CGSize(width: 660, height: 300)
    static let ear: CGFloat = 6
    static let expandedEar: CGFloat = 10
    /// Width of each side of the notch while music plays, ear included.
    static let mediaWing: CGFloat = 44
    /// Height of the text line some banners add under the notch.
    static let captionHeight: CGFloat = 32
    static let expandedWidth: CGFloat = 448
    static let playerHeight: CGFloat = 124
    static let dashboardHeight: CGFloat = 84
}

enum IslandAnimation {
    /// A little overshoot when the island opens, none when it closes: that asymmetry is what makes it feel alive.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.76)
    static let close = Animation.spring(response: 0.36, dampingFraction: 0.9)
    static let morph = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let hover = Animation.spring(response: 0.3, dampingFraction: 0.68)
}

// MARK: - State

/// Banners that take over the island for a couple of seconds.
enum IslandHUD: Equatable {
    case volume(VolumeState)
    case charging(percent: Int)
    case lowBattery(percent: Int)
    case output(AudioOutput)
    /// Announces the track that just started; reads its content from `nowPlaying`.
    case track

    /// Two banners of the same kind update in place instead of replaying the transition.
    var kind: String {
        switch self {
        case .volume: return "volume"
        case .charging: return "charging"
        case .lowBattery: return "lowBattery"
        case .output: return "output"
        case .track: return "track"
        }
    }

    /// Tall banners add a caption under the notch.
    var hasCaption: Bool {
        switch self {
        case .lowBattery, .output, .track: return true
        case .volume, .charging: return false
        }
    }

    /// Width of the area on each side of the notch, ear included.
    var wing: CGFloat {
        switch self {
        case .volume: return 76
        case .charging: return 92
        case .lowBattery: return 58
        case .output, .track: return IslandDesign.mediaWing
        }
    }
}

enum IslandMode: Equatable {
    case idle
    case media
    case hud(IslandHUD)
    case expanded
}

/// A cancellable action that runs later on the main actor.
@MainActor
final class DelayedAction {
    private var task: Task<Void, Never>?

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Model

/// The single source of truth of the island: it listens to the services,
/// decides what the island shows, and exposes the geometry of each state.
@MainActor
final class IslandModel: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var battery: BatteryState = .unknown
    @Published private(set) var hud: IslandHUD?
    @Published private(set) var isExpanded = false
    @Published private(set) var isHovering = false
    /// Whether the compact player is on screen (playing, or paused a moment ago).
    @Published private(set) var showsMedia = false
    /// The closed island has stepped back behind the notch because the pointer
    /// is in the menu bar right beside it.
    @Published private(set) var isYielding = false
    @Published var metrics: IslandMetrics = .placeholder

    let settings: Settings

    private let nowPlayingService = NowPlayingService()
    private let audioService = AudioService()
    private let batteryService = BatteryService()

    private let hudDismissal = DelayedAction()
    private let hoverIntent = DelayedAction()
    private let mediaLinger = DelayedAction()
    private let yieldTimer = DelayedAction()
    private var pointerIsBeside = false

    /// The last track the island saw playing. Announcements compare with it
    /// rather than with the previous snapshot: a track first reported paused,
    /// or a player that briefly reports nothing, must not fool them.
    private var lastPlayingTrackID: String?
    private var settingsObservation: AnyCancellable?

    init(settings: Settings = .shared) {
        self.settings = settings
        // `@Published` emits before storing the new value: use the one emitted.
        settingsObservation = settings.$showNowPlaying
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.nowPlayingActivityChanged(enabled: enabled) }
            }
    }

    func start() {
        nowPlayingService.onChange = { [weak self] snapshot in self?.receive(nowPlaying: snapshot) }
        audioService.onVolumeChange = { [weak self] volume in self?.receive(volume: volume) }
        audioService.onOutputChange = { [weak self] output in self?.receive(output: output) }
        batteryService.onChange = { [weak self] state in self?.receive(battery: state) }

        batteryService.start()
        battery = batteryService.state
        audioService.start()
        nowPlayingService.start()
    }

    func stop() {
        nowPlayingService.stop()
        audioService.stop()
        batteryService.stop()
    }

    // MARK: Presentation

    var mode: IslandMode {
        if isExpanded { return .expanded }
        let resting = restingMode
        // Stepping aside for the pointer. Only the compact player does: it
        // stays for hours. Banners last a few seconds and have to be seen (a
        // low-battery warning is issued once), so they show regardless.
        if isYielding, resting == .media || resting == .hud(.track) { return .idle }
        return resting
    }

    /// What the closed island shows when the pointer is not beside it.
    private var restingMode: IslandMode {
        if let hud { return .hud(hud) }
        if showsMedia, nowPlaying != nil { return .media }
        return .idle
    }

    /// The compact player stays in place while a track is being announced.
    var showsCompactMedia: Bool {
        guard nowPlaying != nil else { return false }
        return mode == .media || mode == .hud(.track)
    }

    var layout: IslandLayout { layout(for: mode, hovering: isHovering) }

    func layout(for mode: IslandMode, hovering: Bool = false) -> IslandLayout {
        let notchWidth = metrics.notchWidth
        let notchHeight = metrics.notchHeight
        // Hovering makes the island swell slightly: feedback before it opens.
        let bump: CGFloat = hovering ? 1 : 0

        switch mode {
        case .idle:
            // At rest the island hides behind the notch. Notchless screens show nothing at all.
            let restHeight = metrics.hasNotch ? notchHeight : 0
            return IslandLayout(width: notchWidth + 16 * bump,
                                height: restHeight + (metrics.hasNotch ? 6 : 9) * bump,
                                topRadius: IslandDesign.ear,
                                bottomRadius: 10 + 3 * bump)
        case .media:
            return IslandLayout(width: notchWidth + 2 * IslandDesign.mediaWing + 10 * bump,
                                height: notchHeight + 4 * bump,
                                topRadius: IslandDesign.ear,
                                bottomRadius: 10 + 2 * bump)
        case .hud(let hud):
            return IslandLayout(width: notchWidth + 2 * hud.wing,
                                height: notchHeight + (hud.hasCaption ? IslandDesign.captionHeight : 0),
                                topRadius: IslandDesign.ear,
                                bottomRadius: hud.hasCaption ? 16 : 10)
        case .expanded:
            let body = nowPlaying == nil ? IslandDesign.dashboardHeight : IslandDesign.playerHeight
            return IslandLayout(width: IslandDesign.expandedWidth,
                                height: notchHeight + body,
                                topRadius: IslandDesign.expandedEar,
                                bottomRadius: 30)
        }
    }

    /// The area, anchored to the top centre of the screen, where the pointer
    /// counts as being on the island. Never smaller than the notch itself.
    var hitSize: CGSize {
        if isExpanded {
            let layout = self.layout
            return CGSize(width: layout.width + 20, height: layout.height + 14)
        }
        if metrics.hasNotch {
            // Closed, the island is only the notch as far as the pointer goes.
            // Its wings lie over the menu bar's own menus and icons, and a
            // banner's caption over the apps' windows: a pointer there is
            // aiming at those, so it must neither open the island nor lose
            // its click to it.
            return CGSize(width: metrics.notchWidth, height: metrics.notchHeight)
        }
        // Without a notch there is nothing to aim at but the pill the island
        // draws: all of it counts (a caption below the menu bar excepted),
        // and at rest a thin strip along the top edge.
        let layout = self.layout
        var height = layout.height
        if case .hud(let hud) = mode, hud.hasCaption {
            height = metrics.notchHeight
        }
        return CGSize(width: max(layout.width, metrics.notchWidth), height: max(height, 5))
    }

    /// Width of the menu bar strip, centred on the notch, in which the compact
    /// player steps aside for the pointer: what its wings cover, plus a margin
    /// so that it moves just before the pointer arrives. Zero when there is no
    /// player beside the notch, and on screens without a notch, where the pill
    /// is the island itself and hiding it would leave nothing to click.
    var yieldZoneWidth: CGFloat {
        guard metrics.hasNotch, !isExpanded, showsMedia, nowPlaying != nil else { return 0 }
        // Measured on the player's own layout, not on what the island shows
        // right now: otherwise the zone would vanish under the pointer as soon
        // as the island stepped aside, and the wings would come straight back.
        return layout(for: .media).width + 2 * 14
    }

    // MARK: Pointer

    /// - Parameters:
    ///   - inside: the pointer is on the island (the notch, or the open island).
    ///   - beside: the pointer is in the menu bar right next to the notch, in
    ///     the strip the closed island's wings cover.
    func pointerMoved(inside: Bool, beside: Bool = false) {
        updateYielding(beside: beside && yieldZoneWidth > 0)
        guard inside != isHovering else { return }
        withAnimation(IslandAnimation.hover) { isHovering = inside }

        if inside {
            haptic(.alignment)
            if settings.expandOnHover, !isExpanded {
                hoverIntent.schedule(after: 0.2) { [weak self] in self?.setExpanded(true) }
            } else {
                // The pointer came back before the island closed: keep it open.
                hoverIntent.cancel()
            }
        } else {
            hoverIntent.schedule(after: 0.3) { [weak self] in self?.setExpanded(false) }
        }
    }

    /// macOS gives apps no way to move the menu bar's items out of the way, so
    /// the island moves instead: when the pointer comes to what the wings
    /// cover, they retract behind the notch, and return once it has left.
    private func updateYielding(beside: Bool) {
        guard beside != pointerIsBeside else { return }
        pointerIsBeside = beside

        if beside {
            // A short dwell, so a pointer merely crossing the menu bar does
            // not make the island flinch.
            yieldTimer.schedule(after: 0.1) { [weak self] in
                guard let self, self.pointerIsBeside, !self.isYielding else { return }
                withAnimation(IslandAnimation.close) { self.isYielding = true }
            }
        } else {
            yieldTimer.schedule(after: 0.45) { [weak self] in
                guard let self, !self.pointerIsBeside, self.isYielding else { return }
                withAnimation(IslandAnimation.morph) { self.isYielding = false }
            }
        }
    }

    func islandClicked() {
        guard !isExpanded else { return }
        hoverIntent.cancel()
        setExpanded(true)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        if expanded { hudDismissal.cancel() }
        withAnimation(expanded ? IslandAnimation.open : IslandAnimation.close) {
            isExpanded = expanded
            if expanded { hud = nil }
        }
        if expanded { haptic(.levelChange) }
    }

    // MARK: Media commands

    func togglePlayPause() { nowPlayingService.togglePlayPause() }
    func nextTrack() { nowPlayingService.nextTrack() }
    func previousTrack() { nowPlayingService.previousTrack() }
    func seek(to seconds: TimeInterval) { nowPlayingService.seek(to: seconds) }

    func openSourceApp() {
        guard let source = nowPlaying?.source else { return }
        if let url = source.bundleURL {
            NSWorkspace.shared.open(url)
        } else {
            NSRunningApplication(processIdentifier: source.pid)?.activate()
        }
        setExpanded(false)
    }

    // MARK: Banners

    func present(_ banner: IslandHUD, for duration: TimeInterval) {
        guard !isExpanded else { return }
        withAnimation(IslandAnimation.morph) { hud = banner }
        hudDismissal.schedule(after: duration) { [weak self] in
            withAnimation(IslandAnimation.close) { self?.hud = nil }
        }
    }

    // MARK: Service events

    /// Internal rather than private so the tests can play snapshots through it.
    func receive(nowPlaying snapshot: NowPlaying?) {
        let previous = nowPlaying
        withAnimation(IslandAnimation.morph) { nowPlaying = snapshot }

        guard let snapshot else {
            mediaLinger.cancel()
            withAnimation(IslandAnimation.close) {
                showsMedia = false
                if hud == .track { hud = nil }
            }
            return
        }

        guard settings.showNowPlaying else {
            // Still tracked, so turning the activity on later does not
            // announce the current track as a new one.
            if snapshot.isPlaying { lastPlayingTrackID = snapshot.trackID }
            return
        }

        if snapshot.isPlaying {
            mediaLinger.cancel()
            if !showsMedia {
                withAnimation(IslandAnimation.morph) { showsMedia = true }
            }
            if snapshot.trackID != lastPlayingTrackID, settings.showTrackChanges {
                present(.track, for: 2.8)
            }
            lastPlayingTrackID = snapshot.trackID
        } else if showsMedia, previous?.isPlaying != false {
            // Just paused: linger so a quick pause/resume does not make the island jump.
            mediaLinger.schedule(after: 4) { [weak self] in
                withAnimation(IslandAnimation.close) { self?.showsMedia = false }
            }
        }
    }

    private func nowPlayingActivityChanged(enabled: Bool) {
        if enabled {
            if nowPlaying?.isPlaying == true, !showsMedia {
                withAnimation(IslandAnimation.morph) { showsMedia = true }
            }
        } else {
            mediaLinger.cancel()
            withAnimation(IslandAnimation.close) {
                showsMedia = false
                if hud == .track { hud = nil }
            }
        }
    }

    private func receive(volume: VolumeState) {
        guard settings.showVolume else { return }
        present(.volume(volume), for: 1.6)
    }

    private func receive(output: AudioOutput) {
        guard settings.showAudioOutput else { return }
        present(.output(output), for: 2.8)
    }

    private func receive(battery state: BatteryState) {
        let previous = battery
        battery = state
        guard settings.showPower, state.hasBattery, previous.hasBattery else { return }

        if state.isPluggedIn, !previous.isPluggedIn {
            present(.charging(percent: state.percent), for: 3)
        } else if !state.isPluggedIn {
            // Warn once per threshold, on the way down only.
            for threshold in [20, 10, 5] where state.percent <= threshold && previous.percent > threshold {
                present(.lowBattery(percent: state.percent), for: 4)
                break
            }
        }
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard settings.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
