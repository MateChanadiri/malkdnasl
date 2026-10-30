import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Sharing songs as files

/// A song handed to the share sheet. The file is made only when someone actually shares it:
/// a copy named "Artist - Title", carrying the tags and cover you see in Music (after Clean Library, edits…),
/// not whatever the original file had.
nonisolated struct SharedSong: Transferable, Sendable {
    let tags: TrackExport.Tags

    @MainActor init?(_ track: Track) {
        guard let url = MediaLocator.localURL(for: track) else { return nil }
        tags = TrackExport.Tags(track: track, source: url)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mp3) { SentTransferredFile(try await TrackExport.file(for: $0.tags)) }
            .exportingCondition { $0.tags.ext == "mp3" }
        FileRepresentation(exportedContentType: .mpeg4Audio) { SentTransferredFile(try await TrackExport.file(for: $0.tags)) }
            .exportingCondition { $0.tags.ext == "m4a" }
        FileRepresentation(exportedContentType: .audio) { SentTransferredFile(try await TrackExport.file(for: $0.tags)) }
    }
}

nonisolated enum TrackExport {
    struct Tags: Sendable {
        var source: URL
        var title: String
        var artist: String
        var album: String?
        var albumArtist: String?
        var trackNumber: Int
        var disc: Int?
        var year: Int?
        var genre: String?
        var composer: String?
        var lyrics: String?
        var artwork: URL?
        var ext: String { source.pathExtension.lowercased() }

        @MainActor init(track t: Track, source: URL) {
            self.source = source
            title = t.title
            artist = t.artist
            album = t.album == "Unknown Album" ? nil : t.album
            albumArtist = t.albumArtist
            trackNumber = t.trackNumber
            disc = t.discNumber
            year = t.year
            genre = t.genre
            composer = t.composer
            // Raw here; the timestamps are stripped in `file(for:)`, only when someone actually shares.
            // Every song row builds one of these for its menu, so this init has to stay cheap.
            lyrics = t.lyrics
            artwork = t.hasArtwork ? Paths.artworkURL(for: t.id) : nil
        }
    }

    static func file(for tags: Tags) async throws -> URL {
        var tags = tags
        tags.lyrics = tags.lyrics.map(plainLyrics)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Share/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(tags.artist) - \(tags.title)".map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }
        let out = dir.appendingPathComponent(String(name.prefix(120))).appendingPathExtension(tags.ext.isEmpty ? "mp3" : tags.ext)
        let cover = tags.artwork.flatMap { try? Data(contentsOf: $0) }
        switch tags.ext {
        case "mp3":
            let audio = try Data(contentsOf: tags.source)
            try (id3(tags, cover: cover) + stripTags(audio)).write(to: out)
        case "m4a", "mp4", "aac":
            if await (try? exportMP4(tags, cover: cover, to: out)) == nil {
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.copyItem(at: tags.source, to: out)
            }
        default:
            try FileManager.default.copyItem(at: tags.source, to: out)
        }
        return out
    }

    /// Lyrics without LRC timestamps, the way other players show them.
    static func plainLyrics(_ raw: String) -> String {
        raw.replacing(/<\d+:\d+(\.\d+)?>/, with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/^(\s*\[\d+:\d+(\.\d+)?\])+\s*/, with: "") }
            .filter { !$0.hasPrefix("[") || !$0.contains(":") }   // [ar:…], [ti:…] header lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: MP3 (ID3v2.3)

    /// The audio without its ID3v2 tag(s) at the start and the ID3v1 tag at the end.
    static func stripTags(_ data: Data) -> Data {
        var d = data
        while d.count > 10, d.starts(with: [0x49, 0x44, 0x33]) {
            let b = [UInt8](d.prefix(10))
            let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
            let total = 10 + size + (b[5] & 0x10 != 0 ? 10 : 0)
            guard total <= d.count else { break }
            d = d.subdata(in: d.startIndex + total ..< d.endIndex)
        }
        if d.count > 128, d.suffix(128).starts(with: [0x54, 0x41, 0x47]) { d = d.dropLast(128) }
        return Data(d)
    }

    static func id3(_ t: Tags, cover: Data?) -> Data {
        var frames = Data()
        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            frames += frame(id, Data([0x01]) + utf16(value))
        }
        text("TIT2", t.title)
        text("TPE1", t.artist)
        text("TALB", t.album)
        text("TPE2", t.albumArtist)
        text("TRCK", t.trackNumber > 0 ? "\(t.trackNumber)" : nil)
        text("TPOS", t.disc.map(String.init))
        text("TYER", t.year.map(String.init))
        text("TCON", t.genre)
        text("TCOM", t.composer)
        if let lyrics = t.lyrics, !lyrics.isEmpty {
            // Encoding, language, empty description, text.
            frames += frame("USLT", Data([0x01]) + Data("XXX".utf8) + utf16("") + [0x00, 0x00] + utf16(lyrics))
        }
        if let cover {
            // Encoding, MIME type, picture type 3 (front cover), empty description, image.
            frames += frame("APIC", Data([0x00]) + Data("image/jpeg".utf8) + [0x00, 0x03, 0x00] + cover)
        }
        let size = frames.count
        let syncsafe: [UInt8] = [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
        return Data("ID3".utf8) + [0x03, 0x00, 0x00] + syncsafe + frames
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        let n = body.count
        return Data(id.utf8) + [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF), 0x00, 0x00] + body
    }

    /// UTF-16 little endian with a byte order mark.
    private static func utf16(_ s: String) -> Data {
        var d = Data([0xFF, 0xFE])
        for unit in s.utf16 { d.append(UInt8(unit & 0xFF)); d.append(UInt8(unit >> 8)) }
        return d
    }

    // MARK: M4A

    private static func exportMP4(_ t: Tags, cover: Data?, to out: URL) async throws {
        let asset = AVURLAsset(url: t.source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        func item(_ id: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?) -> AVMetadataItem? {
            guard let value else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            return m
        }
        var items: [AVMetadataItem?] = [
            item(.commonIdentifierTitle, t.title as NSString),
            item(.commonIdentifierArtist, t.artist as NSString),
            item(.commonIdentifierAlbumName, t.album as NSString?),
            item(.iTunesMetadataAlbumArtist, t.albumArtist as NSString?),
            item(.iTunesMetadataUserGenre, t.genre as NSString?),
            item(.iTunesMetadataComposer, t.composer as NSString?),
            item(.iTunesMetadataReleaseDate, t.year.map { "\($0)" as NSString }),
            item(.iTunesMetadataLyrics, t.lyrics as NSString?)
        ]
        if let cover {
            let m = AVMutableMetadataItem()
            m.identifier = .commonIdentifierArtwork
            m.value = cover as NSData
            m.dataType = kCMMetadataBaseDataType_JPEG as String
            items.append(m)
        }
        session.metadata = items.compactMap { $0 }
        try await session.export(to: out, as: .m4a)
    }
}
