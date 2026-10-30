import SwiftUI
import Observation

// MARK: - Online metadata (iTunes Search API, no account needed)

nonisolated enum MetadataLookup {
    struct AlbumHit: Codable, Sendable {
        var artworkURL: URL?; var genre: String?; var year: Int?; var name: String; var artist: String
        var collectionID: Int?; var trackCount: Int?
    }
    /// One song of an album as the catalog lists it.
    struct CatalogTrack: Codable, Sendable { var title: String; var number: Int; var disc: Int }

    private struct Response: Decodable {
        struct Item: Decodable {
            let wrapperType: String?
            let collectionId: Int?
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
            let primaryGenreName: String?
            let releaseDate: String?
            let trackCount: Int?
            let trackName: String?
            let trackNumber: Int?
            let discNumber: Int?
        }
        let results: [Item]
    }

    /// The iTunes API allows about 20 calls a minute and answers 403 above that,
    /// so every call waits its turn and backs off once when it's told to slow down.
    actor Throttle {
        private var next = ContinuousClock.now
        private let gap: Duration
        init(gap: Duration) { self.gap = gap }
        func wait() async {
            let now = ContinuousClock.now
            let start = max(now, next)
            next = start + gap
            if start > now { try? await Task.sleep(until: start) }
        }
    }
    static let itunes = Throttle(gap: .milliseconds(3100))
    static let musicBrainz = Throttle(gap: .milliseconds(1100))

    private static func itunesData(_ url: URL) async -> Data? {
        for attempt in 0..<2 {
            await itunes.wait()
            guard let (data, resp) = try? await URLSession.shared.data(from: url) else { return nil }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return data }
            if (code == 403 || code == 429) && attempt == 0 { try? await Task.sleep(for: .seconds(20)); continue }
            return nil
        }
        return nil
    }

    private static func norm(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber } }
    private static var country: String { Locale.current.region?.identifier ?? "US" }
    private static func bigArt(_ s: String?) -> URL? { s.map { $0.replacingOccurrences(of: "100x100bb", with: "800x800bb") }.flatMap(URL.init(string:)) }

    /// A single song looked up by artist and title: where it belongs (album, number) plus cover and genre.
    struct SongHit: Codable, Sendable {
        var album: String; var collectionID: Int?; var number: Int?; var disc: Int?
        var artworkURL: URL?; var genre: String?; var year: Int?
        /// The catalog's spelling of the song and artist.
        var title: String?; var artist: String?
    }

    @concurrent
    static func song(artist: String, title: String) async -> SongHit? {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(title)"), URLQueryItem(name: "entity", value: "song"),
                         URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "country", value: country)]
        guard let url = c?.url, let data = await itunesData(url),
              let res = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let wantTitle = norm(title), wantArtist = norm(artist)
        let candidates = res.results.filter { norm($0.trackName ?? "").hasPrefix(wantTitle) && norm($0.artistName ?? "").contains(wantArtist.prefix(6)) }
        // Prefer the original album over compilations and singles.
        guard let hit = candidates.first(where: { ($0.trackCount ?? 0) > 3 && !($0.collectionName ?? "").localizedCaseInsensitiveContains("hits") })
                ?? candidates.first else { return nil }
        return SongHit(album: hit.collectionName ?? "", collectionID: hit.collectionId, number: hit.trackNumber, disc: hit.discNumber,
                       artworkURL: bigArt(hit.artworkUrl100), genre: hit.primaryGenreName, year: hit.releaseDate.flatMap { Int($0.prefix(4)) },
                       title: hit.trackName, artist: hit.artistName)
    }

    /// The album's full tracklist from the iTunes catalog.
    @concurrent
    static func tracklist(collectionID: Int) async -> [CatalogTrack] {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")
        c?.queryItems = [URLQueryItem(name: "id", value: "\(collectionID)"), URLQueryItem(name: "entity", value: "song"),
                         URLQueryItem(name: "country", value: country)]
        guard let url = c?.url, let data = await itunesData(url),
              let res = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return res.results.compactMap { i in
            guard i.wrapperType == "track", let name = i.trackName, let n = i.trackNumber else { return nil }
            return CatalogTrack(title: name, number: n, disc: i.discNumber ?? 1)
        }
    }

    /// Cover Art Archive (MusicBrainz) for albums the iTunes catalog doesn't know.
    @concurrent
    static func coverArtArchive(artist: String, album: String) async -> URL? {
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")
        c?.queryItems = [URLQueryItem(name: "query", value: "releasegroup:\"\(album)\" AND artist:\"\(artist)\""),
                         URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "1")]
        guard let url = c?.url else { return nil }
        await musicBrainz.wait()
        var req = URLRequest(url: url)
        // MusicBrainz asks every client to identify itself.
        req.setValue("\(Brand.name)/1.0", forHTTPHeaderField: "User-Agent")
        struct Groups: Decodable { struct G: Decodable { let id: String; let score: Int? }; let releaseGroups: [G]?
            enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" } }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let g = try? JSONDecoder().decode(Groups.self, from: data).releaseGroups?.first, (g.score ?? 0) >= 90 else { return nil }
        let art = URL(string: "https://coverartarchive.org/release-group/\(g.id)/front-500")!
        var head = URLRequest(url: art)
        head.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: head), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return art
    }

    @concurrent
    static func album(artist: String, album: String) async -> AlbumHit? {
        var c = URLComponents(string: "https://itunes.apple.com/search")
        c?.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(album)"), URLQueryItem(name: "entity", value: "album"),
                         URLQueryItem(name: "limit", value: "5"), URLQueryItem(name: "country", value: country)]
        guard let url = c?.url, let data = await itunesData(url),
              let res = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let want = norm(album), wantArtist = norm(artist)
        let pick = res.results.first { norm($0.collectionName ?? "").hasPrefix(want) && norm($0.artistName ?? "").contains(wantArtist.prefix(6)) }
            ?? res.results.first { norm($0.collectionName ?? "") == want }
        guard let hit = pick else { return nil }
        let art = bigArt(hit.artworkUrl100)
        return AlbumHit(artworkURL: art, genre: hit.primaryGenreName, year: hit.releaseDate.flatMap { Int($0.prefix(4)) },
                        name: hit.collectionName ?? album, artist: hit.artistName ?? artist,
                        collectionID: hit.collectionId, trackCount: hit.trackCount)
    }
}

