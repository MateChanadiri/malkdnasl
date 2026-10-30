import SwiftUI
import Observation

// MARK: - Models

nonisolated struct FeedItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case song, album, playlist, station, artist, video, other }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var art: String?
    var rank: Int?

    /// Artwork URLs from Apple carry `{w}x{h}` placeholders.
    func artURL(_ px: Int) -> URL? {
        guard let art else { return nil }
        let s = art.replacingOccurrences(of: "{w}", with: "\(px)").replacingOccurrences(of: "{h}", with: "\(px)")
            .replacingOccurrences(of: "{f}", with: "jpg").replacingOccurrences(of: "{c}", with: "bb")
        return URL(string: s)
    }

    /// What to search for in the extensions when this is played.
    var searchQuery: String {
        switch kind {
        case .song, .video: return subtitle.isEmpty ? title : "\(subtitle) \(title)"
        default: return seedQuery
        }
    }

    /// "Deftones & Similar Artists" → "Deftones", "Classic Hits Station" → "Classic Hits".
    var seedQuery: String {
        var s = title
        for suffix in [" Station", " Radio Station", " Radio", " Mix"] where s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        if let r = s.range(of: " & Similar") { s = String(s[..<r.lowerBound]) }
        return s
    }
}

nonisolated struct FeedShelf: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var items: [FeedItem]
    var isRound: Bool { !items.isEmpty && items.allSatisfy { $0.kind == .artist } }
    var isSongs: Bool { !items.isEmpty && items.allSatisfy { $0.kind == .song } }
}

nonisolated struct FeedStorefront: Hashable, Sendable, Identifiable {
    var code: String
    var name: String
    var id: String { code }
    var flag: String {
        let base: UInt32 = 127397
        return code.uppercased().unicodeScalars.compactMap { UnicodeScalar(base + $0.value) }.map { String($0) }.joined()
    }
    static let all: [FeedStorefront] = [
        ("us", "United States"), ("gb", "United Kingdom"), ("ge", "Georgia"), ("de", "Germany"), ("fr", "France"), ("it", "Italy"),
        ("es", "Spain"), ("nl", "Netherlands"), ("se", "Sweden"), ("pl", "Poland"), ("ua", "Ukraine"), ("tr", "Türkiye"),
        ("am", "Armenia"), ("az", "Azerbaijan"), ("kz", "Kazakhstan"), ("ru", "Russia"), ("ca", "Canada"), ("mx", "Mexico"),
        ("br", "Brazil"), ("ar", "Argentina"), ("au", "Australia"), ("nz", "New Zealand"), ("jp", "Japan"), ("kr", "South Korea"),
        ("in", "India"), ("id", "Indonesia"), ("ph", "Philippines"), ("sa", "Saudi Arabia"), ("ae", "United Arab Emirates"),
        ("eg", "Egypt"), ("za", "South Africa"), ("ng", "Nigeria"), ("ie", "Ireland"), ("pt", "Portugal"), ("ch", "Switzerland")
    ].map { FeedStorefront(code: $0.0, name: $0.1) }
    static func named(_ code: String) -> FeedStorefront { all.first { $0.code == code } ?? FeedStorefront(code: code, name: code.uppercased()) }
    static var deviceDefault: String {
        let c = (Locale.current.region?.identifier ?? "US").lowercased()
        return all.contains { $0.code == c } ? c : "us"
    }
}

// MARK: - Apple's public catalogue (the same one music.apple.com shows)

