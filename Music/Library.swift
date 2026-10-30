import SwiftUI
import Observation

struct ImportStatus {
    var title: String
    var done: Int
    var total: Int
}

@Observable
final class LibraryStore {
    /// Mixes only make sense once there is enough music to build them from.
    static let mixThreshold = 30

    private(set) var tracks: [Track] = [] { didSet { if !patching { invalidate() }; scheduleSave() } }
    /// Module songs that were only played from Search, never added. They stay out of the library
    /// (Songs, Albums, Recently Added…) but the player, history and downloads still find them by id.
    /// Favoriting, downloading or adding one to a playlist moves it into `tracks`.
    private(set) var heard: [Track] = [] { didSet { if !patching { invalidate() }; scheduleSave() } }
    /// Library songs plus songs only played from modules.
    var allTracks: [Track] { tracks + heard }
    var playlists: [Playlist] = [] { didSet { scheduleSave() } }
    var pinned: [PinnedItem] = [] { didSet { scheduleSave() } }
    var favorites: Set<String> = [] { didSet { scheduleSave() } }
    /// Downloads-tab order, including songs still waiting for their offline copy.
    private(set) var downloadOrder: [UUID] = [] {
        didSet {
            _memo = _memo.filter { !$0.key.hasPrefix("downloads|") }
            scheduleSave()
        }
    }
    var importStatus: ImportStatus?

    // Derived data is rebuilt lazily: many changes in a row (plays, lyrics, analysis, imports) cost one rebuild,
    // done when something reads it. Reading `tracks`/`heard` first keeps SwiftUI observing the right properties.
    var trackByID: [UUID: Track] { _ = tracks; _ = heard; if _trackByID == nil { buildIndex() }; return _trackByID ?? [:] }
    var albumEntries: [LibraryEntry] { _ = tracks; if _albums == nil { buildEntries() }; return _albums ?? [] }
    var artistEntries: [LibraryEntry] { _ = tracks; if _artists == nil { buildEntries() }; return _artists ?? [] }
    /// Albums, newest addition first.
    var albumsByRecent: [LibraryEntry] { _ = tracks; if _albumsByRecent == nil { buildEntries() }; return _albumsByRecent ?? [] }
    @ObservationIgnored private var _trackByID: [UUID: Track]?
    /// Position of each song in `tracks` / `heard`; valid whenever `_trackByID` is.
    @ObservationIgnored private var _trackIndex: [UUID: Int] = [:]
    @ObservationIgnored private var _heardIndex: [UUID: Int] = [:]
    @ObservationIgnored private var _moduleIndex: [String: UUID] = [:]
    @ObservationIgnored private var _albums: [LibraryEntry]?
    @ObservationIgnored private var _artists: [LibraryEntry]?
    @ObservationIgnored private var _albumsByRecent: [LibraryEntry]?
    @ObservationIgnored private var _mostPlayed: [Track]?
    @ObservationIgnored private var _songKeys: Set<String>?
    @ObservationIgnored private var _memo: [String: Any] = [:]
    /// Set while one song is changed in place (see `update`): the id index stays valid, so it's patched instead of rebuilt.
    @ObservationIgnored private var patching = false

    @ObservationIgnored var onTracksDeleted: (Set<UUID>) -> Void = { _ in }
    /// Streaming sources mirror favourites and plays back to the server.
    @ObservationIgnored var onFavoriteChanged: (Track) -> Void = { _ in }
    @ObservationIgnored var onPlayed: (Track) -> Void = { _ in }
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private nonisolated struct Snapshot: Codable, Sendable {
        var tracks: [Track]
        var playlists: [Playlist]
        var pinned: [PinnedItem]
        var favorites: Set<String>
        var heard: [Track]?
        var downloadOrder: [UUID]?
    }

