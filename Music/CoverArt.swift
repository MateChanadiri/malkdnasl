import SwiftUI

// MARK: - Spec

nonisolated enum CoverStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case mesh, orbs, rings, waves, sunburst, stripes, halftone, aurora
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mesh: "Mesh"
        case .orbs: "Orbs"
        case .rings: "Rings"
        case .waves: "Waves"
        case .sunburst: "Sunburst"
        case .stripes: "Stripes"
        case .halftone: "Halftone"
        case .aurora: "Aurora"
        }
    }
}

/// Everything needed to draw a cover deterministically.
nonisolated struct CoverSpec: Codable, Hashable, Sendable {
    var style: CoverStyle
    var colors: [String]      // 3-4 hex colours; [0]/[1] form the base gradient
    var symbol: String?
    var seed: UInt64
    var grain = true
}

nonisolated struct SeededRNG {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

extension Color {
    nonisolated init(hex: String) {
        let v = Self.hexValue(hex)
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    /// Reads "#RRGGBB" like `Scanner.scanHexInt64` would (after dropping "#"), without a Scanner per colour:
    /// theme accents are turned into colours many times per frame.
    private nonisolated static func hexValue(_ hex: String) -> UInt64 {
        var bytes = hex.utf8.filter { $0 != UInt8(ascii: "#") }[...]
        while let b = bytes.first, b == 0x20 || (0x09...0x0D).contains(b) { bytes = bytes.dropFirst() }
        if bytes.count > 2, bytes.first == UInt8(ascii: "0"), let x = bytes.dropFirst().first, x == UInt8(ascii: "x") || x == UInt8(ascii: "X") {
            bytes = bytes.dropFirst(2)
        }
        var v: UInt64 = 0
        for b in bytes {
            let d: UInt64
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt64(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt64(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt64(b - UInt8(ascii: "A") + 10)
            default: return v
            }
            if v > (UInt64.max - d) / 16 { return .max }
            v = v * 16 + d
        }
        return v
    }
    /// "#RRGGBB" of this colour in sRGB.
    nonisolated var hexString: String {
        let c = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Vibe

/// Turns the words in a title/album/artist into a colour world and a visual style.
nonisolated enum VibeEngine {
    private struct Vibe {
        let keywords: [String]
        let hue: Double, spread: Double, sat: Double, bri: Double
        let styles: [CoverStyle]
    }

    private static let vibes: [Vibe] = [
        Vibe(keywords: ["night", "midnight", "dark", "moon", "shadow", "black", "star", "nacht", "mond", "dunkel", "sterne", "dusk"],
             hue: 0.68, spread: 0.13, sat: 0.75, bri: 0.55, styles: [.aurora, .orbs, .rings]),
        Vibe(keywords: ["sun", "gold", "summer", "fire", "hot", "warm", "light", "morning", "sonne", "sommer", "feuer", "licht", "horizon", "dawn"],
             hue: 0.07, spread: 0.09, sat: 0.8, bri: 0.97, styles: [.sunburst, .mesh, .waves]),
        Vibe(keywords: ["rain", "ocean", "sea", "blue", "river", "water", "ice", "harbor", "harbour", "ferry", "regen", "meer", "blau", "wave", "tide"],
             hue: 0.53, spread: 0.1, sat: 0.7, bri: 0.85, styles: [.waves, .aurora, .orbs]),
        Vibe(keywords: ["love", "heart", "kiss", "baby", "rose", "liebe", "herz", "romance", "sweet"],
             hue: 0.97, spread: 0.06, sat: 0.65, bri: 0.95, styles: [.orbs, .mesh]),
        Vibe(keywords: ["neon", "city", "chrome", "electric", "digital", "cyber", "static", "signal", "train", "machine", "glass", "night club", "club", "synth"],
             hue: 0.86, spread: -0.32, sat: 0.8, bri: 0.92, styles: [.halftone, .stripes, .rings]),
        Vibe(keywords: ["forest", "green", "tree", "field", "wild", "garden", "leaf", "wald", "gras", "nature", "kite", "meadow"],
             hue: 0.36, spread: 0.1, sat: 0.65, bri: 0.8, styles: [.mesh, .waves, .aurora]),
        Vibe(keywords: ["soft", "quiet", "slow", "echo", "dream", "sleep", "paper", "small", "sunday", "still", "leise", "traum", "calm"],
             hue: 0.6, spread: 0.2, sat: 0.35, bri: 0.96, styles: [.orbs, .mesh, .waves]),
        Vibe(keywords: ["thunder", "rock", "loud", "storm", "riot", "run", "fast", "backyard", "punk", "metal", "crash", "sturm", "laut"],
             hue: 0.01, spread: 0.12, sat: 0.9, bri: 0.85, styles: [.stripes, .sunburst, .halftone])
    ]

    static func spec(for text: String) -> CoverSpec {
        let lower = text.lowercased()
        let hash = stableHash(lower)
        var best: (score: Int, vibe: Vibe)?
        for v in vibes {
            let score = v.keywords.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            if score > 0, score > (best?.score ?? 0) { best = (score, v) }
        }
        var rng = SeededRNG(hash)
        let vibe: Vibe
        if let best {
            vibe = best.vibe
        } else {
            // No keyword: a hash-derived but still harmonious palette.
            vibe = Vibe(keywords: [], hue: Double(hash % 360) / 360, spread: 0.08 + Double(hash >> 8 % 20) / 100,
                        sat: 0.55 + Double(hash >> 16 % 30) / 100, bri: 0.8, styles: CoverStyle.allCases)
        }
        let h = (vibe.hue + rng.range(-0.03, 0.03)).truncatingRemainder(dividingBy: 1)
        func hex(_ hh: Double, _ s: Double, _ b: Double) -> String {
            let hue = hh.truncatingRemainder(dividingBy: 1)
            return Color(hue: hue < 0 ? hue + 1 : hue, saturation: min(1, max(0, s)), brightness: min(1, max(0, b))).hexString
        }
        let colors = [
            hex(h, vibe.sat, vibe.bri * 0.55),
            hex(h + vibe.spread * 0.6, vibe.sat, vibe.bri * 0.95),
            hex(h + vibe.spread, vibe.sat * 0.8, min(1, vibe.bri * 1.05)),
            hex(h + 0.5, vibe.sat * 0.7, vibe.bri * 0.7)
        ]
        let style = vibe.styles[Int(hash % UInt64(vibe.styles.count))]
        return CoverSpec(style: style, colors: colors, symbol: nil, seed: hash)
    }
}

// MARK: - Painter

nonisolated enum CoverPainter {
    static func paint(_ ctx: inout GraphicsContext, _ size: CGSize, _ spec: CoverSpec) {
        var rng = SeededRNG(spec.seed)
        let cols = spec.colors.count >= 3 ? spec.colors.map { Color(hex: $0) } : [Color.indigo, .purple, .pink]
        let w = size.width, h = size.height
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [cols[0], cols[1]]),
                                                   startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
        switch spec.style {
        case .orbs, .mesh:
            let count = spec.style == .mesh ? 7 : 5
            for i in 0..<count {
                let c = CGPoint(x: w * rng.range(-0.05, 1.05), y: h * rng.range(-0.05, 1.05))
                let r = w * (spec.style == .mesh ? rng.range(0.5, 0.9) : rng.range(0.22, 0.5))
                let color = cols[i % cols.count]
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.95), color.opacity(0)]),
                                               center: c, startRadius: 0, endRadius: r))
            }
        case .rings:
            let c = CGPoint(x: w * rng.range(0.25, 0.75), y: h * rng.range(0.25, 0.75))
            let step = w * rng.range(0.09, 0.13)
            for i in (0..<12).reversed() {
                let r = step * CGFloat(i + 1)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color(cols[(i + 1) % cols.count].opacity(i % 2 == 0 ? 0.9 : 0.55)))
            }
        case .waves:
            let phase = rng.range(0, 6.28)
            for i in 0..<5 {
                var p = Path()
                let base = h * (0.28 + 0.14 * CGFloat(i))
                let amp = h * rng.range(0.05, 0.11)
                let freq = rng.range(1.4, 3.2)
                p.move(to: CGPoint(x: 0, y: h))
                var x: CGFloat = 0
                while x <= w + 4 {
                    p.addLine(to: CGPoint(x: x, y: base + sin(Double(x / w) * freq * 6.28 + phase + Double(i)) * amp))
                    x += 4
                }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
                ctx.fill(p, with: .color(cols[(i + 1) % cols.count].opacity(0.5 + 0.1 * Double(i))))
            }
        case .sunburst:
            let c = CGPoint(x: w * rng.range(0.3, 0.7), y: h * rng.range(0.45, 0.8))
            let rays = Int(rng.range(12, 22))
            let offset = rng.range(0, 6.28)
            for i in 0..<rays where i % 2 == 0 {
                let a0 = offset + Double(i) / Double(rays) * 6.28, a1 = offset + Double(i + 1) / Double(rays) * 6.28
                var p = Path()
                p.move(to: c)
                p.addLine(to: CGPoint(x: c.x + cos(a0) * w * 2, y: c.y + sin(a0) * w * 2))
                p.addLine(to: CGPoint(x: c.x + cos(a1) * w * 2, y: c.y + sin(a1) * w * 2))
                p.closeSubpath()
                ctx.fill(p, with: .color(cols[2].opacity(0.32)))
            }
            let r = w * 0.17
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [cols[2], cols[1]]), center: c, startRadius: 0, endRadius: r))
        case .stripes:
            var layer = ctx
            layer.translateBy(x: w / 2, y: h / 2)
            layer.rotate(by: .degrees(rng.range(-42, -12)))
            let ww = CGFloat(w), hh = CGFloat(h)
            let sw: CGFloat = ww * CGFloat(rng.range(0.14, 0.22))
            for i in -9..<9 {
                let rect = CGRect(x: CGFloat(i) * sw, y: -hh * 1.5, width: sw, height: hh * 3)
                let alpha: Double = i % 2 == 0 ? 0.85 : 0.35
                layer.fill(Path(rect), with: .color(cols[(i + 20) % cols.count].opacity(alpha)))
            }
        case .halftone:
            let n = 10
            let cell = w / CGFloat(n)
            let focus = CGPoint(x: w * rng.range(0.2, 0.8), y: h * rng.range(0.2, 0.8))
            for r in 0..<n {
                for c in 0..<n {
                    let p = CGPoint(x: (CGFloat(c) + 0.5) * cell, y: (CGFloat(r) + 0.5) * cell)
                    let d = hypot(p.x - focus.x, p.y - focus.y) / w
                    let rad = cell * 0.5 * max(0.12, 1 - d * 1.4)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)),
                             with: .color(cols[2].opacity(0.9)))
                }
            }
        case .aurora:
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: w * 0.07))
                for i in 0..<4 {
                    var p = Path()
                    let x0 = w * rng.range(0.05, 0.95)
                    p.move(to: CGPoint(x: x0, y: -h * 0.1))
                    p.addCurve(to: CGPoint(x: w * rng.range(0, 1), y: h * 1.1),
                               control1: CGPoint(x: w * rng.range(-0.2, 1.2), y: h * 0.35),
                               control2: CGPoint(x: w * rng.range(-0.2, 1.2), y: h * 0.7))
                    layer.stroke(p, with: .color(cols[(i + 1) % cols.count].opacity(0.75)), lineWidth: w * rng.range(0.14, 0.26))
                }
            }
        }
        // Soft vignette + fine grain so flat gradients feel like printed cover art.
        ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.22)]),
                                                   center: CGPoint(x: w / 2, y: h / 2), startRadius: w * 0.35, endRadius: w * 0.85))
        if spec.grain {
            var g = SeededRNG(spec.seed ^ 0xA5A5)
            for _ in 0..<260 {
                let p = CGPoint(x: g.range(0, w), y: g.range(0, h))
                ctx.fill(Path(CGRect(x: p.x, y: p.y, width: max(1, w / 240), height: max(1, w / 240))),
                         with: .color((g.unit() > 0.5 ? Color.white : Color.black).opacity(0.07)))
            }
        }
    }
}

