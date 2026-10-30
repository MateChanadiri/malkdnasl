import SwiftUI
import Observation

// MARK: - Tabs

nonisolated enum TabKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case home, newMusic, library, playlists, albums, artists, songs, downloads, favorites, radio, queue, recentlyPlayed, audioLab, files, shortcut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .newMusic: "New"
        case .library: "Library"
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        case .downloads: "Downloads"
        case .favorites: "Favorites"
        case .radio: "Radio"
        case .queue: "Queue"
        case .recentlyPlayed: "Recently Played"
        case .audioLab: "Sound"
        case .files: "Files"
        case .shortcut: "Shortcut"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .newMusic: "square.grid.2x2"
        case .library: "music.note"
        case .playlists: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .songs: "music.quarternote.3"
        case .downloads: "arrow.down.circle"
        case .favorites: "star"
        case .radio: "dot.radiowaves.left.and.right"
        case .queue: "list.bullet"
        case .recentlyPlayed: "clock"
        case .audioLab: "slider.vertical.3"
        case .files: "shippingbox"
        case .shortcut: "bolt"
        }
    }
}

nonisolated struct TabItemConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: TabKind
    var title: String
    var icon: String
    var targetKind: LibraryEntry.Kind?
    var targetKey: String?

    init(kind: TabKind, title: String? = nil, icon: String? = nil, targetKind: LibraryEntry.Kind? = nil, targetKey: String? = nil) {
        self.id = kind == .shortcut ? UUID().uuidString : kind.rawValue
        self.kind = kind
        self.title = title ?? kind.title
        self.icon = icon ?? kind.icon
        self.targetKind = targetKind
        self.targetKey = targetKey
    }

    var appTab: AppTab {
        switch kind {
        case .home: .home
        case .library: .library
        default: .custom(id)
        }
    }
}

extension TabItemConfig {
    @ViewBuilder var rootView: some View {
        switch kind {
        case .home: HomeView()
        case .newMusic: NewTabRoot().themedBackground()
        case .library: LibraryView()
        case .playlists: PlaylistsView().themedBackground()
        case .albums: AlbumsView().themedBackground()
        case .artists: ArtistsView().themedBackground()
        case .songs: SongsView().themedBackground()
        case .downloads: DownloadsView().themedBackground()
        case .favorites: FavoritesView().themedBackground()
        case .radio: RadioTabRoot().themedBackground()
        case .queue: QueueTabView()
        case .recentlyPlayed: RecentlyPlayedView().themedBackground()
        case .audioLab: StudioView().themedBackground()
        case .files: FilesView().themedBackground()
        case .shortcut:
            if let k = targetKind, let key = targetKey { CollectionDetailView(kind: k, key: key).themedBackground() }
            else { ContentUnavailableView("Nothing Here", systemImage: "bolt") }
        }
    }
}

// MARK: - Home sections & shortcuts

nonisolated enum HomeSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case topPicks, suggested, shortcuts, recentlyPlayed, madeForYou, artists, recentlyAdded, latestSongs, favorites, playlists, downloads, streaming
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topPicks: "Top Picks"
        case .suggested: "Suggested for You"
        case .shortcuts: "Shortcuts"
        case .recentlyPlayed: "Recently Played"
        case .madeForYou: "Made for You"
        case .artists: "Artists"
        case .recentlyAdded: "Recently Added"
        case .latestSongs: "Latest Songs"
        case .favorites: "Favorite Songs"
        case .playlists: "Playlists"
        case .downloads: "On This iPhone"
        case .streaming: "From Your Server"
        }
    }
}

nonisolated struct HomeSectionConfig: Codable, Hashable, Identifiable, Sendable {
    var section: HomeSection
    var visible: Bool
    var id: String { section.rawValue }
}

nonisolated struct HomeShortcut: Codable, Hashable, Identifiable, Sendable {
    enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
        case shuffleAll, smartShuffle, favorites, downloads, recentlyAdded, station, sleep30, audioLab, openEntry
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shuffleAll: "Shuffle All"
            case .smartShuffle: "Smart Shuffle"
            case .favorites: "Play Favorites"
            case .downloads: "Play Downloads"
            case .recentlyAdded: "Recently Added"
            case .station: "Surprise Station"
            case .sleep30: "Sleep in 30 min"
            case .audioLab: "Sound"
            case .openEntry: "Open…"
            }
        }
        var icon: String {
            switch self {
            case .shuffleAll: "shuffle"
            case .smartShuffle: "sparkles"
            case .favorites: "star.fill"
            case .downloads: "arrow.down.circle.fill"
            case .recentlyAdded: "clock.badge.checkmark"
            case .station: "dot.radiowaves.left.and.right"
            case .sleep30: "moon.zzz.fill"
            case .audioLab: "slider.vertical.3"
            case .openEntry: "arrow.up.right.square"
            }
        }
    }
    var id = UUID()
    var action: Action
    var title: String
    var icon: String
    var entryKind: LibraryEntry.Kind?
    var entryKey: String?
}

@Observable
final class LayoutStore {
    static let shared = LayoutStore()

