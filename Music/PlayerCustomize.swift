import SwiftUI

// MARK: - Player layout (part of every theme)

/// The rows of the player screen, top to bottom, in whatever order the theme wants.
nonisolated enum PlayerBlock: String, Codable, CaseIterable, Identifiable, Sendable {
    case artwork, title, scrubber, controls, bar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .artwork: "Artwork"
        case .title: "Title & Artist"
        case .scrubber: "Progress Bar"
        case .controls: "Play Controls"
        case .bar: "Button Row"
        }
    }
    var icon: String {
        switch self {
        case .artwork: "photo"
        case .title: "textformat"
        case .scrubber: "minus"
        case .controls: "playpause.fill"
        case .bar: "circle.grid.3x3.fill"
        }
    }
}

/// Anything that can sit in the button row. Spacers push the others apart and may be used several times.
nonisolated enum PlayerBarItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case modes, lyrics, queue, airplay, sleep, equalizer, favorite, share, more, spacer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modes: "Artwork · Lyrics · Queue"
        case .lyrics: "Lyrics"
        case .queue: "Queue"
        case .airplay: "AirPlay"
        case .sleep: "Sleep Timer"
        case .equalizer: "Equalizer"
        case .favorite: "Favorite"
        case .share: "Share"
        case .more: "“…” Menu"
        case .spacer: "Spacer"
        }
    }
    var icon: String {
        switch self {
        case .modes: "rectangle.split.3x1"
        case .lyrics: "quote.bubble"
        case .queue: "list.bullet"
        case .airplay: "airplayaudio"
        case .sleep: "moon.zzz"
        case .equalizer: "slider.vertical.3"
        case .favorite: "star"
        case .share: "square.and.arrow.up"
        case .more: "ellipsis"
        case .spacer: "arrow.left.and.right"
        }
    }
}

nonisolated enum PlayerMenuItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case addToPlaylist, share, download, station, mix, goArtist, goAlbum, editMetadata, designCover, editLyrics, saveQueue, sleep, equalizer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .addToPlaylist: "Add to Playlist"
        case .share: "Share Song"
        case .download: "Download / Remove Download"
        case .station: "Create Station"
        case .mix: "Mix Into Next Song"
        case .goArtist: "Go to Artist"
        case .goAlbum: "Go to Album"
        case .editMetadata: "Edit Metadata"
        case .designCover: "Design Cover"
        case .editLyrics: "Edit Lyrics"
        case .saveQueue: "Save Queue as Playlist"
        case .sleep: "Sleep Timer"
        case .equalizer: "Equalizer"
        }
    }
    var icon: String {
        switch self {
        case .addToPlaylist: "text.badge.plus"
        case .share: "square.and.arrow.up"
        case .download: "arrow.down.circle"
        case .station: "dot.radiowaves.left.and.right"
        case .mix: "arrow.triangle.merge"
        case .goArtist: "music.mic"
        case .goAlbum: "square.stack"
        case .editMetadata: "tag"
        case .designCover: "paintpalette"
        case .editLyrics: "quote.bubble"
        case .saveQueue: "music.note.list"
        case .sleep: "moon.zzz"
        case .equalizer: "slider.vertical.3"
        }
    }
}

nonisolated struct PlayerBlockEntry: Codable, Identifiable, Hashable, Sendable {
    var block: PlayerBlock
    var visible = true
    var id: String { block.rawValue }
}

nonisolated struct PlayerBarEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var item: PlayerBarItem
}

nonisolated struct PlayerMenuEntry: Codable, Identifiable, Hashable, Sendable {
    var item: PlayerMenuItem
    var visible = true
    var id: String { item.rawValue }
}

nonisolated enum PlayerSpacing: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, comfortable, roomy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Gap between the rows below the artwork.
    var gap: CGFloat { switch self { case .compact: 10; case .comfortable: 20; case .roomy: 30 } }
    var bottomLift: CGFloat { switch self { case .compact: 0; case .comfortable: 14; case .roomy: 26 } }
}

nonisolated enum PlayButtonStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case glass, accent, plain
    var id: String { rawValue }
    var title: String { ["glass": "White Circle", "accent": "Accent Circle", "plain": "Icon Only"][rawValue] ?? rawValue }
}

nonisolated enum PlayerTitleAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case leading, center
    var id: String { rawValue }
    var title: String { self == .leading ? "Left" : "Centered" }
}

