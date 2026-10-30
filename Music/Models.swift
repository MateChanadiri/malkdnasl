import SwiftUI

// MARK: - Paths

nonisolated enum Paths {
    // Looked up for every cover and song shown, so the fixed folders are resolved (and created) once.
    // The folders inside Documents can be deleted in the Files app, so those are still checked on each use.
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let documentsPrefix: String = documents.path.hasSuffix("/") ? documents.path : documents.path + "/"
    static var imported: URL { dir(documents.appendingPathComponent("Imported", isDirectory: true)) }
    static var scanFolder: URL { dir(documents.appendingPathComponent("\(Brand.name)Music", isDirectory: true)) }
    static let support: URL = dir(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    static let artwork: URL = dir(support.appendingPathComponent("Artwork", isDirectory: true))
    static let database: URL = support.appendingPathComponent("library.json")
    static var downloads: URL { dir(documents.appendingPathComponent("Downloads", isDirectory: true)) }
    static let streamCache: URL =
        dir(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Stream", isDirectory: true))
    static let queueFile: URL = support.appendingPathComponent("queue.json")

    static func url(for track: Track) -> URL { documents.appendingPathComponent(track.path) }
    static func relative(_ url: URL) -> String {
        url.path.hasPrefix(documentsPrefix) ? String(url.path.dropFirst(documentsPrefix.count)) : url.lastPathComponent
    }
    static func artworkURL(for id: UUID) -> URL { artwork.appendingPathComponent("\(id.uuidString).jpg") }

    @discardableResult
    private static func dir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func prepare() { _ = imported; _ = scanFolder; _ = artwork; _ = downloads; _ = streamCache }
}

// MARK: - Models

nonisolated struct Track: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var path: String
    var trackNumber: Int = 0
    var lyrics: String?
    var hasArtwork = false
    var isFavorite = false
    var addedAt = Date()
    var metadataLocked = false
    var artVersion: Int?
    var playCount: Int?
    var lastPlayed: Date?
    var lyricsChecked: Bool?
    var lyricsSource: String?
    /// Untimed lyrics were already checked once for a synced version on LRCLIB.
    var syncedLyricsChecked: Bool?
    var sourceKey: String?

    // Extended tags
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var discNumber: Int?
    var composer: String?
    var copyright: String?
    var bpm: Double?

    // Audio analysis (see AudioAnalysis.swift)
    var loudness: Double?
    var replayGain: Double?
    var leadIn: Double?
    var outroStart: Double?
    var trailEnd: Double?
    var beatOffset: Double?
    var analyzed: Bool?
    var analysisVersion: Int?
    /// The BPM came from analysis (not from tags or the user), so a newer analysis may replace it.
    var bpmAnalyzed: Bool?

    // Listening behaviour
    var skipCount: Int?
    var lastSkipped: Date?

    // Lyrics extras
    var lyricsOffset: Double?
    var onlineLyricsChecked: Bool?

    // Streaming sources (nil = local file). A downloaded streaming track has a non-empty `path`.
    var sourceID: String?
    var remoteID: String?
    var remoteAlbumID: String?
    var remoteImageTag: String?
    /// Cover image link for songs from modules (downloaded once into the artwork folder).
    var artworkURL: String?
    /// Looping video cover from Apple Music (set by Organize).
    var motionArtworkURL: String?
    /// Where the cover came from. nil for covers saved before this was tracked.
    var artSource: ArtSource?
}

nonisolated enum ArtSource: String, Codable, Sendable {
    /// Embedded in the audio file.
    case file
    /// Apple Music / iTunes catalog or Cover Art Archive (Clean Library).
    case catalog
    /// Designed, picked or edited by you.
    case user
    /// From your music server or a module.
    case server

    /// Clean Library may swap these for the catalog cover.
    var replaceable: Bool { self == .file }
}

extension Track {
    nonisolated var isRemote: Bool { sourceID != nil }
    nonisolated var isDownloaded: Bool { isRemote && !path.isEmpty }
    /// Playable without a network connection.
    nonisolated var isOffline: Bool { !path.isEmpty }
    /// Where this song comes from, for grouping in the unified library.
    nonisolated var origin: TrackOrigin { !isRemote ? .local : isDownloaded ? .downloaded : .streaming }
}

nonisolated enum TrackOrigin: String, CaseIterable, Identifiable, Sendable {
    case local, downloaded, streaming
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: "Local Files"
        case .downloaded: "Downloaded"
        case .streaming: "Streaming"
        }
    }
    var symbol: String {
        switch self {
        case .local: "internaldrive"
        case .downloaded: "arrow.down.circle.fill"
        case .streaming: "cloud"
        }
    }
}

nonisolated struct Playlist: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var createdAt = Date()
    var sourceID: String?
    var remoteID: String?
}

nonisolated struct PinnedItem: Codable, Hashable, Sendable {
    var kind: LibraryEntry.Kind
    var key: String
}