    var tabs: [TabItemConfig] { didSet { save() } }
    var searchEnabled: Bool { didSet { save() } }
    /// You set up the tab bar yourself: themes no longer replace it (until "Reset" in the tab editor).
    private(set) var tabsCustomized: Bool
    @ObservationIgnored private var adoptingTheme = false
    var homeSections: [HomeSectionConfig] { didSet { save() } }
    var shortcuts: [HomeShortcut] { didSet { save() } }

    /// The tab bar is fixed to Apple Music's: Home, New, Radio, Library, plus Search.
    static let defaultTabs: [TabItemConfig] = AppTheme.appleTabs
    static let defaultSections: [HomeSectionConfig] = HomeSection.allCases.map {
        HomeSectionConfig(section: $0, visible: [.topPicks, .suggested, .recentlyPlayed, .madeForYou, .artists, .recentlyAdded].contains($0))
    }
    static let defaultShortcuts: [HomeShortcut] = [.shuffleAll, .favorites, .smartShuffle, .sleep30].map {
        HomeShortcut(action: $0, title: $0.title, icon: $0.icon)
    }

    private struct Stored: Codable {
        var tabs: [TabItemConfig]
        var searchEnabled: Bool
        var homeSections: [HomeSectionConfig]
        var shortcuts: [HomeShortcut]
        var tabsCustomized: Bool?
    }

    private init() {
        let s = UserDefaults.standard.data(forKey: "layout").flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        // Saved tabs are ignored: the tab bar can no longer be changed.
        self.tabs = Self.defaultTabs
        searchEnabled = true
        tabsCustomized = false
        var sections = s?.homeSections ?? Self.defaultSections
        for d in Self.defaultSections where !sections.contains(where: { $0.section == d.section }) {
            if d.section == .suggested {
                // New for everyone: show it right below Top Picks (it hides itself without a module connection).
                let at = sections.firstIndex { $0.section == .topPicks }.map { $0 + 1 } ?? 0
                sections.insert(HomeSectionConfig(section: .suggested, visible: true), at: at)
            } else {
                sections.append(HomeSectionConfig(section: d.section, visible: false))
            }
        }
        homeSections = sections
        shortcuts = s?.shortcuts ?? Self.defaultShortcuts
    }

    /// Kept for older call sites: the tab bar is fixed, so a theme never replaces it.
    func adoptTabs(of theme: AppTheme) {}

    /// Exactly two tabs plus search keeps Music's own floating "+" and search pills around the bar.
    var usesClassicBar: Bool { false }
    var visibleSections: [HomeSection] { homeSections.filter(\.visible).map(\.section) }

    func resetTabs() {
        tabs = Self.defaultTabs
        searchEnabled = true
        tabsCustomized = false
        save()
    }
    func resetHome() { homeSections = Self.defaultSections; shortcuts = Self.defaultShortcuts }

    private func save() {
        let s = Stored(tabs: tabs, searchEnabled: searchEnabled, homeSections: homeSections, shortcuts: shortcuts, tabsCustomized: tabsCustomized)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: "layout") }
    }
}

// MARK: - Editors

/// One place for each settings row's SF Symbol; swap a name here to change an icon everywhere.
enum SettingSymbol {
    static let sources = "server.rack"
    static let sound = "waveform.path.ecg.rectangle.fill"
    static let library = "shippingbox.fill"
    static let customize = "paintpalette.fill"
    static let lyrics = "quote.bubble.fill"
    static let connections = "link"
    static let colors = "paintbrush.pointed.fill"
    static let font = "textformat"
    static let player = "play.rectangle.fill"
    static let lyricsLook = "text.quote"
    static let appearance = "circle.lefthalf.filled"
    static let startup = "scribble.variable"
    static let lockScreen = "lock.fill"
    static let widgets = "square.grid.2x2.fill"
    static let home = "house.fill"
}

/// The one settings-row icon style: a plain symbol in the primary color (black in Light, white in Dark).
struct SettingIcon: View {
    let symbol: String
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.56, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
    }
}

struct CustomizeView: View {
    /// Pushes Colors straight away (the welcome screens' Customize button).
    var opensColors: Bool = false
    @State private var colorsOpen = false
    @AppStorage("feed.enabled") private var feedOn = true
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @State private var confirmReset = false

