import Foundation
import SwiftUI
import Observation
import ImageIO
import UIKit

/// Combines server/local songs, previously played songs and unsaved extension results for one artist.
struct ArtistCatalog {
    let name: String
    let tracks: [Track]
    private let modules: [UUID: ModuleTrack]

    init(name: String, knownTracks: [Track], moduleTracks: [ModuleTrack]) {
        self.name = name
        var tracks: [Track] = []
        var modules: [UUID: ModuleTrack] = [:]
        var seen = Set<String>()
        var positions: [String: Int] = [:]
        for track in knownTracks where Self.matches(track.artist, name: name) || Self.matches(track.albumArtist ?? "", name: name) {
            let identity = Self.identity(track)
            if seen.insert(identity).inserted {
                positions[identity] = tracks.count
                tracks.append(track)
            }
        }
        for result in moduleTracks where Self.matches(result.artist, name: name) || Self.matches(result.albumArtist ?? "", name: name) {
            let track = result.previewTrack
            let identity = Self.identity(track)
            if let index = positions[identity] {
                tracks[index] = result.enriching(tracks[index])
                modules[tracks[index].id] = result
                continue
            }
            guard seen.insert(identity).inserted else { continue }
            positions[identity] = tracks.count
            tracks.append(track)
            modules[track.id] = result
        }
        self.tracks = tracks.sorted {
            let left = Self.normalized($0.album), right = Self.normalized($1.album)
            if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            return ($0.discNumber ?? 1, $0.trackNumber, $0.title, Self.identity($0)) < ($1.discNumber ?? 1, $1.trackNumber, $1.title, Self.identity($1))
        }
        self.modules = modules
    }

    var entry: LibraryEntry {
        LibraryEntry(kind: .artist, key: name, title: name, subtitle: songCount(tracks.count), tracks: tracks)
    }

    var albums: [LibraryEntry] {
        Dictionary(grouping: tracks, by: { Self.normalized($0.album) }).values.map { songs in
            LibraryEntry(kind: .album, key: "\(name)|\(songs[0].album)", title: songs[0].album,
                         subtitle: songCount(songs.count), tracks: songs)
        }.sorted {
            let left = $0.tracks.compactMap(\.year).max() ?? 0
            let right = $1.tracks.compactMap(\.year).max() ?? 0
            return left == right ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : left > right
        }
    }

    func module(for track: Track) -> ModuleTrack? { modules[track.id] }

    func current(_ songs: [Track], library: LibraryStore) -> [Track] {
        songs.map { track in
            if let result = modules[track.id] { return result.enriching(library.moduleTrack(result) ?? track) }
            return library.trackByID[track.id] ?? track
        }
    }

    /// Register extension songs only when an action needs library IDs (play, download, playlist…).
    func resolve(_ songs: [Track], library: LibraryStore) -> [Track] {
        let results = songs.compactMap { modules[$0.id] }
        let saved = library.addModuleTracks(results)
        let bySource = Dictionary(saved.map { (Self.identity($0), $0) }, uniquingKeysWith: { first, _ in first })
        return songs.map { bySource[Self.identity($0)] ?? library.trackByID[$0.id] ?? $0 }
    }

    nonisolated static func matches(_ credit: String, name: String) -> Bool {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return false }
        if normalized(credit) == wanted { return true }
        // Match individual credits without mixing up artists such as "Muse" and "Museums".
        let separated = credit.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+|[,;]"#,
                                                     with: ";", options: .regularExpression)
        return separated.split(separator: ";").contains { normalized(String($0)) == wanted }
    }

    nonisolated private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func identity(_ track: Track) -> String {
        if let source = track.sourceID, let remote = track.remoteID { return "\(source)|\(remote)" }
        return track.id.uuidString
    }
}

struct ArtistCatalogSongRow: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    let catalog: ArtistCatalog
    let track: Track
    let queue: [Track]
    let title: String
    var subtitle: String? = nil

    var body: some View {
        if let result = catalog.module(for: track), library.moduleTrack(result) == nil {
            ModuleResultRow(track: result, subtitle: subtitle, onPlay: play)
        } else {
            TrackRow(track: currentTrack, subtitle: subtitle, onPlay: play)
        }
    }

    private var currentTrack: Track {
        if let result = catalog.module(for: track) { return result.enriching(library.moduleTrack(result) ?? track) }
        return library.trackByID[track.id] ?? track
    }

    private func play() {
        player.play(catalog.resolve(queue, library: library), startAt: queue.firstIndex { $0.id == track.id } ?? 0,
                    title: title)
    }
}

