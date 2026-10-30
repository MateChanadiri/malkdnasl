import SwiftUI

// MARK: - Texture

/// The theme's print surface over a whole screen. Always in the hierarchy (opacity 0 for "none"),
/// so switching themes never rebuilds the app underneath.
struct ThemeTexture: View {
    var kind: AppTheme.Texture
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Image(uiImage: TextureTiles.tile(kind))
            .renderingMode(.template)
            .resizable(resizingMode: .tile)
            .foregroundStyle(dark ? Color.white : Color.black)
            .opacity(kind == .none ? 0 : opacity(dark))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func opacity(_ dark: Bool) -> Double {
        switch kind {
        case .none: 0
        case .grain: dark ? 0.09 : 0.06
        case .paper: dark ? 0.08 : 0.09
        case .halftone: dark ? 0.07 : 0.06
        case .scanlines: dark ? 0.16 : 0.07
        }
    }
}

/// Small tiles drawn once (alpha only; tinted by the view) and repeated across the screen.
enum TextureTiles {
    @MainActor private static var cache: [AppTheme.Texture: UIImage] = [:]

    @MainActor static func tile(_ kind: AppTheme.Texture) -> UIImage {
        if let cached = cache[kind] { return cached }
        let image = draw(kind)
        cache[kind] = image
        return image
    }

    private static func draw(_ kind: AppTheme.Texture) -> UIImage {
        let size: CGFloat = kind == .paper ? 160 : kind == .halftone ? 12 : kind == .scanlines ? 4 : 96
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let c = ctx.cgContext
            var rng = SeededRandom(seed: 7)
            switch kind {
            case .none:
                break
            case .grain:
                for y in 0..<Int(size) {
                    for x in 0..<Int(size) {
                        UIColor(white: 0, alpha: CGFloat(rng.next()) * 0.9).setFill()
                        c.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            case .paper:
                // Soft mottling plus short fibres.
                for _ in 0..<260 {
                    let r = CGFloat(rng.next()) * 10 + 2
                    UIColor(white: 0, alpha: CGFloat(rng.next()) * 0.18).setFill()
                    c.fillEllipse(in: CGRect(x: CGFloat(rng.next()) * size, y: CGFloat(rng.next()) * size, width: r, height: r))
                }
                c.setLineWidth(0.6)
                for _ in 0..<70 {
                    let x = CGFloat(rng.next()) * size, y = CGFloat(rng.next()) * size
                    let a = CGFloat(rng.next()) * .pi, l = CGFloat(rng.next()) * 9 + 3
                    c.setStrokeColor(UIColor(white: 0, alpha: 0.5).cgColor)
                    c.move(to: CGPoint(x: x, y: y))
                    c.addLine(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l))
                    c.strokePath()
                }
            case .halftone:
                UIColor.black.setFill()
                c.fillEllipse(in: CGRect(x: 2, y: 2, width: 3.2, height: 3.2))
                c.fillEllipse(in: CGRect(x: 8, y: 8, width: 3.2, height: 3.2))
            case .scanlines:
                UIColor.black.setFill()
                c.fill(CGRect(x: 0, y: 0, width: size, height: 1.4))
            }
        }
    }
}

/// Deterministic noise so the texture looks the same on every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

// MARK: - Cover shape & frame

extension AppTheme.ArtShape {
    /// The clip for album art with the theme's base radius.
    func shape(radius r: CGFloat) -> AnyShape {
        switch self {
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        case .sharp: AnyShape(Rectangle())
        case .circle: AnyShape(Circle())
        case .arch: AnyShape(ArchShape())
        }
    }
}

/// A doorway: round on top, square at the bottom.
struct ArchShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: rect.width / 2, bottomLeadingRadius: rect.width * 0.04,
                               bottomTrailingRadius: rect.width * 0.04, topTrailingRadius: rect.width / 2, style: .continuous)
            .path(in: rect)
    }
}