nonisolated struct PlayerConfig: Codable, Hashable, Sendable {
    var blocks: [PlayerBlockEntry] = PlayerBlock.allCases.map { PlayerBlockEntry(block: $0) }
    var bar: [PlayerBarEntry] = Self.bar(.airplay, .modes, .sleep)
    var menu: [PlayerMenuEntry] = PlayerMenuItem.allCases.map { .init(item: $0, visible: ![.designCover, .editLyrics, .sleep].contains($0)) }
    var spacing: PlayerSpacing = .comfortable
    var titleAlignment: PlayerTitleAlignment = .leading
    var playStyle: PlayButtonStyle = .glass
    var controlScale = 1.0
    var showShuffleRepeat = true
    var showStar = true
    var showTitleMenu = true
    var showTimes = true
    var showEQBadge = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var p = PlayerConfig()
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        p.blocks = v(.blocks, p.blocks); p.bar = v(.bar, p.bar); p.menu = v(.menu, p.menu)
        p.spacing = v(.spacing, p.spacing); p.titleAlignment = v(.titleAlignment, p.titleAlignment)
        p.playStyle = v(.playStyle, p.playStyle); p.controlScale = v(.controlScale, p.controlScale)
        p.showShuffleRepeat = v(.showShuffleRepeat, p.showShuffleRepeat); p.showStar = v(.showStar, p.showStar)
        p.showTitleMenu = v(.showTitleMenu, p.showTitleMenu); p.showTimes = v(.showTimes, p.showTimes)
        p.showEQBadge = v(.showEQBadge, p.showEQBadge)
        // Rows or menu items added in a later version show up too.
        for b in PlayerBlock.allCases where !p.blocks.contains(where: { $0.block == b }) { p.blocks.append(PlayerBlockEntry(block: b)) }
        for m in PlayerMenuItem.allCases where !p.menu.contains(where: { $0.item == m }) { p.menu.append(PlayerMenuEntry(item: m, visible: false)) }
        self = p
    }

    var visibleBlocks: [PlayerBlock] { blocks.filter(\.visible).map(\.block) }
    var barHasFlexible: Bool { bar.contains { $0.item == .spacer || $0.item == .modes } }

    static func bar(_ items: PlayerBarItem...) -> [PlayerBarEntry] { items.map { PlayerBarEntry(item: $0) } }
    static func blocks(_ order: PlayerBlock...) -> [PlayerBlockEntry] {
        order.map { PlayerBlockEntry(block: $0) } + PlayerBlock.allCases.filter { !order.contains($0) }.map { PlayerBlockEntry(block: $0, visible: false) }
    }
}

// MARK: - Preview

