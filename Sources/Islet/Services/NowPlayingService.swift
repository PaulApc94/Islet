import AppKit
import Darwin

/// Real-time system "Now Playing" for any app (Spotify, Music, browsers…) plus
/// transport controls.
///
/// Since macOS 15.4 MediaRemote only answers Apple-trusted processes, so the
/// service never talks to it directly: it runs `/usr/bin/perl`, which loads
/// `IsletBridge.dylib` (see Bridge/IsletBridge.m). The child streams JSON lines
/// on stdout and reads commands on stdin; this class supervises it and turns
/// its output into `NowPlaying` snapshots.
@MainActor
final class NowPlayingService {

    /// Called on the main thread, only when the snapshot really changed.
    /// `nil` means nothing is playing.
    var onChange: ((NowPlaying?) -> Void)?
    private(set) var current: NowPlaying?

    // Bridge child process.
    private var isStarted = false
    private var bridgePath: String?
    private var child: BridgeChild?
    /// Bumped on every launch and on `stop()`: whatever a previous child (or a
    /// pending restart) still has queued on the main thread is then ignored.
    private var generation = 0
    private var launchUptime: TimeInterval = 0
    private var restartDelay = Tuning.minRestartDelay
    private var didLogMissingBridge = false

    // The bridge sends the image bytes once per artwork; later lines only carry its id.
    private var artworkCache: Artwork?
    private var sourceCache: [pid_t: ResolvedSource] = [:]

    /// Set while an optimistic state is on screen and the bridge has not confirmed it yet.
    private var hold: Hold?
    /// A new track that arrived without its cover and waits a moment for it.
    private var pendingTrack: PendingTrack?
    /// Lets the timer of a hold or of a pending track recognise it is outdated.
    private var ticketCounter = 0

    init() {}

    // MARK: - Lifecycle

    /// Launches the bridge. Does nothing when already started.
    func start() {
        guard !isStarted else { return }
        guard let path = Self.locateBridge() else {
            if !didLogMissingBridge {
                didLogMissingBridge = true
                NSLog("Islet: IsletBridge.dylib not found, Now Playing is disabled")
            }
            return
        }
        // Writing to a bridge that just died must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        bridgePath = path
        isStarted = true
        restartDelay = Tuning.minRestartDelay
        launchBridge()
    }

