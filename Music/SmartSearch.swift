import Foundation
import FoundationModels

/// A structured reading of a search like "songs by Frank Ocean from 2016" or "fast favorites under 3 minutes".
nonisolated struct SmartFilter: Equatable, Sendable {
    var artist: String?
    var album: String?
    var genre: String?
    var years: ClosedRange<Int>?
    var text: [String] = []
    var lyrics: String?
    var favorites = false
    var origin: TrackOrigin?
    var offlineOnly = false
    var maxDuration: Double?
    var minDuration: Double?
    var bpm: ClosedRange<Double>?
    var neverPlayed = false
    var mostPlayed = false
    var addedSince: Date?
    var recentlyPlayed = false

    var isStructured: Bool {
        artist != nil || album != nil || genre != nil || years != nil || lyrics != nil || favorites || origin != nil || offlineOnly
            || maxDuration != nil || minDuration != nil || bpm != nil || neverPlayed || mostPlayed || addedSince != nil || recentlyPlayed
    }

    var summary: String {
        var parts: [String] = []
        if favorites { parts.append("Favorites") }
        if let g = genre { parts.append(g) }
        parts.append("Songs")
        if let a = artist { parts.append("by \(a)") }
        if let al = album { parts.append("on \(al)") }
        if let y = years { parts.append(y.lowerBound == y.upperBound ? "from \(y.lowerBound)" : "from \(y.lowerBound)–\(y.upperBound)") }
        if let o = origin { parts.append("· \(o.title)") }
        if offlineOnly { parts.append("· offline") }
        if let m = maxDuration { parts.append("· under \(Int(m / 60)) min") }
        if let m = minDuration { parts.append("· over \(Int(m / 60)) min") }
        if let b = bpm { parts.append("· \(Int(b.lowerBound))–\(Int(b.upperBound)) BPM") }
        if neverPlayed { parts.append("· never played") }
        if mostPlayed { parts.append("· most played") }
        if recentlyPlayed { parts.append("· recently played") }
        if addedSince != nil { parts.append("· recently added") }
        if let l = lyrics { parts.append("· lyrics “\(l)”") }
        if !text.isEmpty { parts.append("· “\(text.joined(separator: " "))”") }
        return parts.joined(separator: " ")
    }
}

