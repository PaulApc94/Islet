import SwiftUI

/// The open island: a header on both sides of the notch, then the player (or a
/// small dashboard when nothing is playing).
struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    let namespace: Namespace.ID

    var body: some View {
        // Laid out at its final size from the first frame: the shape grows
        // around it, so the text never reflows during the animation.
        let layout = model.layout(for: .expanded)
        VStack(spacing: 0) {
            header
            if let nowPlaying = model.nowPlaying {
                PlayerView(nowPlaying: nowPlaying, model: model, namespace: namespace)
                    .transition(.islandContent)
            } else {
                DashboardView()
                    .transition(.islandContent)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
    }

    private var header: some View {
        WingRow(metrics: model.metrics,
                wing: (IslandDesign.expandedWidth - model.metrics.notchWidth) / 2,
                ear: IslandDesign.expandedEar,
                inset: 10) {
            sourceLabel
        } trailing: {
            BatteryLabel(state: model.battery)
        }
    }

    @ViewBuilder
    private var sourceLabel: some View {
        if let source = model.nowPlaying?.source {
            HStack(spacing: 5) {
                if let icon = source.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(source.name)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        } else {
            Text(Date.now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }
}

// MARK: - Header

private struct BatteryLabel: View {
    let state: BatteryState

    var body: some View {
        if state.hasBattery {
            HStack(spacing: 5) {
                if state.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.green)
                        .accessibilityLabel(L10n.t("En charge", "Charging"))
                }
                Text(L10n.percent(state.percent))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
                BatteryGlyph(percent: state.percent, tint: tint)
            }
        }
    }

    private var tint: Color {
        if state.isPluggedIn { return .green }
        return state.percent <= 20 ? .red : .white
    }
}

// MARK: - Player

private struct PlayerView: View {
    let nowPlaying: NowPlaying
    let model: IslandModel
    let namespace: Namespace.ID

    private let artworkSide: CGFloat = 100

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                model.openSourceApp()
            } label: {
                // The effect goes before the fixed frame: that way the one cover
                // grows from the compact island's size instead of two covers of
                // fixed sizes sliding over each other.
                ArtworkView(nowPlaying: nowPlaying, cornerRadius: 16)
                    .matchedGeometryEffect(id: ArtworkView.geometryID, in: namespace)
                    .frame(width: artworkSide, height: artworkSide)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(nowPlaying.source.map { L10n.t("Ouvrir \($0.name)", "Open \($0.name)") }
                ?? L10n.t("Pochette", "Artwork"))
            .shadow(color: nowPlaying.accentColor.opacity(0.28), radius: 12, y: 4)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nowPlaying.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    .id(nowPlaying.trackID)
                    .transition(.islandContent)

                    Spacer(minLength: 0)

                    SpectrumView(color: nowPlaying.accent ?? .white, isPlaying: nowPlaying.isPlaying)
                        .frame(width: 20, height: 16)
                        .padding(.top, 1)
                }

                Spacer(minLength: 0)

                ProgressScrubber(nowPlaying: nowPlaying) { seconds in
                    model.seek(to: seconds)
                }

                Spacer(minLength: 0)

                HStack(spacing: 18) {
                    IslandButton(symbol: "backward.fill", size: 15,
                                 label: L10n.t("Titre précédent", "Previous Track")) { model.previousTrack() }
                    IslandButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 20,
                                 label: nowPlaying.isPlaying ? L10n.t("Pause", "Pause") : L10n.t("Lecture", "Play")) {
                        model.togglePlayPause()
                    }
                    IslandButton(symbol: "forward.fill", size: 15,
                                 label: L10n.t("Titre suivant", "Next Track")) { model.nextTrack() }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: artworkSide)
        }
        .padding(.horizontal, IslandDesign.expandedEar + 18)
        .padding(.top, 6)
        .frame(height: IslandDesign.playerHeight, alignment: .top)
    }

    private var subtitle: String {
        if !nowPlaying.artist.isEmpty { return nowPlaying.artist }
        if !nowPlaying.album.isEmpty { return nowPlaying.album }
        return nowPlaying.source?.name ?? ""
    }
}

