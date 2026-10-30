import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        NowPlayingLiveActivity()
        PlayPauseControl()
    }
}

// MARK: - Home & Lock Screen widget

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: SharedNowPlaying
    var style = WidgetStyle.load()
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        var s = SharedNowPlaying()
        s.hasTrack = true; s.title = "Glass Horizon"; s.artist = "Aurora Vale"; s.isPlaying = false; s.duration = 200; s.position = 80
        return NowPlayingEntry(date: .now, state: s)
    }
    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let saved = SharedNowPlaying.load().settled()
        completion(context.isPreview && !saved.hasTrack ? placeholder(in: context) : NowPlayingEntry(date: .now, state: saved))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let state = SharedNowPlaying.load().settled()
        var entries = [NowPlayingEntry(date: .now, state: state)]
        // If the app stops reporting (closed, killed), the song can't still be playing after it ended:
        // from then on the widget offers to resume it instead of showing a pause button for nothing.
        if let end = state.liveRange?.upperBound, end > .now {
            var paused = state
            paused.isPlaying = false
            paused.position = state.duration
            entries.append(NowPlayingEntry(date: end.addingTimeInterval(20), state: paused))
        }
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground(state: entry.state, style: entry.style) }
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing in Music, or the last song to resume. Change the look in Music ▸ Customize ▸ Widgets.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry
    var body: some View { NowPlayingWidgetContent(state: entry.state, style: entry.style, family: family) }
}

// MARK: - Live Lyrics (Live Activity + Dynamic Island)

/// Only the lyrics: the system Now Playing next to it already has the cover, controls and progress.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenLyricsView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityArt(file: s.artFile, accent: s.accentHex).frame(width: 36, height: 36)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(s.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LyricLines(state: s, size: 17)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                LyricsGlyph(state: s)
            } compactTrailing: {
                Text(s.lyric.flatMap { $0.isEmpty ? nil : $0 } ?? "♪")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            } minimal: {
                LyricsGlyph(state: s)
            }
            .keylineTint(Color(hex6: s.accentHex))
        }
    }
}

struct LyricsGlyph: View {
    let state: NowPlayingAttributes.ContentState
    var body: some View {
        Image(systemName: "quote.bubble.fill")
            .foregroundStyle(Color(hex6: state.accentHex))
            .symbolEffect(.pulse, isActive: state.isPlaying)
    }
}

struct LyricLines: View {
    let state: NowPlayingAttributes.ContentState
    var size: CGFloat = 20
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.lyric.flatMap { $0.isEmpty ? nil : $0 } ?? "♪")
                .font(.system(size: size, weight: .bold))
                .lineLimit(2)
                .contentTransition(.opacity)
            if let next = state.nextLyric {
                Text(next)
                    .font(.system(size: size * 0.8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
}

struct LockScreenLyricsView: View {
    let state: NowPlayingAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ActivityArt(file: state.artFile, accent: state.accentHex).frame(width: 22, height: 22)
                Text("\(state.title) · \(state.artist)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                LyricsGlyph(state: state).font(.caption)
            }
            LyricLines(state: state)
        }
        .padding(16)
    }
}

struct ActivityArt: View {
    let file: String?
    let accent: String
    var body: some View {
        Group {
            if let file, let url = AppGroup.artworkDir?.appendingPathComponent(file), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack { Color(hex6: accent); Image(systemName: "music.note").foregroundStyle(.white) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Control Center

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.local.music.playpause") {
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                Label("Music", systemImage: "playpause.fill")
            }
        }
        .displayName("Play / Pause Music")
        .description("Plays or pauses Music.")
    }
}