nonisolated enum SmartSearch {
    private static let stop: Set<String> = ["songs", "song", "tracks", "track", "music", "the", "a", "an", "all", "my", "me", "show", "play",
                                            "find", "some", "with", "and", "of", "lieder", "musik", "zeig", "spiel", "meine", "mein", "alle", "titel"]

    static func norm(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil) }

    /// Rule-based parser (English + German keywords). Artist, album and genre names are matched against the library.
    static func parse(_ query: String, artists: [String], albums: [String], genres: [String]) -> SmartFilter {
        var f = SmartFilter()
        var q = " " + norm(query) + " "
        func take(_ pattern: some RegexComponent) -> Bool {
            guard let r = q.firstRange(of: pattern) else { return false }
            q.replaceSubrange(r, with: " ")
            return true
        }

        // Quoted text → lyrics search.
        if let m = q.firstMatch(of: /["“„]([^"”“]+)["”“]/) {
            f.lyrics = String(m.1)
            q.replaceSubrange(m.range, with: " ")
        }
        if let m = q.firstMatch(of: /\s(?:lyrics|text|songtext)\s+(?:contains?|with|mit)?\s*(\w[\w ']{2,})$/) {
            f.lyrics = String(m.1).trimmingCharacters(in: .whitespaces)
            q.replaceSubrange(m.range, with: " ")
        }

        // Years & decades.
        if let m = q.firstMatch(of: /\s(?:between|zwischen)\s+(\d{4})\s+(?:and|und|-)\s+(\d{4})\s/) {
            if let a = Int(m.1), let b = Int(m.2) { f.years = min(a, b)...max(a, b) }
            q.replaceSubrange(m.range, with: " ")
        } else if let m = q.firstMatch(of: /\s(?:before|vor)\s+(\d{4})\s/) {
            if let y = Int(m.1) { f.years = 0...(y - 1) }
            q.replaceSubrange(m.range, with: " ")
        } else if let m = q.firstMatch(of: /\s(?:after|since|nach|seit)\s+(\d{4})\s/) {
            if let y = Int(m.1) { f.years = (y + 1)...3000 }
            q.replaceSubrange(m.range, with: " ")
        } else if let m = q.firstMatch(of: /\s(?:from\s+the\s+|aus\s+den\s+|the\s+|den\s+)?(\d{2}|\d{4})'?(?:s|er)\s/) {
            if var d = Int(m.1) {
                if d < 100 { d += d < 30 ? 2000 : 1900 }
                f.years = d...(d + 9)
            }
            q.replaceSubrange(m.range, with: " ")
        } else if let m = q.firstMatch(of: /\s(?:from|in|von|aus)?\s*((?:19|20)\d{2})\s/) {
            if let y = Int(m.1) { f.years = y...y }
            q.replaceSubrange(m.range, with: " ")
        }

        // Duration.
        if let m = q.firstMatch(of: /\s(?:under|shorter than|less than|unter|kürzer als)\s+(\d+)\s*(?:min|minutes|minuten|m)\w*\s/) {
            f.maxDuration = (Double(m.1) ?? 0) * 60; q.replaceSubrange(m.range, with: " ")
        }
        if let m = q.firstMatch(of: /\s(?:over|longer than|more than|über|länger als)\s+(\d+)\s*(?:min|minutes|minuten|m)\w*\s/) {
            f.minDuration = (Double(m.1) ?? 0) * 60; q.replaceSubrange(m.range, with: " ")
        }

        // Tempo.
        if let m = q.firstMatch(of: /\s(\d{2,3})\s*(?:-|to|bis)\s*(\d{2,3})\s*bpm\s/) {
            if let a = Double(m.1), let b = Double(m.2) { f.bpm = min(a, b)...max(a, b) }
            q.replaceSubrange(m.range, with: " ")
        } else if let m = q.firstMatch(of: /\s(?:bpm\s+(\d{2,3})|(\d{2,3})\s*bpm)\s/) {
            if let v = Double(m.1 ?? m.2 ?? "") { f.bpm = (v - 4)...(v + 4) }
            q.replaceSubrange(m.range, with: " ")
        }
        if take(/\s(?:fast|upbeat|energetic|schnell|schnelle|schnellen)\s/) { f.bpm = 120...250 }
        if take(/\s(?:slow|calm|chill|langsam|langsame|ruhig|ruhige)\s/) { f.bpm = 0...95 }

        // Flags.
        if take(/\s(?:favou?rites?|favou?rite|starred|liked|favoriten|lieblings\w*)\s/) { f.favorites = true }
        if take(/\s(?:downloaded|heruntergeladen\w*)\s/) { f.origin = .downloaded }
        if take(/\s(?:offline|on (?:this|my) (?:iphone|phone)|auf dem iphone)\s/) { f.offlineOnly = true }
        if take(/\s(?:streaming|jellyfin|server|from my server|vom server)\s/) { f.origin = .streaming }
        if take(/\s(?:local|local files|lokal\w*)\s/) { f.origin = .local }
        if take(/\s(?:never played|unplayed|nie gehört|nie gespielt|ungespielt)\s/) { f.neverPlayed = true }
        if take(/\s(?:most played|top|meistgespielt\w*|am meisten gespielt)\s/) { f.mostPlayed = true }
        if take(/\s(?:recently played|zuletzt gespielt|zuletzt gehört)\s/) { f.recentlyPlayed = true }
        if take(/\s(?:added this week|diese woche hinzugefügt|new this week)\s/) { f.addedSince = Date().addingTimeInterval(-7 * 86400) }
        else if take(/\s(?:added this month|diesen monat hinzugefügt|new this month)\s/) { f.addedSince = Date().addingTimeInterval(-31 * 86400) }
        else if take(/\s(?:recently added|new|neu|zuletzt hinzugefügt)\s/) { f.addedSince = Date().addingTimeInterval(-21 * 86400) }

        // "by <artist>" / "von <artist>" / "on <album>".
        func bestMatch(_ candidate: String, in names: [String]) -> String? {
            let c = norm(candidate).trimmingCharacters(in: .whitespaces)
            guard c.count >= 2 else { return nil }
            return names.first { norm($0) == c } ?? names.filter { norm($0).hasPrefix(c) }.min { $0.count < $1.count }
                ?? names.filter { norm($0).contains(c) && c.count >= 4 }.min { $0.count < $1.count }
        }
        if let m = q.firstMatch(of: /\s(?:on|from the album|vom album|auf)\s+(.+?)\s(?=by |von |$)/), let al = bestMatch(String(m.1), in: albums) {
            f.album = al; q.replaceSubrange(m.range, with: " ")
        }
        if let m = q.firstMatch(of: /\s(?:by|von|from|artist|interpret)\s+(.+?)\s*$/), let a = bestMatch(String(m.1), in: artists) {
            f.artist = a; q.replaceSubrange(m.range, with: " ")
        }

        // Genre words anywhere.
        let genreNames = genres.sorted { $0.count > $1.count }
        for g in genreNames {
            let ng = " " + norm(g) + " "
            if q.contains(ng) { f.genre = g; q = q.replacingOccurrences(of: ng, with: " "); break }
        }

        // Artist / album named without "by" ("frank ocean 2016"): longest run of words that is exactly a name.
        var rest = q.split(separator: " ").map(String.init).filter { !stop.contains($0) && $0.count > 1 }
        func takeName(from names: [String]) -> String? {
            let lookup = Dictionary(names.map { (norm($0).filter { $0.isLetter || $0.isNumber || $0 == " " }, $0) }, uniquingKeysWith: { a, _ in a })
            guard !rest.isEmpty else { return nil }
            for len in stride(from: min(rest.count, 6), through: 1, by: -1) {
                for start in 0...(rest.count - len) {
                    let phrase = rest[start..<(start + len)].joined(separator: " ")
                    if phrase.count >= 3, let hit = lookup[phrase] {
                        rest.removeSubrange(start..<(start + len))
                        return hit
                    }
                }
            }
            return nil
        }
        if f.artist == nil, let a = takeName(from: artists) { f.artist = a }
        if f.album == nil, f.isStructured || !rest.isEmpty, let al = takeName(from: albums) { f.album = al }
        f.text = rest
        return f
    }

    static func apply(_ f: SmartFilter, to tracks: [Track]) -> [Track] {
        var out = tracks.filter { t in
            if let a = f.artist, norm(t.artist) != norm(a) && norm(t.albumArtist ?? "") != norm(a) { return false }
            if let al = f.album, norm(t.album) != norm(al) { return false }
            if let g = f.genre, norm(t.genre ?? "") != norm(g) { return false }
            if let y = f.years { guard let ty = t.year, y.contains(ty) else { return false } }
            if f.favorites && !t.isFavorite { return false }
            if let o = f.origin, t.origin != o { return false }
            if f.offlineOnly && !t.isOffline { return false }
            if let m = f.maxDuration, t.duration > m { return false }
            if let m = f.minDuration, t.duration < m { return false }
            if let b = f.bpm { guard let tb = t.bpm, b.contains(tb) else { return false } }
            if f.neverPlayed && (t.playCount ?? 0) > 0 { return false }
            if f.recentlyPlayed && t.lastPlayed == nil { return false }
            if let d = f.addedSince, t.addedAt < d { return false }
            if let l = f.lyrics, !(t.lyrics.map { norm($0).contains(norm(l)) } ?? false) { return false }
            for w in f.text {
                let hay = norm("\(t.title) \(t.artist) \(t.album) \(t.genre ?? "") \(t.composer ?? "")")
                if !hay.contains(w) { return false }
            }
            return true
        }
        if f.mostPlayed { out.sort { ($0.playCount ?? 0) > ($1.playCount ?? 0) }; out = Array(out.prefix(100)) }
        else if f.recentlyPlayed { out.sort { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) } }
        else if f.addedSince != nil { out.sort { $0.addedAt > $1.addedAt } }
        else { out = SmartShuffle.libraryOrder(out) }
        return out
    }
}

