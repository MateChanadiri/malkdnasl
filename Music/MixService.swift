import Foundation
import FoundationModels
import Observation

struct SavedMix: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var vibe: String
    var trackIDs: [UUID]
    var ai: Bool
}

@Generable
struct MixIdea {
    @Guide(description: "A short, tasteful playlist title of 2 to 4 words. No emojis. Do not use the word 'mix'.")
    var name: String
    @Guide(description: "One short sentence saying why these songs belong together.")
    var vibe: String
    @Guide(description: "Numbers of songs taken from the provided list, between 8 and 20 of them.")
    var songs: [Int]
}

@Generable
struct MixPlan {
    @Guide(description: "Three to five clearly different playlists.")
    var mixes: [MixIdea]
}

/// Builds "Made for You" mixes with the on-device language model (Apple Foundation Models).
/// Without the model it falls back to simple, honest groupings (artist and favourites).
@Observable
final class MixService {
    private(set) var mixes: [SavedMix] = []
    private(set) var generating = false
    private(set) var usedAI = false

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var signature = ""

    private struct Stored: Codable { var signature: String; var mixes: [SavedMix]; var ai: Bool }
    private static var fileURL: URL { Paths.support.appendingPathComponent("mixes.json") }

    init(library: LibraryStore) {
        self.library = library
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            mixes = s.mixes
            signature = s.signature
            usedAI = s.ai
        }
    }

    /// Mixes are rebuilt once per day, or when the library changed a lot.
    func refresh(force: Bool = false) async {
        let count = library.tracks.count
        guard count >= LibraryStore.mixThreshold, !generating else { return }
        let day = Date().formatted(.iso8601.year().month().day())
        let sig = "\(day)|\(count / 10)"
        guard force || sig != signature else { return }
        generating = true
        defer { generating = false }

        var result: [SavedMix] = []
        var ai = false
        if let planned = await aiMixes() { result = planned; ai = true }
        if result.count < 2 { result = fallbackMixes() }
        mixes = result
        usedAI = ai
        signature = sig
        if let data = try? JSONEncoder().encode(Stored(signature: sig, mixes: result, ai: ai)) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    var modelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // MARK: On-device model

    private func aiMixes() async -> [SavedMix]? {
        guard modelAvailable else { return nil }
        // The model has a small context window: send a compact, varied sample of the library.
        let played = library.tracks.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        var sample = Array(played.prefix(40))
        sample += library.tracks.filter { t in !sample.contains(where: { $0.id == t.id }) }.shuffled().prefix(80)
        let list = sample.enumerated().map { "\($0.offset). \($0.element.title) — \($0.element.artist) (\($0.element.album))" }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You are a careful music curator. Build playlists using ONLY the numbered songs you are given. \
            Songs inside one playlist must genuinely fit together by artist, genre, era or mood, judging from the \
            titles, artists and albums. Never invent songs or numbers. Prefer fewer, tighter playlists over loose ones.
            """)
        do {
            let response = try await session.respond(to: "Songs:\n\(list)", generating: MixPlan.self)
            let valid: [SavedMix] = response.content.mixes.compactMap { idea in
                var seen = Set<Int>()
                let ids = idea.songs.filter { sample.indices.contains($0) && seen.insert($0).inserted }.map { sample[$0].id }
                guard ids.count >= 5, !idea.name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return SavedMix(name: idea.name, vibe: idea.vibe, trackIDs: ids, ai: true)
            }
            return valid.isEmpty ? nil : valid
        } catch {
            return nil
        }
    }

    // MARK: Fallback (no AI)

    private func fallbackMixes() -> [SavedMix] {
        var out: [SavedMix] = []
        let favs = library.tracks.filter(\.isFavorite)
        if favs.count >= 8 {
            out.append(SavedMix(name: "Favorites", vibe: "The songs you starred", trackIDs: favs.shuffled().map(\.id), ai: false))
        }
        for artist in library.artistEntries.sorted(by: { $0.tracks.count > $1.tracks.count }).prefix(3) where artist.tracks.count >= 4 {
            out.append(SavedMix(name: artist.title, vibe: "\(songCount(artist.tracks.count)) by \(artist.title)",
                                trackIDs: artist.tracks.shuffled().map(\.id), ai: false))
        }
        return out
    }
}