// MARK: - Issues

struct OrganizeIssue: Identifiable {
    enum Kind: String, CaseIterable {
        case artistNames, duplicateAlbums, duplicateSongs, metadata, artwork, tracklist, motion, genres, lyrics
        var title: String {
            switch self {
            case .artistNames: "Artist Names"
            case .duplicateAlbums: "Duplicate Albums"
            case .duplicateSongs: "Duplicate Songs"
            case .metadata: "Incorrect Metadata"
            case .artwork: "Album Covers"
            case .tracklist: "Album Details"
            case .motion: "Animated Covers"
            case .genres: "Missing Genres"
            case .lyrics: "Missing Lyrics"
            }
        }
        var symbol: String {
            switch self {
            case .artistNames: "music.mic"
            case .duplicateAlbums: "square.stack.3d.up"
            case .duplicateSongs: "doc.on.doc"
            case .metadata: "tag"
            case .artwork: "photo"
            case .tracklist: "list.number"
            case .motion: "play.square.stack"
            case .genres: "guitars"
            case .lyrics: "quote.bubble"
            }
        }
    }

    enum Change {
        case renameArtist(from: [String], to: String)
        case renameAlbum(artist: String, from: [String], to: String)
        case delete([UUID])
        case fields([UUID: (title: String?, artist: String?, number: Int?)])
        case artwork(URL, [UUID])
        case genre(String, year: Int?, [UUID])
        case lyrics([UUID])
        /// Track/disc numbers and exact titles from the album's catalog tracklist.
        case tracklist([UUID: (title: String, number: Int, disc: Int)])
        case motion(URL, [UUID])
        /// Album, number, disc, year, genre and cover for songs that had no album tag.
        case albumInfo([UUID: MetadataLookup.SongHit])
        case none
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    let change: Change
    var imageURL: URL?
    var selected = true
}

@Observable
final class Organizer {
    private(set) var issues: [OrganizeIssue] = []
    private(set) var scanning = false
    private(set) var phase = ""
    private(set) var applying = false
    private(set) var lastScan: Date?

