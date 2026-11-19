import AppKit

// The value types shared by the services (which produce them) and the island
// (which displays them). Everything here is a plain snapshot: no behaviour, no
// references to the services themselves.

// MARK: - Now Playing

/// The app that owns the current media session.
struct MediaSource: Equatable {
    var pid: pid_t
    var name: String
    var bundleURL: URL?
    var icon: NSImage?

    static func == (lhs: MediaSource, rhs: MediaSource) -> Bool {
        lhs.pid == rhs.pid && lhs.name == rhs.name && lhs.bundleURL == rhs.bundleURL
    }
}

/// A snapshot of what the system reports as "Now Playing".
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    /// Total length in seconds. `0` when unknown (live streams, some web players).
    var duration: TimeInterval
    /// Playback position at the moment `timestamp` was taken.
    var elapsedAtTimestamp: TimeInterval
    var timestamp: Date
    var playbackRate: Double
    var isPlaying: Bool
    var artwork: NSImage?
    /// Stable identifier of the artwork. Empty when there is none.
    var artworkID: String
    /// A colour sampled from the artwork, tuned to stay readable on black.
    var accent: NSColor?
    var source: MediaSource?

    /// Identifies the track itself, independently of its playback state.
    var trackID: String { "\(title)\u{1F}\(artist)\u{1F}\(album)" }

    /// The playback position extrapolated to `date`.
    func elapsed(at date: Date = Date()) -> TimeInterval {
        var value = elapsedAtTimestamp
        if isPlaying {
            value += date.timeIntervalSince(timestamp) * (playbackRate > 0 ? playbackRate : 1)
        }
        if duration > 0 { value = min(value, duration) }
        return max(0, value)
    }

    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.duration == rhs.duration
            && lhs.elapsedAtTimestamp == rhs.elapsedAtTimestamp
            && lhs.timestamp == rhs.timestamp
            && lhs.playbackRate == rhs.playbackRate
            && lhs.isPlaying == rhs.isPlaying
            && lhs.artworkID == rhs.artworkID
            && lhs.source == rhs.source
    }
}

// MARK: - Power

struct BatteryState: Equatable {
    /// `false` on desktop Macs: the island then hides every battery element.
    var hasBattery: Bool
    /// 0...100
    var percent: Int
    /// The battery is actively taking charge.
    var isCharging: Bool
    /// The Mac runs on AC power (charging or full).
    var isPluggedIn: Bool

    static let unknown = BatteryState(hasBattery: false, percent: 100, isCharging: false, isPluggedIn: true)
}

// MARK: - Audio

struct VolumeState: Equatable {
    /// 0...1
    var level: Float
    var isMuted: Bool
}

struct AudioOutput: Equatable {
    var name: String
    /// SF Symbol describing the device (AirPods, headphones, speakers…).
    var symbolName: String
}

// MARK: - Artwork colour

extension NSImage {
    /// The dominant vivid colour of the image, lifted so it reads well on black.
    func islandAccentColor() -> NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 20
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            // Vivid pixels dominate; grey ones barely count.
            let weight = 0.05 + saturation * maxC
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        guard total > 0 else { return nil }

        let average = NSColor(srgbRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(saturation * 1.15, 0.9), brightness: max(brightness, 0.85), alpha: 1)
    }
}