    private func row(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            SettingIcon(symbol: symbol)
            Text(title)
        }
    }

    var body: some View {
        List {
            Section {
                SingleThemeCard()
            } header: { Text("Theme") }

            Section {
                Toggle("Apple Music Pages", isOn: $feedOn)
            } header: { Text("Home, New & Radio") } footer: { Text("Apple Music's own Home, New and Radio pages. Songs play through your extensions. Off brings the old pages back.") }

            Section {
                NavigationLink { ColorsSettingsView() } label: { row(SettingSymbol.colors, "Colors") }
                NavigationLink { FontSettingsView() } label: { row(SettingSymbol.font, "Fonts & Icons") }
                NavigationLink { PlayerStyleSettings() } label: { row(SettingSymbol.player, "Player") }
                NavigationLink { LyricsLookSettingsView() } label: { row(SettingSymbol.lyricsLook, "Lyrics") }
                Button("Reset to \(PlayerDesignStore.shared.lookName) defaults", role: .destructive) { confirmReset = true }
            } footer: { Text("Colors, background, blur, glass, corner radius, fonts, player layout and lyrics are edited on top of the \(PlayerDesignStore.shared.lookName) theme.") }

            Section {
                NavigationLink { LockScreenSettingsView() } label: { row(SettingSymbol.lockScreen, "Lock Screen") }
                NavigationLink { WidgetCustomizer() } label: { row(SettingSymbol.widgets, "Widgets") }
                NavigationLink { HomeEditor() } label: { row(SettingSymbol.home, "Home Screen") }
            }
        }
        .navigationTitle("Customize")
        .navigationDestination(isPresented: $colorsOpen) { ColorsSettingsView() }
        .onAppear {
            if opensColors && !colorsOpen {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    colorsOpen = true
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset everything to the \(PlayerDesignStore.shared.lookName) defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { PlayerDesignStore.shared.resetToLookDefaults() }
        }
    }
}

/// Lock Screen settings (moved here from the Settings root).
struct LockScreenSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Fullscreen Artwork", isOn: $settings.lockArtwork)
                if settings.lockArtwork {
                    Picker("Layout", selection: $settings.lockArtLayout) {
                        ForEach(LockArtLayout.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Motion", selection: $settings.lockArtMotion) {
                        ForEach(LockArtMotion.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Live Lyrics", isOn: $settings.liveLyrics)
            } footer: {
                Text("Fullscreen Artwork makes a full-screen cover available. Tap the cover on the Lock Screen to expand it. Framed keeps the whole cover visible on a blurred backdrop. Live Lyrics adds the current line as a Live Activity for songs with synced lyrics — it shares the Dynamic Island with the player.")
            }
        }
        .navigationTitle("Lock Screen")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.lockArtwork) { player.refreshNowPlaying() }
        .onChange(of: settings.lockArtLayout) { player.refreshNowPlaying() }
        .onChange(of: settings.lockArtMotion) { player.refreshNowPlaying() }
        .onChange(of: settings.liveLyrics) { player.refreshNowPlaying() }
    }
}

struct HomeEditor: View {
    @Environment(LayoutStore.self) private var layout
    @State private var addingEntryShortcut = false

    var body: some View {
        @Bindable var layout = layout
        List {
            Section {
                ForEach($layout.homeSections) { $s in
                    Toggle(s.section.title, isOn: $s.visible)
                }
                .onMove { layout.homeSections.move(fromOffsets: $0, toOffset: $1) }
            } header: { Text("Sections") } footer: { Text("Drag to reorder, switch off what you don't need. Suggested for You also decides whether Search suggests songs. Without a connection, Home and Search only show music on this iPhone.") }

            Section {
                ForEach(layout.shortcuts) { s in
                    Label(s.title, systemImage: s.icon)
                }
                .onMove { layout.shortcuts.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { layout.shortcuts.remove(atOffsets: $0) }
                Menu {
                    ForEach(HomeShortcut.Action.allCases.filter { $0 != .openEntry }) { a in
                        Button { layout.shortcuts.append(HomeShortcut(action: a, title: a.title, icon: a.icon)) } label: { Label(a.title, systemImage: a.icon) }
                    }
                    Divider()
                    Button { addingEntryShortcut = true } label: { Label("Playlist, Album or Artist…", systemImage: "arrow.up.right.square") }
                } label: { Label("Add Shortcut", systemImage: "plus") }
            } header: { Text("Shortcuts") } footer: { Text("Shown in the Shortcuts section on Home.") }

            Section { Button("Reset Home Screen") { withAnimation { layout.resetHome() } } }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Home Screen")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addingEntryShortcut) {
            EntryPicker(title: "Add Shortcut") { e in
                layout.shortcuts.append(HomeShortcut(action: .openEntry, title: e.title,
                                                     icon: e.kind == .artist ? "music.mic" : e.kind == .album ? "square.stack.fill" : "music.note.list",
                                                     entryKind: e.kind, entryKey: e.key))
                if let i = layout.homeSections.firstIndex(where: { $0.section == .shortcuts }) { layout.homeSections[i].visible = true }
            }
        }
    }
}

/// Picks a playlist, album or artist.
struct EntryPicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let title: String
    var pick: (LibraryEntry) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                section("Playlists", library.playlistEntries)
                section("Albums", library.albumEntries)
                section("Artists", library.artistEntries)
            }
            .searchable(text: $query)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    @ViewBuilder private func section(_ name: String, _ entries: [LibraryEntry]) -> some View {
        let list = query.isEmpty ? entries : entries.filter { $0.title.localizedCaseInsensitiveContains(query) }
        if !list.isEmpty {
            Section(name) {
                ForEach(list.prefix(200)) { e in
                    Button { pick(e); dismiss() } label: {
                        HStack(spacing: 12) {
                            ArtworkView(entry: e, radius: 6).thumbnail().frame(width: 40, height: 40)
                            Text(e.title).foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }
}
