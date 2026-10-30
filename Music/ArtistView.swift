import SwiftUI

// MARK: - Artist page

/// One artist page for local files, music servers and extension catalogs.
struct ArtistDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(SourceManager.self) private var sources

    let name: String
    @State private var titleShown = false
    @State private var about: AboutInfo?
    @State private var catalogLoader = ArtistCatalogLoader()

    private var request: ArtistCatalogLoader.Request {
        ArtistCatalogLoader.Request(name: name, offline: settings.offlineMode, online: NetworkMonitor.shared.isOnline,
                modules: ModuleStore.shared.enabled.filter { $0.canSearch || $0.canArtist })
    }

    var body: some View {
        let catalog = ArtistCatalog(name: name, knownTracks: library.allTracks, moduleTracks: catalogLoader.moduleTracks)
        content(catalog)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: request) { await catalogLoader.load(request) }
            .task(id: name) {
                about = nil
                let info = await AboutInfo.artist(name, settings: settings)
                guard !Task.isCancelled else { return }
                about = info
            }
            .refreshable {
                guard !settings.offlineMode, NetworkMonitor.shared.isOnline else { return }
                async let extensions: Void = catalogLoader.load(request)
                async let servers: Void = sources.syncAll()
                _ = await (extensions, servers)
            }
    }

    private func content(_ catalog: ArtistCatalog) -> some View {
        let stats = ArtistStats(name: name, library: library)
        let albums = catalog.albums

        return ScrollView {
            LazyVStack(spacing: 30) {
                header(catalog, albums: albums.count, stats: stats)
                if catalogLoader.loading || !sources.syncing.isEmpty {
                    HStack { ProgressView(); Text("Loading songs and albums…").foregroundStyle(.secondary) }
                }
                if !catalogLoader.failedModules.isEmpty {
                    VStack(spacing: 8) {
                        Text("Some songs or albums couldn’t be loaded from \(catalogLoader.failedModules.joined(separator: ", ")).")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Retry") { Task { await catalogLoader.load(request) } }
                            .disabled(catalogLoader.loading)
                    }
                    .padding(.horizontal, 20)
                }
                if stats.plays > 0 { statsCard(stats) }
                if !albums.isEmpty { albumsSection(albums, catalog: catalog) }
                if !stats.topSongs.isEmpty {
                    songsSection(catalog, songs: stats.topSongs, ranked: true)
                }
                if !catalog.tracks.isEmpty {
                    songsSection(catalog, songs: catalog.tracks, ranked: false)
                } else if !catalogLoader.loading && sources.syncing.isEmpty {
                    ContentUnavailableView("No songs found", systemImage: "music.note",
                                           description: Text("No songs by \(name) are available from your sources."))
                }
                if let about { AboutCard(info: about).padding(.horizontal, 20) }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 300 } action: { _, shown in
            withAnimation(.easeOut(duration: 0.2)) { titleShown = shown }
        }
        .navigationTitle(titleShown ? name : "")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ArtistCatalogMenu(catalog: catalog, tracks: catalog.tracks, title: name)
                    if let entry = library.entry(.artist, name) {
                        Divider()
                        Button { library.togglePin(entry) } label: {
                            Label(library.isPinned(entry) ? "Unpin" : "Pin", systemImage: "pin")
                        }
                        Button { library.toggleFavorite(entry) } label: {
                            Label(library.isFavorite(entry) ? "Unfavorite" : "Favorite", systemImage: "star")
                        }
                        ShareLink(item: ShareItem.text(for: entry)) { Label("Share…", systemImage: "square.and.arrow.up") }
                    }
                } label: { Image(systemName: "ellipsis") }
                .disabled(catalog.tracks.isEmpty)
            }
        }
    }

    // MARK: Header

    private func header(_ catalog: ArtistCatalog, albums: Int, stats: ArtistStats) -> some View {
        let entry = catalog.entry
        return VStack(spacing: 14) {
            ArtistCatalogArtwork(entry: entry)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(summary(entry, albums: albums, genre: stats.genre))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { player.play(catalog.resolve(entry.tracks, library: library), title: name, context: .artist) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Button { player.play(catalog.resolve(entry.tracks, library: library), title: name, shuffled: true, context: .artist) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.glass)
            }
            .disabled(entry.tracks.isEmpty)
            .font(.system(size: 17, weight: .semibold))
            .controlSize(.large)
            .tint(Theme.accent)
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { backdrop(entry) }
    }

    /// The artist's cover, blurred into a soft wash behind the header (it reaches up under the navigation bar).
    private func backdrop(_ entry: LibraryEntry) -> some View {
        ArtworkView(tracks: entry.tracks, seed: entry.key, style: .rounded(0))
            .frame(width: 560, height: 560)
            .blur(radius: 70)
            .opacity(0.45)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
            .offset(y: -220)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func summary(_ entry: LibraryEntry, albums: Int, genre: String?) -> String {
        var parts = [songCount(entry.tracks.count)]
        if albums > 0 { parts.append(albums == 1 ? "1 album" : "\(albums) albums") }
        if let genre { parts.append(genre) }
        return parts.joined(separator: " · ")
    }

    // MARK: Your listening

    private func statsCard(_ stats: ArtistStats) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                stat(Text(stats.plays, format: .number), stats.plays == 1 ? "Play" : "Plays")
                Divider().frame(height: 36)
                stat(Text(stats.listenedText), "Listened")
                if let last = stats.lastPlayed {
                    Divider().frame(height: 36)
                    stat(Text(last, format: .relative(presentation: .named, unitsStyle: .abbreviated)), "Last Played")
                }
            }
            if let line = stats.rankLine {
                Text(line)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 20)
    }

    private func stat(_ value: Text, _ label: String) -> some View {
        VStack(spacing: 3) {
            value
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    // MARK: Songs

    private func songsSection(_ catalog: ArtistCatalog, songs: [Track], ranked: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            sectionTitle(ranked ? "Top Songs" : "Songs")
                .padding(.horizontal, 20)
            ForEach(songs) { track in
                ArtistCatalogSongRow(catalog: catalog, track: track, queue: songs, title: name,
                                     subtitle: subtitle(track, ranked: ranked))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
    }

    private func subtitle(_ t: Track, ranked: Bool) -> String {
        let plays = t.playCount ?? 0
        guard ranked, plays > 0 else { return "\(t.album) • \(formatTime(t.duration))" }
        return "\(t.album) • " + (plays == 1 ? "1 play" : "\(plays) plays")
    }

    // MARK: Albums

    private func albumsSection(_ albums: [LibraryEntry], catalog: ArtistCatalog) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(albums.count == 1 ? "Album" : "Albums").padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink {
                            if let saved = library.entry(.album, album.key), Set(saved.tracks.map(\.id)) == Set(album.tracks.map(\.id)) {
                                CollectionDetailView(kind: .album, key: saved.key).themedBackground().clearsMiniPlayer()
                            } else {
                                ArtistCatalogAlbumView(catalog: catalog, album: album).themedBackground().clearsMiniPlayer()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                ArtistCatalogArtwork(entry: album)
                                    .frame(width: 150, height: 150)
                                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(album.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text(albumDetail(album)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 150, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let saved = library.entry(.album, album.key), Set(saved.tracks.map(\.id)) == Set(album.tracks.map(\.id)) {
                                EntryMenuItems(entry: saved)
                            } else {
                                ArtistCatalogMenu(catalog: catalog, tracks: album.tracks, title: album.title, kind: .album)
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    private func albumDetail(_ album: LibraryEntry) -> String {
        let count = songCount(album.tracks.count)
        guard let year = album.tracks.compactMap(\.year).max() else { return count }
        return "\(year) · \(count)"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 22, weight: .bold))
    }
}

// MARK: - Listening stats

/// What you've done with one artist: plays, time, last play, and where they rank among everyone you listen to.
/// Counts songs you only played from modules too (`heard`), since those are listens as well.
private struct ArtistStats {
    var plays = 0
    var seconds = 0.0
    var lastPlayed: Date?
    var topSongs: [Track] = []
    var rank: Int?
    var genre: String?

    init(name: String, library: LibraryStore) {
        var totals: [String: Int] = [:]
        var mine: [Track] = []
        for t in library.allTracks {
            let n = t.playCount ?? 0
            if n > 0 { totals[t.artist, default: 0] += n }
            if ArtistCatalog.matches(t.artist, name: name) || ArtistCatalog.matches(t.albumArtist ?? "", name: name) { mine.append(t) }
        }
        for t in mine {
            let n = t.playCount ?? 0
            plays += n
            seconds += Double(n) * t.duration
            if let d = t.lastPlayed, d > (lastPlayed ?? .distantPast) { lastPlayed = d }
        }
        topSongs = Array(mine.filter { ($0.playCount ?? 0) > 0 }
            .sorted { ($0.playCount ?? 0, $0.lastPlayed ?? .distantPast) > ($1.playCount ?? 0, $1.lastPlayed ?? .distantPast) }
            .prefix(5))
        if plays > 0, totals.count > 1 { rank = totals.values.filter { $0 > plays }.count + 1 }
        let genres = Dictionary(grouping: mine.compactMap(\.genre).filter { !$0.isEmpty }, by: { $0 })
        genre = genres.max { $0.value.count < $1.value.count }?.key
    }

    var listenedText: String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let hours = seconds / 3600
        return hours < 10 ? "\(hours.formatted(.number.precision(.fractionLength(0...1)))) hr" : "\(Int(hours.rounded())) hr"
    }

    var rankLine: String? {
        guard let rank, rank <= 50 else { return nil }
        if rank == 1 { return "Your most played artist" }
        let ordinal = NumberFormatter.localizedString(from: rank as NSNumber, number: .ordinal)
        return "Your \(ordinal) most played artist"
    }
}

// MARK: - All songs

/// Every song by the artist. With a unified library they're grouped by where they come from.
struct ArtistSongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    let name: String

    var body: some View {
        let tracks = ArtistCatalog(name: name, knownTracks: library.allTracks, moduleTracks: []).tracks
        let origins = Set(tracks.map(\.origin))
        List {
            PlayShuffleBar(tracks: tracks, title: name)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            if origins.count > 1 {
                ForEach(TrackOrigin.allCases.filter(origins.contains)) { origin in
                    let list = tracks.filter { $0.origin == origin }
                    Section {
                        ForEach(list) { row($0, in: tracks) }
                    } header: {
                        Label("\(origin.title) · \(list.count)", systemImage: origin.symbol).font(.system(size: 15, weight: .semibold))
                    }
                }
            } else {
                ForEach(tracks) { row($0, in: tracks) }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListHeaderHeight, 0)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ track: Track, in tracks: [Track]) -> some View {
        TrackRow(track: track, subtitle: "\(track.album) • \(formatTime(track.duration))") {
            player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0, title: name)
        }
    }
}

// MARK: - About (Wikipedia)

/// A few lines about an artist or album from Wikipedia, with a photo and the basics (where from, since when).
nonisolated struct AboutInfo: Codable, Sendable {
    var summary: String
    var imageURL: URL?
    var pageURL: URL?
    var facts: [String] = []
}

/// Finds the right Wikipedia page through MusicBrainz and Wikidata, so "Muse" is the band and not the goddesses.
/// Wikipedia comes in the phone's language when there's a page in it, in English otherwise.
nonisolated enum AboutLookup {
    private struct Area: Decodable { let name: String? }
    private struct LifeSpan: Decodable { let begin: String?; let end: String?; let ended: Bool? }
    private struct Artists: Decodable {
        struct Artist: Decodable {
            let id: String; let name: String; let score: Int?; let type: String?
            let area: Area?; let beginArea: Area?; let lifeSpan: LifeSpan?
            enum CodingKeys: String, CodingKey { case id, name, score, type, area; case beginArea = "begin-area"; case lifeSpan = "life-span" }
        }
        let artists: [Artist]?
    }
    private struct Groups: Decodable {
        struct Group: Decodable {
            let id: String; let score: Int?; let primaryType: String?; let firstRelease: String?
            enum CodingKeys: String, CodingKey { case id, score; case primaryType = "primary-type"; case firstRelease = "first-release-date" }
        }
        let releaseGroups: [Group]?
        enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
    }
    private struct Relations: Decodable {
        struct Relation: Decodable { struct Link: Decodable { let resource: String }; let type: String; let url: Link? }
        let relations: [Relation]?
    }
    private struct Sitelinks: Decodable {
        struct Entity: Decodable { struct Link: Decodable { let title: String }; let sitelinks: [String: Link]? }
        let entities: [String: Entity]
    }
    private struct Summary: Decodable {
        struct Image: Decodable { let source: String }
        struct Links: Decodable { struct Page: Decodable { let page: String? }; let mobile: Page? }
        let type: String?; let extract: String?; let thumbnail: Image?
        let contentURLs: Links?
        enum CodingKeys: String, CodingKey { case type, extract, thumbnail; case contentURLs = "content_urls" }
    }

    private static func norm(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber } }

    private static func get(_ url: URL, musicBrainz: Bool = false) async -> Data? {
        if musicBrainz { await MetadataLookup.musicBrainz.wait() }
        var req = URLRequest(url: url)
        // MusicBrainz and Wikimedia both ask clients to say who they are; Wikimedia turns away vague ones with 429.
        req.setValue("\(Brand.name)/1.0 (iOS music player)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func musicBrainz(_ path: String, _ query: [URLQueryItem]) async -> Data? {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)")
        c?.queryItems = query + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = c?.url else { return nil }
        return await get(url, musicBrainz: true)
    }

    private static func year(_ date: String?) -> String? { date.map { String($0.prefix(4)) }.flatMap { $0.count == 4 ? $0 : nil } }

    @concurrent
    static func artist(_ name: String) async -> AboutInfo? {
        guard let data = await musicBrainz("artist/", [URLQueryItem(name: "query", value: "artist:\"\(name)\""), URLQueryItem(name: "limit", value: "5")]),
              let found = try? JSONDecoder().decode(Artists.self, from: data).artists else { return nil }
        let want = norm(name)
        guard let a = found.first(where: { norm($0.name) == want && ($0.score ?? 0) >= 90 }) else { return nil }
        guard var info = await wikipedia(mbPath: "artist/\(a.id)") else { return nil }
        let place = a.beginArea?.name ?? a.area?.name
        let since = year(a.lifeSpan?.begin)
        switch a.type {
        case "Person":
            if let place, let since { info.facts.append("Born \(since) in \(place)") }
            else if let place { info.facts.append("From \(place)") }
        default:
            if let place, let since { info.facts.append("Formed \(since) in \(place)") }
            else if let since { info.facts.append("Since \(since)") }
            else if let place { info.facts.append("From \(place)") }
            if a.lifeSpan?.ended == true, let end = year(a.lifeSpan?.end) { info.facts.append("Split \(end)") }
        }
        return info
    }

    @concurrent
    static func album(artist: String, album: String) async -> AboutInfo? {
        guard let data = await musicBrainz("release-group/", [URLQueryItem(name: "query", value: "releasegroup:\"\(album)\" AND artist:\"\(artist)\""),
                                                              URLQueryItem(name: "limit", value: "5")]),
              let groups = try? JSONDecoder().decode(Groups.self, from: data).releaseGroups?.filter({ ($0.score ?? 0) >= 90 }),
              // A single often shares the album's name; the album is the one meant.
              let g = groups.first(where: { $0.primaryType == "Album" }) ?? groups.first,
              var info = await wikipedia(mbPath: "release-group/\(g.id)") else { return nil }
        info.imageURL = nil  // the cover is already on the page
        info.facts = [g.primaryType, year(g.firstRelease)].compactMap { $0 }
        return info
    }

    /// MusicBrainz entity → its Wikidata item → the Wikipedia article's summary.
    private static func wikipedia(mbPath: String) async -> AboutInfo? {
        guard let data = await musicBrainz(mbPath, [URLQueryItem(name: "inc", value: "url-rels")]),
              let rels = try? JSONDecoder().decode(Relations.self, from: data).relations,
              let item = rels.first(where: { $0.type == "wikidata" })?.url?.resource.split(separator: "/").last.map(String.init) else { return nil }

        var langs: [String] = []
        for l in Locale.preferredLanguages.compactMap({ Locale(identifier: $0).language.languageCode?.identifier }) + ["en"] where !langs.contains(l) { langs.append(l) }
        var c = URLComponents(string: "https://www.wikidata.org/w/api.php")
        c?.queryItems = [URLQueryItem(name: "action", value: "wbgetentities"), URLQueryItem(name: "ids", value: item),
                         URLQueryItem(name: "props", value: "sitelinks"), URLQueryItem(name: "sitefilter", value: langs.map { $0 + "wiki" }.joined(separator: "|")),
                         URLQueryItem(name: "format", value: "json")]
        guard let url = c?.url, let data = await get(url),
              let links = try? JSONDecoder().decode(Sitelinks.self, from: data).entities[item]?.sitelinks,
              let lang = langs.first(where: { links[$0 + "wiki"] != nil }), let title = links[lang + "wiki"]?.title else { return nil }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)"), let data = await get(url),
              let s = try? JSONDecoder().decode(Summary.self, from: data), s.type != "disambiguation",
              let text = s.extract?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // The summary's thumbnail is 330 px wide; Wikimedia also serves 500 px, enough for the round photo at 3×.
        let image = s.thumbnail.map { $0.source.replacingOccurrences(of: #"/\d+px-"#, with: "/500px-", options: .regularExpression) }
        return AboutInfo(summary: text, imageURL: image.flatMap(URL.init(string:)),
                         pageURL: s.contentURLs?.mobile?.page.flatMap(URL.init(string:)))
    }
}

extension AboutInfo {
    /// Remembered on disk like the other lookups; nil when online lookups are off or there's no connection.
    @MainActor static func artist(_ name: String, settings: AppSettings) async -> AboutInfo? {
        guard settings.onlineLookups, !settings.offlineMode, NetworkMonitor.shared.isOnline,
              !name.isEmpty, name != "Unknown Artist" else { return nil }
        let key = "about|artist|" + name.lowercased()
        return await LookupCache.shared.value(key) { await AboutLookup.artist(name) }
    }

    @MainActor static func album(artist: String, album: String, settings: AppSettings) async -> AboutInfo? {
        guard settings.onlineLookups, !settings.offlineMode, NetworkMonitor.shared.isOnline,
              !artist.isEmpty, artist != "Unknown Artist", !album.isEmpty else { return nil }
        let key = "about|album|" + artist.lowercased() + "|" + album.lowercased()
        return await LookupCache.shared.value(key) { await AboutLookup.album(artist: artist, album: album) }
    }
}

/// The "About" block: the basics, a few lines that open up on tap, and where it's from.
struct AboutCard: View {
    let info: AboutInfo
    var title = "About"
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 22, weight: .bold))
            VStack(alignment: .leading, spacing: 10) {
                if !info.facts.isEmpty {
                    Text(info.facts.joined(separator: " · "))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(info.summary)
                    .font(.system(size: 15))
                    .lineSpacing(2)
                    .lineLimit(expanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(expanded ? "Less" : "More").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                    Spacer()
                    if let page = info.pageURL {
                        Link(destination: page) {
                            Label("Wikipedia", systemImage: "arrow.up.right").labelStyle(TrailingIconLabel())
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.smooth(duration: 0.3)) { expanded.toggle() } }
        }
    }

    private struct TrailingIconLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 3) { configuration.title; configuration.icon.imageScale(.small) }
        }
    }
}