struct LibraryEntry: Identifiable, Hashable {
    nonisolated enum Kind: String, Codable, Sendable { case playlist, artist, album }
    let kind: Kind
    let key: String
    var title: String
    var subtitle: String
    var tracks: [Track]
    var id: String { "\(kind.rawValue):\(key)" }
    var isCircle: Bool { kind == .artist }
    var route: Route {
        switch kind {
        case .playlist: .playlist(UUID(uuidString: key) ?? UUID())
        case .artist: .artist(key)
        case .album: .album(key)
        }
    }
    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
}

// MARK: - Formatting

nonisolated func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

nonisolated func formatDuration(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
    return "\(max(minutes, seconds > 0 ? 1 : 0)) min"
}

nonisolated func songCount(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

// MARK: - Lyrics

nonisolated struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let time: Double?
    let text: String
    /// Word timings from enhanced LRC (`<mm:ss.xx>word`). Empty when only line timings exist.
    var words: [LyricWord] = []
}

nonisolated struct LyricWord: Hashable, Sendable {
    let time: Double
    let text: String
}

nonisolated enum LyricsParser {
    static func parse(_ raw: String) -> [LyricLine] {
        var timed: [(Double, String, [LyricWord])] = []
        var plain: [String] = []
        // "[offset:+500]" shifts every timestamp; positive means the lyrics come earlier.
        var shift = 0.0
        for line in raw.split(whereSeparator: \.isNewline) {
            var rest = Substring(line).trimmingCharacters(in: .whitespaces)[...]
            var times: [Double] = []
            var skip = false
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    shift = ms / 1000; skip = true; break
                }
                if let t = parseTime(tag) { times.append(t) } else if times.isEmpty { skip = true; break }
                rest = rest[rest.index(after: close)...]
            }
            if skip { continue }
            let (text, words) = splitWords(String(rest))
            if times.isEmpty {
                if !text.isEmpty { plain.append(text) }
            } else {
                for t in times where !text.isEmpty { timed.append((t, text, words)) }
            }
        }
        if !timed.isEmpty {
            return timed.sorted { $0.0 < $1.0 }.enumerated().map {
                LyricLine(id: $0.offset, time: max(0, $0.element.0 - shift), text: $0.element.1,
                          words: $0.element.2.map { LyricWord(time: max(0, $0.time - shift), text: $0.text) })
            }
        }
        return plain.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
    }

    /// Removes enhanced-LRC word tags and returns the clean text plus the timed words.
    private static func splitWords(_ raw: String) -> (String, [LyricWord]) {
        guard raw.contains("<") else { return (raw.trimmingCharacters(in: .whitespaces), []) }
        var words: [LyricWord] = []
        var clean = ""
        var pending: Double?
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "<", let close = raw[i...].firstIndex(of: ">"),
               let t = parseTime(raw[raw.index(after: i)..<close]) {
                pending = t
                i = raw.index(after: close)
                continue
            }
            let j = raw[raw.index(after: i)...].firstIndex(of: "<") ?? raw.endIndex
            let chunk = String(raw[i..<j])
            if let t = pending {
                let word = chunk.trimmingCharacters(in: .whitespaces)
                if !word.isEmpty { words.append(LyricWord(time: t, text: word)) }
                pending = nil
            }
            clean += chunk
            i = j
        }
        let text = clean.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (text, words)
    }

    /// Word timings for a line: real ones from enhanced LRC, otherwise spread over the line by word length.
    static func wordTimings(for line: LyricLine, end: Double?) -> [LyricWord] {
        if !line.words.isEmpty { return line.words }
        guard let start = line.time else { return [] }
        let parts = line.text.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return [] }
        let length = min(max((end ?? start + 4) - start, 0.6), 8) * 0.92
        let total = Double(parts.reduce(0) { $0 + $1.count + 1 })
        var t = start
        return parts.map { word in
            defer { t += length * Double(word.count + 1) / total }
            return LyricWord(time: t, text: word)
        }
    }

    /// Serialises timed lines back to LRC (used by the tap-to-sync editor and timing correction).
    static func lrc(_ lines: [LyricLine]) -> String {
        lines.map { line in
            guard let t = line.time else { return line.text }
            return String(format: "[%02d:%05.2f] ", Int(max(0, t)) / 60, max(0, t).truncatingRemainder(dividingBy: 60)) + line.text
        }.joined(separator: "\n")
    }

    /// "mm:ss.xx", "mm:ss", "mm:ss:xx" (some players write centiseconds after a colon) and "h:mm:ss.xx".
    private static func parseTime(_ s: Substring) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.compactMap { $0 }
        switch n.count {
        case 2: return n[0] * 60 + n[1]
        case 3 where n[2] < 100 && n[1] < 60 && !s.contains("."):
            return n[0] * 60 + n[1] + n[2] / 100
        case 3: return n[0] * 3600 + n[1] * 60 + n[2]
        default: return nil
        }
    }

    /// True when the text carries timestamps (so it can scroll with the song).
    static func isTimed(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return parse(raw).first?.time != nil
    }
}

// MARK: - Theme

enum Theme {
    /// The accent of the active theme (see Themes.swift). Reading it registers observation, so views follow theme changes.
    static var accent: Color { ThemeStore.shared.current.accentColor }
    static let defaultAccent = Color(red: 1, green: 0.231, blue: 0.361)
}
