import AppKit
import SwiftUI

/// Lays content out on both sides of the notch. The centre stays empty: on a
/// MacBook it is hidden by the camera housing.
struct WingRow<Leading: View, Trailing: View>: View {
    let metrics: IslandMetrics
    /// Width of each side, ear included.
    let wing: CGFloat
    var ear: CGFloat = IslandDesign.ear
    var inset: CGFloat = 8
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        let contentWidth = max(0, wing - ear - inset - 4)
        HStack(spacing: 0) {
            leading()
                .frame(width: contentWidth, alignment: .leading)
                .padding(.leading, ear + inset)
                .padding(.trailing, 4)
            Color.clear
                .frame(width: metrics.notchWidth)
            trailing()
                .frame(width: contentWidth, alignment: .trailing)
                .padding(.leading, 4)
                .padding(.trailing, ear + inset)
        }
        .frame(height: metrics.notchHeight)
    }
}

// MARK: - Music

/// Cover on the left, animated bars on the right. When a track starts, a
/// caption with its title slides out underneath.
struct CompactMediaView: View {
    let nowPlaying: NowPlaying
    let metrics: IslandMetrics
    let showsCaption: Bool
    /// Width of the wing on each side of the notch. Normally both the same;
    /// when the player is fitted into the free room of the menu bar, one may
    /// be missing, and the other then carries the cover (and the bars if wide).
    var wings: (left: CGFloat, right: CGFloat) = (IslandDesign.mediaWing, IslandDesign.mediaWing)
    let namespace: Namespace.ID

    var body: some View {
        let side = min(metrics.notchHeight - 10, 24)
        // Effect before the fixed frame, as in the expanded player: the cover
        // morphs between the two sizes instead of sliding.
        let cover = ArtworkView(nowPlaying: nowPlaying, cornerRadius: side * 0.27)
            .matchedGeometryEffect(id: ArtworkView.geometryID, in: namespace)
            .frame(width: side, height: side)
        let bars = SpectrumView(color: nowPlaying.accent ?? .white, isPlaying: nowPlaying.isPlaying)
            .frame(width: 18, height: 14)
        let edge = IslandDesign.ear + 8
        let isWide = max(wings.left, wings.right) > IslandDesign.mediaWing

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    if wings.left > 0 {
                        cover
                        if wings.right == 0, isWide { bars }
                    }
                }
                .padding(.leading, edge)
                .frame(width: wings.left, alignment: .leading)

                Color.clear
                    .frame(width: metrics.notchWidth)

                HStack(spacing: 8) {
                    if wings.right > 0 {
                        if wings.left > 0 {
                            bars
                        } else {
                            if isWide { bars }
                            cover
                        }
                    }
                }
                .padding(.trailing, edge)
                .frame(width: wings.right, alignment: .trailing)
            }
            .frame(height: metrics.notchHeight)

            if showsCaption {
                caption
                    .frame(width: metrics.notchWidth + 2 * IslandDesign.mediaWing - 36,
                           height: IslandDesign.captionHeight)
                    .offset(y: -2)
                    .transition(.islandContent)
            }
        }
    }

    private var caption: some View {
        let artist = nowPlaying.artist.isEmpty ? "" : "  ·  \(nowPlaying.artist)"
        return (Text(nowPlaying.title).fontWeight(.semibold).foregroundStyle(.white)
            + Text(artist).foregroundStyle(.white.opacity(0.55)))
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.tail)
            .id(nowPlaying.trackID)
            .transition(.islandContent)
    }
}

// MARK: - Banners

/// Volume, charging, low battery and audio output banners.
struct HUDView: View {
    let hud: IslandHUD
    let metrics: IslandMetrics

    var body: some View {
        VStack(spacing: 0) {
            WingRow(metrics: metrics, wing: hud.wing) {
                leading
            } trailing: {
                trailing
            }

            if let caption {
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: metrics.notchWidth + 2 * hud.wing - 36,
                           height: IslandDesign.captionHeight)
                    .offset(y: -2)
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch hud {
        case .volume(let volume):
            Image(systemName: Self.speakerSymbol(for: volume))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                // The symbols have different widths: a fixed slot keeps the icon from jittering.
                .frame(width: 24, alignment: .leading)
        case .charging:
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    // The text next to it already says it.
                    .accessibilityHidden(true)
                Text(L10n.t("En charge", "Charging"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Color.green)
        case .lowBattery(let percent):
            BatteryGlyph(percent: percent, tint: .red)
        case .output(let output):
            Image(systemName: Self.validSymbol(output.symbolName))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        case .track:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch hud {
        case .volume(let volume):
            LevelBar(level: volume.isMuted ? 0 : CGFloat(volume.level))
                .frame(width: 52, height: 5)
        case .charging(let percent):
            HStack(spacing: 5) {
                Text(L10n.percent(percent))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.green)
                    .lineLimit(1)
                    .fixedSize()
                BatteryGlyph(percent: percent, tint: .green)
            }
        case .lowBattery(let percent):
            Text(L10n.percent(percent))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.red)
                .lineLimit(1)
                .fixedSize()
        case .output:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
        case .track:
            EmptyView()
        }
    }

    private var caption: String? {
        switch hud {
        case .lowBattery: return L10n.t("Batterie faible", "Low Battery")
        case .output(let output): return output.name
        case .volume, .charging, .track: return nil
        }
    }

    private static func speakerSymbol(for volume: VolumeState) -> String {
        if volume.isMuted || volume.level <= 0.001 { return "speaker.slash.fill" }
        if volume.level < 0.34 { return "speaker.wave.1.fill" }
        if volume.level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// Device symbols vary between macOS releases: never show an empty slot.
    private static func validSymbol(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "speaker.wave.2.fill"
    }
}
