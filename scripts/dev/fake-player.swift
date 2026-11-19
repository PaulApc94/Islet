#!/usr/bin/env swift
//
//  fake-player.swift: a silent "Now Playing" app for developing Islet.
//
//      swift scripts/dev/fake-player.swift
//
//  Registers with the system as the Now Playing app (no audio is ever played),
//  cycles through three fake tracks and logs every remote command it receives,
//  so the island can be exercised without touching a real player.
//
//  FAKE_PLAYER_LAG=0.4 makes it react to commands 0.4 s late, like a sluggish
//  player: handy to check the island's optimistic updates.
//

import AppKit
import MediaPlayer

struct Track {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let hue: CGFloat
}

let tracks = [
    Track(title: "Neon Tide", artist: "The Fixtures", album: "Test Signals", duration: 48, hue: 0.92),
    Track(title: "Paper Satellites", artist: "Mock & Stub", album: "Dry Run", duration: 75, hue: 0.55),
    Track(title: "Golden Hour Loop", artist: "Null Pointer", album: "Edge Cases", duration: 120, hue: 0.12),
]

let lag = TimeInterval(ProcessInfo.processInfo.environment["FAKE_PLAYER_LAG"] ?? "") ?? 0

let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

func log(_ message: String) {
    print("[\(clock.string(from: Date()))] \(message)")
}

/// A cover nobody can mistake for another: one hue per track, plus its number.
func cover(for index: Int) -> MPMediaItemArtwork {
    let size = NSSize(width: 600, height: 600)
    let hue = tracks[index].hue
    let image = NSImage(size: size, flipped: false) { rect in
        let top = NSColor(hue: hue, saturation: 0.85, brightness: 0.95, alpha: 1)
        let bottom = NSColor(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.9, brightness: 0.45, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -60)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 110, dy: 110)).fill()
        let label = NSAttributedString(string: "\(index + 1)", attributes: [
            .font: NSFont.systemFont(ofSize: 260, weight: .black),
            .foregroundColor: NSColor.white,
        ])
        let labelSize = label.size()
        label.draw(at: NSPoint(x: rect.midX - labelSize.width / 2, y: rect.midY - labelSize.height / 2))
        return true
    }
    return MPMediaItemArtwork(boundsSize: size) { _ in image }
}

final class FakePlayer {
    private var index = 0
    private var isPlaying = true
    /// Position when `anchor` was taken; the live one is extrapolated while playing.
    private var position: TimeInterval = 0
    private var anchor = Date()
    private let covers = tracks.indices.map(cover(for:))

    private var livePosition: TimeInterval {
        isPlaying ? position + Date().timeIntervalSince(anchor) : position
    }

    func start() {
        let commands = MPRemoteCommandCenter.shared()
        handle(commands.playCommand, "play") { _ in self.setPlaying(true) }
        handle(commands.pauseCommand, "pause") { _ in self.setPlaying(false) }
        handle(commands.togglePlayPauseCommand, "toggle") { _ in self.setPlaying(!self.isPlaying) }
        handle(commands.nextTrackCommand, "next") { _ in self.skip(by: 1) }
        handle(commands.previousTrackCommand, "previous") { _ in self.skip(by: -1) }
        handle(commands.changePlaybackPositionCommand, "seek") { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            self.move(to: event.positionTime)
        }
        // Auto-advance, like a real player reaching the end of a track.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            guard self.isPlaying, self.livePosition >= tracks[self.index].duration else { return }
            log("track ended")
            self.skip(by: 1)
        }
        publish()
    }

    private func handle(_ command: MPRemoteCommand, _ name: String, _ action: @escaping (MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        command.addTarget { event in
            let target = (event as? MPChangePlaybackPositionCommandEvent).map { String(format: " %.1f", $0.positionTime) } ?? ""
            log("command: \(name)\(target)")
            // The handler may run off the main thread; the player state lives on it.
            DispatchQueue.main.asyncAfter(deadline: .now() + lag) { action(event) }
            return .success
        }
    }

    private func setPlaying(_ playing: Bool) {
        position = livePosition
        anchor = Date()
        isPlaying = playing
        publish()
    }

    private func skip(by offset: Int) {
        index = (index + offset + tracks.count) % tracks.count
        move(to: 0)
    }

    private func move(to seconds: TimeInterval) {
        position = min(max(0, seconds), tracks[index].duration)
        anchor = Date()
        publish()
    }

    private func publish() {
        let track = tracks[index]
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyArtwork: covers[index],
        ]
        // macOS has no audio session to infer this from: it must be set explicitly,
        // otherwise the system never treats this process as the Now Playing app.
        center.playbackState = isPlaying ? .playing : .paused
        log("\(isPlaying ? "playing" : "paused") \"\(track.title)\" at \(String(format: "%.1f", position)) / \(Int(track.duration)) s")
    }
}

// Keep the log live when stdout is a file or a pipe.
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
// No Dock icon and no window: only the run loop MediaPlayer needs.
app.setActivationPolicy(.accessory)

let player = FakePlayer()
print("fake-player pid \(getpid())")
player.start()
app.run()
