import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Cache

enum ArtworkCache {
    private static let images = NSCache<NSString, UIImage>()
    private static var tints: [UUID: (Color, Int)] = [:]

    /// `maxPixel` > 0 returns a small, already decoded copy — much cheaper to draw in lists than the full cover.
    static func image(for track: Track, maxPixel: Int = 0) -> UIImage? {
        guard track.hasArtwork else { return nil }
        let key = "\(track.id.uuidString)-\(track.artVersion ?? 0)-\(maxPixel)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let url = Paths.artworkURL(for: track.id)
        let image = maxPixel > 0 ? thumbnail(url, maxPixel: maxPixel) : UIImage(contentsOfFile: url.path)
        guard let image else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    private static func thumbnail(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(contentsOfFile: url.path) }
        return UIImage(cgImage: cg)
    }

    static func evict(_ id: UUID) {
        tints[id] = nil
    }

    /// Dark, saturated colour used for the player background.
    static func tint(for track: Track?) -> Color {
        guard let track else { return Color(white: 0.25) }
        if let cached = tints[track.id], cached.1 == (track.artVersion ?? 0) { return cached.0 }
        let color: Color
        if let image = image(for: track), let avg = averageColor(image) {
            color = avg
        } else {
            color = Color(hex: CoverKit.auto(track.album + track.artist).colors[0])
        }
        tints[track.id] = (color, track.artVersion ?? 0)
        return color
    }

    private static func averageColor(_ image: UIImage) -> Color? {
        guard let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(1, s * 1.1 + 0.1), brightness: min(0.6, max(0.3, b * 0.7)))
    }
}

nonisolated func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
    return h
}

func placeholderColors(seed: String) -> (Color, Color) {
    let h = Double(stableHash(seed) % 360) / 360
    let h2 = (h + 0.1).truncatingRemainder(dividingBy: 1)
    return (Color(hue: h, saturation: 0.6, brightness: 0.9), Color(hue: h2, saturation: 0.8, brightness: 0.45))
}

// MARK: - View

struct ArtworkView: View {
    enum Style { case rounded(CGFloat), circle }

    var tracks: [Track]
    var seed: String
    var style: Style = .rounded(10)
    var mosaic = false
    var symbol: String? = nil
    /// Plays the song's motion cover over the still one (only the player asks for this).
    var animated = false
    /// Decode the cover at this size (pixels) instead of full size — for small list artwork.
    var maxPixel = 0

    var body: some View {
        let t = ThemeStore.shared.current
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
            .clipShape(shape)
            .overlay { ArtFrameOverlay(frame: t.artFrame, shape: shape, accent: t.accentColor, ink: t.inkColor) }
    }

    /// Covers follow the theme's shape; artist portraits stay round.
    private var shape: AnyShape {
        switch style {
        case .rounded(let r):
            let t = ThemeStore.shared.current
            return t.artShape.shape(radius: r * t.cornerScale)
        case .circle: return AnyShape(Circle())
        }
    }

    @ViewBuilder private var content: some View {
        if mosaic, tracks.count > 1 {
            let cells = (0..<4).map { tracks[$0 % tracks.count] }
            VStack(spacing: 0) {
                HStack(spacing: 0) { cell(cells[0]); cell(cells[1]) }
                HStack(spacing: 0) { cell(cells[2]); cell(cells[3]) }
            }
        } else if let (first, image) = firstCachedArtwork {
            Image(uiImage: image).resizable().scaledToFill()
                .overlay {
                    if animated, let link = first.motionArtworkURL, let url = URL(string: link) { MotionCover(url: url) }
                }
        } else {
            placeholder(seed: seed, symbol: symbol)
        }
    }

    /// A missing file for the first song must not hide a usable cover from another song on the album.
    private var firstCachedArtwork: (Track, UIImage)? {
        for track in tracks {
            if let image = ArtworkCache.image(for: track, maxPixel: animated ? 0 : maxPixel) { return (track, image) }
        }
        return nil
    }

    private func cell(_ track: Track) -> some View {
        Color.clear.overlay {
            // Each mosaic cell is a quarter of the cover.
            if let image = ArtworkCache.image(for: track, maxPixel: 320) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder(seed: track.album + track.artist, symbol: nil)
            }
        }
        .clipped()
    }

    private func placeholder(seed: String, symbol: String?) -> some View {
        var spec = CoverKit.auto(seed)
        spec.symbol = symbol
        return GeneratedCover(spec: spec)
    }
}

extension ArtworkView {
    init(entry: LibraryEntry, radius: CGFloat = 10) {
        self.init(tracks: entry.tracks, seed: entry.key,
                  style: entry.isCircle ? .circle : .rounded(radius),
                  mosaic: entry.kind == .playlist,
                  symbol: entry.kind == .artist ? "music.mic" : entry.kind == .playlist ? "music.note.list" : nil)
    }

    init(track: Track, radius: CGFloat = 8) {
        self.init(tracks: [track], seed: track.album + track.artist, style: .rounded(radius))
    }

    /// Small artwork (rows): decode at `pixels` instead of the full cover.
    func thumbnail(_ pixels: Int = 180) -> ArtworkView {
        var copy = self
        copy.maxPixel = pixels
        return copy
    }

    func animatedCover(_ on: Bool = true) -> ArtworkView {
        var copy = self
        copy.animated = on
        return copy
    }
}

// MARK: - Thumbnail writing (used by importer)

nonisolated enum ArtworkWriter {
    static func writeJPEG(from data: Data, for id: UUID, maxPixel: Int = 900) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(Paths.artworkURL(for: id) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
