import SwiftUI
import Observation
import UniformTypeIdentifiers
import CoreText

// MARK: - Model

extension UTType {
    nonisolated static let themeFile = UTType(exportedAs: "com.local.music.theme", conformingTo: .json)
}

nonisolated struct AppTheme: Codable, Identifiable, Hashable, Sendable {
    enum Background: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, solid, gradient, mesh
        var id: String { rawValue }
        var title: String { ["system": "System", "solid": "Solid Color", "gradient": "Gradient", "mesh": "Mesh"][rawValue] ?? rawValue }
    }
    enum FontStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, rounded, serif, mono
        var id: String { rawValue }
        var title: String { ["standard": "Default", "rounded": "Rounded", "serif": "Serif", "mono": "Monospaced"][rawValue] ?? rawValue }
        var design: Font.Design {
            switch self {
            case .standard: .default
            case .rounded: .rounded
            case .serif: .serif
            case .mono: .monospaced
            }
        }
    }
    enum IconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, filled, outline
        var id: String { rawValue }
        var title: String { ["standard": "Default", "filled": "Filled", "outline": "Outline"][rawValue] ?? rawValue }
    }
    enum Motion: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, snappy, relaxed, off
        var id: String { rawValue }
        var title: String { ["standard": "Standard", "snappy": "Snappy", "relaxed": "Relaxed", "off": "Off"][rawValue] ?? rawValue }
    }
    enum PlayerLayout: String, Codable, CaseIterable, Identifiable, Sendable {
        case classic, large, vinyl, minimal
        /// No vinyl option is offered any more (saved themes that have it still load).
        static var allCases: [PlayerLayout] { [.classic, .large, .vinyl, .minimal] }
        var id: String { rawValue }
        var title: String { ["classic": "Classic", "large": "Large Artwork", "vinyl": "Vinyl", "minimal": "Minimal"][rawValue] ?? rawValue }
    }
    enum QueueLayout: String, Codable, CaseIterable, Identifiable, Sendable {
        case comfortable, compact
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    enum MiniPlayer: String, Codable, CaseIterable, Identifiable, Sendable {
        case capsule, compact, bar
        var id: String { rawValue }
        var title: String { ["capsule": "Capsule", "compact": "Compact", "bar": "Progress Bar"][rawValue] ?? rawValue }
    }
    /// Letter width for all system text: the fastest way to make Music feel like another app.
    enum TypeWidth: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, condensed, compressed, expanded
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var width: Font.Width? {
            switch self {
            case .standard: nil
            case .condensed: .condensed
            case .compressed: .compressed
            case .expanded: .expanded
            }
        }
    }
    /// A print surface laid over every screen.
    enum Texture: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, grain, paper, halftone, scanlines
        var id: String { rawValue }
        var title: String { ["none": "None", "grain": "Film Grain", "paper": "Paper", "halftone": "Halftone", "scanlines": "Scanlines"][rawValue] ?? rawValue }
    }
    enum ArtShape: String, Codable, CaseIterable, Identifiable, Sendable {
        case rounded, sharp, circle, arch
        var id: String { rawValue }
        var title: String { ["rounded": "Rounded", "sharp": "Square", "circle": "Record", "arch": "Arch"][rawValue] ?? rawValue }
    }
    enum ArtFrame: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, print, outline, glow
        var id: String { rawValue }
        var title: String { ["none": "None", "print": "White Border", "outline": "Ink Outline", "glow": "Glow"][rawValue] ?? rawValue }
    }
    enum NowPlayingBackground: String, Codable, CaseIterable, Identifiable, Sendable {
        case artworkTint, blurredArtwork, themeColors, black
        var id: String { rawValue }
        var title: String { ["artworkTint": "Artwork Color", "blurredArtwork": "Blurred Artwork", "themeColors": "Theme Colors", "black": "Black"][rawValue] ?? rawValue }
    }

    var id: String
    var name: String
    var author = "You"
    var inspiredBy: String?
    var summary: String?
    var accent = "#FF3B5C"
    /// 0 follows the app setting, 1 light, 2 dark.
    var scheme = 0
    var background: Background = .system
    var backgroundColors: [String] = ["#101014", "#26262E"]
    var blur = 0.5
    var transparency = 0.0
    var glass = 0.0
    var cornerScale = 1.0
    var font: FontStyle = .standard
    var icons: IconStyle = .standard
    var motion: Motion = .standard
    var playerLayout: PlayerLayout = .classic
    /// What the player screen shows and where (rows, buttons, menu).
    var player = PlayerConfig()
    var artworkScale = 1.0
    var queueLayout: QueueLayout = .comfortable
    var lyricsSize = 30.0
    var lyricsCentered = false
    var lyricsGlow = false
    var miniPlayer: MiniPlayer = .capsule
    var nowPlaying: NowPlayingBackground = .artworkTint
    var typeWidth: TypeWidth = .standard
    var allCaps = false
    /// Text color for the whole app; nil keeps the system's black/white.
    var ink: String?
    var texture: Texture = .none
    var artShape: ArtShape = .rounded
    var artFrame: ArtFrame = .none
    /// Tab bar this theme brings along (nil keeps the user's own). Applied when the theme is applied.
    var tabs: [TabItemConfig]?
    /// PostScript name of an imported font; nil uses the font style above.
    var customFont: String?
    var searchTab: Bool?
    var builtIn = false

    init(id: String = UUID().uuidString, name: String) { self.id = id; self.name = name }

    // Lenient decoding: themes shared by others may come from older/newer versions.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var t = AppTheme(id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
                         name: (try? c.decode(String.self, forKey: .name)) ?? "Imported Theme")
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        t.author = v(.author, t.author); t.inspiredBy = v(.inspiredBy, t.inspiredBy); t.summary = v(.summary, t.summary)
        t.accent = v(.accent, t.accent); t.scheme = v(.scheme, t.scheme); t.background = v(.background, t.background)
        t.backgroundColors = v(.backgroundColors, t.backgroundColors); t.blur = v(.blur, t.blur)
        t.transparency = v(.transparency, t.transparency); t.glass = v(.glass, t.glass); t.cornerScale = v(.cornerScale, t.cornerScale)
        t.font = v(.font, t.font); t.icons = v(.icons, t.icons); t.motion = v(.motion, t.motion)
        t.playerLayout = v(.playerLayout, t.playerLayout); t.player = v(.player, t.player); t.artworkScale = v(.artworkScale, t.artworkScale)
        t.queueLayout = v(.queueLayout, t.queueLayout); t.lyricsSize = v(.lyricsSize, t.lyricsSize)
        t.lyricsCentered = v(.lyricsCentered, t.lyricsCentered); t.lyricsGlow = v(.lyricsGlow, t.lyricsGlow)
        t.miniPlayer = v(.miniPlayer, t.miniPlayer); t.nowPlaying = v(.nowPlaying, t.nowPlaying)
        t.typeWidth = v(.typeWidth, t.typeWidth); t.allCaps = v(.allCaps, t.allCaps); t.ink = v(.ink, t.ink)
        t.texture = v(.texture, t.texture); t.artShape = v(.artShape, t.artShape); t.artFrame = v(.artFrame, t.artFrame)
        t.tabs = v(.tabs, t.tabs); t.customFont = v(.customFont, t.customFont); t.searchTab = v(.searchTab, t.searchTab)
        t.builtIn = false
        self = t
    }

    var accentColor: Color { Color(hex: accent) }
    var colors: [Color] { (backgroundColors.isEmpty ? ["#101014"] : backgroundColors).map(Color.init(hex:)) }
    var colorScheme: ColorScheme? { scheme == 1 ? .light : scheme == 2 ? .dark : nil }
    var hasCustomBackground: Bool { background != .system }
    var inkColor: Color? { ink.map(Color.init(hex:)) }
}

