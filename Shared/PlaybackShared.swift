import ActivityKit
import AppIntents
import Foundation
import SwiftUI

// Shared between the app and the widget extension.

nonisolated enum AppGroup {
    static let id = "group.com.local.music"
    /// One instance: the app writes the Now Playing state every few seconds. UserDefaults is thread-safe.
    nonisolated(unsafe) static let defaults: UserDefaults = UserDefaults(suiteName: id) ?? .standard
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
    static var artworkDir: URL? {
        guard let c = container else { return nil }
        let u = c.appendingPathComponent("NowPlaying", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// What the widgets show; written by the app on every meaningful change.
nonisolated struct SharedNowPlaying: Codable, Hashable, Sendable {
    var hasTrack = false
    var title = ""
    var artist = ""
    var album = ""
    var isPlaying = false
    var position = 0.0
    var duration = 0.0
    var updatedAt = Date()
    var artFile: String?
    var accentHex = "#FF3B5C"
    var upNext: String?

    static let key = "nowPlaying"

    static func load() -> SharedNowPlaying {
        guard let data = AppGroup.defaults.data(forKey: key), let s = try? JSONDecoder().decode(SharedNowPlaying.self, from: data) else { return SharedNowPlaying() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { AppGroup.defaults.set(data, forKey: Self.key) }
    }

    var artURL: URL? { artFile.flatMap { AppGroup.artworkDir?.appendingPathComponent($0) } }
    var accent: Color {
        var v: UInt64 = 0
        Scanner(string: accentHex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

nonisolated struct NowPlayingAttributes: ActivityAttributes {
    /// Lyrics only — artwork, controls and progress come from the system Now Playing.
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var lyric: String?
        var nextLyric: String?
        var isPlaying: Bool
        var artFile: String?
        var accentHex: String
    }
    var appName = "\(Brand.name)"
}

/// The app installs the handler; intents triggered from widgets / Live Activities run inside the app process.
@MainActor
enum PlaybackBridge {
    enum Command { case toggle, play, pause, next, previous, favorite }
    static var handler: ((Command) -> Void)?
    static func send(_ c: Command) { handler?(c) }
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses Music.")
    init() {}
    @MainActor func perform() async throws -> some IntentResult { PlaybackBridge.send(.toggle); return .result() }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"
    init() {}
    @MainActor func perform() async throws -> some IntentResult { PlaybackBridge.send(.next); return .result() }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    init() {}
    @MainActor func perform() async throws -> some IntentResult { PlaybackBridge.send(.previous); return .result() }
}

struct FavoriteTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Favorite Current Song"
    init() {}
    @MainActor func perform() async throws -> some IntentResult { PlaybackBridge.send(.favorite); return .result() }
}