    /// Terminates the bridge for good (no restart). Call it at app termination.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        child = nil
        hold = nil
        pendingTrack = nil
        artworkCache = nil
        publish(nil)
    }

    // MARK: - Commands

    func togglePlayPause() {
        guard send("toggle"), var snapshot = current else { return }
        // Re-anchor at "now" so flipping the state does not move the position.
        let now = Date()
        snapshot.elapsedAtTimestamp = snapshot.elapsed(at: now)
        snapshot.timestamp = now
        snapshot.isPlaying.toggle()
        if !snapshot.isPlaying {
            snapshot.playbackRate = 0
        } else if snapshot.playbackRate <= 0 {
            snapshot.playbackRate = 1
        }
        publishOptimistically(snapshot)
    }

    func nextTrack() {
        send("next")
    }

    func previousTrack() {
        send("previous")
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        var target = max(0, seconds)
        if let duration = current?.duration, duration > 0 { target = min(target, duration) }
        // POSIX locale: the bridge parses a "." decimal separator whatever the user's region.
        let command = String(format: "seek %.3f", locale: Locale(identifier: "en_US_POSIX"), target)
        guard send(command), var snapshot = current else { return }
        snapshot.elapsedAtTimestamp = target
        snapshot.timestamp = Date()
        publishOptimistically(snapshot)
    }

    /// Returns `false` when the line could not be delivered (no bridge, or it just died).
    @discardableResult
    private func send(_ command: String) -> Bool {
        child?.send(command) ?? false
    }

    // MARK: - Bridge process

    /// Makes perl load the dylib and call `islet_bridge_run()`, which never returns.
    private static let perlLoader = [
        #"my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die "load: " . DynaLoader::dl_error() . "\n";"#,
        #"my $s = DynaLoader::dl_find_symbol($h, "islet_bridge_run") or die "symbol missing\n";"#,
        #"DynaLoader::dl_install_xsub("main::islet_bridge_run", $s);"#,
        #"main::islet_bridge_run();"#,
    ].joined(separator: " ")

    /// `ISLET_BRIDGE_PATH` wins (development builds), otherwise the copy shipped in the bundle.
    private static func locateBridge() -> String? {
        let override = ProcessInfo.processInfo.environment["ISLET_BRIDGE_PATH"] ?? ""
        let path = override.isEmpty
            ? Bundle.main.url(forResource: "IsletBridge", withExtension: "dylib")?.path
            : override
        guard let path, FileManager.default.isReadableFile(atPath: path) else { return nil }
        return path
    }

    private func launchBridge() {
        guard isStarted, let bridgePath else { return }
        generation += 1
        let generation = generation
        // A fresh bridge sends the image again with its first line; an id kept
        // from the previous one must not vouch for it.
        artworkCache = nil

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MDynaLoader", "-e", Self.perlLoader, bridgePath]
        process.standardInput = input
        process.standardOutput = output
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.bridgeDidExit(generation: generation) }
        }

        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // End of file: without this the handler would spin forever.
                handle.readabilityHandler = nil
                return
            }
            for line in lines.append(chunk) {
                guard let message = BridgeMessage(jsonLine: line) else { continue }
                DispatchQueue.main.async { [weak self] in self?.receive(message, generation: generation) }
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            NSLog("Islet: could not launch the Now Playing bridge: %@", error.localizedDescription)
            scheduleRestart()
            return
        }
        child = BridgeChild(
            process: process,
            commands: input.fileHandleForWriting,
            output: output.fileHandleForReading
        )
        launchUptime = ProcessInfo.processInfo.systemUptime
    }

    private func bridgeDidExit(generation: Int) {
        guard isStarted, generation == self.generation else { return }
        let lifetime = ProcessInfo.processInfo.systemUptime - launchUptime
        child = nil
        if lifetime >= Tuning.healthyRunTime { restartDelay = Tuning.minRestartDelay }
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, Tuning.maxRestartDelay)
        // One hiccup keeps the last snapshot on screen (the bridge is back within
        // a second); a crash loop must not leave a frozen "playing" state behind.
        if delay > Tuning.minRestartDelay {
            hold = nil
            pendingTrack = nil
            publish(nil)
        }
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.launchBridge()
        }
    }

    // MARK: - Snapshots

    private func receive(_ message: BridgeMessage, generation: Int) {
        guard isStarted, generation == self.generation else { return }
        switch message {
        case .empty:
            hold = nil
            pendingTrack = nil
            publish(nil)
        case .update(let update):
            let snapshot = makeSnapshot(from: update)
            if snapshot.artwork == nil, snapshot.trackID != current?.trackID {
                awaitArtwork(for: snapshot)
                return
            }
            pendingTrack = nil
            if hold != nil, let current, snapshot.trackID == current.trackID {
                guard Self.agree(snapshot, current) else {
                    // Most likely the state from just before our command: it only
                    // wins if the player never confirms what we showed.
                    hold?.parked = snapshot
                    return
                }
                // Confirmed. The hold stays open all the same: a slow player
                // answering two quick commands still reports the state in between.
                hold?.parked = nil
            } else {
                hold = nil
            }
            publish(snapshot)
        }
    }

    private func makeSnapshot(from update: BridgeUpdate) -> NowPlaying {
        var snapshot = NowPlaying(
            title: update.title,
            artist: update.artist,
            album: update.album,
            duration: update.duration,
            elapsedAtTimestamp: update.elapsed,
            timestamp: update.timestamp,
            playbackRate: update.rate,
            isPlaying: update.isPlaying,
            artwork: nil,
            artworkID: "",
            accent: nil,
            source: source(for: update.pid)
        )

        if let artwork = update.artwork { artworkCache = artwork }
        if let artworkCache, artworkCache.id == update.artworkID {
            snapshot.artwork = artworkCache.image
            snapshot.artworkID = artworkCache.id
            snapshot.accent = artworkCache.accent
        } else if let current, current.trackID == snapshot.trackID {
            // Players sometimes drop the artwork for a moment: keep the one on screen.
            snapshot.artwork = current.artwork
            snapshot.artworkID = current.artworkID
            snapshot.accent = current.accent
        }

        // We stamped this line ourselves, so an unchanged state would look new
        // on every refresh: keep the anchor we already have.
        if !update.hasTimestamp, let current {
            var probe = snapshot
            probe.timestamp = current.timestamp
            if probe == current { snapshot.timestamp = current.timestamp }
        }
        return snapshot
    }

    private func publish(_ snapshot: NowPlaying?) {
        guard snapshot != current else { return }
        current = snapshot
        onChange?(snapshot)
    }

    // MARK: - Track changes

    private struct PendingTrack {
        let id: Int
        var snapshot: NowPlaying
    }

    /// The system delivers the cover of a new track a moment after its title
    /// (about 50 ms with Chrome and MediaPlayer apps). Publishing the title
    /// alone would flash the placeholder at every track change, so a new track
    /// without a cover waits for it; the wait is short and never extended.
    private func awaitArtwork(for snapshot: NowPlaying) {
        if pendingTrack?.snapshot.trackID == snapshot.trackID {
            pendingTrack?.snapshot = snapshot
            return
        }
        ticketCounter += 1
        let id = ticketCounter
        pendingTrack = PendingTrack(id: id, snapshot: snapshot)
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.artworkGrace) { [weak self] in
            guard let self, let pending = self.pendingTrack, pending.id == id else { return }
            // No cover in time (or none at all): the track is shown without it.
            self.pendingTrack = nil
            self.hold = nil
            self.publish(pending.snapshot)
        }
    }

    // MARK: - Optimistic updates

    private struct Hold {
        let id: Int
        /// The latest bridge snapshot that contradicted what is on screen, as
        /// long as no later one confirmed it.
        var parked: NowPlaying?
    }

    /// Shows `snapshot` right away. The bridge still has the last word: a
    /// snapshot that agrees replaces it at once, one that disagrees (usually
    /// the bridge answering before a slow player reacted) waits for the hold
    /// to expire and is dropped if the player agrees in the meantime, so the
    /// UI does not flicker back and forth.
    private func publishOptimistically(_ snapshot: NowPlaying) {
        ticketCounter += 1
        let id = ticketCounter
        hold = Hold(id: id, parked: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.optimisticHold) { [weak self] in
            guard let self, let hold = self.hold, hold.id == id else { return }
            self.hold = nil
            if let parked = hold.parked { self.publish(parked) }
        }
        publish(snapshot)
    }

    private static func agree(_ lhs: NowPlaying, _ rhs: NowPlaying) -> Bool {
        let now = Date()
        return lhs.isPlaying == rhs.isPlaying
            && abs(lhs.elapsed(at: now) - rhs.elapsed(at: now)) < Tuning.positionTolerance
    }

    // MARK: - Source app

    private func source(for pid: pid_t) -> MediaSource? {
        guard pid > 0 else { return nil }
        // A terminated app means the pid may now belong to something else.
        if let cached = sourceCache[pid], cached.app?.isTerminated != true {
            return cached.source
        }
        sourceCache[pid] = nil
        let resolved = ResolvedSource(mediaPid: pid)
        // An unidentified process most likely just vanished: not worth remembering.
        if resolved.source != nil { sourceCache[pid] = resolved }
        return resolved.source
    }
}