    func toggle(_ id: UUID) { if let i = issues.firstIndex(where: { $0.id == id }) { issues[i].selected.toggle() } }
    func setAll(_ kind: OrganizeIssue.Kind, _ on: Bool) { for i in issues.indices where issues[i].kind == kind { issues[i].selected = on } }

    private static func norm(_ s: String) -> String {
        var t = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        if t.hasPrefix("the ") { t.removeFirst(4) }
        return t.filter { $0.isLetter || $0.isNumber }
    }

    func scan(library: LibraryStore, online: Bool) async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false; phase = ""; lastScan = Date() }
        var found: [OrganizeIssue] = []
        let tracks = library.tracks

        // Artist spellings ("Beatles" / "The Beatles" / "the beatles").
        phase = "Checking artist names…"
        let artistsByKey = Dictionary(grouping: tracks, by: { Self.norm($0.artist) })
        for (_, list) in artistsByKey {
            let counts = Dictionary(grouping: list, by: \.artist).mapValues(\.count)
            guard counts.count > 1, let best = counts.max(by: { $0.value < $1.value })?.key else { continue }
            let others = counts.keys.filter { $0 != best }.sorted()
            found.append(OrganizeIssue(kind: .artistNames, title: "Use “\(best)”",
                                       detail: "Also written as " + others.map { "“\($0)”" }.joined(separator: ", "),
                                       change: .renameArtist(from: others, to: best)))
        }

        // Albums split by spelling within an artist.
        phase = "Checking albums…"
        for (artist, list) in Dictionary(grouping: tracks, by: \.artist) {
            for (_, same) in Dictionary(grouping: list, by: { Self.norm($0.album) }) {
                let counts = Dictionary(grouping: same, by: \.album).mapValues(\.count)
                guard counts.count > 1, let best = counts.max(by: { $0.value < $1.value })?.key else { continue }
                let others = counts.keys.filter { $0 != best }.sorted()
                found.append(OrganizeIssue(kind: .duplicateAlbums, title: "Merge into “\(best)”",
                                           detail: "\(artist): " + others.map { "“\($0)”" }.joined(separator: ", "),
                                           change: .renameAlbum(artist: artist, from: others, to: best)))
            }
        }

        // Duplicate songs (same song twice as local files).
        phase = "Looking for duplicates…"
        let locals = tracks.filter { !$0.isRemote }
        for (_, group) in Dictionary(grouping: locals, by: { "\(Self.norm($0.title))|\(Self.norm($0.artist))" }) where group.count > 1 {
            let sorted = group.sorted {
                let a = ($0.hasArtwork ? 1 : 0) + ($0.lyrics != nil ? 1 : 0), b = ($1.hasArtwork ? 1 : 0) + ($1.lyrics != nil ? 1 : 0)
                return a != b ? a > b : ($0.playCount ?? 0) > ($1.playCount ?? 0)
            }
            guard let keep = sorted.first else { continue }
            let extra = sorted.dropFirst().filter { abs($0.duration - keep.duration) < 2.5 }
            guard !extra.isEmpty else { continue }
            found.append(OrganizeIssue(kind: .duplicateSongs, title: keep.title,
                                       detail: "\(keep.artist) · keeps 1, removes \(extra.count) " + (extra.count == 1 ? "copy" : "copies") + " (" + extra.map(\.album).joined(separator: ", ") + ")",
                                       change: .delete(extra.map(\.id))))
        }

        // Titles that are really file names, unknown artist / album.
        phase = "Checking tags…"
        var fixes: [UUID: (title: String?, artist: String?, number: Int?)] = [:]
        var fixText: [String] = []
        for t in tracks where !t.isRemote {
            guard let parsed = Self.parseFileTitle(t.title, artist: t.artist) else { continue }
            // Tags you set stay — except names that are plainly a download's file name ("… - Topic").
            guard !t.metadataLocked || parsed.replacesArtist else { continue }
            let newArtist = t.artist == "Unknown Artist" || parsed.replacesArtist ? parsed.artist : nil
            let newNumber = t.trackNumber == 0 ? parsed.number : nil
            guard parsed.title != t.title || newArtist != nil || newNumber != nil else { continue }
            fixes[t.id] = (parsed.title, newArtist, newNumber)
            fixText.append("“\(t.title)” → “\(parsed.title)”" + (newArtist.map { " by \($0)" } ?? ""))
        }
        if !fixes.isEmpty {
            found.append(OrganizeIssue(kind: .metadata, title: "Clean up \(songCount(fixes.count))",
                                       detail: fixText.prefix(4).joined(separator: "\n") + (fixText.count > 4 ? "\n…and \(fixText.count - 4) more" : ""),
                                       change: .fields(fixes)))
        }
        let unknown = tracks.filter { $0.artist == "Unknown Artist" || $0.album == "Unknown Album" }.count
        if unknown > 0 && fixes.isEmpty {
            found.append(OrganizeIssue(kind: .metadata, title: "\(songCount(unknown)) with unknown artist or album",
                                       detail: "Edit them in Tags & Metadata — select several to fix them at once.", change: .fields([:]), selected: false))
        }