struct ArtistCatalogMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    let catalog: ArtistCatalog
    let tracks: [Track]
    let title: String
    var kind: LibraryEntry.Kind = .artist

    var body: some View {
        let current = catalog.current(tracks, library: library)
        Button { player.play(catalog.resolve(tracks, library: library), title: title, context: kind) } label: { Label("Play", systemImage: "play") }
        Button { player.play(catalog.resolve(tracks, library: library), title: title, shuffled: true, context: kind) } label: { Label("Shuffle", systemImage: "shuffle") }
        Button { player.playNext(catalog.resolve(tracks, library: library)) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.playAfter(catalog.resolve(tracks, library: library)) } label: { Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward") }
        if tracks.contains(where: { catalog.module(for: $0) != nil }) {
            Button { library.keep(catalog.resolve(tracks, library: library).map(\.id)) } label: { Label("Add to Library", systemImage: "plus") }
        }
        if current.contains(where: { $0.isRemote && !$0.isDownloaded }) {
            Button { downloads.download(catalog.resolve(tracks.filter(\.isRemote), library: library)) } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        if current.contains(where: \.isDownloaded) {
            Button(role: .destructive) { downloads.removeDownloads(current.filter(\.isDownloaded)) } label: {
                Label("Remove Downloads", systemImage: "xmark.circle")
            }
        }
    }
}

/// Use a real cached image when available; a stale hasArtwork flag must not hide source artwork.
struct ArtistCatalogArtwork: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SourceManager.self) private var sources
    @Environment(AppSettings.self) private var settings
    @State private var remoteImage: UIImage?
    let entry: LibraryEntry
    var radius: CGFloat = 12

    var body: some View {
        let tracks = currentTracks
        let cached = cachedImage(in: tracks)
        let requests = cached == nil && !settings.offlineMode && NetworkMonitor.shared.isOnline
            ? imageRequests(for: tracks) : []
        let theme = ThemeStore.shared.current
        let shape = entry.isCircle ? AnyShape(Circle()) : theme.artShape.shape(radius: radius * theme.cornerScale)

        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = cached ?? remoteImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ArtworkView(tracks: tracks, seed: entry.key, style: entry.isCircle ? .circle : .rounded(radius)).thumbnail(480)
                }
            }
            .clipShape(shape)
            .overlay { ArtFrameOverlay(frame: theme.artFrame, shape: shape, accent: theme.accentColor, ink: theme.inkColor) }
            .task(id: requests) {
                remoteImage = nil
                for request in requests {
                    guard !Task.isCancelled else { return }
                    let image = await ArtistCatalogImageCache.shared.image(for: request)
                    guard !Task.isCancelled else { return }
                    if let image { remoteImage = image; return }
                }
            }
    }

    private var currentTracks: [Track] {
        entry.tracks.map { preview in
            var track = library.trackByID[preview.id] ?? preview
            if track.artworkURL?.isEmpty != false { track.artworkURL = preview.artworkURL }
            if track.remoteAlbumID?.isEmpty != false { track.remoteAlbumID = preview.remoteAlbumID }
            return track
        }
    }

    private func cachedImage(in tracks: [Track]) -> UIImage? {
        for track in tracks {
            if let image = ArtworkCache.image(for: track, maxPixel: 700) { return image }
        }
        return nil
    }

    private func imageRequests(for tracks: [Track]) -> [URLRequest] {
        var requests: [URLRequest] = []
        var seen = Set<URLRequest>()
        var serverAlbums = Set<String>()
        for track in tracks {
            if let link = track.artworkURL, let url = URL(string: link),
               let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) {
                let request = URLRequest(url: url)
                if seen.insert(request).inserted { requests.append(request) }
            }
            guard let client = sources.client(for: track.sourceID) else { continue }
            let album = track.remoteAlbumID ?? track.remoteImageTag ?? "\(track.artist)|\(track.album)"
            guard serverAlbums.insert("\(client.account.id)|\(album)").inserted else { continue }
            let ids = client.account.kind == .subsonic
                ? [track.remoteImageTag, track.remoteAlbumID, track.remoteID]
                : [track.remoteAlbumID, track.remoteID]
            for id in ids.compactMap({ $0 }).filter({ !$0.isEmpty }) {
                guard let request = client.imageRequest(itemID: id, maxSide: 700), seen.insert(request).inserted else { continue }
                requests.append(request)
            }
        }
        return requests
    }
}