/// A small, live drawing of the player built from the same config the real player reads.
struct PlayerPreview: View {
    let theme: AppTheme
    private var p: PlayerConfig { theme.player }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let s = w / 390
            ZStack {
                background
                VStack(spacing: p.spacing.gap * s) {
                    if !p.visibleBlocks.contains(.artwork) { Spacer(minLength: 0) }
                    ForEach(p.visibleBlocks) { block(for: $0, s: s, w: w) }
                }
                .padding(.horizontal, 24 * s)
                .padding(.top, 44 * s)
                .padding(.bottom, (22 + p.spacing.bottomLift) * s)
                VStack { Capsule().fill(.white.opacity(0.35)).frame(width: 40 * s, height: 5 * s).padding(.top, 14 * s); Spacer() }
            }
            .foregroundStyle(.white)
            .fontDesign(theme.font.design)
        }
        .aspectRatio(390 / 844, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .animation(.smooth(duration: 0.35), value: theme)
    }

    @ViewBuilder private var background: some View {
        switch theme.nowPlaying {
        case .artworkTint: LinearGradient(colors: [theme.accentColor.opacity(0.85), theme.accentColor.opacity(0.4), .black], startPoint: .top, endPoint: .bottom)
        case .blurredArtwork: ZStack { GeneratedCover(spec: CoverKit.auto(theme.name + "cover")).scaledToFill().blur(radius: 24); Color.black.opacity(0.4) }
        case .themeColors: LinearGradient(colors: theme.colors, startPoint: .top, endPoint: .bottom)
        case .black: Color.black
        }
    }

    @ViewBuilder private func block(for b: PlayerBlock, s: CGFloat, w: CGFloat) -> some View {
        switch b {
        case .artwork:
            let shape = theme.playerLayout == .vinyl ? AnyShape(Circle()) : theme.artShape.shape(radius: 16 * theme.cornerScale * s)
            let size: CGFloat = theme.playerLayout == .minimal ? 0.35 : theme.playerLayout == .large ? 0.95 : 0.82
            GeneratedCover(spec: CoverKit.auto(theme.name + "cover"))
                .aspectRatio(1, contentMode: .fit)
                .clipShape(shape)
                .frame(maxWidth: (w - 48 * s) * size * min(theme.artworkScale, 1.1))
                .shadow(color: .black.opacity(0.35), radius: 14 * s, y: 8 * s)
                .frame(maxHeight: .infinity)
        case .title:
            let centered = p.titleAlignment == .center
            let buttons = (p.showStar ? 1 : 0) + (p.showTitleMenu ? 1 : 0)
            HStack(spacing: 10 * s) {
                // Like the player: a centred title sits in the middle of the whole row, the buttons stay on the right.
                VStack(alignment: centered ? .center : .leading, spacing: 2 * s) {
                    Text("Song Title").font(.system(size: 22 * s, weight: .bold)).fontWidth(theme.typeWidth.width)
                    Text("Artist").font(.system(size: 18 * s)).foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                .offset(x: centered && buttons > 0 ? CGFloat(buttons * 40 + buttons * 10) * s / 2 : 0)
                if buttons > 0 { titleButtons(s) }
            }
            .lineLimit(1)
        case .scrubber:
            VStack(spacing: 6 * s) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 6 * s)
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: w * 0.35, height: 6 * s) }
                if p.showTimes {
                    HStack { Text("1:12"); Spacer(); Text("3:41") }.font(.system(size: 12 * s, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
            }
        case .controls:
            let c = s * p.controlScale
            HStack {
                if p.showShuffleRepeat { Image(systemName: "shuffle").font(.system(size: 19 * c, weight: .semibold)).opacity(0.5); Spacer() }
                Image(systemName: "backward.fill").font(.system(size: 34 * c))
                Spacer()
                playButton(c)
                Spacer()
                Image(systemName: "forward.fill").font(.system(size: 34 * c))
                if p.showShuffleRepeat { Spacer(); Image(systemName: "repeat").font(.system(size: 19 * c, weight: .semibold)).opacity(0.5) }
            }
            .frame(maxWidth: p.showShuffleRepeat ? .infinity : w * 0.72)
        case .bar:
            HStack(spacing: 10 * s) {
                if !p.barHasFlexible { Spacer(minLength: 0) }
                ForEach(p.bar) { e in
                    switch e.item {
                    case .spacer: Spacer(minLength: 0)
                    case .modes:
                        HStack(spacing: 0) {
                            ForEach(["music.note", "quote.bubble", "list.bullet"], id: \.self) { sym in
                                Image(systemName: sym).font(.system(size: 16 * s, weight: .semibold)).frame(maxWidth: .infinity)
                                    .frame(height: 40 * s)
                                    .background { if sym == "music.note" { Capsule().fill(.white.opacity(0.25)).padding(.horizontal, 4 * s) } }
                            }
                        }
                        .frame(height: 48 * s)
                        .background(Capsule().fill(.white.opacity(0.12)))
                    default: bubble(e.item.icon, size: 48 * s)
                    }
                }
                if !p.barHasFlexible { Spacer(minLength: 0) }
            }
        }
    }

    private func titleButtons(_ s: CGFloat) -> some View {
        HStack(spacing: 10 * s) {
            if p.showStar { bubble("star", size: 40 * s) }
            if p.showTitleMenu { bubble("ellipsis", size: 40 * s) }
        }
    }

    @ViewBuilder private func playButton(_ c: CGFloat) -> some View {
        switch p.playStyle {
        case .glass:
            Image(systemName: "pause.fill").font(.system(size: 28 * c, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                .frame(width: 74 * c, height: 74 * c).background(Circle().fill(.white.opacity(0.92)))
        case .accent:
            Image(systemName: "pause.fill").font(.system(size: 28 * c, weight: .bold))
                .frame(width: 74 * c, height: 74 * c).background(Circle().fill(theme.accentColor))
        case .plain:
            Image(systemName: "pause.fill").font(.system(size: 46 * c, weight: .bold)).frame(width: 74 * c, height: 74 * c)
        }
    }

    private func bubble(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.36, weight: .semibold))
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(0.14)))
    }
}

// MARK: - Editor

/// Edits the player of one theme, with the preview pinned on top.
struct PlayerLayoutEditor: View {
    @Binding var theme: AppTheme

