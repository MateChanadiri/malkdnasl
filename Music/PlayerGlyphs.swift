import SwiftUI

// MARK: - Press style

/// Soft circular highlight under the finger. `scales` adds a small squeeze (play/pause); skip buttons and the
/// star never scale as a whole, only their symbols animate.
struct TransportPressStyle: ButtonStyle {
    var scales: Bool = false
    var highlight: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let pressed: Bool = configuration.isPressed
        return configuration.label
            .background {
                if highlight {
                    Circle()
                        .fill(Color.white.opacity(pressed ? 0.2 : 0))
                        .animation(.easeOut(duration: pressed ? 0.08 : 0.35), value: pressed)
                }
            }
            .scaleEffect(scales && pressed ? 0.92 : 1)
            .animation(.spring(duration: 0.28, bounce: 0.2), value: pressed)
    }
}

// MARK: - Skip glyph (the two triangles flow through the button)

/// Three triangles ride a conveyor: one leaves (shrinks and fades), one moves into its place, a small one
/// grows in from behind. `phase` only ever increases, so repeated taps just keep the belt moving.
struct SkipGlyph: View, Animatable {
    var phase: CGFloat
    var size: CGFloat
    var mirrored: Bool
    var color: Color
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    private func slot(_ k: Int) -> CGFloat {
        let raw: CGFloat = (CGFloat(k) + phase).truncatingRemainder(dividingBy: 3)
        return raw - 1
    }

    private func beltScale(_ s: CGFloat) -> CGFloat {
        if s < 0 { return max(0, 1 + 1.3 * s) }
        if s > 1 { return max(0, 1 - 1.8 * (s - 1)) }
        return 1
    }

    private func beltOpacity(_ s: CGFloat) -> CGFloat {
        if s < 0 { return min(1, max(0, 1 + 0.5 * s)) }
        if s > 1 { return max(0, 1 - 1.3 * (s - 1)) }
        return 1
    }

    var body: some View {
        let w: CGFloat = size * 0.86
        let pitch: CGFloat = w * 0.84
        let total: CGFloat = pitch + w
        ZStack(alignment: .leading) {
            ForEach(0..<3, id: \.self) { (k: Int) in
                let s: CGFloat = slot(k)
                triangle(w: w)
                    .scaleEffect(beltScale(s))
                    .opacity(Double(beltOpacity(s)))
                    .offset(x: s * pitch)
            }
        }
        .frame(width: total, height: size, alignment: .leading)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
    }

    private func triangle(w: CGFloat) -> some View {
        // The same symbol path the play/pause icon uses, so it gets identical glass vibrancy and stays solid.
        Image(systemName: "play.fill")
            .font(.system(size: size * 0.92, weight: .regular))
            .foregroundStyle(color)
            .frame(width: w, height: size)
    }
}

/// Previous / next button. Only its own glyph animates; the button frame, hit area and neighbours stay still.
struct SkipButton: View {
    enum Direction { case previous, next }

    let direction: Direction
    var size: CGFloat = 32
    var frame: CGFloat = 76
    var color: Color = .white
    var highlight: Bool = true
    let action: () -> Void

    @State private var phase: CGFloat = 0

    var body: some View {
        Button {
            action()
            withAnimation(.timingCurve(0.25, 0.9, 0.3, 1, duration: 0.44)) { phase += 1 }
        } label: {
            SkipGlyph(phase: phase, size: size, mirrored: direction == .previous, color: color)
                .frame(width: frame, height: frame)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportPressStyle(scales: false, highlight: highlight))
        .accessibilityLabel(direction == .next ? "Next" : "Previous")
    }
}

// MARK: - Play / pause icon

/// Pause bars shrink away and fade while the rounded play triangle fades in and grows to full size, and back again.
/// Both symbols are always in the view; only the playback state decides which one is showing, so it can't get stuck.
struct PlayPauseIcon: View {
    let isPlaying: Bool
    var size: CGFloat = 46
    var color: Color = .white

