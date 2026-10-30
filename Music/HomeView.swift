import SwiftUI

/// Apple-Music-style Home: Top Picks, Recently Played, Made for You mixes, Artists, Recently Added.
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(MixService.self) private var mixService
    @Environment(LayoutStore.self) private var layout
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads

    private var day: String { Date().formatted(.iso8601.year().month().day()) }

    /// Online with Offline Mode off. Without it, Home only shows music on this iPhone.
    private var connected: Bool { NetworkMonitor.shared.isOnline && !settings.offlineMode }
    private func playable(_ t: Track) -> Bool { connected || t.isOffline }

    // Shelves are kept until the library changes: Home re-renders on every song change and would
    // otherwise filter and sort the whole library several times each time.
    private var recentlyPlayed: [Track] {
        let connected = connected
        return library.memo("home.recentlyPlayed|\(connected)") {
            let played = library.allTracks.filter { $0.lastPlayed != nil && (connected || $0.isOffline) }.sorted { $0.lastPlayed! > $1.lastPlayed! }
            return Array(played.prefix(12))
        }
    }

    private var recentlyAdded: [LibraryEntry] {
        let all = library.albumsByRecent
        if connected { return all }
        return library.memo("home.recentlyAdded.offline") { all.filter { $0.tracks.contains(where: \.isOffline) } }
    }

    private var favoriteSongs: [Track] {
        let connected = connected
        return library.memo("home.favorites|\(connected)") { library.tracks.filter { $0.isFavorite && (connected || $0.isOffline) } }
    }

    private var onThisIPhone: [Track] {
        library.memo("home.downloads") { library.tracks.filter(\.isOffline).sorted { $0.addedAt > $1.addedAt } }
    }

    /// Offline, "On This iPhone" and "Recently Added" would show the same music — keep only the first one.
    private var showsRecentlyAdded: Bool { connected || !layout.visibleSections.contains(.downloads) }

    private var suggested: [ModuleTrack] {
        guard connected else { return [] }
        return Array(library.newToYou(ModuleStore.shared.suggestions.flatMap(\.tracks)).prefix(20))
    }

    /// AI-curated (or fallback) mixes with their resolved songs.
    private var mixes: [(mix: SavedMix, tracks: [Track])] {
        guard library.tracks.count >= LibraryStore.mixThreshold else { return [] }
        return mixService.mixes.compactMap { m in
            let t = library.tracks(for: m.trackIDs)
            return t.count >= 4 ? (m, t) : nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 38) {
                if library.tracks.isEmpty {
                    EmptyLibraryCard().padding(.horizontal, 20)
                } else {
                    ForEach(layout.visibleSections) { section in
                        switch section {
                        case .topPicks: topPicks
                        case .suggested: if !suggested.isEmpty { suggestedShelf }
                        case .shortcuts: if !layout.shortcuts.isEmpty { shortcutsGrid }
                        case .recentlyPlayed: if !recentlyPlayed.isEmpty { recentlyPlayedShelf }
                        case .madeForYou: if !mixes.isEmpty { madeForYou }
                        case .artists: if library.artistEntries.count > 0 { artistsShelf }
                        case .recentlyAdded: if showsRecentlyAdded && !recentlyAdded.isEmpty { recentlyAddedShelf }
                        case .latestSongs: latestSongsShelf
                        case .favorites: trackShelf("Favorite Songs", favoriteSongs, route: .favorites)
                        case .playlists: entryShelf("Playlists", library.playlistEntries, route: .playlists)
                        case .downloads: trackShelf("On This iPhone", onThisIPhone, route: .downloads)
                        case .streaming:
                            if connected { entryShelf("From Your Server", recentlyAdded.filter { $0.tracks.contains(where: \.isRemote) }, route: .albums) }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .trackScroll()
        .task(id: library.tracks.count / 10) { await mixService.refresh() }
        .task(id: connected) {
            guard connected, layout.visibleSections.contains(.suggested) else { return }
            await ModuleStore.shared.refreshSuggestions(seeds: Array(library.mostPlayed.prefix(10)))
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.showSettings = true } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Settings")
            }
        }
    }

    // MARK: Top Picks

    private var topPicks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: 14)
            sectionTitle("Top Picks for You")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(mixes.prefix(2)), id: \.mix.id) { entry in
                        pick(eyebrow: "Made for You", title: entry.mix.name, subtitle: entry.mix.vibe,
                             art: MixArt(tracks: entry.tracks, seed: entry.mix.name)) {
                            player.play(entry.tracks, title: entry.mix.name)
                        }
                    }
                    if let artist = library.artistEntries.max(by: { $0.tracks.count < $1.tracks.count }) {
                        pick(eyebrow: "Station", title: "\(artist.title) & Similar",
                             subtitle: "Endless music, starting with \(artist.title)",
                             art: ArtworkView(tracks: artist.tracks, seed: artist.key, style: .rounded(20), mosaic: artist.tracks.count > 1)) {
                            if let seed = artist.tracks.first { player.startRadio(from: seed) }
                        }
                    }
                    if showsRecentlyAdded, let album = recentlyAdded.first {
                        pick(eyebrow: "Recently Added", title: album.title, subtitle: album.subtitle,
                             art: ArtworkView(entry: album, radius: 20)) {
                            player.play(album)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private func pick(eyebrow: String, title: String, subtitle: String, art: some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(eyebrow.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 20, weight: .regular)).lineLimit(1)
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                }
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { art.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .padding(14)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .containerRelativeFrame(.horizontal) { w, _ in w - 64 }
    }

    // MARK: Shelves

    /// Songs from modules, like the ones you play most. Playing one doesn't add it to the library.
    private var suggestedShelf: some View {
        let list = suggested
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Suggested for You")
            shelfScroll {
                ForEach(list) { m in
                    Button {
                        let start = list.firstIndex(of: m) ?? 0
                        player.play(library.addModuleTracks(list), startAt: start, title: "Suggested for You")
                    } label: {
                        caption(AsyncImage(url: m.cover.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: {
                            GeneratedCover(spec: CoverKit.auto(m.album + m.artist))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12 * ThemeStore.shared.current.cornerScale, style: .continuous)), m.title, m.artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { _ = library.addModuleTrack(m, keep: true) } label: { Label("Add to Library", systemImage: "plus") }
                        Button { downloads.download([library.addModuleTrack(m, keep: true)]) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    }
                }
            }
        }
    }

    private var recentlyPlayedShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Recently Played")
            shelfScroll {
                ForEach(recentlyPlayed) { t in
                    Button {
                        player.play(recentlyPlayed, startAt: recentlyPlayed.firstIndex(of: t) ?? 0, title: "Recently Played")
                    } label: {
                        caption(ArtworkView(track: t, radius: 12).thumbnail(460), t.title, t.artist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var madeForYou: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Made for You")
            shelfScroll {
                ForEach(mixes, id: \.mix.id) { entry in
                    Button { player.play(entry.tracks, title: entry.mix.name) } label: {
                        caption(MixArt(tracks: entry.tracks, seed: entry.mix.name), entry.mix.name, entry.mix.vibe)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var artistsShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Artists", route: .artists)
            shelfScroll {
                ForEach(library.artistEntries) { artist in
                    NavigationLink(value: artist.route) {
                        VStack(spacing: 8) {
                            ArtworkView(entry: artist).thumbnail(400).frame(width: 128, height: 128)
                            Text(artist.title).font(.system(size: 14, weight: .medium)).lineLimit(1).frame(width: 128)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var latestSongsShelf: some View {
        let latest: [Track] = library.memo("home.latestSongs") { Array(library.tracks.sorted { $0.addedAt > $1.addedAt }.prefix(100)) }
        return Group {
            if !latest.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Latest Songs", route: .songs)
                    HStack(spacing: 12) {
                        Button { player.play(latest, startAt: 0, title: "Latest Songs") } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { player.play(latest.shuffled(), startAt: 0, title: "Latest Songs") } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 20)
                    LazyVStack(spacing: 0) {
                        ForEach(latest.prefix(30)) { t in
                            TrackRow(track: t) { player.play(latest, startAt: latest.firstIndex(of: t) ?? 0, title: "Latest Songs") }
                                .padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private var recentlyAddedShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Recently Added", route: .albums)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                ForEach(recentlyAdded.prefix(6)) { album in
                    NavigationLink(value: album.route) {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(entry: album, radius: 12)
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                            Text(album.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text(album.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: Customizable sections

    private var shortcutsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Shortcuts")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(layout.shortcuts) { sc in
                    Button { run(sc) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: sc.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 22)
                            Text(sc.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .glassEffect(ThemeStore.shared.glass.interactive(), in: RoundedRectangle(cornerRadius: 16 * ThemeStore.shared.current.cornerScale, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.impact(weight: .light), trigger: player.queueTitle)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func run(_ sc: HomeShortcut) {
        switch sc.action {
        case .shuffleAll: player.play(library.tracks, title: "All Songs", shuffled: true)
        case .smartShuffle: player.play(SmartShuffle.order(library.tracks, options: .init(familiarity: settings.shuffleFamiliarity)), title: "Smart Shuffle")
        case .favorites: player.play(library.tracks.filter(\.isFavorite), title: "Favorites", shuffled: true)
        case .downloads: player.play(library.tracks.filter(\.isOffline), title: "On This iPhone", shuffled: true)
        case .recentlyAdded: player.play(Array(library.tracks.filter(playable).sorted { $0.addedAt > $1.addedAt }.prefix(50)), title: "Recently Added")
        case .station: if let seed = library.tracks.randomElement() { player.startStation(from: seed) }
        case .sleep30: player.setSleepTimer(minutes: 30)
        case .audioLab: router.open(.audioLab)
        case .openEntry:
            if let k = sc.entryKind, let key = sc.entryKey, let e = library.entry(k, key) { router.open(e.route) }
        }
    }

    @ViewBuilder private func trackShelf(_ title: String, _ tracks: [Track], route: Route) -> some View {
        if !tracks.isEmpty {
            let list = Array(tracks.prefix(20))
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(title, route: route)
                shelfScroll {
                    ForEach(list) { t in
                        Button { player.play(list, startAt: list.firstIndex(of: t) ?? 0, title: title) } label: {
                            caption(ArtworkView(track: t, radius: 12).thumbnail(460), t.title, t.artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private func entryShelf(_ title: String, _ entries: [LibraryEntry], route: Route) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(title, route: route)
                shelfScroll {
                    ForEach(entries.prefix(20)) { e in
                        NavigationLink(value: e.route) { caption(ArtworkView(entry: e, radius: 12).thumbnail(460), e.title, e.subtitle) }
                            .buttonStyle(.plain)
                            .contextMenu { EntryMenuItems(entry: e) }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    @ViewBuilder private func sectionTitle(_ title: String, route: Route? = nil) -> some View {
        if let route {
            NavigationLink(value: route) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        } else {
            Text(title).font(.system(size: 22, weight: .bold)).padding(.horizontal, 20)
        }
    }

    private func shelfScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) { content() }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
    }

    private func caption(_ art: some View, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            art.frame(width: 150, height: 150)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// Mix cover: a plain 2x2 mosaic of the real album covers, no decoration.
struct MixArt: View {
    let tracks: [Track]
    let seed: String

    var body: some View {
        let distinct = Dictionary(grouping: tracks, by: { $0.album + $0.artist }).values.compactMap(\.first)
        ArtworkView(tracks: Array(distinct.prefix(4)) + tracks, seed: seed, style: .rounded(14), mosaic: true)
    }
}
