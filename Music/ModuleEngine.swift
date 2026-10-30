import Foundation
import JavaScriptCore
import Observation
import CryptoKit

// MARK: - Models

/// A track as returned by a module's `searchTracks` / `getAlbum`.
nonisolated struct ModuleTrack: Sendable, Hashable, Identifiable {
    var moduleID: String
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var cover: String?
    var albumArtist: String? = nil
    var albumID: String? = nil
    var trackNumber: Int = 0
    var year: Int? = nil
    var id: String { "\(moduleID):\(trackID)" }

    /// Refresh source metadata without replacing the saved song's identity, download or user edits.
    func enriching(_ saved: Track) -> Track {
        var track = saved
        if track.artworkURL?.isEmpty != false { track.artworkURL = cover }
        if track.remoteAlbumID?.isEmpty != false { track.remoteAlbumID = albumID }
        if !track.metadataLocked {
            if track.album.isEmpty || track.album == "Unknown Album" { track.album = album }
            if track.albumArtist?.isEmpty != false { track.albumArtist = albumArtist }
            if track.trackNumber == 0 { track.trackNumber = trackNumber }
            if track.year == nil { track.year = year }
        }
        return track
    }

    /// A stable, unsaved song for catalog pages. Merely browsing must not add songs to the library.
    var previewTrack: Track {
        let bytes = Array(SHA256.hash(data: Data(id.utf8)).prefix(16))
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        var track = Track(id: uuid, title: title, artist: artist, album: album, duration: duration, path: "")
        track.sourceID = "module:\(moduleID)"
        track.remoteID = trackID
        track.albumArtist = albumArtist
        track.remoteAlbumID = albumID
        track.trackNumber = trackNumber
        track.year = year
        track.artworkURL = cover
        return track
    }
}

nonisolated struct ModuleSetting: Codable, Hashable, Sendable, Identifiable {
    struct Option: Codable, Hashable, Sendable { var value: String; var label: String }   // value = JSON fragment
    var key: String
    var type: String
    var label: String
    var detail: String?
    var options: [Option]
    var defaultValue: String      // JSON fragment
    var id: String { key }
}

nonisolated struct InstalledModule: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var version: String
    var author: String?
    var detail: String?
    var labels: [String]
    var functions: [String]
    var settings: [ModuleSetting]
    var values: [String: String] = [:]   // key → JSON fragment
    var sourceURL: String?
    var enabled = true
    var installedAt = Date()

    var canSearch: Bool { functions.contains("searchTracks") }
    var canArtist: Bool { functions.contains("getArtistTracks") }
    var canStream: Bool { functions.contains("getTrackStreamUrl") }
    var canAlbum: Bool { functions.contains("getAlbum") }
    var sourceID: String { "module:\(id)" }
}

/// A Browse Categories tile supplied by an extension.
nonisolated struct ModuleCategory: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var image: String?
}

/// One module's songs for a shelf (search results or suggestions).
struct ModuleShelf: Identifiable {
    var module: InstalledModule
    var tracks: [ModuleTrack]
    var id: String { module.id }
}

nonisolated struct ModuleRepo: Codable, Hashable, Sendable, Identifiable {
    struct Entry: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var version: String
        var author: String?
        var description: String?
        var tags: [String]
        var url: String
        var locked: Bool? = nil
    }
    var url: String
    var name: String
    var entries: [Entry]
    var id: String { url }
}

nonisolated enum ModuleError: LocalizedError {
    case invalid(String), unsupported(String), timeout, notInstalled, encrypted
    var errorDescription: String? {
        switch self {
        case .encrypted: "This extension is in a locked format that \(Brand.name) can't run. \(Brand.name) runs open extensions: plain JavaScript files that start with “export const …”."
        case .invalid(let m): "This isn't a working extension: \(m)"
        case .unsupported(let f): "This extension doesn't support \(f)."
        case .timeout: "The extension took too long to answer."
        case .notInstalled: "The extension isn't installed or is switched off."
        }
    }
}

// MARK: - Engine

/// Runs 8SPINE-compatible modules (plain JavaScript) in a sandboxed JavaScriptCore context.
/// Modules only get what a browser would give them for talking to the web: fetch, URL, timers, base64, console.
/// They have no access to files, the library or anything else in Music.
@MainActor
@Observable
final class ModuleStore {
    static let shared = ModuleStore()

    private(set) var modules: [InstalledModule] = [] { didSet { saveList() } }
    private(set) var repos: [ModuleRepo] = [] { didSet { saveRepos() } }
    private(set) var logs: [String] = []
    /// Songs to discover, seeded with what you play most (see `refreshSuggestions`).
    private(set) var suggestions: [ModuleShelf] = []
    private(set) var chartTracks: [ModuleTrack] = []
    private(set) var categories: [ModuleCategory] = []
    @ObservationIgnored private var discoveryAt: Date?
    @ObservationIgnored private var suggestionsAt: Date?
    @ObservationIgnored private var suggesting = false