nonisolated extension AppTheme: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .themeFile) { theme in
            let safe = theme.name.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).musictheme")
            var copy = theme
            copy.builtIn = false
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(copy).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - Built-in themes

extension AppTheme {
    static let base: AppTheme = {
        var t = AppTheme(id: "base", name: "\(Brand.name)")
        t.author = "\(Brand.name)"; t.summary = "The original look."; t.builtIn = true
        t.tabs = appleTabs
        t.searchTab = true
        return t
    }()

    /// The fixed tab bar: Home, New, Radio, Library (+ Search).
    static let appleTabs: [TabItemConfig] = [
        TabItemConfig(kind: .home, title: "Home", icon: "house.fill"),
        TabItemConfig(kind: .newMusic, title: "New", icon: "square.grid.2x2.fill"),
        TabItemConfig(kind: .radio, title: "Radio", icon: "dot.radiowaves.left.and.right"),
        TabItemConfig(kind: .library, title: "Library", icon: "music.note.square.stack.fill")
    ]

    /// The one and only theme: an Apple Music-style look. More may come later.
    static let appleMusic: AppTheme = {
        var t = AppTheme(id: "crimson", name: "Apple Music")
        t.author = "\(Brand.name)"; t.builtIn = true
        // Apple Music: lyrics, AirPlay and queue spread across the bottom.
        t.player.blocks = PlayerConfig.blocks(.artwork, .title, .scrubber, .controls, .bar)
        t.player.bar = PlayerConfig.bar(.lyrics, .spacer, .airplay, .spacer, .queue)
        t.player.showShuffleRepeat = false; t.player.playStyle = .plain; t.player.controlScale = 1.1
        t.inspiredBy = "Apple Music"; t.summary = "Soft glass, blurred covers, glowing lyrics."
        t.accent = "#FA2D48"; t.scheme = 0; t.cornerScale = 1.1; t.nowPlaying = .blurredArtwork; t.blur = 0.75
        t.lyricsSize = 32; t.lyricsGlow = true; t.glass = 0.1; t.miniPlayer = .capsule
        t.tabs = appleTabs
        t.searchTab = true
        return t
    }()