        // Lyrics.
        let noLyrics = tracks.filter { $0.lyrics == nil && $0.onlineLyricsChecked != true }
        if !noLyrics.isEmpty, online {
            found.append(OrganizeIssue(kind: .lyrics, title: "Look up lyrics for \(songCount(noLyrics.count))",
                                       detail: "Searches your server and LRCLIB.", change: .lyrics(noLyrics.map(\.id))))
        }
        issues = found

        // Per album, online: artwork (iTunes, then Cover Art Archive), tracklist, genre, animated cover. Throttled.
        guard online, NetworkMonitor.shared.isOnline else { return }
        let motion = await MotionArtwork.requestAccess()
        // Server albums only get the animated cover: their cover, tracklist and genre belong to the server.
        let albums = Dictionary(grouping: tracks, by: { "\($0.artist)|\($0.album)" })
            .filter { _, list in list.first?.album != "Unknown Album" }
        // Songs whose cover can be swapped for the catalog one: none at all, or the one embedded in the file.
        func replaceableArt(_ list: [Track]) -> [Track] { list.filter { !$0.hasArtwork || ($0.artSource ?? .file).replaceable } }
        // Albums missing a cover come first, then file covers, then the ones missing a genre, then the rest.
        func need(_ list: [Track]) -> Int {
            (list.contains { !$0.hasArtwork } ? 4 : 0) + (replaceableArt(list).isEmpty ? 0 : 2) + (list.contains { $0.genre == nil } ? 1 : 0)
        }
        let ordered = albums.sorted { need($0.value) != need($1.value) ? need($0.value) > need($1.value) : $0.key < $1.key }
        let cache = LookupCache.shared
        // Answers from earlier scans are free; only new lookups count toward the limit (the iTunes API is slow on purpose).
        var fresh = 0
        for (_, list) in ordered {
            guard fresh < 30, let first = list.first else { break }
            if list.allSatisfy({ $0.isRemote && $0.remoteImageTag != nil }) {
                guard motion, list.contains(where: { $0.motionArtworkURL == nil }) else { continue }
                if !(await cache.isKnown(LookupCache.motionKey(artist: first.artist, album: first.album))) { fresh += 1 }
                phase = "Looking up “\(first.album)”…"
                if let video = await cache.motion(artist: first.artist, album: first.album) {
                    issues.append(OrganizeIssue(kind: .motion, title: first.album, detail: "\(first.artist) · plays in Now Playing",
                                                change: .motion(video, list.map(\.id)), imageURL: nil))
                }
                continue
            }
            if !(await cache.isKnown(LookupCache.albumKey(artist: first.artist, album: first.album))) { fresh += 1 }
            phase = "Looking up “\(first.album)”…"
            let hit = await cache.album(artist: first.artist, album: first.album)
            let swap = replaceableArt(list)
            let missing = swap.filter { !$0.hasArtwork }
            if !swap.isEmpty {
                // A missing cover may come from the Cover Art Archive; one from the file is only replaced by Apple Music's.
                var art = hit?.artworkURL
                if art == nil, !missing.isEmpty { art = await cache.coverArtArchive(artist: first.artist, album: first.album) }
                let targets = hit?.artworkURL == nil ? missing : swap
                if let art, !targets.isEmpty {
                    let replacing = targets.count - missing.count
                    let what = replacing == 0 ? "adds the cover to \(songCount(targets.count))"
                        : missing.isEmpty ? "replaces the cover from the file on \(songCount(replacing))"
                        : "adds or replaces the cover on \(songCount(targets.count))"
                    issues.append(OrganizeIssue(kind: .artwork, title: first.album, detail: "\(first.artist) · Apple Music \(what)",
                                                change: .artwork(art, targets.map(\.id)), imageURL: art))
                }
            }
            if let id = hit?.collectionID {
                let catalog = await cache.tracklist(collectionID: id)
                if let issue = Self.tracklistIssue(album: first.album, artist: first.artist, songs: list, catalog: catalog) { issues.append(issue) }
            }
            if motion, list.contains(where: { $0.motionArtworkURL == nil }),
               let video = await cache.motion(artist: first.artist, album: first.album) {
                issues.append(OrganizeIssue(kind: .motion, title: first.album, detail: "\(first.artist) · plays in Now Playing",
                                            change: .motion(video, list.map(\.id)), imageURL: hit?.artworkURL))
            }
            guard let hit else { continue }
            if let g = hit.genre, list.contains(where: { $0.genre == nil }) {
                issues.append(OrganizeIssue(kind: .genres, title: "\(first.album): \(g)", detail: first.artist + (hit.year.map { " · \($0)" } ?? ""),
                                            change: .genre(g, year: hit.year, list.filter { $0.genre == nil }.map(\.id))))
            }
        }

