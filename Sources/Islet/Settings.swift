import Combine
import Foundation

/// User preferences, persisted in UserDefaults and observable by the UI.
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Hovering the island opens it; when off, a click is required.
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: Key.expandOnHover) } }
    @Published var showVolume: Bool { didSet { defaults.set(showVolume, forKey: Key.showVolume) } }
    @Published var showPower: Bool { didSet { defaults.set(showPower, forKey: Key.showPower) } }
    @Published var showAudioOutput: Bool { didSet { defaults.set(showAudioOutput, forKey: Key.showAudioOutput) } }
    @Published var showTrackChanges: Bool { didSet { defaults.set(showTrackChanges, forKey: Key.showTrackChanges) } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: Key.haptics) } }

    private let defaults: UserDefaults

    private enum Key {
        static let expandOnHover = "expandOnHover"
        static let showVolume = "showVolume"
        static let showPower = "showPower"
        static let showAudioOutput = "showAudioOutput"
        static let showTrackChanges = "showTrackChanges"
        static let haptics = "haptics"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.expandOnHover: true,
            Key.showVolume: true,
            Key.showPower: true,
            Key.showAudioOutput: true,
            Key.showTrackChanges: true,
            Key.haptics: true,
        ])
        expandOnHover = defaults.bool(forKey: Key.expandOnHover)
        showVolume = defaults.bool(forKey: Key.showVolume)
        showPower = defaults.bool(forKey: Key.showPower)
        showAudioOutput = defaults.bool(forKey: Key.showAudioOutput)
        showTrackChanges = defaults.bool(forKey: Key.showTrackChanges)
        haptics = defaults.bool(forKey: Key.haptics)
    }
}
