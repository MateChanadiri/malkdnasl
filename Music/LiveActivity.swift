import ActivityKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import WidgetKit

/// Keeps the Home/Lock Screen widgets and the optional Live Lyrics activity in step with the player.
@MainActor
final class NowPlayingBridge {
    static let shared = NowPlayingBridge()

    private weak var player: PlayerModel?
    private weak var settings: AppSettings?
    private var activity: Activity<NowPlayingAttributes>?
    private var lastState: NowPlayingAttributes.ContentState?
    private var lastWidgetReload = Date.distantPast
    private var lastWidgetKey = ""
    private var artKey = ""
    private var lyricTask: Task<Void, Never>?
    private var lyricLines: [LyricLine] = []
    private var lyricsFor: String = ""
    /// What the widgets last got, so the 5-second refresh only writes and reloads when something changed.
    private var savedKey = ""
    private var savedStart = Date.distantPast
    private var lastSave = Date.distantPast

    func attach(player: PlayerModel, settings: AppSettings) {
        self.player = player
        self.settings = settings
        player.onStateChanged = { [weak self] in self?.refresh() }
        lyricTask = Task { [weak self] in
            while !Task.isCancelled {
                // Twice a second only while a Live Lyrics activity is showing.
                try? await Task.sleep(for: .milliseconds(self?.activity == nil ? 3000 : 500))
                self?.lyricTick()
            }
        }
        // Swiping the app away should close everything, not leave a player or Live Activity behind.
        // Handled synchronously — there's no time for async work once the app terminates.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NowPlayingBridge.shared.shutdown() }
        }
        // Clean up an activity left over from a previous launch.
        for a in Activity<NowPlayingAttributes>.activities where a.id != activity?.id {
            nonisolated(unsafe) let old = a
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The line being sung and the one after it; nil when the song has no synced lyrics.
    private func currentLyrics() -> (line: String, next: String?)? {
        guard let p = player, let t = p.current, let raw = t.lyrics else { return nil }
        let key = "\(t.id)\(raw.hashValue)"
        if key != lyricsFor { lyricLines = LyricsParser.parse(raw); lyricsFor = key }
        guard lyricLines.first?.time != nil else { return nil }
        let now = p.position + (t.lyricsOffset ?? 0)
        let i = lyricLines.lastIndex { ($0.time ?? .infinity) <= now + 0.25 }
        let next = lyricLines[(i.map { $0 + 1 } ?? 0)...].first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }?.text
        return (i.map { lyricLines[$0].text } ?? "", next)
    }

    private func lyricTick() {
        guard let p = player, p.isPlaying, activity != nil else { return }
        if currentLyrics()?.line != lastState?.lyric { refresh() }
    }

    func refresh() {
        guard let p = player else { return }
        let accent = ThemeStore.shared.current.accent
        guard let t = p.current else {
            SharedNowPlaying().save()
            reloadWidgets(key: "none")
            endActivity()
            return
        }
        let art = writeArtwork(t)
        var shared = SharedNowPlaying()
        shared.hasTrack = true
        shared.title = t.title
        shared.artist = t.artist
        shared.album = t.album
        shared.isPlaying = p.isPlaying
        shared.position = p.position
        shared.duration = p.duration
        shared.artFile = art
        shared.accentHex = accent
        // The next item only, without copying the rest of a long queue every few seconds.
        let nextItem = p.queue.indices.contains(p.currentIndex + 1) ? p.queue[p.currentIndex + 1] : nil
        shared.upNext = nextItem.flatMap { p.library.trackByID[$0.trackID] }.map { "\($0.title) — \($0.artist)" }
        // The widget's progress bar runs by itself from (updatedAt − position), so a playing song needs no new
        // data until something changes: another song, play/pause, a seek, the look. Saved now and then anyway,
        // for "Resume" after the app is gone.
        let key = "\(t.id)|\(p.isPlaying)|\(accent)|\(art ?? "")|\(shared.upNext ?? "")|\(t.title)|\(t.artist)"
        let start = shared.updatedAt.addingTimeInterval(-shared.position)
        let seeked = p.isPlaying && abs(start.timeIntervalSince(savedStart)) > 2
        if key != savedKey || seeked || Date().timeIntervalSince(lastSave) > 30 {
            shared.save()
            lastSave = Date()
            savedStart = start
            // At another speed the widget's clock drifts, so then it is still refreshed every minute.
            reloadWidgets(key: key + (seeked ? "|\(Int(start.timeIntervalSince1970))" : ""), periodic: p.playbackRate != 1)
            savedKey = key
        }

        // The system Now Playing already shows the song in the Dynamic Island and on the Lock Screen;
        // this activity only exists to add the lyrics.
        guard settings?.liveLyrics == true, ActivityAuthorizationInfo().areActivitiesEnabled,
              let lyrics = currentLyrics() else { endActivity(); return }
        let state = NowPlayingAttributes.ContentState(title: t.title, artist: t.artist, lyric: lyrics.line, nextLyric: lyrics.next,
                                                      isPlaying: p.isPlaying, artFile: art, accentHex: accent)
        if let activity {
            guard state != lastState else { return }
            lastState = state
            nonisolated(unsafe) let act = activity
            Task { await act.update(ActivityContent(state: state, staleDate: nil)) }
        } else if p.isPlaying, UIApplication.shared.applicationState == .active {
            do {
                activity = try Activity.request(attributes: NowPlayingAttributes(), content: ActivityContent(state: state, staleDate: nil))
                lastState = state
            } catch {}
        }
    }

    private func shutdown() {
        // The widget keeps the song, paused, so it can offer "Resume Music" instead of "Nothing Playing".
        var last = SharedNowPlaying.load()
        last.isPlaying = false
        if let p = player { last.position = p.position }
        last.updatedAt = Date()
        player?.shutdown()
        activity = nil
        lastState = nil
        last.save()
        WidgetCenter.shared.reloadAllTimelines()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<NowPlayingAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    private func endActivity() {
        guard let a = activity else { return }
        activity = nil
        lastState = nil
        nonisolated(unsafe) let act = a
        Task { await act.end(nil, dismissalPolicy: .immediate) }
    }

    private func reloadWidgets(key: String, periodic: Bool = false) {
        guard key != lastWidgetKey || (periodic && Date().timeIntervalSince(lastWidgetReload) > 60) else { return }
        lastWidgetKey = key
        lastWidgetReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Small JPEG in the App Group container that the widget extension can read.
    private func writeArtwork(_ t: Track) -> String? {
        let key = "\(t.id.uuidString)-\(t.artVersion ?? 0)"
        let name = "art-\(key).jpg"
        if key == artKey { return name }
        guard let dir = AppGroup.artworkDir else { return nil }
        let image = ArtworkCache.image(for: t) ?? CoverKit.image(CoverKit.auto(t.album + t.artist), side: 300)
        guard let cg = image?.cgImage,
              let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let side = 300
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.interpolationQuality = .high
        let w = CGFloat(cg.width), h = CGFloat(cg.height), s = max(CGFloat(side) / w, CGFloat(side) / h)
        ctx?.draw(cg, in: CGRect(x: (CGFloat(side) - w * s) / 2, y: (CGFloat(side) - h * s) / 2, width: w * s, height: h * s))
        guard let small = ctx?.makeImage() else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        // Keep the previous file too, so a widget that hasn't reloaded yet still finds its image.
        let old = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in old where f.lastPathComponent != name && f.lastPathComponent != "art-\(artKey).jpg" { try? FileManager.default.removeItem(at: f) }
        artKey = key
        return name
    }
}