        // Songs without an album tag: look each one up by artist and title, then fill in album, number, cover and genre.
        // Use the cleaned-up names from above, so "Title - Artist - Topic.mp3" is searched the right way round.
        func names(_ t: Track) -> (artist: String, title: String) {
            let f = fixes[t.id]
            return (f?.artist ?? t.artist, f?.title ?? t.title)
        }
        let loose = tracks.filter { !$0.isRemote && $0.album == "Unknown Album" && names($0).artist != "Unknown Artist" }
        var found2: [UUID: MetadataLookup.SongHit] = [:]
        var looked = 0
        var swapped: [UUID: (title: String?, artist: String?, number: Int?)] = [:]
        for (i, t) in loose.enumerated() {
            let n = names(t)
            if !(await cache.isKnown(LookupCache.songKey(artist: n.artist, title: n.title))) {
                guard looked < 30 else { break }
                looked += 1
            }
            phase = "Finding the album of “\(n.title)” (\(i + 1)/\(loose.count))…"
            if let hit = await cache.song(artist: n.artist, title: n.title), !hit.album.isEmpty {
                found2[t.id] = hit
            } else if fixes[t.id] == nil {
                // Maybe artist and title are the wrong way round.
                let known = await cache.isKnown(LookupCache.songKey(artist: n.title, title: n.artist))
                guard known || looked < 30 else { continue }
                if !known { looked += 1 }
                if let hit = await cache.song(artist: n.title, title: n.artist), !hit.album.isEmpty {
                    found2[t.id] = hit
                    swapped[t.id] = (hit.title ?? n.artist, hit.artist ?? n.title, nil)
                }
            }
        }
        if !swapped.isEmpty {
            let list = swapped.compactMap { id, f in library.trackByID[id].map { "“\($0.title)” by \($0.artist) → “\(f.title ?? "")” by \(f.artist ?? "")" } }
            issues.append(OrganizeIssue(kind: .metadata, title: "Swap artist and title on \(songCount(swapped.count))",
                                        detail: list.prefix(4).joined(separator: "\n") + (list.count > 4 ? "\n…and \(list.count - 4) more" : ""),
                                        change: .fields(swapped)))
        }
        for (album, entries) in Dictionary(grouping: found2, by: { $0.value.album }) {
            let ids = entries.map(\.key)
            let sample = entries[0].value
            let names = ids.compactMap { library.trackByID[$0]?.title }.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            issues.append(OrganizeIssue(kind: .tracklist, title: album,
                                        detail: "Adds album, track number and genre to " + names + (ids.count > 3 ? " and \(ids.count - 3) more" : ""),
                                        change: .albumInfo(Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })),
                                        imageURL: sample.artworkURL))
        }
    }

    /// Matches the album's songs to the catalog by title: fixes numbering and spelling, and says which songs are missing.
    static func tracklistIssue(album: String, artist: String, songs: [Track], catalog: [MetadataLookup.CatalogTrack]) -> OrganizeIssue? {
        guard !catalog.isEmpty else { return nil }
        func key(_ s: String) -> String {
            // "Song (Remastered 2011)" and "Song - 2011 Remaster" match "Song".
            var t = s.lowercased()
            if let r = t.range(of: #"\s[\(\[-].*(remaster|version|edit|mix|live|mono|stereo|deluxe).*$"#, options: .regularExpression) { t.removeSubrange(r) }
            return norm(t)
        }
        let byKey = Dictionary(catalog.map { (key($0.title), $0) }, uniquingKeysWith: { a, _ in a })
        var fixes: [UUID: (title: String, number: Int, disc: Int)] = [:]
        var matched = Set<String>()
        for t in songs where !t.metadataLocked || t.trackNumber == 0 {
            guard let c = byKey[key(t.title)] else { continue }
            matched.insert(key(c.title))
            let disc = t.discNumber ?? 1
            if t.trackNumber != c.number || disc != c.disc || (t.title != c.title && !t.metadataLocked) {
                fixes[t.id] = (t.metadataLocked ? t.title : c.title, c.number, c.disc)
            }
        }
        for t in songs { if let c = byKey[key(t.title)] { matched.insert(key(c.title)) } }
        let missing = catalog.filter { !matched.contains(key($0.title)) }
        guard !fixes.isEmpty || !missing.isEmpty else { return nil }
        var detail: [String] = []
        if !fixes.isEmpty { detail.append("Fixes numbers or titles of \(songCount(fixes.count)).") }
        if !missing.isEmpty {
            let names = missing.prefix(3).map { "“\($0.title)”" }.joined(separator: ", ")
            detail.append("You have \(catalog.count - missing.count) of \(catalog.count) songs. Missing: \(names)" + (missing.count > 3 ? " and \(missing.count - 3) more." : "."))
        }
        return OrganizeIssue(kind: .tracklist, title: album, detail: "\(artist) · " + detail.joined(separator: " "),
                             change: fixes.isEmpty ? .none : .tracklist(fixes), selected: !fixes.isEmpty)
    }

    static func parseFileTitle(_ raw: String, artist current: String) -> FileTitleParser.Result? {
        FileTitleParser.parse(raw, artist: current)
    }

    func apply(library: LibraryStore, lyrics: LyricsService) async {
        applying = true
        defer { applying = false }
        // Each cover is downloaded once, however many issues use it, and written once, then copied to the album's other songs.
        var downloads: [URL: Data] = [:]
        func download(_ url: URL) async -> Data? {
            if let d = downloads[url] { return d }
            guard let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            downloads[url] = data
            return data
        }
        func setCover(_ data: Data, for ids: [UUID]) {
            guard let first = ids.first, ArtworkWriter.writeJPEG(from: data, for: first) else { return }
            var done = [first]
            for id in ids.dropFirst() {
                try? FileManager.default.removeItem(at: Paths.artworkURL(for: id))
                if (try? FileManager.default.copyItem(at: Paths.artworkURL(for: first), to: Paths.artworkURL(for: id))) != nil { done.append(id) }
            }
            for id in done { ArtworkCache.evict(id) }
            library.updateMany(Set(done)) { $0.hasArtwork = true; $0.artSource = .catalog; $0.artVersion = ($0.artVersion ?? 0) + 1 }
        }
        for issue in issues where issue.selected {
            switch issue.change {
            case .renameArtist(let from, let to):
                let ids = Set(library.tracks.filter { from.contains($0.artist) }.map(\.id))
                library.updateMany(ids) { $0.artist = to; $0.metadataLocked = true }
                library.pinned = library.pinned.map { p in
                    var p = p
                    if p.kind == .artist, from.contains(p.key) { p.key = to }
                    if p.kind == .album, let a = p.key.split(separator: "|").first.map(String.init), from.contains(a) { p.key = to + p.key.dropFirst(a.count) }
                    return p
                }
            case .renameAlbum(let artist, let from, let to):
                let ids = Set(library.tracks.filter { $0.artist == artist && from.contains($0.album) }.map(\.id))
                library.updateMany(ids) { $0.album = to; $0.metadataLocked = true }
            case .delete(let ids):
                library.delete(Set(ids))
            case .fields(let map):
                library.updateMany(Set(map.keys)) { t in
                    guard let f = map[t.id] else { return }
                    if let v = f.title { t.title = v }
                    if let v = f.artist { t.artist = v }
                    if let v = f.number { t.trackNumber = v }
                    t.metadataLocked = true
                }
            case .artwork(let url, let ids):
                guard let data = await download(url) else { continue }
                setCover(data, for: ids)
            case .genre(let g, let year, let ids):
                library.updateMany(Set(ids)) { t in
                    t.genre = g
                    if t.year == nil, let year { t.year = year }
                }
            case .lyrics(let ids):
                for id in ids {
                    // Skip songs that got lyrics (or were looked up) since the scan.
                    guard let t = library.trackByID[id], t.lyrics == nil, t.onlineLyricsChecked != true else { continue }
                    await lyrics.fetchOnline(t)
                }
            case .tracklist(let map):
                library.updateMany(Set(map.keys)) { t in
                    guard let f = map[t.id] else { return }
                    t.title = f.title; t.trackNumber = f.number; t.discNumber = f.disc
                }
            case .motion(let url, let ids):
                library.updateMany(Set(ids)) { $0.motionArtworkURL = url.absoluteString }
            case .albumInfo(let map):
                library.updateMany(Set(map.keys)) { t in
                    guard let h = map[t.id] else { return }
                    t.album = h.album
                    if let n = h.number { t.trackNumber = n }
                    if let d = h.disc { t.discNumber = d }
                    if t.year == nil { t.year = h.year }
                    if t.genre == nil { t.genre = h.genre }
                }
                // One download per cover, shared by every song of that album; replaces covers that came with the file.
                let swap = map.filter { e in library.trackByID[e.key].map { !$0.hasArtwork || ($0.artSource ?? .file).replaceable } ?? false }
                for (url, ids) in Dictionary(grouping: swap, by: { $0.value.artworkURL }) {
                    guard let url, let data = await download(url) else { continue }
                    setCover(data, for: ids.map(\.key))
                }
            case .none:
                break
            }
        }
        issues.removeAll { $0.selected }
    }
}

