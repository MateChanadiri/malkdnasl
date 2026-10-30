import Foundation

/// Remembers online lookups so Clean Library never asks for the same album or song twice:
/// answers are kept on disk, and callers asking at the same time share one request.
/// Misses are tried again after a few days, in case the catalog (or the connection) was the problem.
actor LookupCache {
    static let shared = LookupCache()

    private struct Entry: Codable {
        var data: Data?
        var date: Date
    }

    private static let missLifetime: TimeInterval = 3 * 86_400
    private static var file: URL { Paths.support.appendingPathComponent("lookups.json") }

    private var entries: [String: Entry]
    private var running: [String: Task<Data?, Never>] = [:]
    private var saveTask: Task<Void, Never>?

    init() {
        entries = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// True when `key` can be answered without going online.
    func isKnown(_ key: String) -> Bool {
        guard let e = entries[key] else { return false }
        return e.data != nil || Date().timeIntervalSince(e.date) < Self.missLifetime
    }

    func value<T: Codable & Sendable>(_ key: String, fetch: @escaping @Sendable () async -> T?) async -> T? {
        if isKnown(key), let e = entries[key] { return e.data.flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
        let task = running[key] ?? Task { await fetch().flatMap { try? JSONEncoder().encode($0) } }
        running[key] = task
        let data = await task.value
        running[key] = nil
        entries[key] = Entry(data: data, date: Date())
        scheduleSave()
        return data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    // MARK: Keys and typed lookups

    nonisolated private static func norm(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }
    nonisolated static func albumKey(artist: String, album: String) -> String { "album|\(norm(artist))|\(norm(album))" }
    nonisolated static func songKey(artist: String, title: String) -> String { "song|\(norm(artist))|\(norm(title))" }

    func album(artist: String, album: String) async -> MetadataLookup.AlbumHit? {
        await value(Self.albumKey(artist: artist, album: album)) { await MetadataLookup.album(artist: artist, album: album) }
    }

    func coverArtArchive(artist: String, album: String) async -> URL? {
        await value("caa|\(Self.norm(artist))|\(Self.norm(album))") { await MetadataLookup.coverArtArchive(artist: artist, album: album) }
    }

    func tracklist(collectionID: Int) async -> [MetadataLookup.CatalogTrack] {
        await value("tracks|\(collectionID)") { () -> [MetadataLookup.CatalogTrack]? in
            let list = await MetadataLookup.tracklist(collectionID: collectionID)
            return list.isEmpty ? nil : list
        } ?? []
    }

    nonisolated static func motionKey(artist: String, album: String) -> String { "motion|\(norm(artist))|\(norm(album))" }

    func motion(artist: String, album: String) async -> URL? {
        await value(Self.motionKey(artist: artist, album: album)) { await MotionArtwork.find(artist: artist, album: album) }
    }

    func song(artist: String, title: String) async -> MetadataLookup.SongHit? {
        await value(Self.songKey(artist: artist, title: title)) { await MetadataLookup.song(artist: artist, title: title) }
    }
}
