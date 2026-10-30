import AppIntents
import Foundation
import SwiftUI

// MARK: - Shared access for Siri, Shortcuts, widgets and CarPlay

@MainActor
final class AppServices {
    static let shared = AppServices()
    private(set) var library: LibraryStore?
    private(set) var player: PlayerModel?
    private(set) var settings: AppSettings?
    private(set) var sources: SourceManager?

    func configure(library: LibraryStore, player: PlayerModel, settings: AppSettings, sources: SourceManager) {
        self.library = library
        self.player = player
        self.settings = settings
        self.sources = sources
        PlaybackBridge.handler = { [weak player] command in
            guard let player else { return }
            switch command {
            case .toggle: player.togglePlay()
            case .play: player.resume()
            case .pause: player.pause()
            case .next: player.next()
            case .previous: player.previous()
            case .favorite: if let t = player.current { player.library.toggleFavorite(t) }
            }
        }
        NowPlayingBridge.shared.attach(player: player, settings: settings)
    }
}

enum ShareItem {
    static func text(for t: Track) -> String { "\(t.title) — \(t.artist)" + (t.album == "Unknown Album" ? "" : " (\(t.album))") }
    static func text(for e: LibraryEntry) -> String {
        "\(e.title)\n" + e.tracks.prefix(100).enumerated().map { "\($0.offset + 1). \($0.element.title) — \($0.element.artist)" }.joined(separator: "\n")
    }
}

// MARK: - Entities

struct CollectionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music"
    static let defaultQuery = CollectionQuery()
    let id: String            // "kind:key"
    let name: String
    let kindName: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(kindName)") }
}

struct CollectionQuery: EntityStringQuery {
    @MainActor private func all() -> [CollectionEntity] {
        guard let lib = AppServices.shared.library else { return [] }
        let entries = lib.playlistEntries + lib.artistEntries + lib.albumEntries
        return entries.map { CollectionEntity(id: $0.id, name: $0.title, kindName: $0.kind.rawValue.capitalized) }
    }
    func entities(for identifiers: [String]) async throws -> [CollectionEntity] {
        await MainActor.run { all().filter { identifiers.contains($0.id) } }
    }
    func entities(matching string: String) async throws -> [CollectionEntity] {
        await MainActor.run { all().filter { $0.name.localizedCaseInsensitiveContains(string) } }
    }
    func suggestedEntities() async throws -> [CollectionEntity] {
        await MainActor.run {
            guard let lib = AppServices.shared.library else { return [] }
            let pinned = lib.pinnedEntries.map { CollectionEntity(id: $0.id, name: $0.title, kindName: $0.kind.rawValue.capitalized) }
            return pinned + all().prefix(20)
        }
    }
}

struct SongEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Song"
    static let defaultQuery = SongQuery()
    let id: UUID
    let title: String
    let artist: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(artist)") }
}

struct SongQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [SongEntity] {
        await MainActor.run {
            identifiers.compactMap { AppServices.shared.library?.trackByID[$0] }.map { SongEntity(id: $0.id, title: $0.title, artist: $0.artist) }
        }
    }
    func entities(matching string: String) async throws -> [SongEntity] {
        await MainActor.run {
            (AppServices.shared.library?.tracks ?? []).filter { $0.title.localizedCaseInsensitiveContains(string) || $0.artist.localizedCaseInsensitiveContains(string) }
                .prefix(30).map { SongEntity(id: $0.id, title: $0.title, artist: $0.artist) }
        }
    }
    func suggestedEntities() async throws -> [SongEntity] {
        await MainActor.run {
            (AppServices.shared.library?.tracks ?? []).sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(20)
                .map { SongEntity(id: $0.id, title: $0.title, artist: $0.artist) }
        }
    }
}

// MARK: - Intents

struct PlayCollectionIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays a playlist, artist or album from your Music library.")
    @Parameter(title: "Music") var item: CollectionEntity
    @Parameter(title: "Shuffle", default: false) var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let lib = AppServices.shared.library, let player = AppServices.shared.player else { return .result(dialog: "Music isn't ready yet.") }
        let parts = item.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = LibraryEntry.Kind(rawValue: parts[0]), let entry = lib.entry(kind, parts[1]) else {
            return .result(dialog: "I couldn't find that.")
        }
        player.play(entry, shuffled: shuffle)
        return .result(dialog: "Playing \(entry.title).")
    }
}

struct PlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    @Parameter(title: "Song") var song: SongEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let lib = AppServices.shared.library, let player = AppServices.shared.player, let t = lib.trackByID[song.id] else { return .result() }
        player.startRadio(from: t)
        return .result()
    }
}

struct ShuffleAllIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle All Music"
    @Parameter(title: "Smart Shuffle", default: true) var smart: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let lib = AppServices.shared.library, let player = AppServices.shared.player, let s = AppServices.shared.settings else { return .result() }
        let list = smart ? SmartShuffle.order(lib.tracks, options: .init(familiarity: s.shuffleFamiliarity)) : lib.tracks.shuffled()
        player.play(list, title: "All Songs")
        return .result()
    }
}

struct PlayFavoritesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Favorites"
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let lib = AppServices.shared.library, let player = AppServices.shared.player else { return .result() }
        player.play(lib.tracks.filter(\.isFavorite), title: "Favorites", shuffled: true)
        return .result()
    }
}

struct PlayDownloadsIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Offline Music"
    @MainActor
    func perform() async throws -> some IntentResult {
        guard let lib = AppServices.shared.library, let player = AppServices.shared.player else { return .result() }
        player.play(lib.tracks.filter(\.isOffline), title: "On This iPhone", shuffled: true)
        return .result()
    }
}

struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 240)) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppServices.shared.player?.setSleepTimer(minutes: minutes)
        return .result(dialog: "Music stops in \(minutes) minutes.")
    }
}

struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let t = AppServices.shared.player?.current else { return .result(dialog: "Nothing is playing.") }
        return .result(dialog: "\(t.title) by \(t.artist).")
    }
}

struct MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayCollectionIntent(), phrases: ["Play \(\.$item) in \(.applicationName)", "Play \(\.$item) on \(.applicationName)"],
                    shortTitle: "Play Music", systemImageName: "play.fill")
        AppShortcut(intent: ShuffleAllIntent(), phrases: ["Shuffle my music in \(.applicationName)", "Shuffle \(.applicationName)"],
                    shortTitle: "Shuffle All", systemImageName: "shuffle")
        AppShortcut(intent: PlayFavoritesIntent(), phrases: ["Play my favorites in \(.applicationName)"],
                    shortTitle: "Favorites", systemImageName: "star.fill")
        AppShortcut(intent: PlayDownloadsIntent(), phrases: ["Play my offline music in \(.applicationName)"],
                    shortTitle: "Offline Music", systemImageName: "arrow.down.circle")
        AppShortcut(intent: SleepTimerIntent(), phrases: ["Set a sleep timer in \(.applicationName)"],
                    shortTitle: "Sleep Timer", systemImageName: "moon.zzz")
        AppShortcut(intent: TogglePlaybackIntent(), phrases: ["Pause \(.applicationName)", "Resume \(.applicationName)"],
                    shortTitle: "Play/Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: NextTrackIntent(), phrases: ["Skip this song in \(.applicationName)", "Next song in \(.applicationName)"],
                    shortTitle: "Next Song", systemImageName: "forward.fill")
        AppShortcut(intent: WhatsPlayingIntent(), phrases: ["What's playing in \(.applicationName)"],
                    shortTitle: "What's Playing", systemImageName: "music.note")
    }
}