/// The position bar. It advances by itself from the last known position, and
/// dragging it seeks.
private struct ProgressScrubber: View {
    let nowPlaying: NowPlaying
    let onSeek: (TimeInterval) -> Void

    // Not `@State`: see `ViewState` in Components.swift.
    private let drag = ViewState<Double?>(nil)
    private let hover = ViewState(false)

    /// The position under the pointer while dragging, as a fraction of the track.
    private var dragFraction: Double? {
        get { drag.wrappedValue }
        nonmutating set { drag.wrappedValue = newValue }
    }

    private var isHovering: Bool {
        get { hover.wrappedValue }
        nonmutating set { hover.wrappedValue = newValue }
    }

    var body: some View {
        // Redraw only as often as the bar can visibly move (about one point per
        // step): a three-minute track needs two frames per second, not sixty.
        // Every redraw re-rasterises the island's shadow, so this is the
        // difference between 7 % and 1 % of CPU while the island is open.
        // With no duration (radio, live streams) the bar never moves: only the
        // clock ticks, and half a second keeps it from skipping a second.
        let interval = nowPlaying.duration > 0 ? min(max(nowPlaying.duration / 250, 0.1), 0.5) : 0.5
        TimelineView(.animation(minimumInterval: interval, paused: !nowPlaying.isPlaying)) { timeline in
            let duration = nowPlaying.duration
            let elapsed = nowPlaying.elapsed(at: timeline.date)
            let fraction = dragFraction ?? (duration > 0 ? min(max(elapsed / duration, 0), 1) : 0)
            let shown = dragFraction.map { $0 * duration } ?? elapsed

            VStack(spacing: 2) {
                GeometryReader { geometry in
                    let thickness: CGFloat = isHovering || dragFraction != nil ? 6 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: fraction <= 0 ? 0 : max(thickness, geometry.size.width * fraction))
                    }
                    .frame(height: thickness)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(scrub(width: geometry.size.width, duration: duration))
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
                    }
                }
                .frame(height: 10)
                // Drawn shapes are invisible to VoiceOver: expose the bar as one
                // adjustable element that seeks by ten seconds.
                .accessibilityElement()
                .accessibilityLabel(L10n.t("Position de lecture", "Playback Position"))
                .accessibilityValue(Self.clock(shown))
                .accessibilityAdjustableAction { direction in
                    guard duration > 0 else { return }
                    switch direction {
                    case .increment: onSeek(min(duration, elapsed + 10))
                    case .decrement: onSeek(max(0, elapsed - 10))
                    @unknown default: break
                    }
                }

                HStack {
                    Text(Self.clock(shown))
                    Spacer()
                    Text(duration > 0 ? "-" + Self.clock(max(0, duration - shown)) : "–:––")
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func scrub(width: CGFloat, duration: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0, width > 0 else { return }
                dragFraction = min(max(value.location.x / width, 0), 1)
            }
            .onEnded { value in
                defer { dragFraction = nil }
                guard duration > 0, width > 0 else { return }
                onSeek(min(max(value.location.x / width, 0), 1) * duration)
            }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        // Int(_:) traps beyond Int.max: never trust a player's numbers that far.
        let bounded = seconds.isFinite ? min(max(seconds, 0), 3_599_999) : 0
        let total = Int(bounded.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Dashboard

/// Shown when nothing is playing: the time, and a hint about what the island is for.
private struct DashboardView: View {
    var body: some View {
        HStack(alignment: .center) {
            TimelineView(.everyMinute) { timeline in
                Text(timeline.date, format: .dateTime.hour().minute())
                    .font(.system(size: 36, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Text(L10n.t("Aucune lecture en cours", "Nothing Playing"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, IslandDesign.expandedEar + 22)
        .padding(.bottom, 8)
        .frame(height: IslandDesign.dashboardHeight)
    }
}