    init() {
        Paths.prepare()
        if let data = try? Data(contentsOf: Paths.database),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            tracks = snap.tracks
            playlists = snap.playlists
            pinned = snap.pinned
            favorites = snap.favorites
            heard = snap.heard ?? []
            downloadOrder = snap.downloadOrder ?? []
        }
        // Property observers don't run in init, so save explicitly when these changed anything.
        let moved = separateHeardOnce(), pruned = pruneHeard()
        if moved || pruned { scheduleSave() }
    }

    // MARK: Songs only played from modules

    /// Before `heard` existed, playing a search result added it (and the rest of the results) to the library.
    /// Move those back out once: module songs that aren't favorites, downloads or in a playlist.
    private func separateHeardOnce() -> Bool {
        let key = "heardSeparated"
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.set(true, forKey: key)
        let inPlaylists = Set(playlists.flatMap(\.trackIDs))
        let isHeard: (Track) -> Bool = { t in
            (t.sourceID?.hasPrefix("module:") ?? false) && t.path.isEmpty && !t.isFavorite && !inPlaylists.contains(t.id)
        }
        let moved = tracks.filter(isHeard)
        guard !moved.isEmpty else { return false }
        heard += moved
        tracks.removeAll(where: isHeard)
        return true
    }

    /// Forgets songs that were only played from modules more than 60 days ago.
    private func pruneHeard() -> Bool {
        let cutoff = Date().addingTimeInterval(-60 * 86_400)
        let old = heard.filter { $0.path.isEmpty && ($0.lastPlayed ?? $0.addedAt) < cutoff }
        guard !old.isEmpty else { return false }
        for t in old { try? FileManager.default.removeItem(at: Paths.artworkURL(for: t.id)) }
        let ids = Set(old.map(\.id))
        heard.removeAll { ids.contains($0.id) }
        return true
    }

    /// Moves a song that was only played from a module into the library ("Recently Added" from now).
    func keep(_ ids: [UUID]) {
        let set = Set(ids)
        guard heard.contains(where: { set.contains($0.id) }) else { return }
        var moving = heard.filter { set.contains($0.id) }
        for i in moving.indices { moving[i].addedAt = Date() }
        heard.removeAll { set.contains($0.id) }
        tracks += moving
    }

    // MARK: Derived data

    private func invalidate() {
        _trackByID = nil; _albums = nil; _artists = nil; _albumsByRecent = nil; _mostPlayed = nil; _songKeys = nil; _memo = [:]
    }

    private func buildIndex() {
        var byID: [UUID: Track] = [:], trackIndex: [UUID: Int] = [:], heardIndex: [UUID: Int] = [:]
        byID.reserveCapacity(tracks.count + heard.count)
        trackIndex.reserveCapacity(tracks.count)
        heardIndex.reserveCapacity(heard.count)
        var modules: [String: UUID] = [:]
        // The first song with an id wins, library songs before ones only played.
        for (i, t) in tracks.enumerated() where trackIndex[t.id] == nil { trackIndex[t.id] = i; byID[t.id] = t }
        for (i, t) in heard.enumerated() where heardIndex[t.id] == nil {
            heardIndex[t.id] = i
            if byID[t.id] == nil { byID[t.id] = t }
        }
        for list in [tracks, heard] {
            for t in list { if let s = t.sourceID, let r = t.remoteID, modules["\(s)|\(r)"] == nil { modules["\(s)|\(r)"] = t.id } }
        }
        _trackByID = byID
        _trackIndex = trackIndex
        _heardIndex = heardIndex
        _moduleIndex = modules
    }

    /// One song changed in place: keep the id index, drop only what depends on the song's fields.
    private func patched(_ old: Track, _ new: Track) {
        guard old.sourceID == new.sourceID, old.remoteID == new.remoteID, _trackByID != nil else { invalidate(); return }
        _trackByID?[new.id] = new
        _albums = nil; _artists = nil; _albumsByRecent = nil; _mostPlayed = nil; _memo = [:]
        if old.title != new.title || old.artist != new.artist { _songKeys = nil }
    }

    /// Caches a value derived from the songs (a sorted list, a shelf …) until the songs change.
    /// Anything else the value depends on (a sort order, being online …) must be part of `key`,
    /// and read outside `build` so the calling view keeps observing it.
    func memo<T>(_ key: String, _ build: () -> T) -> T {
        _ = tracks; _ = heard
        if let hit = _memo[key] as? T { return hit }
        let value = build()
        _memo[key] = value
        return value
    }

    // MARK: Downloads order

    /// Unordered songs keep the existing artist/album order supplied by the caller.
    func orderedDownloads(_ list: [Track]) -> [Track] {
        guard !downloadOrder.isEmpty else { return list }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = Set(downloadOrder)
        return downloadOrder.compactMap { byID[$0] } + list.filter { !ordered.contains($0.id) }
    }

    /// Record a batch before it starts, so completion timing cannot shuffle a playlist.
    func rememberDownloads(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var order = downloadOrder
        var seen = Set(order)
        let existing = SmartShuffle.libraryOrder(tracks.filter(\.isOffline)).map(\.id)
        for id in existing + ids where seen.insert(id).inserted { order.append(id) }
        if order != downloadOrder { downloadOrder = order }
    }

    /// Replace only the visible songs' slots; other Downloads filters retain their positions.
    func setDownloadOrder(_ ids: [UUID]) {
        var seen = Set<UUID>()
        let ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        rememberDownloads(ids)
        let visible = Set(ids)
        var replacements = ids.makeIterator()
        let order = downloadOrder.map { visible.contains($0) ? (replacements.next() ?? $0) : $0 }
        if order != downloadOrder { downloadOrder = order }
    }

    /// The song for a streaming id (`sourceID|remoteID`), in the library or only played.
    func track(source: String, remoteID: String) -> Track? {
        _ = tracks; _ = heard
        if _trackByID == nil { buildIndex() }
        return _moduleIndex["\(source)|\(remoteID)"].flatMap { _trackByID?[$0] }
    }

    private func buildEntries() {
        let byAlbum = Dictionary(grouping: tracks) { "\($0.artist)|\($0.album)" }
        let albums: [LibraryEntry] = byAlbum.map { key, list -> LibraryEntry in
            let sorted = list.sorted { ($0.trackNumber, $0.title) < ($1.trackNumber, $1.title) }
            return LibraryEntry(kind: .album, key: key, title: sorted[0].album,
                                subtitle: "\(sorted[0].artist) • \(songCount(sorted.count))", tracks: sorted)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let byArtist = Dictionary(grouping: tracks) { $0.artist }
        _albums = albums
        let latest = Dictionary(albums.map { ($0.key, $0.tracks.map(\.addedAt).max() ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
        _albumsByRecent = albums.sorted { (latest[$0.key] ?? .distantPast) > (latest[$1.key] ?? .distantPast) }

        _artists = byArtist.map { name, list -> LibraryEntry in
            let sorted = list.sorted { $0.album == $1.album ? ($0.trackNumber, $0.title) < ($1.trackNumber, $1.title) : $0.album < $1.album }
            return LibraryEntry(kind: .artist, key: name, title: name,
                                subtitle: "\(songCount(sorted.count)) • \(formatDuration(sorted.reduce(0) { $0 + $1.duration }))",
                                tracks: sorted)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var playlistEntries: [LibraryEntry] { playlists.map(entry(for:)) }

    func entry(for playlist: Playlist) -> LibraryEntry {
        let list = playlist.trackIDs.compactMap { trackByID[$0] }
        return LibraryEntry(kind: .playlist, key: playlist.id.uuidString, title: playlist.name,
                            subtitle: "\(songCount(list.count)) • \(formatDuration(list.reduce(0) { $0 + $1.duration }))",
                            tracks: list)
    }

    func entry(_ kind: LibraryEntry.Kind, _ key: String) -> LibraryEntry? {
        switch kind {
        case .playlist: playlists.first { $0.id.uuidString == key }.map(entry(for:))
        case .artist: artistEntries.first { $0.key == key }
        case .album: albumEntries.first { $0.key == key }
        }
    }

    var pinnedEntries: [LibraryEntry] { pinned.compactMap { entry($0.kind, $0.key) } }

    /// Songs you play most (ties: most recently played), including ones only played from modules.
    var mostPlayed: [Track] {
        _ = tracks; _ = heard
        if let cached = _mostPlayed { return cached }
        let list = allTracks.filter { ($0.playCount ?? 0) > 0 }
            .sorted { ($0.playCount ?? 0, $0.lastPlayed ?? .distantPast) > ($1.playCount ?? 0, $1.lastPlayed ?? .distantPast) }
        _mostPlayed = list
        return list
    }

    func tracks(for ids: [UUID]) -> [Track] { ids.compactMap { trackByID[$0] } }

    /// Module suggestions without the songs you already have or played: the same module song, or the same
    /// title and artist from anywhere else (another module, a server, your own files). Repeats are dropped too.
    func newToYou(_ list: [ModuleTrack]) -> [ModuleTrack] {
        _ = tracks; _ = heard
        if _songKeys == nil { _songKeys = Set(allTracks.map { Self.songKey($0.title, $0.artist) }) }
        let have = _songKeys ?? []
        var seen = Set<String>()
        return list.filter { m in
            let key = Self.songKey(m.title, m.artist)
            return !have.contains(key) && moduleTrack(m) == nil && seen.insert(key).inserted
        }
    }

    /// "Get Lucky (feat. Pharrell Williams) - Radio Edit" by "Daft Punk, Pharrell" → "getlucky|daftpunk".
    private static func songKey(_ title: String, _ artist: String) -> String {
        func core(_ s: String, cutAt marks: [String]) -> String {
            var s = SmartSearch.norm(s)
            for mark in marks {
                if let r = s.range(of: mark), r.lowerBound > s.startIndex { s = String(s[..<r.lowerBound]) }
            }
            return String(String.UnicodeScalarView(s.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
        }
        return core(title, cutAt: [" (", " [", " - ", " feat"]) + "|" + core(artist, cutAt: [",", " & ", " feat", " ft.", " x "])
    }

    var totalSize: Int64 {
        tracks.reduce(0) { sum, t in
            guard !t.path.isEmpty else { return sum }
            let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.url(for: t).path)
            return sum + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    // MARK: Pins & favourites

    func isPinned(_ e: LibraryEntry) -> Bool { pinned.contains(PinnedItem(kind: e.kind, key: e.key)) }
    func togglePin(_ e: LibraryEntry) {
        let item = PinnedItem(kind: e.kind, key: e.key)
        withAnimation(.smooth) {
            if let i = pinned.firstIndex(of: item) { pinned.remove(at: i) } else { pinned.append(item) }
        }
    }
    func isFavorite(_ e: LibraryEntry) -> Bool { favorites.contains(e.id) }
    func toggleFavorite(_ e: LibraryEntry) {
        if favorites.contains(e.id) { favorites.remove(e.id) } else { favorites.insert(e.id) }
    }

    func recordPlay(_ id: UUID) {
        update(id) { $0.playCount = ($0.playCount ?? 0) + 1; $0.lastPlayed = Date() }
        if let t = trackByID[id] { onPlayed(t) }
    }

    func recordSkip(_ id: UUID) {
        update(id) { $0.skipCount = ($0.skipCount ?? 0) + 1; $0.lastSkipped = Date() }
    }

    func toggleFavorite(_ track: Track) {
        keep([track.id])
        update(track.id) { $0.isFavorite.toggle() }
        if let t = trackByID[track.id] { onFavoriteChanged(t) }
    }

    // MARK: Mutations

    func update(_ id: UUID, _ change: (inout Track) -> Void) {
        if _trackByID == nil { buildIndex() }
        // Plays, lyrics and analysis results arrive one song at a time; patching keeps that from
        // rebuilding the index of the whole library on every change.
        if let i = _trackIndex[id], tracks.indices.contains(i), tracks[i].id == id {
            let old = tracks[i]
            var t = old
            change(&t)
            guard t != old else { return }
            patching = true
            tracks[i] = t
            patching = false
            patched(old, t)
        } else if let i = _heardIndex[id], heard.indices.contains(i), heard[i].id == id {
            let old = heard[i]
            var t = old
            change(&t)
            guard t != old else { return }
            patching = true
            heard[i] = t
            patching = false
            patched(old, t)
        }
    }

    /// Applies one change to many songs with a single rebuild.
    func updateMany(_ ids: Set<UUID>, _ change: (inout Track) -> Void) {
        guard !ids.isEmpty else { return }
        var copy = tracks
        for i in copy.indices where ids.contains(copy[i].id) { change(&copy[i]) }
        tracks = copy
        if heard.contains(where: { ids.contains($0.id) }) {
            var h = heard
            for i in h.indices where ids.contains(h[i].id) { change(&h[i]) }
            heard = h
        }
    }

    /// Replaces songs with the same id and appends new ones (used by streaming sources; no duplicate matching).
    func upsert(_ list: [Track]) {
        var copy = tracks
        var index: [UUID: Int] = [:]
        for (i, t) in copy.enumerated() { index[t.id] = i }
        for t in list {
            if let i = index[t.id] { copy[i] = t } else { index[t.id] = copy.count; copy.append(t) }
        }
        tracks = copy
    }

    func finishStatus() {
        if let total = importStatus?.total { importStatus?.done = total }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.smooth) { importStatus = nil }
        }
    }

    func replace(_ updated: [Track]) {
        if _trackByID == nil { buildIndex() }
        var copy = tracks, h = heard
        for t in updated {
            if let i = _trackIndex[t.id] { copy[i] = t }
            else if let i = _heardIndex[t.id] { h[i] = t }
        }
        tracks = copy
        if h != heard { heard = h }
    }

    /// Adds a song that was only played (not added) — see `heard`.
    func addHeard(_ t: Track) { heard.append(t) }
    func addHeard(_ list: [Track]) { heard += list }

    private struct DupeKey: Hashable {
        let title, artist, album: String
        init(_ t: Track) { title = t.title; artist = t.artist; album = t.album }
    }

    /// Adds tracks, skipping duplicates. Returns the ids the input tracks resolve to (existing ids for duplicates).
    @discardableResult
    func merge(_ new: [Track]) -> [UUID] {
        var ids: [UUID] = []
        var toAdd: [Track] = []
        guard !new.isEmpty else { return [] }
        // Songs by title, artist and album, in library order (then the ones added here), for the duplicate check.
        var known: [DupeKey: [(id: UUID, duration: Double)]] = [:]
        for t in tracks { known[DupeKey(t), default: []].append((t.id, t.duration)) }
        for t in new {
            let key = DupeKey(t)
            if let dupe = known[key]?.first(where: { abs($0.duration - t.duration) < 0.6 }), dupe.id != t.id {
                ids.append(dupe.id)
                if t.path.hasPrefix("Imported/") { try? FileManager.default.removeItem(at: Paths.url(for: t)) }
                try? FileManager.default.removeItem(at: Paths.artworkURL(for: t.id))
            } else {
                ids.append(t.id)
                toAdd.append(t)
                known[key, default: []].append((t.id, t.duration))
            }
        }
        if !toAdd.isEmpty { tracks += toAdd }
        return ids
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids {
            guard let t = trackByID[id] else { continue }
            if !t.path.isEmpty { try? FileManager.default.removeItem(at: Paths.url(for: t)) }
            StreamCache.remove(id)
            try? FileManager.default.removeItem(at: Paths.artworkURL(for: id))
            ArtworkCache.evict(id)
        }
        onTracksDeleted(ids)
        var lists = playlists
        for i in lists.indices { lists[i].trackIDs.removeAll { ids.contains($0) } }
        if lists != playlists { playlists = lists }
        tracks.removeAll { ids.contains($0.id) }
        if heard.contains(where: { ids.contains($0.id) }) { heard.removeAll { ids.contains($0.id) } }
        downloadOrder.removeAll { ids.contains($0) }
        pinned.removeAll { entry($0.kind, $0.key) == nil }
    }

    func deleteAll() { delete(Set(allTracks.map(\.id))) }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(name: String, trackIDs: [UUID] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        keep(trackIDs)
        let p = Playlist(name: trimmed.isEmpty ? "New Playlist" : trimmed, trackIDs: trackIDs)
        withAnimation(.smooth) { playlists.append(p) }
        return p
    }

    func add(_ ids: [UUID], to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        keep(ids)
        playlists[i].trackIDs.append(contentsOf: ids.filter { !playlists[i].trackIDs.contains($0) })
    }

    func rename(_ playlistID: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }), !name.isEmpty else { return }
        playlists[i].name = name
    }

    func deletePlaylist(_ id: UUID) {
        withAnimation(.smooth) {
            playlists.removeAll { $0.id == id }
            pinned.removeAll { $0.kind == .playlist && $0.key == id.uuidString }
        }
    }

    func setPlaylistTracks(_ id: UUID, _ ids: [UUID]) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        keep(ids)
        playlists[i].trackIDs = ids
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            // Taken when writing, not on every change: a snapshot held while changes keep coming would make
            // each of them copy the whole song list.
            let snapshot = Snapshot(tracks: tracks, playlists: playlists, pinned: pinned, favorites: favorites, heard: heard, downloadOrder: downloadOrder)
            await Task.detached(priority: .utility) { Self.write(snapshot) }.value
        }
    }

    nonisolated private static func write(_ snap: Snapshot) {
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: Paths.database, options: .atomic) }
    }
}