    var body: some View {
        VStack(spacing: 0) {
            PlayerPreview(theme: theme)
                .frame(height: 290)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.bar)
            Divider()
            form
        }
        .navigationTitle("Music Player")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var form: some View {
        List {
            Section {
                ForEach($theme.player.blocks) { $e in
                    Toggle(isOn: $e.visible) { Label(e.block.title, systemImage: e.block.icon) }
                        .disabled(e.block == .controls)
                }
                .onMove { theme.player.blocks.move(fromOffsets: $0, toOffset: $1) }
            } header: { Text("Screen") } footer: { Text("Drag to change the order from top to bottom. Hide what you don't need.") }

            Section {
                ForEach(theme.player.bar) { e in
                    Label(e.item.title, systemImage: e.item.icon)
                }
                .onMove { theme.player.bar.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { theme.player.bar.remove(atOffsets: $0) }
                Menu {
                    ForEach(PlayerBarItem.allCases.filter { i in i == .spacer || !theme.player.bar.contains { $0.item == i } }) { i in
                        Button { theme.player.bar.append(PlayerBarEntry(item: i)) } label: { Label(i.title, systemImage: i.icon) }
                    }
                } label: { Label("Add Button", systemImage: "plus") }
            } header: { Text("Button Row") } footer: {
                Text("Add, remove and drag buttons. Spacers push buttons apart: one on each side centres what's between them.")
            }

            Section("Title") {
                Picker("Alignment", selection: $theme.player.titleAlignment) { ForEach(PlayerTitleAlignment.allCases) { Text($0.title).tag($0) } }
                Toggle("Favorite Star", isOn: $theme.player.showStar)
                Toggle("“…” Button", isOn: $theme.player.showTitleMenu)
            }

            Section("Controls") {
                Picker("Play Button", selection: $theme.player.playStyle) { ForEach(PlayButtonStyle.allCases) { Text($0.title).tag($0) } }
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text("Size"); Spacer(); Text("\(Int((theme.player.controlScale * 100).rounded())) %").foregroundStyle(.secondary).monospacedDigit() }
                    Slider(value: $theme.player.controlScale, in: 0.75...1.25, step: 0.05)
                }
                Toggle("Shuffle & Repeat", isOn: $theme.player.showShuffleRepeat)
                Toggle("Times Under Progress Bar", isOn: $theme.player.showTimes)
                Toggle("Active Equalizer Preset", isOn: $theme.player.showEQBadge)
                Picker("Spacing", selection: $theme.player.spacing) { ForEach(PlayerSpacing.allCases) { Text($0.title).tag($0) } }
            }

            Section("Look") {
                Picker("Artwork", selection: $theme.playerLayout) { ForEach(AppTheme.PlayerLayout.allCases) { Text($0.title).tag($0) } }
                Picker("Background", selection: $theme.nowPlaying) { ForEach(AppTheme.NowPlayingBackground.allCases) { Text($0.title).tag($0) } }
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text("Album Art Size"); Spacer(); Text("\(Int((theme.artworkScale * 100).rounded())) %").foregroundStyle(.secondary).monospacedDigit() }
                    Slider(value: $theme.artworkScale, in: 0.6...1.25)
                }
            }

            Section {
                ForEach($theme.player.menu) { $e in
                    Toggle(isOn: $e.visible) { Label(e.item.title, systemImage: e.item.icon) }
                }
                .onMove { theme.player.menu.move(fromOffsets: $0, toOffset: $1) }
            } header: { Text("“…” Menu") } footer: { Text("Drag to reorder, switch off what you never use.") }

            Section {
                Button("Reset Player Layout") {
                    // Back to the preset this theme came from (a copy of "Green Room" goes back to Green Room's player).
                    let base = AppTheme.builtIns.first { $0.id == theme.id } ?? AppTheme.builtIns.dropFirst().first { theme.name.hasPrefix($0.name) }
                    withAnimation { theme.player = base?.player ?? PlayerConfig() }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }
}

/// Customize ▸ Music Player: edits the current theme's player. A built-in theme is copied first, like the theme editor does.
struct PlayerLayoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var theme: AppTheme

    var body: some View {
        NavigationStack {
            PlayerLayoutEditor(theme: $theme)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { ThemeStore.shared.save(theme); ThemeStore.shared.apply(theme, edited: true); dismiss() }
                    }
                }
        }
    }
}

// MARK: - Edit mode on the real player

/// What's being edited in the player's edit mode: one row, or the screen as a whole (background, spacing).
enum PlayerEditTarget: Hashable, Identifiable {
    case block(PlayerBlock), screen
    var id: String { if case .block(let b) = self { b.rawValue } else { "screen" } }
    var title: String { if case .block(let b) = self { b.title } else { "Screen" } }
}