// MARK: - Tuning

private enum Tuning {
    static let minRestartDelay: TimeInterval = 1
    static let maxRestartDelay: TimeInterval = 30
    /// A child that lived this long was healthy: the backoff starts over.
    static let healthyRunTime: TimeInterval = 60
    /// How long an optimistic state outranks a contradicting bridge snapshot.
    static let optimisticHold: TimeInterval = 0.6
    /// Two positions closer than this are the same position.
    static let positionTolerance: TimeInterval = 2
    /// How long a new track may wait for its cover before it is shown without.
    static let artworkGrace: TimeInterval = 0.12
    /// No sane line is longer; protects against a child that never sends "\n".
    static let maxLineLength = 64 << 20
}

// MARK: - Bridge process

/// The running perl child and our ends of its pipes. Releasing it shuts the
/// child down, so a service that goes away (even without `stop()`) never
/// leaves a bridge behind.
private final class BridgeChild {
    private let process: Process
    private let commands: FileHandle
    private let output: FileHandle

    init(process: Process, commands: FileHandle, output: FileHandle) {
        self.process = process
        self.commands = commands
        self.output = output
    }

    /// Returns `false` when the child is gone and the line went nowhere.
    func send(_ command: String) -> Bool {
        (try? commands.write(contentsOf: Data((command + "\n").utf8))) != nil
    }

