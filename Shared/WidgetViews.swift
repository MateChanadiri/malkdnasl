import AppIntents
import SwiftUI
import WidgetKit

// Shared between the app (Customize ▸ Widgets preview) and the widget extension, so the preview is the real widget.

/// How the Now Playing widgets look. Set in Customize ▸ Widgets, stored in the App Group.
nonisolated struct WidgetStyle: Codable, Hashable, Sendable {
    enum Background: String, Codable, CaseIterable, Identifiable, Sendable {
        case blurredArt, cover, accent, black
        var id: String { rawValue }
        var title: String { ["blurredArt": "Blurred Cover", "cover": "Full Cover", "accent": "Color", "black": "Black"][rawValue] ?? rawValue }
        var icon: String { ["blurredArt": "drop.fill", "cover": "photo.fill", "accent": "paintpalette.fill", "black": "moon.fill"][rawValue] ?? "circle" }
    }
    enum ArtShape: String, Codable, CaseIterable, Identifiable, Sendable {
        case rounded, square, circle
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var icon: String { ["rounded": "app", "square": "square", "circle": "circle"][rawValue] ?? "app" }
    }
    enum Font: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, rounded, serif, mono
        var id: String { rawValue }
        var title: String { ["standard": "Default", "rounded": "Rounded", "serif": "Serif", "mono": "Mono"][rawValue] ?? rawValue }
        var design: SwiftUI.Font.Design { ["rounded": .rounded, "serif": .serif, "mono": .monospaced][rawValue] ?? .default }
    }

    var background: Background = .blurredArt
    /// nil follows the app theme's accent.
    var customAccent: String?
    var artShape: ArtShape = .rounded
    var font: Font = .standard
    var showArtwork = true
    var showControls = true
    var showProgress = true
    var showUpNext = true
    var showStatus = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = WidgetStyle()
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        s.background = v(.background, s.background); s.customAccent = v(.customAccent, s.customAccent)
        s.artShape = v(.artShape, s.artShape); s.font = v(.font, s.font)
        s.showArtwork = v(.showArtwork, s.showArtwork); s.showControls = v(.showControls, s.showControls)
        s.showProgress = v(.showProgress, s.showProgress); s.showUpNext = v(.showUpNext, s.showUpNext)
        s.showStatus = v(.showStatus, s.showStatus)
        self = s
    }

    static let key = "widgetStyle"
    static func load() -> WidgetStyle {
        AppGroup.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetStyle.self, from: $0) } ?? WidgetStyle()
    }
    func save() { if let d = try? JSONEncoder().encode(self) { AppGroup.defaults.set(d, forKey: Self.key) } }

    func accent(_ s: SharedNowPlaying) -> Color { Color(hex6: customAccent ?? s.accentHex) }
}

extension SharedNowPlaying {
    /// "Resume Music" once nothing is playing any more, "Now Playing" while it is.
    var status: String { isPlaying ? "Now Playing" : "Resume Music" }

    /// After the song would have ended with no word from the app (it was closed or killed), it isn't playing any more.
    func settled(at date: Date = .now) -> SharedNowPlaying {
        guard isPlaying, duration > 0, updatedAt.addingTimeInterval(duration - position + 20) < date else { return self }
        var s = self
        s.isPlaying = false
        s.position = duration
        return s
    }

    /// Where playback is right now, assuming it kept going since the app last wrote this.
    var liveRange: ClosedRange<Date>? {
        guard isPlaying, duration > 0 else { return nil }
        let start = updatedAt.addingTimeInterval(-position)
        return start...start.addingTimeInterval(duration)
    }
}

struct WidgetBackground: View {
    let state: SharedNowPlaying
    var style = WidgetStyle()

    var body: some View {
        ZStack {
            Color.black
            switch style.background {
            case .blurredArt:
                if let image = state.artImage {
                    Image(uiImage: image).resizable().scaledToFill().blur(radius: 30).opacity(0.75)
                } else { gradient }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            case .cover:
                if let image = state.artImage { Image(uiImage: image).resizable().scaledToFill() } else { gradient }
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            case .accent:
                gradient
            case .black:
                EmptyView()
            }
        }
    }

