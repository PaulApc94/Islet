import SwiftUI

// MARK: - Transition

extension AnyTransition {
    /// Content dissolves through a blur while the black shape morphs around it,
    /// so two states never appear to overlap sharply.
    static var islandContent: AnyTransition {
        .modifier(active: BlurFade(progress: 1), identity: BlurFade(progress: 0))
    }
}

private struct BlurFade: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: progress * 10)
            .opacity(1 - progress)
            .scaleEffect(1 - progress * 0.08, anchor: .top)
    }
}

// MARK: - Now Playing helpers

extension NowPlaying {
    var accentColor: Color {
        accent.map { Color(nsColor: $0) } ?? .white
    }
}

/// The cover of the current track; falls back to the player's icon, then to a note.
struct ArtworkView: View {
    /// Shared by the compact and expanded players so the cover flies between them.
    static let geometryID = "artwork"

    let nowPlaying: NowPlaying
    let cornerRadius: CGFloat

    var body: some View {
        // The overlay keeps the layout size independent of the image's aspect ratio
        // (video thumbnails are 16:9 and get cropped to a square).
        Color.white.opacity(0.08)
            .overlay {
                if let artwork = nowPlaying.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else if let icon = nowPlaying.source?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(cornerRadius * 0.4)
                } else {
                    Image(systemName: "music.note")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(cornerRadius)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Animated bars suggesting the audio. They are not driven by the real signal:
/// capturing system audio would require a screen-recording permission.
///
/// They are animated by Core Animation rather than by SwiftUI: the render
/// server interpolates the frames, so the bars cost the app no CPU even when
/// music plays for hours (a SwiftUI-driven version measured around 7 %).
struct SpectrumView: NSViewRepresentable {
    var color: NSColor
    var isPlaying: Bool

    func makeNSView(context: Context) -> SpectrumLayerView {
        SpectrumLayerView()
    }

    func updateNSView(_ view: SpectrumLayerView, context: Context) {
        view.configure(color: color, isPlaying: isPlaying)
    }
}

final class SpectrumLayerView: NSView {
    private static let animationKey = "spectrum"

    /// Heights (as a fraction of the view) each bar cycles through. Every row
    /// ends where it starts so the loop is seamless, and the rows have
    /// different lengths in time so the bars never move in step.
    private static let patterns: [[CGFloat]] = [
        [0.35, 0.90, 0.50, 1.00, 0.30, 0.70, 0.45, 0.35],
        [0.80, 0.40, 1.00, 0.55, 0.90, 0.30, 0.75, 0.80],
        [0.50, 1.00, 0.35, 0.85, 0.60, 1.00, 0.40, 0.50],
        [1.00, 0.45, 0.80, 0.30, 0.95, 0.50, 0.65, 1.00],
        [0.40, 0.75, 0.30, 0.90, 0.50, 0.85, 0.35, 0.40],
    ]
    private static let durations: [CFTimeInterval] = [1.9, 2.3, 1.7, 2.6, 2.1]

    private let bars: [CALayer] = patterns.map { _ in CALayer() }
    private var color: NSColor = .white
    private var isPlaying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SpectrumLayerView is created in code only")
    }

    func configure(color: NSColor, isPlaying: Bool) {
        let playbackChanged = isPlaying != self.isPlaying
        self.color = color
        self.isPlaying = isPlaying
        // Standalone layers animate colour changes implicitly: a new cover fades in.
        bars.forEach { $0.backgroundColor = color.cgColor }
        if playbackChanged { animate() }
    }

    override func layout() {
        super.layout()
        let slot = bounds.width / CGFloat(bars.count)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: modelHeight(of: index))
            bar.position = CGPoint(x: (CGFloat(index) + 0.5) * slot, y: bounds.midY)
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = color.cgColor
        }
        CATransaction.commit()
        animate()
    }

    // Core Animation drops running animations when a view leaves its window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { animate() }
    }

    private var barWidth: CGFloat { bounds.width / CGFloat(bars.count) * 0.56 }
    private var restHeight: CGFloat { max(barWidth, bounds.height * 0.16) }

    /// The height a bar has when no animation is running (also what a static render shows).
    private func modelHeight(of index: Int) -> CGFloat {
        isPlaying ? max(barWidth, bounds.height * Self.patterns[index][0]) : restHeight
    }

    private func animate() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        for (index, bar) in bars.enumerated() {
            let current = bar.presentation()?.bounds.height ?? bar.bounds.height
            bar.removeAnimation(forKey: Self.animationKey)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds.size.height = modelHeight(of: index)
            CATransaction.commit()

            if isPlaying {
                let loop = CAKeyframeAnimation(keyPath: "bounds.size.height")
                loop.values = Self.patterns[index].map { max(barWidth, bounds.height * $0) }
                loop.duration = Self.durations[index]
                loop.calculationMode = .cubic
                loop.repeatCount = .infinity
                bar.add(loop, forKey: Self.animationKey)
            } else {
                // Settle from wherever the bar was instead of snapping flat.
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = current
                settle.toValue = restHeight
                settle.duration = 0.3
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(settle, forKey: Self.animationKey)
            }
        }
    }
}

// MARK: - View state

/// Local view state, spelled without the `@State` attribute.
///
/// On recent SDKs `@State` is a macro whose compiler plugin only ships with
/// Xcode, so using it would make the project impossible to build with the
/// Command Line Tools alone. Storing the `State` value explicitly is exactly
/// what the attribute expands to, and SwiftUI manages it the same way.
typealias ViewState<Value> = State<Value>

extension State {
    init(_ initialValue: Value) {
        self.init(initialValue: initialValue)
    }
}

// MARK: - Small controls

struct BatteryGlyph: View {
    let percent: Int
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, 18 * CGFloat(min(max(percent, 0), 100)) / 100))
                    .padding(2)
            }
            .frame(width: 22, height: 11)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.white.opacity(0.4))
                .frame(width: 1.5, height: 4)
        }
    }
}

struct LevelBar: View {
    /// 0...1
    let level: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(level, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(Color.white)
                    .frame(width: clamped <= 0 ? 0 : max(geometry.size.height, geometry.size.width * clamped))
            }
        }
    }
}

struct IslandButton: View {
    let symbol: String
    let size: CGFloat
    /// Read by VoiceOver: the symbol alone says nothing.
    let label: String
    let action: () -> Void

    // Not `@State`: see `ViewState` below.
    private let hover = ViewState(false)
    private var isHovering: Bool {
        get { hover.wrappedValue }
        nonmutating set { hover.wrappedValue = newValue }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: size + 16, height: size + 16)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
