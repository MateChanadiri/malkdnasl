import Foundation
import Observation
import SwiftUI

// MARK: - Smart shuffle

/// A shuffle that spaces out artists and albums and, depending on the "familiarity" slider,
/// leans towards favourites and often-played songs and away from skipped or just-played ones.
nonisolated enum SmartShuffle {
    struct Options: Sendable {
        var familiarity: Double       // 0 random … 1 familiar
        var recent: Set<UUID> = []
    }

    static func order(_ tracks: [Track], options: Options) -> [Track] {
        guard tracks.count > 2 else { return tracks.shuffled() }
        let f = max(0, min(1, options.familiarity))
        let maxPlays = Double(tracks.map { $0.playCount ?? 0 }.max() ?? 0)
        let now = Date()

        func familiar(_ t: Track) -> Double {
            var s = 0.0
            if maxPlays > 0 { s += log(1 + Double(t.playCount ?? 0)) / log(1 + maxPlays) }
            if t.isFavorite { s += 0.8 }
            let plays = Double(t.playCount ?? 0), skips = Double(t.skipCount ?? 0)
            if skips > 0 { s -= 1.2 * skips / (plays + skips + 1) }
            if let last = t.lastSkipped, now.timeIntervalSince(last) < 7 * 86400 { s -= 0.4 }
            return s
        }
        var pool = tracks.map { t -> (Track, Double) in
            var score = f * 2.2 * familiar(t) + Double.random(in: 0...1) * (1.2 - f * 0.6)
            if options.recent.contains(t.id) { score -= 1.5 }
            if let lp = t.lastPlayed, now.timeIntervalSince(lp) < 3 * 3600 { score -= 0.8 }
            return (t, score)
        }
        // Sorted once; each pick looks at the best few remaining candidates and applies spacing rules.
        pool.sort { $0.1 > $1.1 }
        var out: [Track] = []
        out.reserveCapacity(pool.count)
        let smartLimit = 400
        while !pool.isEmpty {
            if out.count >= smartLimit { out += pool.map(\.0); break }
            let last = out.last
            let recentArtists = Set(out.suffix(3).map(\.artist))
            var pick = 0
            var bestAdjusted = -Double.infinity
            for i in 0..<min(12, pool.count) {
                let t = pool[i].0
                var adj = pool[i].1 + Double.random(in: 0...0.35)
                if recentArtists.contains(t.artist) { adj -= 2 }
                if let last, last.album == t.album, last.artist == t.artist { adj -= 1.5 }
                if let last {
                    if let g1 = last.genre, let g2 = t.genre, g1 == g2 { adj += 0.25 * f }
                    if let b1 = last.bpm, let b2 = t.bpm { adj += abs(b1 - b2) < 12 ? 0.3 * f : -0.15 * f }
                }
                if adj > bestAdjusted { bestAdjusted = adj; pick = i }
            }
            out.append(pool.remove(at: pick).0)
        }
        return out
    }

    /// Order of a whole library for "continue library" modes.
    static func libraryOrder(_ tracks: [Track]) -> [Track] {
        tracks.sorted {
            let a = ($0.albumArtist ?? $0.artist).lowercased(), b = ($1.albumArtist ?? $1.artist).lowercased()
            if a != b { return a < b }
            if $0.album != $1.album { return $0.album.localizedStandardCompare($1.album) == .orderedAscending }
            if ($0.discNumber ?? 1) != ($1.discNumber ?? 1) { return ($0.discNumber ?? 1) < ($1.discNumber ?? 1) }
            return ($0.trackNumber, $0.title) < ($1.trackNumber, $1.title)
        }
    }
}

// MARK: - Queue presets ("rules")

nonisolated struct QueueRule: Codable, Identifiable, Hashable, Sendable {
    enum Trigger: String, Codable, CaseIterable, Identifiable, Sendable {
        case album, playlist, artist, anything
        var id: String { rawValue }
        var title: String {
            switch self {
            case .album: "I play an album"
            case .playlist: "I play a playlist"
            case .artist: "I play an artist"
            case .anything: "I play anything"
            }
        }
    }
    enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
        case favorites, downloads, sameArtist, similar, recentlyAdded, playlist, random
        var id: String { rawValue }
        var title: String {
            switch self {
            case .favorites: "Add my favorite songs"
            case .downloads: "Add my downloaded songs"
            case .sameArtist: "Add more from the same artist"
            case .similar: "Add similar songs (smart shuffle)"
            case .recentlyAdded: "Add recently added songs"
            case .playlist: "Add a playlist"
            case .random: "Add random songs"
            }
        }
    }
    var id = UUID()
    var trigger: Trigger
    var action: Action
    var playlistID: String?
    var count = 20
    var shuffled = true
    var enabled = true
}

