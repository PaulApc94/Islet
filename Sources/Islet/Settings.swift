import Combine
import Foundation

/// User preferences, persisted in UserDefaults and observable by the UI.
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Hovering the island opens it; when off, a click is required.
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: Key.expandOnHover) } }
    /// The compact player beside the notch while something plays. Off, the
    /// island stays hidden behind the notch (and off the menu bar items next
    /// to it) until it is hovered.
    @Published var showNowPlaying: Bool { didSet { defaults.set(showNowPlaying, forKey: Key.showNowPlaying) } }
    /// Fit the compact player into the free room beside the notch instead of
    /// drawing it over the menu bar's items. Off by default: measuring that
    /// room needs the Accessibility permission.
    @Published var fitToMenuBar: Bool { didSet { defaults.set(fitToMenuBar, forKey: Key.fitToMenuBar) } }
    @Published var showVolume: Bool { didSet { defaults.set(showVolume, forKey: Key.showVolume) } }
    @Published var showPower: Bool { didSet { defaults.set(showPower, forKey: Key.showPower) } }
    @Published var showAudioOutput: Bool { didSet { defaults.set(showAudioOutput, forKey: Key.showAudioOutput) } }
    @Published var showTrackChanges: Bool { didSet { defaults.set(showTrackChanges, forKey: Key.showTrackChanges) } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: Key.haptics) } }
    /// Islet's own icon in the menu bar. Hidden, it leaves its place beside the
    /// notch free; the settings then open from the island (right-click) or by
    /// launching Islet again.
    @Published var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }

    private let defaults: UserDefaults

    private enum Key {
        static let expandOnHover = "expandOnHover"
        static let showNowPlaying = "showNowPlaying"
        static let fitToMenuBar = "fitToMenuBar"
        static let showVolume = "showVolume"
        static let showPower = "showPower"
        static let showAudioOutput = "showAudioOutput"
        static let showTrackChanges = "showTrackChanges"
        static let haptics = "haptics"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.expandOnHover: true,
            Key.showNowPlaying: true,
            Key.fitToMenuBar: false,
            Key.showVolume: true,
            Key.showPower: true,
            Key.showAudioOutput: true,
            Key.showTrackChanges: true,
            Key.haptics: true,
            Key.showMenuBarIcon: true,
        ])
        expandOnHover = defaults.bool(forKey: Key.expandOnHover)
        showNowPlaying = defaults.bool(forKey: Key.showNowPlaying)
        fitToMenuBar = defaults.bool(forKey: Key.fitToMenuBar)
        showVolume = defaults.bool(forKey: Key.showVolume)
        showPower = defaults.bool(forKey: Key.showPower)
        showAudioOutput = defaults.bool(forKey: Key.showAudioOutput)
        showTrackChanges = defaults.bool(forKey: Key.showTrackChanges)
        haptics = defaults.bool(forKey: Key.haptics)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
    }
}