/// Share cover downloads between the artist header, album cards and album detail pages.
@MainActor
private final class ArtistCatalogImageCache {
    static let shared = ArtistCatalogImageCache()
    private let images = NSCache<NSString, UIImage>()
    private var running: [URLRequest: Task<UIImage?, Never>] = [:]

    private init() {
        images.countLimit = 128
        images.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for request: URLRequest) async -> UIImage? {
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }.joined(separator: "\n")
        let key = ((request.url?.absoluteString ?? "") + "\n" + headers) as NSString
        if let image = images.object(forKey: key) { return image }
        let task: Task<UIImage?, Never>
        if let pending = running[request] {
            task = pending
        } else {
            task = Task {
                var timedRequest = request
                timedRequest.timeoutInterval = 15
                guard let (data, response) = try? await URLSession.shared.data(for: timedRequest),
                      let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 700]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                return UIImage(cgImage: image)
            }
            running[request] = task
        }
        let image = await task.value
        running[request] = nil
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            images.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}

/// Catalog albums can be opened before any of their extension songs have been saved.
struct ArtistCatalogAlbumView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    let catalog: ArtistCatalog
    let album: LibraryEntry

    var body: some View {
        List {
            VStack(spacing: 12) {
                ArtistCatalogArtwork(entry: album).frame(width: 210, height: 210)
                Text(album.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text("\(catalog.name) · \(songCount(album.tracks.count))").foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        player.play(catalog.resolve(album.tracks, library: library), title: album.title, context: .album)
                    } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    Button {
                        player.play(catalog.resolve(album.tracks, library: library), title: album.title, shuffled: true, context: .album)
                    } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
                .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            ForEach(album.tracks) { track in
                ArtistCatalogSongRow(catalog: catalog, track: track, queue: album.tracks, title: album.title)
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ArtistCatalogMenu(catalog: catalog, tracks: album.tracks, title: album.title, kind: .album)
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }
}

@MainActor
@Observable
final class ArtistCatalogLoader {
    nonisolated struct Request: Equatable, Sendable {
        let name: String
        let offline: Bool
        let online: Bool
        let modules: [InstalledModule]
    }

    private(set) var moduleTracks: [ModuleTrack] = []
    private(set) var loading = false
    private(set) var failedModules: [String] = []
    @ObservationIgnored private var generation = UUID()

    func load(_ request: Request) async {
        let generation = UUID()
        self.generation = generation
        moduleTracks = []
        failedModules = []
        guard !request.offline, request.online else { loading = false; return }
        loading = true
        defer { if self.generation == generation { loading = false } }
        await withTaskGroup(of: String?.self) { group in
            for module in request.modules {
                group.addTask {
                    await self.loadModule(module, name: request.name, generation: generation)
                }
            }
            for await failure in group {
                guard !Task.isCancelled, self.generation == generation else { group.cancelAll(); return }
                if let failure, !failedModules.contains(failure) { failedModules.append(failure) }
            }
        }
    }

    private func loadModule(_ module: InstalledModule, name: String, generation: UUID) async -> String? {
        do {
            _ = try await ModuleStore.shared.artistTracks(module, name: name, onAlbumFailure: { _ in
                guard !Task.isCancelled, self.generation == generation else { return }
                if !self.failedModules.contains(module.name) { self.failedModules.append(module.name) }
            }) { found in
                guard !Task.isCancelled, self.generation == generation else { return }
                self.moduleTracks.removeAll { $0.moduleID == module.id }
                self.moduleTracks += found
            }
            return nil
        } catch { return module.name }
    }

}