@Observable
final class QueueRules {
    var rules: [QueueRule] { didSet { if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "queueRules") } } }

    init() {
        rules = (UserDefaults.standard.data(forKey: "queueRules").flatMap { try? JSONDecoder().decode([QueueRule].self, from: $0) }) ?? []
    }

    func matching(_ kind: LibraryEntry.Kind?) -> [QueueRule] {
        rules.filter { r in
            guard r.enabled else { return false }
            switch r.trigger {
            case .anything: return true
            case .album: return kind == .album
            case .playlist: return kind == .playlist
            case .artist: return kind == .artist
            }
        }
    }

    /// Songs a rule appends after `seed`.
    func tracks(for rule: QueueRule, seed: [Track], library: LibraryStore, familiarity: Double) -> [Track] {
        let inQueue = Set(seed.map(\.id))
        var pool: [Track]
        switch rule.action {
        case .favorites: pool = library.tracks.filter(\.isFavorite)
        case .downloads: pool = library.tracks.filter(\.isOffline)
        case .sameArtist:
            let artists = Set(seed.map(\.artist))
            pool = library.tracks.filter { artists.contains($0.artist) }
        case .similar:
            let genres = Set(seed.compactMap(\.genre)), artists = Set(seed.map(\.artist))
            pool = library.tracks.filter { t in (t.genre.map(genres.contains) ?? false) || artists.contains(t.artist) }
            if pool.count < rule.count { pool = library.tracks }
            return Array(SmartShuffle.order(pool.filter { !inQueue.contains($0.id) }, options: .init(familiarity: familiarity)).prefix(rule.count))
        case .recentlyAdded: pool = Array(library.tracks.sorted { $0.addedAt > $1.addedAt }.prefix(rule.count * 2))
        case .playlist:
            pool = rule.playlistID.flatMap { id in library.playlists.first { $0.id.uuidString == id } }.map { library.tracks(for: $0.trackIDs) } ?? []
        case .random: pool = library.tracks
        }
        pool = pool.filter { !inQueue.contains($0.id) }
        if rule.shuffled || rule.action == .random { pool.shuffle() }
        return Array(pool.prefix(rule.count))
    }
}

struct QueueRulesView: View {
    @Environment(QueueRules.self) private var rules
    @Environment(LibraryStore.self) private var library
    @State private var editing: QueueRule?

    var body: some View {
        @Bindable var rules = rules
        List {
            Section {
                ForEach($rules.rules) { $rule in
                    Button { editing = rule } label: {
                        HStack(spacing: 12) {
                            GradientIcon(symbol: "wand.and.rays", colors: [.teal, .blue], size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Whenever \(rule.trigger.title.lowercased())").font(.subheadline.weight(.semibold))
                                Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $rule.enabled).labelsHidden()
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { rules.rules.remove(atOffsets: $0) }
                .onMove { rules.rules.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Example: “Whenever I play an album, automatically add my favorite songs afterward.”")
            }
            Section {
                Button { editing = QueueRule(trigger: .album, action: .favorites) } label: { Label("New Rule", systemImage: "plus") }
            }
        }
        .navigationTitle("Queue Presets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .overlay {
            if rules.rules.isEmpty {
                ContentUnavailableView("No Queue Presets", systemImage: "text.badge.plus",
                                       description: Text("Presets add songs automatically after what you start playing."))
            }
        }
        .sheet(item: $editing) { rule in
            QueueRuleEditor(rule: rule) { saved in
                if let i = rules.rules.firstIndex(where: { $0.id == saved.id }) { rules.rules[i] = saved } else { rules.rules.append(saved) }
            }
        }
    }

    private func summary(_ r: QueueRule) -> String {
        var s = r.action.title
        if r.action == .playlist, let id = r.playlistID, let p = library.playlists.first(where: { $0.id.uuidString == id }) { s += " “\(p.name)”" }
        return s + " · up to \(r.count)"
    }
}

struct QueueRuleEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State var rule: QueueRule
    var save: (QueueRule) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Whenever", selection: $rule.trigger) { ForEach(QueueRule.Trigger.allCases) { Text($0.title).tag($0) } }
                Picker("Then", selection: $rule.action) { ForEach(QueueRule.Action.allCases) { Text($0.title).tag($0) } }
                if rule.action == .playlist {
                    Picker("Playlist", selection: Binding(get: { rule.playlistID ?? "" }, set: { rule.playlistID = $0 })) {
                        Text("Choose…").tag("")
                        ForEach(library.playlists) { Text($0.name).tag($0.id.uuidString) }
                    }
                }
                Stepper("Up to \(rule.count) songs", value: $rule.count, in: 5...100, step: 5)
                Toggle("Shuffle Added Songs", isOn: $rule.shuffled)
            }
            .navigationTitle("Queue Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(rule); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