    @State private var showsPause: Bool

    init(isPlaying: Bool, size: CGFloat = 46, color: Color = .white) {
        self.isPlaying = isPlaying
        self.size = size
        self.color = color
        _showsPause = State(initialValue: isPlaying)
    }

    var body: some View {
        ZStack {
            Image(systemName: "pause.fill")
                .scaleEffect(showsPause ? 1 : 0.3)
                .opacity(showsPause ? 1 : 0)
            Image(systemName: "play.fill")
                .scaleEffect(showsPause ? 0.3 : 1)
                .opacity(showsPause ? 0 : 1)
        }
        .font(.system(size: size, weight: .regular))
        .foregroundStyle(color)
        // Driven explicitly, so the zoom-and-fade plays every time no matter what animation is around it.
        .onChange(of: isPlaying) { _, playing in
            withAnimation(.easeInOut(duration: 0.34)) { showsPause = playing }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Favourite star

/// The Apple Music star, copied from a frame-by-frame recording at 30 frames per second.
/// Adding: the outline swells a little, the star fills and grows with a soft glow to about 1.45 times its size,
/// shrinks under its size to 0.9, and settles back with a small overshoot (about 0.8 seconds).
/// Removing: the filled star blurs, grows to 1.17 times and fades while the outline comes back (about 0.17 seconds).
/// Only the symbol animates; the frame never changes. The filled state is read straight from the model,
/// so rapid taps can't leave it out of step.
struct FavoriteStarButton: View {
    let isFavorite: Bool
    var size: CGFloat = 36
    var filled: Bool = true
    let action: () -> Void

    @State private var pulse: Int = 0
    @State private var adding = true

    private struct StarFrame {
        var scale = 1.0
        var glow = 0.0
        var tilt = 0.0
        var ghost = 0.0
        var ghostScale = 1.0
    }

    var body: some View {
        Button {
            adding = !isFavorite
            pulse += 1
            action()
        } label: {
            ZStack {
                if filled { Circle().fill(Color.white.opacity(0.18)) }
                symbol
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(TransportPressStyle(scales: false, highlight: false))
        .sensoryFeedback(.impact(weight: .light), trigger: pulse)
        .accessibilityLabel("Favorite")
        .accessibilityValue(isFavorite ? "On" : "Off")
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }

    private var symbol: some View {
        ZStack {
            Image(systemName: "star")
                .opacity(isFavorite ? 0 : 1)
            Image(systemName: "star.fill")
                .opacity(isFavorite ? 1 : 0)
        }
        .keyframeAnimator(initialValue: StarFrame(), trigger: pulse) { content, v in
            content
                .scaleEffect(v.scale)
                .background {
                    Circle()
                        .fill(Color.white)
                        .frame(width: size * 0.78, height: size * 0.78)
                        .blur(radius: size * 0.2)
                        .opacity(0.42 * v.glow)
                }
        } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(adding ? 1.105 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.158 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.237 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.276 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.316 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.342 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.368 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.395 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.421 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.421 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.421 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.434 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.447 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.447 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.447 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.368 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.224 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.079 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.974 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.921 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.895 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.921 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.947 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.974 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.026 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.026 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.013 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.013 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                }
                KeyframeTrack(\.glow) {
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.35 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.5 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.6 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.75 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.85 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.95 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.85 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.45 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.15 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                }
                KeyframeTrack(\.tilt) {
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                }
                KeyframeTrack(\.ghost) {
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 0.0 : 0.0, duration: 1.0 / 30)
                }
                KeyframeTrack(\.ghostScale) {
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                    LinearKeyframe(adding ? 1.0 : 1.0, duration: 1.0 / 30)
                }
        }
        .font(.system(size: size * 0.46, weight: .semibold))
        .foregroundStyle(Color.white)
        .animation(.easeOut(duration: 0.03), value: isFavorite)
    }
}