    static let builtIns: [AppTheme] = [appleMusic]
}

// MARK: - Store

@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var custom: [AppTheme] = [] { didSet { _selected = nil; save() } }
    var selectedID: String { didSet { _selected = nil; UserDefaults.standard.set(selectedID, forKey: "themeID") } }
    /// While set, the whole app renders with this theme (live preview before applying).
    var previewing: AppTheme?
    var favorites: Set<String> { didSet { UserDefaults.standard.set(Array(favorites), forKey: "themeFavorites") } }
    var ratings: [String: Int] { didSet { UserDefaults.standard.set(ratings, forKey: "themeRatings") } }

    private static var fileURL: URL { Paths.support.appendingPathComponent("themes.json") }

    private init() {
        let d = UserDefaults.standard
        FontImporter.registerAll()
        let savedID: String = d.string(forKey: "themeID") ?? "crimson"
        selectedID = AppTheme.builtIns.contains(where: { $0.id == savedID }) ? savedID : "crimson"
        favorites = Set(d.stringArray(forKey: "themeFavorites") ?? [])
        ratings = (d.dictionary(forKey: "themeRatings") as? [String: Int]) ?? [:]
        if let data = try? Data(contentsOf: Self.fileURL), let list = try? JSONDecoder().decode([AppTheme].self, from: data) { custom = list }
    }

    /// Only the built-in theme exists. Edits are stored as an override with the same id; anything else saved is ignored.
    var all: [AppTheme] {
        var list: [AppTheme] = []
        for base in AppTheme.builtIns {
            if var edited = custom.first(where: { $0.id == base.id }) {
                edited.builtIn = true
                edited.name = base.name
                edited.inspiredBy = base.inspiredBy
                edited.author = base.author
                edited.tabs = base.tabs
                edited.searchTab = base.searchTab
                list.append(edited)
            } else {
                list.append(base)
            }
        }
        return list
    }

    /// Back to the built-in Apple Music definition.
    func resetToDefault() {
        custom = []
        selectedID = "crimson"
    }

    /// Saves a change made on a customization page; unchanged values are ignored so pages never loop.
    func commit(_ t: AppTheme) {
        if t == selected { return }
        save(t)
    }

    /// Every cover, row and button asks for the theme, so the lookup is kept until the selection or the themes change.
    @ObservationIgnored private var _selected: AppTheme?
    var selected: AppTheme {
        // Read both so views keep following theme changes when the cached value is used.
        _ = selectedID; _ = custom
        if let hit = _selected { return hit }
        let t = all.first { $0.id == selectedID } ?? all.first { $0.id == "crimson" } ?? AppTheme.appleMusic
        _selected = t
        return t
    }
    var current: AppTheme { previewing ?? selected }

    /// `edited`: saving a change to the current theme (or to the copy a built-in one becomes). Only picking another
    /// theme brings its tab bar; an edit must never replace the tabs you have.
    func apply(_ t: AppTheme, edited: Bool = false) {
        if !all.contains(where: { $0.id == t.id }) { save(t) }
        let switching = !edited && t.id != selectedID
        withAnimation(.smooth(duration: 0.5)) {
            selectedID = t.id; previewing = nil
            if switching { LayoutStore.shared.adoptTabs(of: t) }
        }
    }

    func preview(_ t: AppTheme?) { withAnimation(.smooth(duration: 0.4)) { previewing = t } }

    func save(_ t: AppTheme) {
        var t = t
        t.builtIn = false
        if let i = custom.firstIndex(where: { $0.id == t.id }) { custom[i] = t } else { custom.append(t) }
    }

    func delete(_ t: AppTheme) {
        custom.removeAll { $0.id == t.id }
        if selectedID == t.id { selectedID = "crimson" }
    }

    func duplicate(_ t: AppTheme) -> AppTheme {
        var copy = t
        copy.id = UUID().uuidString
        copy.name = t.name + " Copy"
        copy.author = "You"
        copy.builtIn = false
        return copy
    }

    func toggleFavorite(_ t: AppTheme) { if favorites.contains(t.id) { favorites.remove(t.id) } else { favorites.insert(t.id) } }

    @discardableResult
    func importTheme(data: Data) -> AppTheme? {
        guard var t = try? JSONDecoder().decode(AppTheme.self, from: data) else { return nil }
        if AppTheme.builtIns.contains(where: { $0.id == t.id }) { t.id = UUID().uuidString }
        save(t)
        return t
    }

    func importTheme(from url: URL) -> AppTheme? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return importTheme(data: data)
    }

    // Glass used by the floating controls.
    var glass: Glass {
        let t = current
        let base: Glass = t.transparency > 0.6 ? .clear : .regular
        return t.glass > 0.01 ? base.tint(t.accentColor.opacity(t.glass * 0.35)) : base
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}

