import Foundation

/// Turns file names into title / artist / track number:
/// "03 - Artist - Title", "Artist - Title", "03. Title", "title_with_underscores.mp3", and downloads like
/// "Title - Artist - Topic (192k).mp3" (YouTube's auto-generated "Artist - Topic" channels).
/// Careful with real titles: "7 Rings", "Song - Remastered" or "Song (feat. X)" stay as they are.
nonisolated enum FileTitleParser {
    struct Result: Sendable {
        var title: String
        var artist: String?
        var number: Int?
        /// The artist must be replaced even though one is set (it was taken from the wrong part of the name).
        var replacesArtist = false
    }

    static func parse(_ raw: String, artist current: String) -> Result? {
        var s = raw
        for ext in [".mp3", ".m4a", ".flac", ".wav", ".aac"] where s.lowercased().hasSuffix(ext) { s = String(s.dropLast(ext.count)) }
        if s.contains("_") && !s.contains(" ") { s = s.replacingOccurrences(of: "_", with: " ") }
        s = stripJunk(s)
        let unknown = current == "Unknown Artist"

        // "Title - Artist - Topic": the channel name is the artist, everything before it the title.
        var parts = s.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3, parts.last?.caseInsensitiveCompare("Topic") == .orderedSame {
            parts.removeLast()
            let artist = parts.removeLast()
            return Result(title: parts.joined(separator: " - "), artist: artist, number: nil, replacesArtist: !unknown && norm(artist) != norm(current))
        }
        // Already split the wrong way round earlier: artist "Title", title "Artist - Topic".
        if parts.count == 2, parts[1].caseInsensitiveCompare("Topic") == .orderedSame, !unknown {
            return Result(title: current, artist: parts[0], number: nil, replacesArtist: true)
        }

        var number: Int?
        if let m = s.firstMatch(of: /^\s*(\d{1,3})\s*[-.)]\s+/) ?? s.firstMatch(of: /^\s*(0\d)\s+/) {
            number = Int(m.1)
            s = String(s[m.range.upperBound...])
        }
        var artist: String?
        parts = s.components(separatedBy: " - ")
        if parts.count >= 2 {
            let head = parts[0].trimmingCharacters(in: .whitespaces)
            if norm(head) == norm(current) {
                s = parts.dropFirst().joined(separator: " - ")
            } else if unknown {
                artist = head
                s = parts.dropFirst().joined(separator: " - ")
            }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s != raw || number != nil || artist != nil else { return nil }
        return Result(title: s, artist: artist, number: number)
    }

    /// Download leftovers: "(192k)", "[320 kbps]", "(Official Video)", "(Lyrics)", "[HD]", "[dQw4w9WgXcQ]".
    static func stripJunk(_ s: String) -> String {
        let words = #"\d{2,3}\s?k(bps)?|official(\s+(music|lyric|hd|4k))?\s+(video|audio|visuali[sz]er)|(official\s+)?lyrics?(\s+video)?|audio(\s+only)?|hq|hd|4k|visuali[sz]er"#
        var t = s.replacingOccurrences(of: #"\s*[\(\[]\s*(\#(words))\s*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s*\[[A-Za-z0-9_-]{11}\]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func norm(_ s: String) -> String {
        var t = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        if t.hasPrefix("the ") { t.removeFirst(4) }
        return t.filter { $0.isLetter || $0.isNumber }
    }
}