    @ObservationIgnored private var context: JSContext?
    @ObservationIgnored private var loaded = Set<String>()
    @ObservationIgnored private var pendingCalls: [Int: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored private var nextCall = 1

    private static var dir: URL {
        let u = Paths.support.appendingPathComponent("Modules", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static var listURL: URL { dir.appendingPathComponent("modules.json") }
    private static var reposURL: URL { dir.appendingPathComponent("repos.json") }
    private static func codeURL(_ id: String) -> URL { dir.appendingPathComponent("\(id.replacingOccurrences(of: "/", with: "_")).js") }

    private init() {
        if let d = try? Data(contentsOf: Self.listURL), let list = try? JSONDecoder().decode([InstalledModule].self, from: d) { modules = list }
        if let d = try? Data(contentsOf: Self.reposURL), let list = try? JSONDecoder().decode([ModuleRepo].self, from: d) { repos = list }
    }

    var enabled: [InstalledModule] { modules.filter(\.enabled) }
    var hasSearchModules: Bool { enabled.contains(where: \.canSearch) }
    func module(_ id: String) -> InstalledModule? { modules.first { $0.id == id } }
    func module(forSource sourceID: String?) -> InstalledModule? {
        guard let s = sourceID, s.hasPrefix("module:") else { return nil }
        return module(String(s.dropFirst(7)))
    }

    // MARK: Install / remove

    /// Accepts built `.8spine` files (`export const X = \`…\``), raw sources with `// @8spine-export`, or plain module code.
    static func normalizeCode(_ raw: String) -> String {
        var code = raw
        if let m = code.firstMatch(of: /export\s+const\s+\w+\s*=\s*`([\s\S]+)`\s*;?\s*$/) {
            code = String(m.1)
                .replacingOccurrences(of: "\\`", with: "`")
                .replacingOccurrences(of: "\\$", with: "$")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        code = code.replacingOccurrences(of: #"(?m)^\s*//\s*@8spine-export\s+\w+\s*$"#, with: "", options: .regularExpression)
        let hasTopReturn = code.range(of: #"(?m)^return\s*[\{\w]"#, options: .regularExpression) != nil
        if !hasTopReturn {
            if let m = code.firstMatch(of: /(?m)^export\s+default\s+/) {
                code.replaceSubrange(m.range, with: "return ")
            } else if let m = code.firstMatch(of: /(?m)^export\s+const\s+(\w+)\s*=\s*/) {
                let name = String(m.1)
                code.replaceSubrange(m.range, with: "var \(name) = ")
                code += "\nreturn \(name);"
            }
        }
        return code
    }

    /// 8SPINE's locked module files start with "8SM1." followed by encoded data.
    nonisolated static func isLocked(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).firstMatch(of: /^8SM\d+\./) != nil
    }

    @discardableResult
    func install(code raw: String, sourceURL: String?) throws -> InstalledModule {
        if Self.isLocked(raw) { throw ModuleError.encrypted }
        let code = Self.normalizeCode(raw)
        let ctx = engine()
        let tempID = "__install_\(UUID().uuidString.prefix(8))"
        guard let info = load(code: code, as: tempID, in: ctx) else {
            throw ModuleError.invalid(lastError ?? "it didn't return an extension object")
        }
        var mod = info
        guard !mod.id.isEmpty else { throw ModuleError.invalid("it has no id") }
        guard mod.canSearch || mod.canArtist || mod.canStream || mod.canAlbum else { throw ModuleError.invalid("it has no searchTracks / getArtistTracks / getTrackStreamUrl") }
        ctx.evaluateScript("delete __modules['\(tempID)'];")
        if let old = modules.first(where: { $0.id == mod.id }) {
            mod.values = old.values.filter { k, _ in mod.settings.contains { $0.key == k } }
            mod.enabled = old.enabled
        }
        mod.sourceURL = sourceURL
        try code.write(to: Self.codeURL(mod.id), atomically: true, encoding: .utf8)
        loaded.remove(mod.id)
        if let i = modules.firstIndex(where: { $0.id == mod.id }) { modules[i] = mod } else { modules.append(mod) }
        log("info", "[\(Brand.name)] Installed \(mod.name) \(mod.version)")
        return mod
    }

    func install(from url: URL) async throws -> InstalledModule {
        var req = URLRequest(url: Self.rawURL(url))
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) { throw SourceError.server(code) }
        guard let text = String(data: data, encoding: .utf8) else { throw ModuleError.invalid("the file isn't text") }
        if Self.isLocked(text) { throw ModuleError.encrypted }
        // A repository index instead of a module? Offer its modules.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), (try? JSONSerialization.jsonObject(with: data)) != nil,
           !text.contains("searchTracks") {
            _ = try await addRepo(url)
            throw ModuleError.invalid("that link is an extension list. It was added under Repositories")
        }
        return try install(code: text, sourceURL: url.absoluteString)
    }

    func remove(_ id: String) {
        modules.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.codeURL(id))
        loaded.remove(id)
        context?.evaluateScript("delete __modules[\(Self.jsString(id))];")
    }

    func setEnabled(_ id: String, _ on: Bool) {
        if let i = modules.firstIndex(where: { $0.id == id }) { modules[i].enabled = on }
    }

    func setValue(_ id: String, key: String, json: String) {
        if let i = modules.firstIndex(where: { $0.id == id }) { modules[i].values[key] = json }
    }

    func value(_ m: InstalledModule, _ s: ModuleSetting) -> String { m.values[s.key] ?? s.defaultValue }

    /// Reads the entries of a repository file. Synchronous, so nothing non-Sendable crosses an await.
    nonisolated private static func parseRepoEntries(_ data: Data, base: URL) -> [ModuleRepo.Entry]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var entries: [ModuleRepo.Entry] = []
        func take(_ list: [[String: Any]]) {
            for e in list {
                let file: String? = (e["download"] as? String) ?? (e["file"] as? String) ?? (e["url"] as? String)
                guard let file else { continue }
                let folder: String = (e["folder"] as? String).map { $0 + "/" } ?? ""
                let full: URL? = file.hasPrefix("http") ? URL(string: file) : URL(string: folder + file, relativeTo: base)?.absoluteURL
                guard let full else { continue }
                entries.append(.init(id: (e["id"] as? String) ?? file, name: (e["name"] as? String) ?? file,
                                     version: (e["version"] as? String) ?? "", author: e["author"] as? String,
                                     description: e["description"] as? String, tags: (e["tags"] as? [String]) ?? [],
                                     url: full.absoluteString))
            }
        }
        if let dict = obj as? [String: Any] {
            for (_, v) in dict.sorted(by: { $0.key < $1.key }) { if let list = v as? [[String: Any]] { take(list) } }
            if let list = dict["modules"] as? [[String: Any]] { take(list) }
        } else if let list = obj as? [[String: Any]] { take(list) }
        return entries
    }


    // MARK: Repositories (8SPINE "module-source.json")

    @discardableResult
    func addRepo(_ url: URL) async throws -> ModuleRepo {
        let src = Self.rawURL(url)
        let (data, _) = try await URLSession.shared.data(from: src)
        guard var entries = Self.parseRepoEntries(data, base: src.deletingLastPathComponent()) else { throw ModuleError.invalid("the repository isn't JSON") }
        guard !entries.isEmpty else { throw ModuleError.invalid("no extensions found in that repository") }
        // Peek at each file so locked 8SPINE-only modules are marked instead of failing on install.
        for i in entries.indices {
            guard let u = URL(string: entries[i].url) else { continue }
            var r = URLRequest(url: Self.rawURL(u))
            r.setValue("bytes=0-15", forHTTPHeaderField: "Range")
            r.timeoutInterval = 10
            if let (d, _) = try? await URLSession.shared.data(for: r), let head = String(data: d.prefix(16), encoding: .utf8) {
                entries[i].locked = Self.isLocked(head)
            }
        }
        let name = src.host() ?? "Repository"
        let repo = ModuleRepo(url: src.absoluteString, name: name, entries: entries)
        repos.removeAll { $0.url == repo.url }
        repos.append(repo)
        return repo
    }

    func removeRepo(_ url: String) { repos.removeAll { $0.url == url } }

    /// GitHub "blob" pages → raw files.
    static func rawURL(_ url: URL) -> URL {
        guard url.host() == "github.com", url.path().contains("/blob/") else { return url }
        let s = url.absoluteString.replacingOccurrences(of: "://github.com/", with: "://raw.githubusercontent.com/").replacingOccurrences(of: "/blob/", with: "/")
        return URL(string: s) ?? url
    }

    // MARK: Calls

    func search(_ query: String, limit: Int = 20) async -> [(InstalledModule, [ModuleTrack])] {
        var out: [(InstalledModule, [ModuleTrack])] = []
        for m in enabled where m.canSearch {
            do {
                let tracks = try await searchTracks(m, query, limit: limit)
                if !tracks.isEmpty { out.append((m, tracks)) }
            } catch {
                log("error", "[\(m.name)] search failed: \(error.localizedDescription)")
            }
        }
        return out
    }

    /// Whether modules can be asked right now (one that searches is on, the iPhone is online, Offline Mode is off).
    func canDiscover(offlineMode: Bool) -> Bool { hasSearchModules && NetworkMonitor.shared.isOnline && !offlineMode }

    /// Asks each module for songs like `seeds` (your most played). Modules with `getRecommendations(ids, limit)`
    /// answer directly; others are searched for the artists you play most. Cached for 30 minutes.
    func refreshSuggestions(seeds: [Track], force: Bool = false) async {
        guard !suggesting, NetworkMonitor.shared.isOnline, hasSearchModules else { return }
        if !force, let at = suggestionsAt, Date().timeIntervalSince(at) < 1800 { return }
        suggesting = true
        defer { suggesting = false }
        var out: [ModuleShelf] = []
        for m in enabled where m.canSearch {
            let own = seeds.filter { $0.sourceID == m.sourceID }.compactMap(\.remoteID)
            do {
                var list: [ModuleTrack] = []
                if m.functions.contains("getRecommendations") {
                    let ids = "[" + own.prefix(5).map(Self.jsString).joined(separator: ",") + "]"
                    list = Self.parseTracks(try await call(m, "getRecommendations", args: [["__json": ids], 24]), moduleID: m.id)
                } else {
                    var artists: [String] = []
                    for t in seeds where !artists.contains(t.artist) && artists.count < 3 { artists.append(t.artist) }
                    var lists: [[ModuleTrack]] = []
                    for a in artists { lists.append((try? await searchTracks(m, a, limit: 15)) ?? []) }
                    for i in 0..<(lists.map(\.count).max() ?? 0) { for l in lists where i < l.count { list.append(l[i]) } }
                }
                var seen = Set(own)
                list = list.filter { seen.insert($0.trackID).inserted }
                if !list.isEmpty { out.append(ModuleShelf(module: m, tracks: list)) }
            } catch {
                log("error", "[\(m.name)] suggestions failed: \(error.localizedDescription)")
            }
        }
        suggestions = out
        suggestionsAt = Date()
    }

    /// Today's Hits and Browse Categories from extensions that offer `getCharts` / `getCategories`. Cached for 30 minutes.
    func refreshDiscovery(force: Bool = false) async {
        guard NetworkMonitor.shared.isOnline, hasSearchModules else { return }
        if !force, let at = discoveryAt, Date().timeIntervalSince(at) < 1800 { return }
        discoveryAt = Date()
        var hits: [ModuleTrack] = []
        var cats: [ModuleCategory] = []
        for m in enabled where m.canSearch {
            if m.functions.contains("getCharts") {
                if let json = try? await call(m, "getCharts", args: [40]) {
                    hits.append(contentsOf: Self.parseTracks(json, moduleID: m.id))
                }
            }
            if m.functions.contains("getCategories") {
                if let json = try? await call(m, "getCategories", args: []) {
                    cats.append(contentsOf: Self.parseCategories(json))
                }
            }
        }
        chartTracks = hits
        categories = cats
    }

    /// The songs of one category, asked from every extension that supports `getCategoryTracks`; others are searched by name.
    func categoryTracks(_ name: String, id: String) async -> [ModuleTrack] {
        var out: [ModuleTrack] = []
        for m in enabled where m.canSearch {
            if m.functions.contains("getCategoryTracks") {
                if let json = try? await call(m, "getCategoryTracks", args: [name, id, 50]) {
                    out.append(contentsOf: Self.parseTracks(json, moduleID: m.id))
                }
            } else if let found = try? await searchTracks(m, name, limit: 30) {
                out.append(contentsOf: found)
            }
        }
        return out
    }

    nonisolated static func parseCategories(_ json: String) -> [ModuleCategory] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return [] }
        var rows: [[String: Any]] = []
        if let a = obj as? [[String: Any]] {
            rows = a
        } else if let d = obj as? [String: Any], let a = d["categories"] as? [[String: Any]] {
            rows = a
        }
        var out: [ModuleCategory] = []
        for r in rows {
            let name: String = (r["name"] as? String) ?? ""
            if name.isEmpty { continue }
            let rawID: String = (r["id"] as? String) ?? (r["id"] as? NSNumber)?.stringValue ?? name
            out.append(ModuleCategory(id: rawID, name: name, image: imageURL(r["image"])))
        }
        return out
    }