// MARK: - Applying a theme

struct ThemeRoot: ViewModifier {
    @Environment(AppSettings.self) private var settings
    func body(content: Content) -> some View {
        let t = ThemeStore.shared.current
        let scheme = t.colorScheme ?? settings.colorScheme
        content
            .preferredColorScheme(scheme)
            // SwiftUI keeps a forced dark/light window after the preference goes back to nil ("System");
            // setting the window style directly makes the switch back work, e.g. from a dark theme to Music.
            .onChange(of: scheme, initial: true) { _, s in
                let style: UIUserInterfaceStyle = s == .dark ? .dark : s == .light ? .light : .unspecified
                // Open sheets keep the style they were presented with, so walk them too.
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    for window in scene.windows {
                        window.overrideUserInterfaceStyle = style
                        var vc = window.rootViewController?.presentedViewController
                        while let presented = vc {
                            presented.overrideUserInterfaceStyle = style
                            vc = presented.presentedViewController
                        }
                    }
                }
            }
            .tint(t.accentColor)
            .fontDesign(t.font.design)
            .font(t.customFont.map { Font.custom($0, size: 17, relativeTo: .body) })
            .fontWidth(t.typeWidth.width)
            .textCase(t.allCaps ? .uppercase : nil)
            .foregroundStyle(t.inkColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            .overlay { ThemeTexture(kind: t.texture).ignoresSafeArea() }
            .modifier(IconStyleModifier(style: t.icons))
            .transaction { tr in
                switch t.motion {
                case .standard: break
                case .snappy: tr.animation = tr.animation?.speed(1.5)
                case .relaxed: tr.animation = tr.animation?.speed(0.7)
                case .off: tr.animation = nil
                }
            }
    }
}

