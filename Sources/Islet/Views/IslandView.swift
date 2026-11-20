import SwiftUI

/// The root view of the panel: one black shape hanging from the top of the
/// screen, whose size follows the model, with the current content clipped inside.
struct IslandView: View {
    @ObservedObject var model: IslandModel
    @Namespace private var namespace

    var body: some View {
        let layout = model.layout
        let shape = NotchShape(topRadius: layout.topRadius,
                               bottomRadius: layout.bottomRadius,
                               neckWidth: layout.neckWidth,
                               neckHeight: layout.neckHeight)

        Color.clear
            .frame(width: layout.width, height: layout.height)
            // Content is an overlay so that it never influences the size of the
            // island: each state lays itself out at its final size and gets revealed.
            .overlay(alignment: .top) { content }
            .clipShape(shape)
            // The black body sits behind the clipped content, so its shadow is not clipped away.
            .background {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.isExpanded ? 0.45 : 0), radius: 18, y: 10)
            }
            .contentShape(shape)
            .onTapGesture { model.islandClicked() }
            // Wings of different widths shift the island's centre off the notch's.
            .offset(x: layout.offsetX)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        if model.isExpanded {
            ExpandedView(model: model, namespace: namespace)
                .transition(.islandContent)
        } else if model.showsCompactMedia, let nowPlaying = model.nowPlaying {
            CompactMediaView(nowPlaying: nowPlaying,
                             metrics: model.metrics,
                             showsCaption: model.mode == .hud(.track),
                             // An announcement keeps both wings to the end, even if the
                             // room changes meanwhile: its banner was sized for them.
                             wings: model.mode == .hud(.track)
                                 ? (IslandDesign.mediaWing, IslandDesign.mediaWing)
                                 : model.mediaWings,
                             namespace: namespace)
                .transition(.islandContent)
        } else if case .hud(let hud) = model.mode {
            // From the mode, not from `model.hud`: while the island steps aside
            // for the pointer, a pending banner must not be drawn.
            HUDView(hud: hud, metrics: model.metrics)
                .id(hud.kind)
                .transition(.islandContent)
        }
    }
}