    private var gradient: some View {
        LinearGradient(colors: [style.accent(state), style.accent(state).opacity(0.35), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension SharedNowPlaying {
    var artImage: UIImage? { artURL.flatMap { UIImage(contentsOfFile: $0.path) } }
}

struct ArtImage: View {
    let state: SharedNowPlaying
    var style = WidgetStyle()
    var radius: CGFloat = 10

    var body: some View {
        let shape: AnyShape = switch style.artShape {
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .square: AnyShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        case .circle: AnyShape(Circle())
        }
        Group {
            if let image = state.artImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [style.accent(state), style.accent(state).opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.title2.bold()).foregroundStyle(.white)
                }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(shape)
    }
}

/// The Now Playing widget for every size. `family` is passed in so the app can draw it too.
struct NowPlayingWidgetContent: View {
    let state: SharedNowPlaying
    var style = WidgetStyle()
    let family: WidgetFamily
    private var s: SharedNowPlaying { state }
    private var title: String { s.hasTrack ? s.title : "Play Something" }
    private var subtitle: String { s.hasTrack ? s.artist : "Open \(Brand.name)" }
    /// The full cover is the background, so the small artwork would just repeat it.
    private var showsArt: Bool { style.showArtwork && style.background != .cover }

    var body: some View {
        content
            .fontDesign(style.font.design)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Label(s.hasTrack ? "\(s.isPlaying ? "" : "Resume · ")\(s.title) · \(s.artist)" : "\(Brand.name)", systemImage: s.isPlaying ? "waveform" : "play.fill")
        case .accessoryCircular:
            Button(intent: TogglePlaybackIntent()) {
                ZStack {
                    AccessoryWidgetBackground()
                    if let r = s.liveRange, style.showProgress {
                        ProgressView(timerInterval: r, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                            .progressViewStyle(.circular)
                    }
                    Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
            }
            .buttonStyle(.plain)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    if style.showStatus && s.hasTrack && !s.isPlaying {
                        Text("Resume Music").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(intent: TogglePlaybackIntent()) { Image(systemName: s.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(.plain)
            }
        case .systemMedium:
            HStack(spacing: 14) {
                if showsArt { ArtImage(state: s, style: style, radius: 14).frame(width: 110, height: 110) }
                VStack(alignment: .leading, spacing: 4) {
                    if style.showStatus { statusLabel }
                    Text(title).font(.headline).lineLimit(2)
                    Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if style.showUpNext, s.isPlaying, let next = s.upNext {
                        Text("Next: \(next)").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if style.showProgress { progress }
                    if style.showControls { controls } else { playButton(size: 36) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white)
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    if showsArt { ArtImage(state: s, style: style).frame(width: 56, height: 56) }
                    Spacer()
                    playButton(size: 40)
                }
                Spacer(minLength: 0)
                if style.showStatus { statusLabel }
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                if style.showProgress { progress.padding(.top, 2) }
            }
            .foregroundStyle(.white)
        }
    }

    private var statusLabel: some View {
        Text(s.hasTrack ? s.status : "\(Brand.name)")
            .font(.system(size: 10, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(s.isPlaying ? .white.opacity(0.6) : style.accent(s))
            .lineLimit(1)
    }

    /// Runs by itself while playing (no widget reloads needed); stands still when paused.
    @ViewBuilder private var progress: some View {
        if let r = s.liveRange {
            ProgressView(timerInterval: r, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(.white)
        } else if s.hasTrack, s.duration > 0 {
            ProgressView(value: min(s.position, s.duration), total: s.duration).tint(.white)
        }
    }

    private func playButton(size: CGFloat) -> some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: s.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.45, weight: .bold))
                .frame(width: size, height: size)
                .background(.white.opacity(0.2), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
            Button(intent: TogglePlaybackIntent()) { Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
            Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .font(.body.bold())
    }
}

extension Color {
    nonisolated init(hex6: String) {
        var v: UInt64 = 0
        Scanner(string: hex6.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}