    deinit {
        output.readabilityHandler = nil
        process.terminationHandler = nil
        // End of file on stdin is what makes the bridge exit; SIGTERM covers
        // the case where it is stuck.
        try? commands.close()
        if process.isRunning { process.terminate() }
    }
}

// MARK: - Bridge protocol

private struct Artwork {
    let id: String
    let image: NSImage
    let accent: NSColor?
}

private struct BridgeUpdate {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var elapsed: TimeInterval
    var timestamp: Date
    /// `false` when the bridge had none and `timestamp` is our own clock.
    var hasTimestamp: Bool
    var rate: Double
    var isPlaying: Bool
    var pid: pid_t
    var artworkID: String
    /// Only when this line carried the image bytes.
    var artwork: Artwork?
}

/// One line of bridge output. Built on the pipe's reader queue, then handed
/// over to the main thread once and never shared: hence the unchecked Sendable.
private enum BridgeMessage: @unchecked Sendable {
    case empty
    case update(BridgeUpdate)

    init?(jsonLine: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: jsonLine)) as? [String: Any] else {
            return nil
        }
        if object["empty"] as? Bool == true {
            self = .empty
            return
        }
        guard let title = object["title"] as? String, !title.isEmpty else { return nil }

        func number(_ key: String) -> Double? {
            guard let value = (object[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }

        let isPlaying = object["playing"] as? Bool ?? false
        let timestamp = number("timestamp").map { Date(timeIntervalSince1970: $0) }
        let artworkID = object["artworkId"] as? String ?? ""

        // Decoding the image and sampling its colour is the expensive part:
        // done here, off the main thread, and only once per artwork.
        var artwork: Artwork?
        if !artworkID.isEmpty,
           let encoded = object["artwork"] as? String,
           let data = Data(base64Encoded: encoded),
           let image = NSImage(data: data), image.isValid {
            artwork = Artwork(id: artworkID, image: image, accent: image.islandAccentColor())
        }

        self = .update(BridgeUpdate(
            title: title,
            artist: object["artist"] as? String ?? "",
            album: object["album"] as? String ?? "",
            duration: max(0, number("duration") ?? 0),
            elapsed: max(0, number("elapsed") ?? 0),
            timestamp: timestamp ?? Date(),
            hasTimestamp: timestamp != nil,
            rate: number("rate") ?? (isPlaying ? 1 : 0),
            isPlaying: isPlaying,
            pid: pid_t(truncatingIfNeeded: (object["pid"] as? NSNumber)?.intValue ?? 0),
            artworkID: artworkID,
            artwork: artwork
        ))
    }
}