nonisolated enum AppleFeedAPI {
    private static let tokenKey = "feed.token"
    private static let tokenDateKey = "feed.tokenDate"

    private static func fetch(_ url: URL, headers: [String: String] = [:]) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// The anonymous developer token music.apple.com itself uses. Found once, kept for a day.
    static func token(refresh: Bool = false) async -> String? {
        let d = UserDefaults.standard
        if !refresh, let t = d.string(forKey: tokenKey), let at = d.object(forKey: tokenDateKey) as? Date, Date().timeIntervalSince(at) < 86_400 { return t }
        guard let page = URL(string: "https://music.apple.com/us/browse"), let html = await fetch(page).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        var scripts: [String] = []
        var rest = Substring(html)
        while let r = rest.range(of: "/assets/") {
            let tail = rest[r.lowerBound...]
            guard let end = tail.range(of: ".js") else { break }
            scripts.append(String(tail[..<end.upperBound]))
            rest = tail[end.upperBound...]
        }
        for path in scripts.prefix(8) {
            guard let url = URL(string: "https://music.apple.com" + path), let js = await fetch(url).flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
            if let r = js.range(of: #"eyJh[A-Za-z0-9_\-\.]{80,}"#, options: .regularExpression) {
                let t = String(js[r])
                d.set(t, forKey: tokenKey)
                d.set(Date(), forKey: tokenDateKey)
                return t
            }
        }
        return nil
    }

    static func get(_ path: String, _ query: [String: String] = [:]) async -> [String: Any]? {
        for attempt in 0..<2 {
            guard let token = await token(refresh: attempt == 1) else { return nil }
            var c = URLComponents(string: "https://amp-api.music.apple.com" + path)
            var items: [URLQueryItem] = [URLQueryItem(name: "l", value: "en-US")]
            for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
            c?.queryItems = items
            guard let url = c?.url else { return nil }
            let headers: [String: String] = ["Authorization": "Bearer \(token)", "Origin": "https://music.apple.com", "Referer": "https://music.apple.com/"]
            if let data = await fetch(url, headers: headers), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return obj }
        }
        return nil
    }

    // MARK: Parsing

    private static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    private static func list(_ v: Any?) -> [[String: Any]] { (v as? [[String: Any]]) ?? [] }

    private static func artwork(_ attrs: [String: Any]?, _ rel: [String: Any]?) -> String? {
        if let a = dict(attrs?["artwork"]), let u = a["url"] as? String { return u }
        if let e = dict(attrs?["editorialArtwork"]) {
            for key in ["staticDetailSquare", "subscriptionCover", "storeFlowcase", "staticDetailTall", "superHeroWide"] {
                if let a = dict(e[key]), let u = a["url"] as? String { return u }
            }
        }
        if let first = list(dict(dict(rel?["contents"]))?["data"]).first { return artwork(dict(first["attributes"]), dict(first["relationships"])) }
        return nil
    }

    static func item(_ raw: [String: Any]) -> FeedItem? {
        guard let type = raw["type"] as? String else { return nil }
        let attrs = dict(raw["attributes"])
        let id = (raw["id"] as? String) ?? UUID().uuidString
        let name = (attrs?["name"] as? String) ?? (dict(attrs?["title"])?["stringForDisplay"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let kind: FeedItem.Kind
        var sub = ""
        switch type {
        case "songs": kind = .song; sub = (attrs?["artistName"] as? String) ?? ""
        case "albums": kind = .album; sub = (attrs?["artistName"] as? String) ?? ""
        case "playlists": kind = .playlist; sub = (attrs?["curatorName"] as? String) ?? (attrs?["artistName"] as? String) ?? ""
        case "stations": kind = .station; sub = (attrs?["stationProviderName"] as? String) ?? ""
        case "artists": kind = .artist
        case "music-videos": kind = .video; sub = (attrs?["artistName"] as? String) ?? ""
        case "apple-curators", "curators": kind = .other; sub = "Curator"
        default: kind = .other
        }
        if sub.isEmpty, let g = (attrs?["genreNames"] as? [String])?.first { sub = g }
        return FeedItem(id: id, kind: kind, title: name, subtitle: sub, art: artwork(attrs, dict(raw["relationships"])), rank: nil)
    }

    /// Flattens one grouping shelf (and any editorial cards nested in it) into items.
    private static func items(from contents: [[String: Any]]) -> [FeedItem] {
        var out: [FeedItem] = []
        for raw in contents {
            if let it = item(raw), it.kind != .other { out.append(it); continue }
            let nested = list(dict(dict(raw["relationships"])?["contents"])?["data"])
            if !nested.isEmpty { out.append(contentsOf: items(from: nested)) }
        }
        return out
    }

    /// `name`: "new", "radio" or "music" (Browse) — the page sections music.apple.com builds those screens from.
    static func grouping(_ name: String, storefront: String) async -> [FeedShelf] {
        let q: [String: String] = ["platform": "web", "name": name, "extend": "editorialArtwork,artistUrl,subscriptionHero",
                                   "art[url]": "f", "omit[resource]": "autos"]
        guard let root = await get("/v1/editorial/\(storefront)/groupings", q) else { return [] }
        var shelves: [FeedShelf] = []
        for g in list(root["data"]) {
            let tabs = list(dict(dict(g["relationships"])?["tabs"])?["data"])
            for tab in tabs {
                let children = list(dict(dict(tab["relationships"])?["children"])?["data"])
                for (i, child) in children.enumerated() {
                    let attrs = dict(child["attributes"])
                    let title = (dict(attrs?["title"])?["stringForDisplay"] as? String) ?? (attrs?["title"] as? String) ?? ""
                    let contents = list(dict(dict(child["relationships"])?["contents"])?["data"])
                    let found = items(from: contents)
                    if found.isEmpty { continue }
                    let sub = (dict(attrs?["subtitle"])?["stringForDisplay"] as? String) ?? (attrs?["subtitle"] as? String)
                    shelves.append(FeedShelf(id: "\(name).\(i).\(title)", title: title.isEmpty ? (found.first?.title ?? "Featured") : title,
                                             subtitle: sub, items: Array(found.prefix(30))))
                }
            }
        }
        return shelves
    }

    static func charts(storefront: String, global: Bool) async -> [FeedShelf] {
        let types = "songs,albums,playlists,city-charts,daily-global-top-charts"
        guard let root = await get("/v1/catalog/\(storefront)/charts", ["types": types, "limit": "25"]),
              let results = dict(root["results"]) else { return [] }
        var shelves: [FeedShelf] = []
        func add(_ key: String, _ title: String, _ sub: String?, numbered: Bool = false) {
            for (n, chart) in list(results[key]).enumerated() {
                var its = items(from: list(chart["data"]))
                if numbered { its = its.enumerated().map { var i = $0.element; i.rank = $0.offset + 1; return i } }
                if its.isEmpty { continue }
                let t = (chart["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
                shelves.append(FeedShelf(id: "charts.\(key).\(n)", title: t, subtitle: sub, items: its))
            }
        }
        add("songs", "Trending Songs", "Most played right now", numbered: true)
        add("daily-global-top-charts", "Top 100: Global", "Updated daily")
        add("playlists", "Top Playlists", "The playlists everyone's on")
        add("city-charts", "City Charts", "Live top 25, city by city")
        add("albums", "Top Albums", "Biggest albums this week")
        return shelves
    }

    static func genres(storefront: String) async -> [FeedItem] {
        guard let root = await get("/v1/catalog/\(storefront)/genres") else { return [] }
        return list(root["data"]).compactMap { g in
            guard let n = dict(g["attributes"])?["name"] as? String, n != "Music" else { return nil }
            return FeedItem(id: (g["id"] as? String) ?? n, kind: .station, title: n, subtitle: "Mix station", art: nil, rank: nil)
        }
    }

    static func radio(storefront: String) async -> [FeedShelf] {
        let page = await grouping("radio", storefront: storefront)
        if !page.isEmpty { return page }
        guard let root = await get("/v1/catalog/\(storefront)/stations", ["filter[featured]": "apple-music-live-radio", "limit": "20"]) else { return [] }
        let live = list(root["data"]).compactMap { item($0) }
        var shelves: [FeedShelf] = []
        if !live.isEmpty { shelves.append(FeedShelf(id: "radio.live", title: "On Air Now", subtitle: nil, items: live)) }
        let g = await genres(storefront: storefront)
        if !g.isEmpty { shelves.append(FeedShelf(id: "radio.genres", title: "Stations by Genre", subtitle: nil, items: g)) }
        return shelves
    }

    /// Songs of an album or playlist.
    static func tracks(kind: FeedItem.Kind, id: String, storefront: String) async -> [FeedItem] {
        let type = kind == .album ? "albums" : "playlists"
        guard let root = await get("/v1/catalog/\(storefront)/\(type)/\(id)", ["include": "tracks", "extend": "artistUrl"]),
              let first = list(root["data"]).first else { return [] }
        let tr = list(dict(dict(first["relationships"])?["tracks"])?["data"])
        var out: [FeedItem] = []
        let albumArt = artwork(dict(first["attributes"]), nil)
        for (i, t) in tr.enumerated() {
            guard var it = item(t) else { continue }
            if it.art == nil { it.art = albumArt }
            it.rank = i + 1
            out.append(it)
        }
        return out
    }
}

// MARK: - Store (one load per page, kept for a while)

@MainActor @Observable
final class AppleFeedStore {
    static let shared = AppleFeedStore()
    var home: [FeedShelf] = []
    var new: [FeedShelf] = []
    var radio: [FeedShelf] = []
    var loading: Set<String> = []
    private var loaded: [String: Date] = [:]

    var storefront: String {
        get { UserDefaults.standard.string(forKey: "feed.storefront") ?? FeedStorefront.deviceDefault }
        set { UserDefaults.standard.set(newValue, forKey: "feed.storefront") }
    }
    var global: Bool {
        get { UserDefaults.standard.object(forKey: "feed.global") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "feed.global") }
    }

    func reload(force: Bool = false) async {
        await load("home", force: force)
        await load("new", force: force)
        await load("radio", force: force)
    }

    func load(_ page: String, force: Bool = false) async {
        let key = "\(page).\(storefront).\(global)"
        if !force, let d = loaded[key], Date().timeIntervalSince(d) < 900 { return }
        guard !loading.contains(page) else { return }
        loading.insert(page)
        defer { loading.remove(page) }
        let sf = global ? "us" : storefront
        switch page {
        case "home":
            async let charts = AppleFeedAPI.charts(storefront: sf, global: global)
            async let genres = AppleFeedAPI.genres(storefront: sf)
            let c = await charts
            let g = await genres
            var shelves = c
            if !g.isEmpty { shelves.append(FeedShelf(id: "home.genres", title: "Browse moods & genres", subtitle: nil, items: g)) }
            if !shelves.isEmpty { home = shelves; loaded[key] = Date() }
        case "new":
            let s = await AppleFeedAPI.grouping("new", storefront: sf)
            if !s.isEmpty { new = s; loaded[key] = Date() }
        default:
            let s = await AppleFeedAPI.radio(storefront: sf)
            if !s.isEmpty { radio = s; loaded[key] = Date() }
        }
    }
}

// MARK: - Playing a catalogue item through the extensions

@MainActor
enum FeedPlayer {
    private static func norm(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber } }

    static func resolve(_ item: FeedItem) async -> ModuleTrack? {
        var best: ModuleTrack?
        let wantTitle = norm(item.title)
        let wantArtist = norm(item.subtitle)
        for m in ModuleStore.shared.enabled where m.canSearch {
            guard let found = try? await ModuleStore.shared.searchTracks(m, item.searchQuery, limit: 8), !found.isEmpty else { continue }
            let exact = found.first { norm($0.title) == wantTitle && (wantArtist.isEmpty || norm($0.artist).contains(wantArtist) || wantArtist.contains(norm($0.artist))) }
            if let exact { return exact }
            if best == nil { best = found.first { norm($0.title).contains(wantTitle) || wantTitle.contains(norm($0.title)) } ?? found.first }
        }
        return best
    }

    /// Plays the tapped song right away, then queues the songs after it as they are found.
    static func play(_ items: [FeedItem], start: Int, title: String, library: LibraryStore, player: PlayerModel) {
        guard items.indices.contains(start) else { return }
        Task {
            guard let first = await resolve(items[start]) else { return }
            player.play(library.addModuleTracks([first]), title: title)
            var rest: [ModuleTrack] = []
            for it in items[(start + 1)...].prefix(14) {
                if let t = await resolve(it) { rest.append(t) }
            }
            if !rest.isEmpty { player.playNext(library.addModuleTracks(rest)) }
        }
    }
}

// MARK: - Views

/// A horizontal shelf: squares, circles or pages of song rows.
struct FeedShelfView: View {
    let shelf: FeedShelf
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.title).font(.system(size: 22, weight: .bold))
                if let s = shelf.subtitle, !s.isEmpty { Text(s).font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 20)
            if shelf.isSongs { songPages } else { cards }
        }
    }

    private var cards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(shelf.items) { it in card(it) }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder private func card(_ it: FeedItem) -> some View {
        let w: CGFloat = shelf.isRound ? 96 : 150
        if it.kind == .song || it.kind == .video {
            Button { FeedPlayer.play(shelf.items, start: shelf.items.firstIndex(of: it) ?? 0, title: shelf.title, library: library, player: player) } label: { cardLabel(it, w) }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: Route.feed(it)) { cardLabel(it, w) }.buttonStyle(.plain)
        }
    }

    private func cardLabel(_ it: FeedItem, _ w: CGFloat) -> some View {
        VStack(alignment: shelf.isRound ? .center : .leading, spacing: 6) {
            FeedArt(item: it, size: w)
                .clipShape(shelf.isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
            Text(it.title).font(.system(size: 14, weight: .medium)).lineLimit(1).foregroundStyle(.primary)
            if !shelf.isRound {
                Text(it.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: w, alignment: shelf.isRound ? .center : .leading)
    }

    private var songPages: some View {
        let pages: [[FeedItem]] = stride(from: 0, to: shelf.items.count, by: 4).map { Array(shelf.items[$0..<min($0 + 4, shelf.items.count)]) }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(pages.enumerated()), id: \.offset) { _, page in
                    VStack(spacing: 0) {
                        ForEach(page) { it in
                            FeedSongRow(item: it, number: it.rank) {
                                FeedPlayer.play(shelf.items, start: shelf.items.firstIndex(of: it) ?? 0, title: shelf.title, library: library, player: player)
                            }
                        }
                    }
                    .frame(width: UIScreen.main.bounds.width - 56)
                }
            }
            .padding(.horizontal, 20)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

struct FeedArt: View {
    let item: FeedItem
    var size: CGFloat
    var body: some View {
        AsyncImage(url: item.artURL(Int(size * 3))) { phase in
            if let img = phase.image { img.resizable().scaledToFill() }
            else { GeneratedCover(spec: CoverKit.auto(item.title + item.subtitle)) }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

struct FeedSongRow: View {
    let item: FeedItem
    var number: Int?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                FeedArt(item: item, size: 48).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 16, weight: .medium)).lineLimit(1).foregroundStyle(.primary)
                    Text(item.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Where a tapped card goes: an album or playlist page, or a station of songs from your extensions.
struct FeedDestination: View {
    let item: FeedItem
    var body: some View {
        switch item.kind {
        case .album, .playlist: FeedCollectionView(item: item)
        default: NonStopStationView(name: item.title, query: item.seedQuery)
        }
    }
}

struct FeedCollectionView: View {
    let item: FeedItem
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var songs: [FeedItem] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 10) {
                    FeedArt(item: item, size: 240).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    Text(item.title).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
                    Text(item.subtitle).font(.system(size: 16)).foregroundStyle(.secondary)
                    if !songs.isEmpty {
                        HStack(spacing: 12) {
                            Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent)
                            Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                ForEach(songs) { s in
                    FeedSongRow(item: s, number: s.rank) {
                        FeedPlayer.play(songs, start: songs.firstIndex(of: s) ?? 0, title: item.title, library: library, player: player)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 20)
        }
        .overlay {
            if loading { ProgressView() }
            else if songs.isEmpty { ContentUnavailableView("Couldn't Load", systemImage: "wifi.slash") }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let sf = AppleFeedStore.shared.storefront
            songs = await AppleFeedAPI.tracks(kind: item.kind, id: item.id, storefront: sf)
            loading = false
        }
    }

    private func play(shuffled: Bool) {
        let list: [FeedItem] = shuffled ? songs.shuffled() : songs
        FeedPlayer.play(list, start: 0, title: item.title, library: library, player: player)
    }
}

/// Which pages the Apple Music look builds from the online catalogue.
enum FeedPage { case home, new, radio }

/// One of Apple Music's own pages, built from the online catalogue.
struct FeedPageView: View {
    let page: FeedPage
    @State private var store = AppleFeedStore.shared
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router

    private var key: String { page == .home ? "home" : page == .new ? "new" : "radio" }
    private var shelves: [FeedShelf] { page == .home ? store.home : page == .new ? store.new : store.radio }

    var body: some View {
        feed.task { await store.load(key) }
    }

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if page == .radio { radioSearch }
                if page == .home { yourShelves }
                ForEach(shelves) { s in FeedShelfView(shelf: s) }
                if shelves.isEmpty && !store.loading.contains(key) {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "wifi.slash")
                    } description: {
                        Text("Check your connection, then pull down to try again.")
                    }
                }
            }
            .padding(.bottom, 24)
            .padding(.top, 4)
        }
        .refreshable { await store.load(key, force: true) }
        .overlay { if shelves.isEmpty && store.loading.contains(key) { ProgressView() } }
    }

    private var radioSearch: some View {
        Button { router.tab = .search } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Search stations — Pop, Jazz, Chill…")
                Spacer()
            }
            .font(.system(size: 16)).foregroundStyle(.secondary)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.15)))
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }

    /// Home's personal shelves: what you played, and stations that start from artists you play.
    @ViewBuilder private var yourShelves: some View {
        let artists: [LibraryEntry] = Array(library.artistEntries.sorted { a, b in
            a.tracks.reduce(0) { $0 + ($1.playCount ?? 0) } > b.tracks.reduce(0) { $0 + ($1.playCount ?? 0) }
        }.prefix(10))
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stations for You").font(.system(size: 22, weight: .bold))
                    Text("Personal radio built from your top artists").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(artists) { a in
                            Button { if let seed = a.tracks.randomElement() { player.startStation(from: seed) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ArtworkView(entry: a).thumbnail(450).frame(width: 150, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    Text("\(a.title) & Similar Artists").font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text("Radio Station").font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                                .frame(width: 150, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

// MARK: - Tab roots (turn "Apple Music feed" off in Settings to get the old pages back)

struct HomeTabRoot: View {
    @AppStorage("feed.enabled") private var on = true
    var body: some View {
        if on { FeedPageView(page: .home) } else { HomeView() }
    }
}

struct NewTabRoot: View {
    @AppStorage("feed.enabled") private var on = true
    var body: some View {
        if on { FeedPageView(page: .new) } else { NewMusicView() }
    }
}

struct RadioTabRoot: View {
    @AppStorage("feed.enabled") private var on = true
    var body: some View {
        if on { FeedPageView(page: .radio) } else { RadioView() }
    }
}