// MARK: - On-device model for free-form questions

@Generable
struct SearchIntentGuess {
    @Guide(description: "Artist name if the user asks for one, exactly as written in the list of artists, otherwise empty.")
    var artist: String
    @Guide(description: "Genre if mentioned, otherwise empty.")
    var genre: String
    @Guide(description: "First year of the requested period, or 0.")
    var fromYear: Int
    @Guide(description: "Last year of the requested period, or 0.")
    var toYear: Int
    @Guide(description: "True if the user wants favorite / liked songs.")
    var favorites: Bool
    @Guide(description: "Maximum length in minutes, or 0.")
    var maxMinutes: Int
    @Guide(description: "Mood words such as calm, fast, sad or happy, or empty.")
    var mood: String
}

nonisolated enum SmartSearchAI {
    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @concurrent
    static func interpret(_ query: String, artists: [String], genres: [String]) async -> SmartFilter? {
        guard available else { return nil }
        let session = LanguageModelSession(instructions: """
            You turn a music search into filters. Only use artists and genres from these lists.
            Artists: \(artists.prefix(150).joined(separator: ", "))
            Genres: \(genres.prefix(40).joined(separator: ", "))
            """)
        guard let r = try? await session.respond(to: query, generating: SearchIntentGuess.self).content else { return nil }
        var f = SmartFilter()
        if !r.artist.isEmpty, let a = artists.first(where: { SmartSearch.norm($0) == SmartSearch.norm(r.artist) }) { f.artist = a }
        if !r.genre.isEmpty, let g = genres.first(where: { SmartSearch.norm($0) == SmartSearch.norm(r.genre) }) { f.genre = g }
        if r.fromYear > 1000 { f.years = r.fromYear...max(r.fromYear, r.toYear > 1000 ? r.toYear : r.fromYear) }
        f.favorites = r.favorites
        if r.maxMinutes > 0 { f.maxDuration = Double(r.maxMinutes) * 60 }
        let mood = SmartSearch.norm(r.mood)
        if ["fast", "energetic", "upbeat", "happy", "party"].contains(where: mood.contains) { f.bpm = 118...250 }
        if ["calm", "slow", "sad", "chill", "relax"].contains(where: mood.contains) { f.bpm = 0...95 }
        return f.isStructured ? f : nil
    }
}