private struct IconStyleModifier: ViewModifier {
    let style: AppTheme.IconStyle
    @Environment(\.symbolVariants) private var inherited
    // One structure for every style: switching between `content` and `content.environment(…)` would give the
    // whole app a new identity on a theme change and throw away its state (onboarding, navigation, sheets).
    // "Filled" is kept for older theme files but behaves like the default: a global fill
    // would turn state icons such as the favourite star into their "on" look.
    func body(content: Content) -> some View {
        content.environment(\.symbolVariants, style == .outline ? .none : inherited)
    }
}

struct ThemeBackgroundView: View {
    var theme: AppTheme { ThemeStore.shared.current }
    var body: some View {
        let t = theme
        Group {
            switch t.background {
            case .system: Color(.systemBackground)
            case .solid: t.colors[0]
            case .gradient: LinearGradient(colors: t.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            case .mesh:
                TimelineView(.animation(minimumInterval: 1 / 20, paused: t.motion == .off)) { ctx in
                    let s = Float(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60) / 60 * 2 * .pi)
                    let c = t.colors + t.colors
                    MeshGradient(width: 3, height: 3, points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [0.5 + 0.2 * sin(s), 0.5 + 0.15 * cos(s * 1.3)], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1]
                    ], colors: [c[0], c[1], c[0], c[2 % c.count], c[1], c[2 % c.count], c[0], c[2 % c.count], c[1]])
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct ThemedBackground: ViewModifier {
    // Same structure with or without a custom background, so switching themes keeps the screen's state.
    func body(content: Content) -> some View {
        let custom = ThemeStore.shared.current.hasCustomBackground
        content
            .scrollContentBackground(custom ? .hidden : .automatic)
            .background { if custom { ThemeBackgroundView() } }
    }
}

extension View {
    func themedBackground() -> some View { modifier(ThemedBackground()) }
    func themeRoot() -> some View { modifier(ThemeRoot()) }
}

/// A tiny drawing of the app in a theme: background, cover, lyric lines, accent controls.
struct ThemeMock: View {
    let theme: AppTheme
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // The mock shows the player, whose backgrounds are dark except light theme colors.
            let fg: Color = theme.nowPlaying == .themeColors && theme.scheme == 1 ? .black : .white
            let ink = theme.nowPlaying == .themeColors ? (theme.inkColor ?? fg) : fg
            ZStack {
                background
                ThemeTexture(kind: theme.texture).environment(\.colorScheme, theme.scheme == 1 && theme.nowPlaying == .themeColors ? .light : .dark)
                VStack(alignment: theme.lyricsCentered ? .center : .leading, spacing: w * 0.05) {
                    Text(theme.name)
                        .font(.system(size: w * 0.1, weight: .heavy))
                        .fontWidth(theme.typeWidth.width)
                        .textCase(theme.allCaps ? .uppercase : nil)
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    cover
                        .frame(width: theme.playerLayout == .large ? w * 0.84 : theme.playerLayout == .minimal ? w * 0.35 : w * 0.62)
                        .frame(maxWidth: .infinity)
                    RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.45)).frame(width: w * 0.32, height: w * 0.04)
                    Capsule().fill(ink.opacity(0.25)).frame(height: 3)
                        .overlay(alignment: .leading) { Capsule().fill(theme.accentColor).frame(width: w * 0.35, height: 3) }
                    HStack(spacing: w * 0.07) {
                        Image(systemName: "backward.fill")
                        Image(systemName: "play.fill").font(.system(size: w * 0.11))
                            .foregroundStyle(theme.accentColor)
                        Image(systemName: "forward.fill")
                    }
                    .font(.system(size: w * 0.08))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity)
                    if let tabs = theme.tabs {
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
                                VStack(spacing: 2) {
                                    Image(systemName: tab.icon).font(.system(size: w * 0.07))
                                    Text(tab.title).font(.system(size: w * 0.045, weight: .medium)).lineLimit(1).minimumScaleFactor(0.5)
                                }
                                .foregroundStyle(i == 0 ? theme.accentColor : ink.opacity(0.6))
                                .frame(maxWidth: .infinity)
                            }
                            if theme.searchTab ?? true {
                                Image(systemName: "magnifyingglass").font(.system(size: w * 0.07))
                                    .foregroundStyle(ink.opacity(0.6))
                                    .frame(width: w * 0.16)
                            }
                        }
                        .padding(.vertical, w * 0.025)
                        .background(Capsule().fill(.ultraThinMaterial))
                    }
                }
                .padding(w * 0.09)
            }
            .fontDesign(theme.font.design)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var background: some View {
        switch theme.nowPlaying {
        case .artworkTint: LinearGradient(colors: [theme.accentColor.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
        case .blurredArtwork: ZStack { GeneratedCover(spec: CoverKit.auto(theme.name)).blur(radius: 14); Color.black.opacity(0.35) }
        case .themeColors: LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        case .black: Color.black
        }
    }

    private var cover: some View {
        let shape = theme.playerLayout == .vinyl ? AnyShape(Circle()) : theme.artShape.shape(radius: 10 * theme.cornerScale)
        return GeneratedCover(spec: CoverKit.auto(theme.name + "cover"))
            .aspectRatio(1, contentMode: .fit)
            .clipShape(shape)
            .overlay { ArtFrameOverlay(frame: theme.artFrame, shape: shape, accent: theme.accentColor, ink: theme.inkColor) }
            .overlay { if theme.playerLayout == .vinyl { Circle().fill(.black).frame(width: 10, height: 10) } }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

/// Floating banner while a theme is being previewed.
struct ThemePreviewBanner: View {
    var body: some View {
        let store = ThemeStore.shared
        if let t = store.previewing {
            HStack(spacing: 10) {
                Image(systemName: "eye.fill").foregroundStyle(t.accentColor)
                Text("Previewing \(t.name)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button("Cancel") { store.preview(nil) }.buttonStyle(.glass)
                Button("Apply") { store.apply(t) }.buttonStyle(.glassProminent).tint(t.accentColor)
            }
            .font(.system(size: 14))
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}


// MARK: - The single theme card

/// Shown in Customize where the theme picker used to be.
struct SingleThemeCard: View {
    var body: some View {
        let t = ThemeStore.shared.selected
        let style = PlayerDesignStore.shared.current.style
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ThemeMock(theme: t)
                    .frame(width: 84, height: 108)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(t.accentColor, lineWidth: 3)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.title).font(.system(size: 17, weight: .semibold))
                    Text("Inspired by \(style.title)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 22))
                    .foregroundStyle(t.accentColor)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editing the current theme

/// A customization page: edits the current theme in place and saves each change.
struct ThemeEditForm<Content: View>: View {
    let title: String
    let content: (Binding<AppTheme>) -> Content
    @State private var theme: AppTheme = ThemeStore.shared.selected

    init(title: String, @ViewBuilder content: @escaping (Binding<AppTheme>) -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Form {
            content($theme)
            Section {
                Button("Reset to \(PlayerDesignStore.shared.lookName) defaults", role: .destructive) {
                    PlayerDesignStore.shared.resetToLookDefaults()
                    theme = ThemeStore.shared.selected
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: theme) { _, new in ThemeStore.shared.commit(new) }
    }
}

private func themeSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit() }
        Slider(value: value, in: range)
    }
}

struct ColorsSettingsView: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        ThemeEditForm(title: "Colors") { theme in
            Section {
                ThemeMock(theme: theme.wrappedValue).frame(width: 150, height: 195).frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            Section("Appearance") {
                Picker("Appearance", selection: Binding<Int>(
                    get: { settings.appearance },
                    set: { v in
                        settings.appearance = v
                        // A theme that forces light or dark would override this setting.
                        var t: AppTheme = ThemeStore.shared.selected
                        if t.scheme != 0 { t.scheme = 0; ThemeStore.shared.commit(t) }
                    })) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
            }
            Section("Colors") {
                ColorPicker("Accent", selection: Binding<Color>(
                    get: { Color(hex: theme.wrappedValue.accent) },
                    set: { theme.wrappedValue.accent = $0.hexString }), supportsOpacity: false)
                Picker("Background", selection: theme.background) {
                    ForEach(AppTheme.Background.allCases) { Text($0.title).tag($0) }
                }
                if theme.wrappedValue.background != .system {
                    let count: Int = theme.wrappedValue.background == .solid ? 1 : 3
                    ForEach(0..<count, id: \.self) { i in
                        ColorPicker(count == 1 ? "Color" : "Color \(i + 1)", selection: Binding<Color>(
                            get: {
                                let list: [String] = theme.wrappedValue.backgroundColors
                                return list.indices.contains(i) ? Color(hex: list[i]) : Color.black
                            },
                            set: { c in
                                var list: [String] = theme.wrappedValue.backgroundColors
                                while list.count <= i { list.append(list.last ?? "#101014") }
                                list[i] = c.hexString
                                theme.wrappedValue.backgroundColors = list
                            }), supportsOpacity: false)
                    }
                }
                Toggle("Custom Text Color", isOn: Binding<Bool>(
                    get: { theme.wrappedValue.ink != nil },
                    set: { on in theme.wrappedValue.ink = on ? (theme.wrappedValue.ink ?? "#141414") : nil }))
                if theme.wrappedValue.ink != nil {
                    ColorPicker("Text Color", selection: Binding<Color>(
                        get: { theme.wrappedValue.inkColor ?? Color.primary },
                        set: { theme.wrappedValue.ink = $0.hexString }), supportsOpacity: false)
                }
            }
            Section("Surface & Covers") {
                Picker("Surface", selection: theme.texture) { ForEach(AppTheme.Texture.allCases) { Text($0.title).tag($0) } }
                Picker("Cover Shape", selection: theme.artShape) { ForEach(AppTheme.ArtShape.allCases) { Text($0.title).tag($0) } }
                Picker("Cover Frame", selection: theme.artFrame) { ForEach(AppTheme.ArtFrame.allCases) { Text($0.title).tag($0) } }
            }
            Section("Glass & Shape") {
                themeSlider("Blur", theme.blur, 0...1)
                themeSlider("Transparency", theme.transparency, 0...1)
                themeSlider("Glass Intensity", theme.glass, 0...1)
                themeSlider("Corner Radius", theme.cornerScale, 0...1.8)
            }
            Section("Motion") {
                Picker("Animations", selection: theme.motion) { ForEach(AppTheme.Motion.allCases) { Text($0.title).tag($0) } }
            }
        }
    }
}

struct FontSettingsView: View {
    @State private var imported: [ImportedFont] = FontImporter.stored()
    @State private var importing = false
    @State private var errorMessage: String?

    var body: some View {
        ThemeEditForm(title: "Fonts & Icons") { theme in
            Section("Font") {
                Picker("Style", selection: theme.font) { ForEach(AppTheme.FontStyle.allCases) { Text($0.title).tag($0) } }
                Picker("Letter Width", selection: theme.typeWidth) { ForEach(AppTheme.TypeWidth.allCases) { Text($0.title).tag($0) } }
                Toggle("All Caps", isOn: theme.allCaps)
            }
            Section {
                Picker("Imported Font", selection: Binding<String>(
                    get: { theme.wrappedValue.customFont ?? "" },
                    set: { theme.wrappedValue.customFont = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(imported) { f in Text(f.family).tag(f.postScript) }
                }
                Button { importing = true } label: { Label("Import Font…", systemImage: "square.and.arrow.down") }
            } header: { Text("Your Fonts") } footer: {
                Text("Import a .ttf or .otf file. It is copied into \(Brand.name) and stays available after a restart.")
            }
            TabIconsSection()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType.font]) { result in
            switch result {
            case .success(let url):
                do {
                    _ = try FontImporter.importFont(from: url)
                    imported = FontImporter.stored()
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Couldn't Import Font", isPresented: Binding<Bool>(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
    }
}

struct LyricsLookSettingsView: View {
    var body: some View {
        ThemeEditForm(title: "Lyrics") { theme in
            Section("Lyrics") {
                themeSlider("Text Size", theme.lyricsSize, 20...44)
                Toggle("Centered", isOn: theme.lyricsCentered)
                Toggle("Glow on Current Line", isOn: theme.lyricsGlow)
            }
            LyricsSourceSections()
        }
    }
}

/// Customize ▸ Player when no song is playing (with a song, the real player opens in edit mode).
struct PlayerSettingsView: View {
    @State private var theme: AppTheme = ThemeStore.shared.selected
    var body: some View {
        PlayerLayoutEditor(theme: $theme)
            .onChange(of: theme) { _, new in ThemeStore.shared.commit(new) }
    }
}

// MARK: - Imported fonts

nonisolated struct ImportedFont: Codable, Hashable, Identifiable, Sendable {
    var postScript: String
    var family: String
    var file: String
    var id: String { postScript }
}

struct FontImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum FontImporter {
    private static let key = "importedFonts"

    static var directory: URL {
        let url = Paths.support.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func stored() -> [ImportedFont] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        let list: [ImportedFont]? = try? JSONDecoder().decode([ImportedFont].self, from: data)
        return list ?? []
    }

    private static func store(_ list: [ImportedFont]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Registers every stored font for this process. Safe to call more than once; failures are ignored.
    static func registerAll() {
        let dir: URL = directory
        for f in stored() {
            let url: URL = dir.appendingPathComponent(f.file)
            if FileManager.default.fileExists(atPath: url.path) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// Copies the picked file into Application Support/Fonts, registers it and remembers it. Throws instead of crashing.
    static func importFont(from url: URL) throws -> ImportedFont {
        let scoped: Bool = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data = try Data(contentsOf: url)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider),
              let psName = cgFont.postScriptName else {
            throw FontImportError(message: "That file isn't a font \(Brand.name) can read.")
        }
        let postScript: String = psName as String
        var family: String = postScript
        if let full = cgFont.fullName { family = full as String }
        let fileName: String = url.lastPathComponent
        let dest: URL = directory.appendingPathComponent(fileName)
        try data.write(to: dest, options: .atomic)
        // Registering a font that is already registered reports an error; that's fine as long as the font loads.
        CTFontManagerRegisterFontsForURL(dest as CFURL, .process, nil)
        guard UIFont(name: postScript, size: 12) != nil else {
            try? FileManager.default.removeItem(at: dest)
            throw FontImportError(message: "The font couldn't be loaded.")
        }
        let item = ImportedFont(postScript: postScript, family: family, file: fileName)
        var list: [ImportedFont] = stored().filter { $0.postScript != postScript }
        list.append(item)
        store(list)
        return item
    }
}