/// Border drawn inside the art's shape, sized relative to the art so it reads the same in a list and the player.
struct ArtFrameOverlay: View {
    let frame: AppTheme.ArtFrame
    let shape: AnyShape
    let accent: Color
    let ink: Color?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // AnyShape can't inset, so stroke twice as wide and clip: the inner half stays inside the cover.
            ZStack {
                shape.stroke(Color.white, lineWidth: max(4, w * 0.11))
                    .opacity(frame == .print ? 1 : 0)
                shape.stroke(ink ?? Color.primary, lineWidth: max(3, w * 0.036))
                    .opacity(frame == .outline ? 1 : 0)
                shape.stroke(accent, lineWidth: max(3, w * 0.04))
                    .opacity(frame == .glow ? 1 : 0)
            }
            .clipShape(shape)
            .shadow(color: frame == .glow ? accent : .clear, radius: w * 0.05)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Surprise me

extension AppTheme {
    /// A random but coherent theme: a curated palette plus random type, surface, cover and player choices.
    static func surprise() -> AppTheme {
        struct Palette { let bg: [String]; let ink: String?; let accent: String; let scheme: Int; let background: Background }
        let palettes: [Palette] = [
            .init(bg: ["#F4EFE6"], ink: "#1B1A17", accent: "#E8412C", scheme: 1, background: .solid),
            .init(bg: ["#FFE45C"], ink: "#111111", accent: "#111111", scheme: 1, background: .solid),
            .init(bg: ["#0A0A0F"], ink: "#E9E7FF", accent: "#FF2BD6", scheme: 2, background: .solid),
            .init(bg: ["#E8ECF2", "#C9D3E3", "#F4E4F1"], ink: "#22252B", accent: "#6A5CFF", scheme: 1, background: .mesh),
            .init(bg: ["#102A1E", "#0B1A13"], ink: "#E8F5E9", accent: "#7CF29A", scheme: 2, background: .gradient),
            .init(bg: ["#F7F3EE"], ink: "#0078BF", accent: "#FF48B0", scheme: 1, background: .solid),
            .init(bg: ["#1A1410", "#3B2414"], ink: "#F3E3C7", accent: "#FF8A3D", scheme: 2, background: .gradient),
            .init(bg: ["#DADDE1", "#B9BEC6"], ink: "#202226", accent: "#FF5A1F", scheme: 1, background: .gradient),
            .init(bg: ["#FFFFFF"], ink: nil, accent: "#FF3B5C", scheme: 1, background: .system),
        ]
        let words1 = ["Velvet", "Static", "Paper", "Neon", "Quiet", "Golden", "Late", "Chrome", "Basement", "Sunday", "Midnight", "Analog"]
        let words2 = ["Radio", "Room", "Tape", "Signal", "Club", "Press", "Hour", "Wave", "Sleeve", "Session", "Groove", "Hiss"]
        let p = palettes.randomElement()!
        var t = AppTheme(name: "\(words1.randomElement()!) \(words2.randomElement()!)")
        t.summary = "Made by Surprise Me."
        t.accent = p.accent; t.scheme = p.scheme; t.background = p.background; t.backgroundColors = p.bg; t.ink = p.ink
        t.font = FontStyle.allCases.randomElement()!
        t.typeWidth = TypeWidth.allCases.randomElement()!
        t.allCaps = Double.random(in: 0...1) < 0.25
        t.texture = Texture.allCases.randomElement()!
        t.artShape = ArtShape.allCases.randomElement()!
        t.artFrame = ArtFrame.allCases.randomElement()!
        t.cornerScale = [0, 0.4, 1, 1.5].randomElement()!
        t.playerLayout = PlayerLayout.allCases.randomElement()!
        t.nowPlaying = p.background == .system ? .artworkTint : [.themeColors, .artworkTint, .blurredArtwork].randomElement()!
        t.miniPlayer = MiniPlayer.allCases.randomElement()!
        t.icons = Bool.random() ? .outline : .standard
        t.motion = [.standard, .snappy, .relaxed].randomElement()!
        t.glass = Double.random(in: 0...0.5)
        t.lyricsCentered = Bool.random()
        t.lyricsGlow = p.scheme == 2 && Bool.random()
        t.lyricsSize = Double(Int.random(in: 24...36))
        return t
    }
}