/// Reassembles lines from pipe chunks. A line carrying artwork exceeds 1 MB
/// and arrives in dozens of chunks, so only the new bytes are ever scanned.
/// Confined to the pipe's reader queue: hence the unchecked Sendable.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private var isDiscarding = false

    /// Appends a chunk and returns the lines it completed.
    func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            pending.append(chunk[start..<newline])
            if !isDiscarding { lines.append(pending) }
            pending = Data()
            isDiscarding = false
            start = chunk.index(after: newline)
        }
        pending.append(chunk[start...])
        if pending.count > Tuning.maxLineLength {
            pending = Data()
            isDiscarding = true
        }
        return lines
    }
}

// MARK: - Source resolution

/// The app the user would name as "what is playing" for a media pid.
@MainActor
private struct ResolvedSource {
    /// `nil` when the process could not be identified at all.
    let source: MediaSource?
    /// Kept to notice when the app quits and the cache entry goes stale.
    let app: NSRunningApplication?

    init(mediaPid: pid_t) {
        var pid = mediaPid
        var app = NSRunningApplication(processIdentifier: pid)
        // Browsers play media from helpers (Google Chrome Helper,
        // com.apple.WebKit.GPU): show the app responsible for them instead.
        if !Self.standsAlone(app, pid: pid), let responsible = Self.responsiblePid(for: pid) {
            pid = responsible
            app = NSRunningApplication(processIdentifier: responsible)
        }

        let location = Self.location(of: app, pid: pid)
        var bundleURL = app?.bundleURL.flatMap { $0.pathExtension == "app" ? $0 : nil }
        var name = app?.localizedName ?? location?.lastPathComponent
        // Still a helper (no responsibility API, or it had no better answer):
        // the outermost .app of its path is the app it belongs to.
        if !Self.standsAlone(app, pid: pid),
           let outer = Self.outermostApp(containing: location),
           outer.path != bundleURL?.path {
            bundleURL = outer
            name = Self.displayName(ofAppAt: outer)
        }

        if let name, !name.isEmpty {
            source = MediaSource(
                pid: pid,
                name: name,
                bundleURL: bundleURL,
                icon: bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? app?.icon
            )
        } else {
            source = nil
        }
        self.app = app
    }

    /// Dock apps are sources in their own right, and so are stand-alone
    /// menu-bar apps and bare executables. Background processes, XPC services,
    /// extensions and apps nested inside another app play on behalf of someone.
    private static func standsAlone(_ app: NSRunningApplication?, pid: pid_t) -> Bool {
        guard let app else { return false }
        switch app.activationPolicy {
        case .regular:
            return true
        case .accessory:
            guard let location = location(of: app, pid: pid)?.standardizedFileURL else { return true }
            if location.pathComponents.contains(where: { $0.hasSuffix(".xpc") || $0.hasSuffix(".appex") }) {
                return false
            }
            guard let outer = outermostApp(containing: location) else { return true }
            return outer.path == location.path
        default:
            return false
        }
    }

    private static func location(of app: NSRunningApplication?, pid: pid_t) -> URL? {
        app?.bundleURL ?? app?.executableURL ?? executableURL(of: pid)
    }

    /// ".../Google Chrome.app/Contents/…/Google Chrome Helper.app/…" -> ".../Google Chrome.app"
    private static func outermostApp(containing url: URL?) -> URL? {
        guard let url else { return nil }
        var result = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            result.appendPathComponent(component)
            if component.hasSuffix(".app") { return result }
        }
        return nil
    }

    private static func displayName(ofAppAt url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func executableURL(of pid: pid_t) -> URL? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift cannot import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private typealias ResponsiblePidFunction = @convention(c) (pid_t) -> pid_t

    /// Private libsystem call, looked up at run time so a future macOS that
    /// drops it only costs us the nicer answer.
    private static let responsiblePidFunction: ResponsiblePidFunction? = {
        // RTLD_DEFAULT, another macro Swift cannot import.
        let anyLoadedImage = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(anyLoadedImage, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsiblePidFunction.self)
    }()

    private static func responsiblePid(for pid: pid_t) -> pid_t? {
        guard let responsible = responsiblePidFunction?(pid), responsible > 1, responsible != pid else {
            return nil
        }
        return responsible
    }
}
