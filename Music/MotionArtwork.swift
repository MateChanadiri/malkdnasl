import AVFoundation
import MusicKit
import SwiftUI

// MARK: - Lookup

/// Animated album covers ("motion artwork") from the Apple Music catalog.
/// Needs the MusicKit app service on the App ID and the user's OK; without either it quietly finds nothing.
enum MotionArtwork {
    static var isAvailable: Bool { MusicAuthorization.currentStatus == .authorized }

    /// Asks once, from a user action (Organize's scan).
    static func requestAccess() async -> Bool {
        if MusicAuthorization.currentStatus == .notDetermined { _ = await MusicAuthorization.request() }
        return isAvailable
    }

    /// The looping square video for an album, if Apple Music has one.
    @concurrent
    static func find(artist: String, album: String) async -> URL? {
        guard MusicAuthorization.currentStatus == .authorized else { return nil }
        var search = MusicCatalogSearchRequest(term: "\(artist) \(album)", types: [Album.self])
        search.limit = 5
        guard let hits = try? await search.response().albums else { return nil }
        func norm(_ s: String) -> String { s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber } }
        guard let match = hits.first(where: { norm($0.title).hasPrefix(norm(album)) && norm($0.artistName).contains(norm(artist).prefix(6)) }),
              let storefront = try? await MusicDataRequest.currentCountryCode,
              let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/albums/\(match.id.rawValue)?extend=editorialVideo"),
              let data = try? await MusicDataRequest(urlRequest: URLRequest(url: url)).response().data else { return nil }

        struct Response: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable {
                    struct Videos: Decodable {
                        struct Video: Decodable { let video: String? }
                        let motionSquareVideo1x1: Video?
                        let motionDetailSquare: Video?
                    }
                    let editorialVideo: Videos?
                }
                let attributes: Attributes?
            }
            let data: [Item]
        }
        let videos = (try? JSONDecoder().decode(Response.self, from: data))?.data.first?.attributes?.editorialVideo
        return (videos?.motionSquareVideo1x1?.video ?? videos?.motionDetailSquare?.video).flatMap(URL.init(string:))
    }
}

extension MotionArtwork {
    /// When a song starts, its album's animated cover is looked up once (answers are cached, misses retried after
    /// a few days), so Now Playing shows it without a Clean Library scan first. Only with Apple Music access
    /// already given (Clean Library asks for it) and online lookups allowed.
    static func fillIn(for track: Track, library: LibraryStore, settings: AppSettings) {
        guard track.motionArtworkURL == nil, track.album != "Unknown Album", !track.album.isEmpty,
              isAvailable, settings.onlineLookups, !settings.offlineMode, NetworkMonitor.shared.isOnline else { return }
        let artist = track.artist, album = track.album
        Task {
            guard let url = await LookupCache.shared.motion(artist: artist, album: album) else { return }
            let ids = Set(library.allTracks.filter { $0.artist == artist && $0.album == album && $0.motionArtworkURL == nil }.map(\.id))
            library.updateMany(ids) { $0.motionArtworkURL = url.absoluteString }
        }
    }
}

// MARK: - Playback

/// A muted, looping video laid over the still cover; it fades in once the first frame is ready,
/// so a slow connection only ever shows the normal artwork.
struct MotionCover: View {
    let url: URL
    @State private var ready = false

    var body: some View {
        LoopingVideo(url: url, ready: $ready)
            .opacity(ready ? 1 : 0)
            .animation(.easeOut(duration: 0.6), value: ready)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct LoopingVideo: UIViewRepresentable {
    let url: URL
    @Binding var ready: Bool

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url) { ready = true }
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.url != url { ready = false; view.play(url) { ready = true } }
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var observation: NSKeyValueObservation?
        private(set) var url: URL?

        func play(_ url: URL, onReady: @escaping @MainActor () -> Void) {
            stop()
            self.url = url
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: item)
            let layer = self.layer as! AVPlayerLayer
            layer.videoGravity = .resizeAspectFill
            layer.player = player
            observation = layer.observe(\.isReadyForDisplay, options: [.new]) { layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor in onReady() }
            }
            self.player = player
            player.play()
        }

        func stop() {
            observation = nil
            player?.pause()
            looper = nil
            player = nil
            (layer as? AVPlayerLayer)?.player = nil
        }
    }
}