// MARK: - View, cache, render

struct GeneratedCover: View {
    let spec: CoverSpec

    var body: some View {
        Canvas { ctx, size in
            var c = ctx
            CoverPainter.paint(&c, size, spec)
        }
        .overlay {
            if let symbol = spec.symbol {
                GeometryReader { geo in
                    Image(systemName: symbol)
                        .font(.system(size: geo.size.width * 0.34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: geo.size.width * 0.03, y: geo.size.width * 0.015)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .drawingGroup(opaque: true)
    }
}

enum CoverKit {
    private static var autoCache: [String: CoverSpec] = [:]

    /// The generated cover for a piece of text, cached.
    static func auto(_ text: String) -> CoverSpec {
        if let hit = autoCache[text] { return hit }
        let spec = VibeEngine.spec(for: text)
        autoCache[text] = spec
        return spec
    }

    @MainActor
    static func image(_ spec: CoverSpec, side: CGFloat = 900) -> UIImage? {
        let renderer = ImageRenderer(content: GeneratedCover(spec: spec).frame(width: side, height: side))
        renderer.scale = 1
        return renderer.uiImage
    }

    static let palettes: [(name: String, colors: [String])] = [
        ("Night", ["#12103A", "#3B2F9E", "#7B6CF6", "#1D3A6B"]),
        ("Sunset", ["#5B1A3A", "#F0503C", "#FFB347", "#2B1B5A"]),
        ("Ocean", ["#062A44", "#0E7C9B", "#5EE1D0", "#123F73"]),
        ("Neon", ["#1A0B3B", "#E63DAF", "#3DE0F5", "#5B2BD9"]),
        ("Forest", ["#0B2A1C", "#2E8B57", "#B7E36B", "#153F3A"]),
        ("Rose", ["#3D0F22", "#D6336C", "#FFB3C7", "#6A1B4D"]),
        ("Mono", ["#0E0E10", "#3A3A40", "#C9C9D0", "#1C1C20"]),
        ("Gold", ["#2B1A05", "#B9770E", "#FFD976", "#5C3A0C"])
    ]
}

/// Remembers the spec of designed covers so they can be edited again later.
@Observable
final class CoverStore {
    static let shared = CoverStore()
    private(set) var specs: [String: CoverSpec] = [:]
    private static var url: URL { Paths.support.appendingPathComponent("covers.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let s = try? JSONDecoder().decode([String: CoverSpec].self, from: data) { specs = s }
    }

    func key(for track: Track) -> String { "t:\(track.id.uuidString)" }
    func albumKey(_ track: Track) -> String { "a:\(track.artist)|\(track.album)" }
    func spec(for track: Track) -> CoverSpec? { specs[key(for: track)] ?? specs[albumKey(track)] }

    func set(_ spec: CoverSpec?, keys: [String]) {
        for k in keys { specs[k] = spec }
        if let data = try? JSONEncoder().encode(specs) { try? data.write(to: Self.url, options: .atomic) }
    }
}