/// The floating card with the options of whatever you tapped. The player behind it updates as you change things.
struct PlayerElementPanel: View {
    let target: PlayerEditTarget
    @Binding var theme: AppTheme
    var close: () -> Void
    var hide: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(target.title).font(.system(size: 17, weight: .bold))
                Spacer()
                if let hide {
                    Button(action: hide) { Label("Hide", systemImage: "eye.slash").font(.system(size: 14, weight: .semibold)) }
                        .buttonStyle(.glass)
                }
                Button(action: close) {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
            content
        }
        .padding(18)
        .foregroundStyle(.white)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch target {
        case .screen:
            chips("Background", AppTheme.NowPlayingBackground.allCases, $theme.nowPlaying) { ($0.title, backgroundIcon($0)) }
            chips("Spacing", PlayerSpacing.allCases, $theme.player.spacing) { ($0.title, ["compact": "arrow.down.right.and.arrow.up.left", "comfortable": "equal", "roomy": "arrow.up.left.and.arrow.down.right"][$0.rawValue]!) }
        case .block(.artwork):
            chips("Style", AppTheme.PlayerLayout.allCases, $theme.playerLayout) { ($0.title, ["classic": "square", "large": "square.fill", "vinyl": "record.circle", "minimal": "waveform"][$0.rawValue]!) }
            slider("Size", $theme.artworkScale, 0.6...1.25)
        case .block(.title):
            chips("Alignment", PlayerTitleAlignment.allCases, $theme.player.titleAlignment) { ($0.title, $0 == .leading ? "text.alignleft" : "text.aligncenter") }
            HStack(spacing: 10) {
                toggleChip("Favorite Star", "star", $theme.player.showStar)
                toggleChip("“…” Button", "ellipsis", $theme.player.showTitleMenu)
            }
        case .block(.scrubber):
            HStack(spacing: 10) {
                toggleChip("Times", "clock", $theme.player.showTimes)
                toggleChip("EQ Preset", "slider.vertical.3", $theme.player.showEQBadge)
            }
        case .block(.controls):
            chips("Play Button", PlayButtonStyle.allCases, $theme.player.playStyle) { ($0.title, ["glass": "circle.fill", "accent": "circle.hexagongrid.fill", "plain": "play.fill"][$0.rawValue]!) }
            slider("Size", $theme.player.controlScale, 0.75...1.25)
            toggleChip("Shuffle & Repeat", "shuffle", $theme.player.showShuffleRepeat)
        case .block(.bar):
            Text("Tap to add or remove. Drag the buttons in the row to move them.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 12) {
                ForEach(PlayerBarItem.allCases) { item in
                    let on = item != .spacer && theme.player.bar.contains { $0.item == item }
                    Button {
                        withAnimation(.smooth(duration: 0.3)) {
                            if on { theme.player.bar.removeAll { $0.item == item } } else { theme.player.bar.append(PlayerBarEntry(item: item)) }
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.icon).font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(on ? .black : .white)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(on ? .white : .white.opacity(0.12)))
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: on ? "minus.circle.fill" : "plus.circle.fill")
                                        .font(.system(size: 15)).foregroundStyle(on ? .white : .black, on ? .black : .white)
                                        .offset(x: 4, y: -4)
                                }
                            Text(item == .modes ? "Views" : item.title.replacingOccurrences(of: "“…” ", with: ""))
                                .font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(PressScale())
                }
            }
        }
    }

    private func backgroundIcon(_ b: AppTheme.NowPlayingBackground) -> String {
        switch b {
        case .artworkTint: "drop.fill"
        case .blurredArtwork: "photo.fill"
        case .themeColors: "paintpalette.fill"
        case .black: "moon.fill"
        }
    }

    private func chips<T: Hashable & Identifiable>(_ title: String, _ options: [T], _ selection: Binding<T>, label: @escaping (T) -> (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).textCase(.uppercase)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options) { o in
                        let on = selection.wrappedValue == o
                        let (name, icon) = label(o)
                        Button { withAnimation(.smooth(duration: 0.35)) { selection.wrappedValue = o } } label: {
                            Label(name, systemImage: icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(on ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 38)
                                .background(Capsule().fill(on ? .white : .white.opacity(0.12)))
                        }
                        .buttonStyle(PressScale())
                    }
                }
            }
            .scrollClipDisabled()
        }
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }

    private func toggleChip(_ title: String, _ icon: String, _ isOn: Binding<Bool>) -> some View {
        Button { withAnimation(.smooth(duration: 0.3)) { isOn.wrappedValue.toggle() } } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? .black : .white)
                .padding(.horizontal, 14).frame(height: 38)
                .background(Capsule().fill(isOn.wrappedValue ? .white : .white.opacity(0.12)))
        }
        .buttonStyle(PressScale())
        .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).textCase(.uppercase)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded())) %").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
            }
            Slider(value: value, in: range).tint(.white)
        }
    }
}

/// Live reordering while something is dragged over another item of the same list.
struct PlayerReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(.smooth(duration: 0.3)) { move(d, target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