    func searchTracks(_ m: InstalledModule, _ query: String, limit: Int = 20) async throws -> [ModuleTrack] {
        let json = try await call(m, "searchTracks", args: [query, limit])
        return Self.parseTracks(json, moduleID: m.id)
    }

    func album(_ m: InstalledModule, id: String) async throws -> [ModuleTrack] {
        let json = try await call(m, "getAlbum", args: [id])
        return Self.parseTracks(json, moduleID: m.id)
    }

    /// Prefer an extension's artist catalog; search-only extensions remain compatible.
    /// Publish search results immediately, then fill in their albums with at most four requests at a time.
    func artistTracks(_ m: InstalledModule, name: String,
                      onAlbumFailure: @MainActor (String) -> Void = { _ in },
                      onUpdate: @MainActor ([ModuleTrack]) -> Void = { _ in }) async throws -> [ModuleTrack] {
        let found: [ModuleTrack]
        if m.canArtist {
            found = Self.parseTracks(try await call(m, "getArtistTracks", args: [name]), moduleID: m.id)
        } else {
            found = try await searchTracks(m, name, limit: 500)
        }
        try Task.checkCancellation()
        var seen = Set<String>()
        func relevant(_ tracks: [ModuleTrack]) -> [ModuleTrack] {
            tracks.filter { (ArtistCatalog.matches($0.artist, name: name) || ArtistCatalog.matches($0.albumArtist ?? "", name: name))
                && seen.insert($0.id).inserted }
        }
        var list = relevant(found)
        onUpdate(list)
        if m.canAlbum {
            let ids = Set(list.compactMap(\.albumID)).sorted()
            await withTaskGroup(of: (String, [ModuleTrack]?).self) { group in
                var next = 0
                func add() {
                    guard next < ids.count, !Task.isCancelled else { return }
                    let id = ids[next]
                    next += 1
                    group.addTask {
                        do { return (id, try await self.album(m, id: id)) }
                        catch {
                            if !Task.isCancelled { await self.log("error", "[\(m.name)] artist album failed: \(error.localizedDescription)") }
                            return (id, nil)
                        }
                    }
                }
                for _ in 0..<min(4, ids.count) { add() }
                for await (id, tracks) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let tracks { list += relevant(tracks) }
                    else { onAlbumFailure(id) }
                    onUpdate(list)
                    add()
                }
            }
        }
        try Task.checkCancellation()
        return list
    }

    /// Resolves a playable URL. Stream URLs usually expire, so this is asked again for every play/download.
    func streamURL(moduleID: String, trackID: String, quality: String) async throws -> URL {
        guard let m = module(moduleID), m.enabled else { throw ModuleError.notInstalled }
        let json = try await call(m, "getTrackStreamUrl", args: [trackID, quality])
        guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            throw ModuleError.invalid("no stream")
        }
        var s: String?
        if let str = obj as? String { s = str }
        else if let d = obj as? [String: Any] {
            s = (d["streamUrl"] ?? d["url"] ?? d["stream"] ?? (d["data"] as? [String: Any])?["streamUrl"]) as? String
        }
        guard let s, let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { throw ModuleError.invalid("the extension returned no stream link") }
        return url
    }

    /// Lyrics from an extension that offers `getLyrics(trackID, title, artist, album, duration)`.
    /// It may answer with LRC / plain text, or an object with `syncedLyrics`, `lrc`, `lyrics` or `plainLyrics`.
    func lyrics(moduleID: String, track: Track) async -> String? {
        guard let m = module(moduleID), m.enabled, m.functions.contains("getLyrics"), let rid = track.remoteID else { return nil }
        guard let json = try? await call(m, "getLyrics", args: [rid, track.title, track.artist, track.album, Int(track.duration.rounded())]),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return nil }
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        if let str = obj as? String { return clean(str) }
        if let d = obj as? [String: Any] {
            for key in ["syncedLyrics", "lrc", "synced", "lyrics", "plainLyrics", "text"] {
                if let s = clean(d[key] as? String) { return s }
            }
        }
        return nil
    }

    nonisolated static func parseTracks(_ json: String, moduleID: String) -> [ModuleTrack] {
        guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return [] }
        var list: [[String: Any]] = []
        if let a = obj as? [[String: Any]] { list = a }
        else if let d = obj as? [String: Any] {
            list = (d["tracks"] as? [[String: Any]]) ?? (d["items"] as? [[String: Any]]) ?? (d["results"] as? [[String: Any]]) ?? []
        }
        func str(_ v: Any?) -> String? {
            if let s = v as? String, !s.isEmpty { return s }
            if let n = v as? NSNumber { return n.stringValue }
            if let d = v as? [String: Any] { return str(d["name"] ?? d["title"]) }
            if let a = v as? [Any], let f = a.first { return str(f) }
            return nil
        }
        return list.compactMap { t in
            guard let id = str(t["id"] ?? t["trackId"]), let title = str(t["title"] ?? t["name"]) else { return nil }
            var duration = (t["duration"] as? NSNumber)?.doubleValue ?? Double(str(t["duration"]) ?? "") ?? 0
            if duration > 36_000 { duration /= 1000 }   // milliseconds
            let album = t["album"]
            let albumObject = album as? [String: Any]
            let coverKeys = ["albumCover", "albumCoverUrl", "albumCoverURL", "cover", "coverUrl", "coverURL",
                             "artwork", "artworkUrl", "artworkURL", "image", "imageUrl", "imageURL",
                             "cover_xl", "cover_big", "cover_medium", "artworkUrl100"]
            let cover = coverKeys.compactMap { imageURL(t[$0]) }.first
                ?? albumObject.flatMap { album in coverKeys.compactMap { imageURL(album[$0]) }.first }
            return ModuleTrack(moduleID: moduleID, trackID: id, title: title, artist: str(t["artist"] ?? t["artists"]) ?? "Unknown Artist",
                               album: str(album) ?? "Unknown Album", duration: duration, cover: cover,
                               albumArtist: str(t["albumArtist"] ?? albumObject?["artist"]),
                               albumID: str(t["albumId"] ?? t["albumID"] ?? t["album_id"] ?? albumObject?["id"]),
                               trackNumber: Int(str(t["trackNumber"] ?? t["track_position"]) ?? "") ?? 0,
                               year: Int(str(t["year"]) ?? ""))
        }
    }

    /// Artwork is often returned as an object or a list of image sizes, rather than a plain URL.
    nonisolated private static func imageURL(_ value: Any?) -> String? {
        if let string = value as? String {
            var link = string.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
            if link.hasPrefix("//") { link = "https:" + link }
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  ["https", "http"].contains(scheme), url.host != nil else { return nil }
            return url.absoluteString
        }
        if let object = value as? [String: Any] {
            for key in ["xl", "large", "cover_xl", "cover_big", "url", "src", "uri", "source", "medium", "small", "cover", "image", "artwork"] {
                if let link = imageURL(object[key]) { return link }
            }
        }
        if let images = value as? [Any] {
            let sorted = images.sorted {
                let left = (($0 as? [String: Any])?["width"] as? NSNumber)?.intValue ?? 0
                let right = (($1 as? [String: Any])?["width"] as? NSNumber)?.intValue ?? 0
                return left > right
            }
            for image in sorted { if let link = imageURL(image) { return link } }
        }
        return nil
    }

    private func call(_ m: InstalledModule, _ fn: String, args: [Any]) async throws -> String {
        guard m.functions.contains(fn) else { throw ModuleError.unsupported(fn) }
        let ctx = engine()
        if !loaded.contains(m.id) {
            guard let code = try? String(contentsOf: Self.codeURL(m.id), encoding: .utf8), load(code: code, as: m.id, in: ctx) != nil else {
                throw ModuleError.invalid(lastError ?? "couldn't load")
            }
            loaded.insert(m.id)
        }
        var allArgs = args
        // Third argument: the context 8SPINE passes (settings as { key: { value } }).
        let settingsJSON = "{" + m.settings.map { "\(Self.jsString($0.key)):{\"value\":\(value(m, $0))}" }.joined(separator: ",") + "}"
        allArgs.append(["__json": "{\"settings\":\(settingsJSON)}"])
        let argsJSON = "[" + allArgs.map { a -> String in
            if let d = a as? [String: String], let j = d["__json"] { return j }
            if let s = a as? String { return Self.jsString(s) }
            return "\(a)"
        }.joined(separator: ",") + "]"

        let id = nextCall
        nextCall += 1
        return try await withCheckedThrowingContinuation { cont in
            pendingCalls[id] = cont
            ctx.objectForKeyedSubscript("__invoke").call(withArguments: [id, m.id, fn, argsJSON])
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                MainActor.assumeIsolated {
                    if let c = self?.pendingCalls.removeValue(forKey: id) { c.resume(throwing: ModuleError.timeout) }
                }
            }
        }
    }

    // MARK: JavaScriptCore

    @ObservationIgnored private var lastError: String?

    private func load(code: String, as id: String, in ctx: JSContext) -> InstalledModule? {
        lastError = nil
        let loader = ctx.objectForKeyedSubscript("__loadModule")
        let result = loader?.call(withArguments: [id, code])
        guard lastError == nil, let json = result?.toString(), let data = json.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let settings: [ModuleSetting] = ((d["settings"] as? [[String: Any]]) ?? []).map { s in
            ModuleSetting(key: s["key"] as? String ?? "", type: (s["type"] as? String ?? "selector").lowercased(),
                          label: s["label"] as? String ?? (s["key"] as? String ?? ""), detail: s["description"] as? String,
                          options: ((s["options"] as? [[String: String]]) ?? []).map { .init(value: $0["value"] ?? "null", label: $0["label"] ?? "") },
                          defaultValue: s["defaultValue"] as? String ?? "null")
        }
        return InstalledModule(id: d["id"] as? String ?? "", name: d["name"] as? String ?? (d["id"] as? String ?? "Extension"),
                               version: d["version"] as? String ?? "", author: d["author"] as? String, detail: d["description"] as? String,
                               labels: (d["labels"] as? [String]) ?? [], functions: (d["functions"] as? [String]) ?? [], settings: settings)
    }

    private func engine() -> JSContext {
        if let context { return context }
        let ctx = JSContext()!
        ctx.name = "Extensions"
        ctx.exceptionHandler = { [weak self] _, exception in
            let msg = exception?.toString() ?? "error"
            MainActor.assumeIsolated {
                self?.lastError = msg
                self?.log("error", "JS: \(msg)")
            }
        }

        let logBlock: @convention(block) (String, String) -> Void = { [weak self] level, msg in
            MainActor.assumeIsolated { self?.log(level, msg) }
        }
        let timerBlock: @convention(block) (Int, Double) -> Void = { [weak ctx] id, ms in
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ms) / 1000) {
                ctx?.objectForKeyedSubscript("__timer_fire").call(withArguments: [id])
            }
        }
        let atobBlock: @convention(block) (String) -> String = { s in
            var t = s.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            guard let d = Data(base64Encoded: t) else { return "" }
            return String(String.UnicodeScalarView(d.map { Unicode.Scalar($0) }))
        }
        let btoaBlock: @convention(block) (String) -> String = { s in
            Data(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }).base64EncodedString()
        }
        let settleBlock: @convention(block) (Int, Bool, String) -> Void = { [weak self] id, ok, payload in
            MainActor.assumeIsolated {
                guard let c = self?.pendingCalls.removeValue(forKey: id) else { return }
                if ok { c.resume(returning: payload) } else { c.resume(throwing: ModuleError.invalid(payload)) }
            }
        }
        let fetchBlock: @convention(block) (Int, String, String, String, JSValue) -> Void = { [weak ctx] id, urlString, method, headersJSON, body in
            let bodyText = body.isNull || body.isUndefined ? nil : body.toString()
            Task { @MainActor in
                func done(_ args: [Any]) { ctx?.objectForKeyedSubscript("__fetch_done").call(withArguments: [id] + args) }
                guard let url = URL(string: urlString) ?? URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else {
                    done([0, "", "{}", "", "", urlString, "Invalid URL: \(urlString)"]); return
                }
                var req = URLRequest(url: url)
                req.httpMethod = method
                req.timeoutInterval = 30
                if let h = headersJSON.data(using: .utf8).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) {
                    for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) }
                }
                if req.value(forHTTPHeaderField: "User-Agent") == nil { req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) \(Brand.name)/1.0", forHTTPHeaderField: "User-Agent") }
                if let bodyText, method != "GET" { req.httpBody = bodyText.data(using: .utf8) }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let http = resp as? HTTPURLResponse
                    var headers: [String: String] = [:]
                    for (k, v) in http?.allHeaderFields ?? [:] { headers[String(describing: k).lowercased()] = String(describing: v) }
                    let hj = (try? JSONSerialization.data(withJSONObject: headers)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    let b64 = data.count <= 8_000_000 ? data.base64EncodedString() : ""
                    done([http?.statusCode ?? 0, HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0), hj, text, b64,
                          http?.url?.absoluteString ?? urlString, NSNull()])
                } catch {
                    done([0, "", "{}", "", "", urlString, error.localizedDescription])
                }
            }
        }
        ctx.setObject(unsafeBitCast(logBlock, to: AnyObject.self), forKeyedSubscript: "__native_log" as NSString)
        ctx.setObject(unsafeBitCast(timerBlock, to: AnyObject.self), forKeyedSubscript: "__native_timer" as NSString)
        ctx.setObject(unsafeBitCast(atobBlock, to: AnyObject.self), forKeyedSubscript: "__native_atob" as NSString)
        ctx.setObject(unsafeBitCast(btoaBlock, to: AnyObject.self), forKeyedSubscript: "__native_btoa" as NSString)
        ctx.setObject(unsafeBitCast(settleBlock, to: AnyObject.self), forKeyedSubscript: "__native_settle" as NSString)
        ctx.setObject(unsafeBitCast(fetchBlock, to: AnyObject.self), forKeyedSubscript: "__native_fetch" as NSString)
        ctx.evaluateScript(Self.runtime)
        context = ctx
        return ctx
    }

    private func log(_ level: String, _ message: String) {
        logs.append("\(Date().formatted(date: .omitted, time: .standard)) \(level.uppercased()) \(message)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    func clearLogs() { logs.removeAll() }

    nonisolated static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    private func saveList() {
        if let d = try? JSONEncoder().encode(modules) { try? d.write(to: Self.listURL, options: .atomic) }
    }
    private func saveRepos() {
        if let d = try? JSONEncoder().encode(repos) { try? d.write(to: Self.reposURL, options: .atomic) }
    }

    // MARK: Browser-like runtime for modules

    private static let runtime = #"""
    (function (g) {
      g.window = g; g.self = g; g.globalThis = g;
      function fmt(args) {
        var out = [];
        for (var i = 0; i < args.length; i++) {
          var x = args[i];
          if (typeof x === 'string') out.push(x);
          else if (x instanceof Error) out.push(x.name + ': ' + x.message);
          else { try { out.push(JSON.stringify(x)); } catch (e) { out.push(String(x)); } }
        }
        return out.join(' ');
      }
      function lg(level) { return function () { __native_log(level, fmt(arguments)); }; }
      g.console = { log: lg('log'), info: lg('info'), warn: lg('warn'), error: lg('error'), debug: lg('debug'), trace: lg('debug') };

      var timers = {}, nextTimer = 1;
      g.setTimeout = function (fn, ms) { var id = nextTimer++; timers[id] = { fn: fn, args: Array.prototype.slice.call(arguments, 2), every: 0 }; __native_timer(id, +ms || 0); return id; };
      g.setInterval = function (fn, ms) { var id = nextTimer++; timers[id] = { fn: fn, args: Array.prototype.slice.call(arguments, 2), every: Math.max(4, +ms || 0) }; __native_timer(id, +ms || 0); return id; };
      g.clearTimeout = g.clearInterval = function (id) { delete timers[id]; };
      g.__timer_fire = function (id) {
        var t = timers[id]; if (!t) return;
        if (t.every) __native_timer(id, t.every); else delete timers[id];
        try { if (typeof t.fn === 'function') t.fn.apply(null, t.args); } catch (e) { console.error('Timer error', e); }
      };
      g.queueMicrotask = function (fn) { Promise.resolve().then(fn); };

      g.atob = function (s) { return __native_atob(String(s)); };
      g.btoa = function (s) { return __native_btoa(String(s)); };
      g.TextEncoder = function () {};
      g.TextEncoder.prototype.encode = function (s) { var b = unescape(encodeURIComponent(String(s || ''))), a = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) a[i] = b.charCodeAt(i); return a; };
      g.TextDecoder = function () {};
      g.TextDecoder.prototype.decode = function (a) { var u = new Uint8Array(a && a.buffer ? a.buffer : a || []), s = ''; for (var i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); try { return decodeURIComponent(escape(s)); } catch (e) { return s; } };
      g.require = function (name) { throw new Error('require("' + name + '") is not available in modules'); };

      // URLSearchParams / URL
      function dec(s) { try { return decodeURIComponent(String(s).replace(/\+/g, ' ')); } catch (e) { return s; } }
      function enc(s) { return encodeURIComponent(String(s)).replace(/%20/g, '+'); }
      function USP(init) {
        this._p = [];
        if (init == null) return;
        if (init instanceof USP) { this._p = init._p.slice(); return; }
        if (typeof init === 'string') {
          if (init.charAt(0) === '?') init = init.slice(1);
          var parts = init.split('&');
          for (var i = 0; i < parts.length; i++) { if (!parts[i]) continue; var kv = parts[i].split('='); var k = kv.shift(); this._p.push([dec(k), dec(kv.join('='))]); }
        } else if (Array.isArray(init)) { for (var j = 0; j < init.length; j++) this._p.push([String(init[j][0]), String(init[j][1])]); }
        else if (typeof init === 'object') { for (var key in init) if (Object.prototype.hasOwnProperty.call(init, key)) this._p.push([key, String(init[key])]); }
      }
      USP.prototype.append = function (k, v) { this._p.push([String(k), String(v)]); };
      USP.prototype.set = function (k, v) { k = String(k); var f = false; this._p = this._p.filter(function (p) { if (p[0] !== k) return true; if (!f) { p[1] = String(v); f = true; return true; } return false; }); if (!f) this._p.push([k, String(v)]); };
      USP.prototype.get = function (k) { for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === String(k)) return this._p[i][1]; return null; };
      USP.prototype.getAll = function (k) { return this._p.filter(function (p) { return p[0] === String(k); }).map(function (p) { return p[1]; }); };
      USP.prototype.has = function (k) { return this.get(k) !== null; };
      USP.prototype['delete'] = function (k) { this._p = this._p.filter(function (p) { return p[0] !== String(k); }); };
      USP.prototype.forEach = function (cb, t) { for (var i = 0; i < this._p.length; i++) cb.call(t, this._p[i][1], this._p[i][0], this); };
      USP.prototype.entries = function () { return this._p.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); };
      USP.prototype.keys = function () { return this._p.map(function (p) { return p[0]; })[Symbol.iterator](); };
      USP.prototype.values = function () { return this._p.map(function (p) { return p[1]; })[Symbol.iterator](); };
      USP.prototype[Symbol.iterator] = USP.prototype.entries;
      USP.prototype.sort = function () { this._p.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; }); };
      USP.prototype.toString = function () { return this._p.map(function (p) { return enc(p[0]) + '=' + enc(p[1]); }).join('&'); };
      Object.defineProperty(USP.prototype, 'size', { get: function () { return this._p.length; } });
      g.URLSearchParams = USP;

      function URLp(url, base) {
        url = String(url).trim();
        var m = /^([a-zA-Z][a-zA-Z0-9+.\-]*:)\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(url);
        if (!m) {
          if (base === undefined) throw new TypeError('Invalid URL: ' + url);
          var b = base instanceof URLp ? base : new URLp(base);
          if (url.indexOf('//') === 0) return new URLp(b.protocol + url);
          if (url.charAt(0) === '/') return new URLp(b.origin + url);
          if (url.charAt(0) === '?') return new URLp(b.origin + b.pathname + url);
          if (url.charAt(0) === '#') return new URLp(b.origin + b.pathname + b.search + url);
          var dir = b.pathname.replace(/[^\/]*$/, '');
          var segs = (dir + url).split('/'), outp = [];
          for (var i = 0; i < segs.length; i++) { if (segs[i] === '..') outp.pop(); else if (segs[i] !== '.') outp.push(segs[i]); }
          return new URLp(b.origin + outp.join('/'));
        }
        this.protocol = m[1].toLowerCase();
        var auth = m[2], at = auth.lastIndexOf('@');
        if (at >= 0) { var cred = auth.slice(0, at).split(':'); this.username = cred[0] || ''; this.password = cred[1] || ''; auth = auth.slice(at + 1); }
        else { this.username = ''; this.password = ''; }
        this.host = auth.toLowerCase();
        var pm = /^(.*?)(?::(\d+))?$/.exec(this.host);
        this.hostname = pm[1]; this.port = pm[2] || '';
        this.pathname = m[3] || '/';
        this.hash = m[5] || '';
        this.searchParams = new USP(m[4] || '');
      }
      Object.defineProperty(URLp.prototype, 'search', { get: function () { var s = this.searchParams.toString(); return s ? '?' + s : ''; }, set: function (v) { this.searchParams = new USP(v); } });
      Object.defineProperty(URLp.prototype, 'origin', { get: function () { return this.protocol + '//' + this.host; } });
      Object.defineProperty(URLp.prototype, 'href', { get: function () { return this.origin + this.pathname + this.search + this.hash; }, set: function (v) { var n = new URLp(v); for (var k in n) this[k] = n[k]; } });
      URLp.prototype.toString = URLp.prototype.toJSON = function () { return this.href; };
      g.URL = URLp;

      // Headers / Response / fetch
      function Headers(init) {
        this._h = {};
        if (!init) return;
        if (init instanceof Headers) { for (var k in init._h) this._h[k] = init._h[k]; }
        else if (Array.isArray(init)) { for (var i = 0; i < init.length; i++) this._h[String(init[i][0]).toLowerCase()] = String(init[i][1]); }
        else { for (var key in init) this._h[key.toLowerCase()] = String(init[key]); }
      }
      Headers.prototype.get = function (k) { var v = this._h[String(k).toLowerCase()]; return v === undefined ? null : v; };
      Headers.prototype.set = function (k, v) { this._h[String(k).toLowerCase()] = String(v); };
      Headers.prototype.append = Headers.prototype.set;
      Headers.prototype.has = function (k) { return String(k).toLowerCase() in this._h; };
      Headers.prototype['delete'] = function (k) { delete this._h[String(k).toLowerCase()]; };
      Headers.prototype.forEach = function (cb, t) { for (var k in this._h) cb.call(t, this._h[k], k, this); };
      Headers.prototype.entries = function () { var h = this._h; return Object.keys(h).map(function (k) { return [k, h[k]]; })[Symbol.iterator](); };
      Headers.prototype[Symbol.iterator] = Headers.prototype.entries;
      g.Headers = Headers;

      function Resp(text, init, b64, url) {
        init = init || {};
        this.status = init.status === undefined ? 200 : init.status;
        this.statusText = init.statusText || '';
        this.ok = this.status >= 200 && this.status < 300;
        this.headers = new Headers(init.headers);
        this.url = url || '';
        this.redirected = false;
        this.bodyUsed = false;
        this._text = text == null ? '' : String(text);
        this._b64 = b64 || '';
      }
      Resp.prototype.text = function () { this.bodyUsed = true; return Promise.resolve(this._text); };
      Resp.prototype.json = function () { this.bodyUsed = true; var t = this._text; return new Promise(function (res, rej) { try { res(JSON.parse(t)); } catch (e) { rej(new SyntaxError('Unexpected response (not JSON)')); } }); };
      Resp.prototype.arrayBuffer = function () {
        var bin = this._b64 ? atob(this._b64) : unescape(encodeURIComponent(this._text)), a = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
        return Promise.resolve(a.buffer);
      };
      Resp.prototype.clone = function () { var r = new Resp(this._text, { status: this.status, statusText: this.statusText, headers: this.headers._h }, this._b64, this.url); return r; };
      g.Response = Resp;

      function FormData() { this._p = []; }
      FormData.prototype.append = function (k, v) { this._p.push([String(k), String(v)]); };
      FormData.prototype.set = function (k, v) { this['delete'](k); this.append(k, v); };
      FormData.prototype.get = function (k) { for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === k) return this._p[i][1]; return null; };
      FormData.prototype.has = function (k) { return this.get(k) !== null; };
      FormData.prototype['delete'] = function (k) { this._p = this._p.filter(function (p) { return p[0] !== k; }); };
      FormData.prototype._encode = function () {
        var b = '----Music' + Math.random().toString(16).slice(2), s = '';
        for (var i = 0; i < this._p.length; i++) s += '--' + b + '\r\nContent-Disposition: form-data; name="' + this._p[i][0] + '"\r\n\r\n' + this._p[i][1] + '\r\n';
        return { boundary: b, text: s + '--' + b + '--\r\n' };
      };
      g.FormData = FormData;

      function AbortController() { var s = { aborted: false, reason: undefined, _l: [], addEventListener: function (n, f) { if (n === 'abort') s._l.push(f); }, removeEventListener: function () {}, onabort: null }; this.signal = s; }
      AbortController.prototype.abort = function (r) { var s = this.signal; if (s.aborted) return; s.aborted = true; s.reason = r; if (s._onabort) s._onabort(); for (var i = 0; i < s._l.length; i++) try { s._l[i](); } catch (e) {} if (typeof s.onabort === 'function') s.onabort(); };
      g.AbortController = AbortController;
      g.AbortSignal = { timeout: function (ms) { var c = new AbortController(); setTimeout(function () { c.abort(); }, ms); return c.signal; } };

      var pending = {}, nextFetch = 1;
      g.fetch = function (input, init) {
        init = init || {};
        var url = typeof input === 'string' ? input : (input && (input.href || input.url)) || String(input);
        var method = String(init.method || 'GET').toUpperCase();
        var headers = {};
        if (init.headers) { var hh = init.headers instanceof Headers ? init.headers : new Headers(init.headers); for (var k in hh._h) headers[k] = hh._h[k]; }
        var body = init.body, text = null;
        if (body != null) {
          if (typeof body === 'string') text = body;
          else if (body instanceof USP) { text = body.toString(); if (!headers['content-type']) headers['content-type'] = 'application/x-www-form-urlencoded;charset=UTF-8'; }
          else if (body instanceof FormData) { var e = body._encode(); text = e.text; headers['content-type'] = 'multipart/form-data; boundary=' + e.boundary; }
          else { text = JSON.stringify(body); if (!headers['content-type']) headers['content-type'] = 'application/json'; }
        }
        return new Promise(function (resolve, reject) {
          var id = nextFetch++;
          pending[id] = { resolve: resolve, reject: reject };
          var sig = init.signal;
          if (sig) {
            sig._onabort = function () { if (pending[id]) { delete pending[id]; var er = new Error('The operation was aborted.'); er.name = 'AbortError'; reject(er); } };
            if (sig.aborted) { sig._onabort(); return; }
          }
          __native_fetch(id, String(url), method, JSON.stringify(headers), text);
        });
      };
      g.__fetch_done = function (id, status, statusText, headersJSON, text, b64, finalURL, error) {
        var p = pending[id]; if (!p) return; delete pending[id];
        if (error) { p.reject(new TypeError('Network request failed: ' + error)); return; }
        var h = {}; try { h = JSON.parse(headersJSON || '{}'); } catch (e) {}
        p.resolve(new Resp(text, { status: status, statusText: statusText, headers: h }, b64, finalURL));
      };

      // Module loading & calls
      g.__modules = {};
      g.__loadModule = function (id, code) {
        var m = (new Function(code))();
        if (!m || typeof m !== 'object') throw new Error('The module did not return an object');
        g.__modules[id] = m;
        var fns = [];
        for (var k in m) if (typeof m[k] === 'function') fns.push(k);
        var settings = [];
        var s = m.settings || {};
        for (var key in s) {
          var d = s[key] || {};
          var opts = (d.options || []).map(function (o) {
            if (o !== null && typeof o === 'object') {
              var v = o.value !== undefined ? o.value : (o.id !== undefined ? o.id : o.name);
              return { value: JSON.stringify(v), label: String(o.label || o.name || o.title || v) };
            }
            return { value: JSON.stringify(o), label: String(o) };
          });
          var def = d.defaultValue !== undefined ? d.defaultValue : (d['default'] !== undefined ? d['default'] : (d.value !== undefined ? d.value : null));
          settings.push({ key: key, type: String(d.type || (opts.length ? 'selector' : typeof def === 'boolean' ? 'toggle' : 'text')), label: String(d.label || key),
                          description: d.description ? String(d.description) : undefined, options: opts, defaultValue: JSON.stringify(def) });
        }
        return JSON.stringify({ id: String(m.id || ''), name: String(m.name || m.id || ''), version: String(m.version || ''),
          author: m.author ? String(m.author) : undefined, description: m.description ? String(m.description) : undefined,
          labels: (m.labels || m.tags || []).map(String), functions: fns, settings: settings });
      };
      g.__invoke = function (callID, moduleID, fn, argsJSON) {
        function fail(e) { __native_settle(callID, false, String((e && e.message) || e || 'Error')); }
        try {
          var m = g.__modules[moduleID];
          if (!m || typeof m[fn] !== 'function') throw new Error('The module does not support ' + fn);
          var r = m[fn].apply(m, JSON.parse(argsJSON));
          Promise.resolve(r).then(function (v) {
            var out; try { out = JSON.stringify(v === undefined ? null : v); } catch (e) { fail(e); return; }
            __native_settle(callID, true, out);
          }, fail);
        } catch (e) { fail(e); }
      };
    })(this);
    """#
}