// MARK: - UI

struct OrganizeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LyricsService.self) private var lyrics
    @Environment(AppSettings.self) private var settings
    @State private var organizer = Organizer()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Organize My Library").font(.title3.bold())
                    Text("Finds missing covers, wrong track numbers and missing songs per album, animated covers from Apple Music, messy tags, duplicates, and missing lyrics and genres. Nothing changes until you apply it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button {
                        Task { await organizer.scan(library: library, online: settings.onlineLookups && !settings.offlineMode) }
                    } label: {
                        HStack {
                            if organizer.scanning { ProgressView().tint(.white) }
                            Text(organizer.scanning ? organizer.phase : organizer.lastScan == nil ? "Scan Library" : "Scan Again")
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(organizer.scanning || library.tracks.isEmpty)
                }
                .padding(.vertical, 6)
            }

            ForEach(OrganizeIssue.Kind.allCases, id: \.self) { kind in
                let list = organizer.issues.filter { $0.kind == kind }
                if !list.isEmpty {
                    Section {
                        ForEach(list) { issue in
                            Button { organizer.toggle(issue.id) } label: { row(issue) }.tint(.primary)
                        }
                    } header: {
                        HStack {
                            Label(kind.title, systemImage: kind.symbol)
                            Spacer()
                            Button(list.allSatisfy(\.selected) ? "None" : "All") { organizer.setAll(kind, !list.allSatisfy(\.selected)) }
                                .font(.caption.bold())
                        }
                    }
                }
            }

            if organizer.lastScan != nil && organizer.issues.isEmpty && !organizer.scanning {
                Section { Label("Everything looks tidy.", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            }
        }
        .navigationTitle("Organize")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            let count = organizer.issues.filter(\.selected).count
            if count > 0 && !organizer.scanning {
                Button {
                    Task { await organizer.apply(library: library, lyrics: lyrics) }
                } label: {
                    HStack {
                        if organizer.applying { ProgressView().tint(.white) }
                        Text(organizer.applying ? "Applying…" : "Apply \(count) " + (count == 1 ? "Change" : "Changes"))
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .disabled(organizer.applying)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
    }

    private func row(_ issue: OrganizeIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.selected ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(issue.selected ? Theme.accent : .secondary)
            if let url = issue.imageURL {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                    .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.system(size: 15, weight: .semibold))
                Text(issue.detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
