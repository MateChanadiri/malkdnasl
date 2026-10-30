import SwiftUI
import MediaPlayer
import AVKit

// MARK: - Apple Music style player
//
// Built fresh for Music. It is used whenever the active theme is the Apple Music one (inspiredBy == "Apple Music").
// Every other theme keeps using the customizable NowPlayingView.

/// How the artwork looks in the Apple Music player (Customize ▸ Player).
enum AMArtStyle: String, CaseIterable, Identifiable {
    case large, classic, vinyl, minimal, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .large: "Large"
        case .classic: "Classic"
        case .vinyl: "Vinyl"
        case .minimal: "Minimal"
        case .hidden: "Hidden"
        }
    }
    /// Share of the full artwork size.
    var factor: CGFloat {
        switch self {
        case .large: 1
        case .classic: 0.82
        case .vinyl: 0.92
        case .minimal: 0.45
        case .hidden: 0
        }
    }
    var radius: CGFloat { self == .classic ? 22 : self == .minimal ? 12 : 14 }
}

struct AppleMusicPlayerView: View {
    enum Panel { case artwork, lyrics, queue }

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(LyricsService.self) private var lyricsService
    @Environment(DownloadManager.self) private var downloads
    /// Artwork styles are switched off for now; the big cover is always used.
    private var artStyle: AMArtStyle { AMArtStyle(rawValue: design.artStyleRaw ?? "") ?? .large }

    @State private var panel: Panel = .artwork
    @State private var drift = false
    @State private var showEQ = false
    @State private var showPicker = false
    @State private var editLyrics = false
    @State private var fullLyrics = false
    /// Lyrics open: the controls slide away so the words use the whole screen (the strip at the bottom brings them back).
    @State private var focus = false
    @State private var controlsH: CGFloat = 320
    @State private var focusTask: Task<Void, Never>?
    @State private var showTiming = false
    @State private var showMetadata = false
    @State private var showCover = false
    @State private var showCustomize = false
    @Namespace private var ns
    @State private var dragOffset: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    private var screenHeight: CGFloat { UIScreen.main.bounds.height }
    private var design: PlayerDesign { PlayerDesignStore.shared.current }

    var body: some View {
        let track = player.current
        GeometryReader { geo in
        ZStack {
            AMBackground(track: track, drift: drift, mode: design.background)
                .contentShape(Rectangle())
                .gesture(dismissDrag)

            if let track {
                appleLayout(track)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .animation(.smooth(duration: 0.5), value: panel)
                .animation(.smooth(duration: 0.38), value: focus)
                .onChange(of: panel) { _, now in
                    focusTask?.cancel()
                    if now == .lyrics {
                        focusTask = Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            if !Task.isCancelled, panel == .lyrics { setFocus(true) }
                        }
                    } else { focus = false }
                }
                .sheet(isPresented: $showEQ) { EqualizerSheet() }
                .sheet(isPresented: $showPicker) { PlaylistPicker(trackIDs: [track.id]) }
                .sheet(isPresented: $editLyrics) { LyricsEditor(track: track) }
                .sheet(isPresented: $showTiming) { LyricsTimingSheet(track: track) }
                .sheet(isPresented: $showCover) { CoverDesigner(track: track) }
                .sheet(isPresented: $showCustomize) { NavigationStack { PlayerStyleSettings().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCustomize = false } } } }.presentationDetents([.medium, .large]) }
                .sheet(isPresented: $showMetadata) {
                    NavigationStack {
                        TrackEditor(track: library.trackByID[track.id] ?? track)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showMetadata = false } } }
                    }
                }
                .fullScreenCover(isPresented: $fullLyrics) { FullScreenLyricsView() }
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.colorScheme, .dark)
        .mask { RoundedRectangle(cornerRadius: dragOffset > 0 ? min(44, 12 + dragOffset * 0.3) : 0, style: .continuous).ignoresSafeArea() }
        .scaleEffect(1 - min(dragOffset / screenHeight, 1) * 0.06, anchor: .top)
        .offset(y: dragOffset)
        .presentationBackground(.clear)
        .onAppear { drift = true }
        .onChange(of: track == nil) { _, gone in if gone { dismiss() } }
    }


    // MARK: Apple layout

    private func appleLayout(_ track: Track) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .gesture(dismissDrag)

            middle(track)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, focus ? -(controlsH - 34) : 0)
                .zIndex(0)

            VStack(spacing: 0) {
                ForEach(design.activeRows) { row in
                    switch row {
                    case .scrubber: scrubberBlock.padding(.horizontal, 26).padding(.top, 16)
                    case .controls: transport.padding(.top, 14)
                    case .volume: volumeRow.padding(.horizontal, 26).padding(.top, 18)
                    case .bottom: bottomRow.padding(.horizontal, 26).padding(.top, 14)
                    default: EmptyView()
                    }
                }
                Color.clear.frame(height: 14)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 100 { controlsH = $0 } }
            .offset(y: focus ? controlsH : 0)
            .opacity(focus ? 0 : 1)
            .allowsHitTesting(!focus)
            .zIndex(1)
        }
        .overlay(alignment: .bottom) {
            // Invisible strip where the controls were: one tap brings them back.
            if focus {
                Color.clear
                    .frame(height: 96)
                    .contentShape(Rectangle())
                    .onTapGesture { setFocus(false) }
                    .accessibilityLabel("Show Controls")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    // MARK: Middle area (artwork morphs between big and the small header cover; everything else stays put)

    private func middle(_ track: Track) -> some View {
        GeometryReader { g in
            let W: CGFloat = g.size.width
            let H: CGFloat = g.size.height
            let isArt: Bool = panel == .artwork
            let headerH: CGFloat = 56
            let gap: CGFloat = 20
            let inset: CGFloat = 26
            let full: CGFloat = max(60, min(W - inset * 2, H - headerH - gap))
            let style: AMArtStyle = artStyle
            let big: CGFloat = style == .hidden ? 0 : full * CGFloat(design.artScale)
            let extra: CGFloat = max(0, (H - (big + gap + headerH)) / 2)
            let artSize: CGFloat = isArt ? big : 52
            let artX: CGFloat = isArt ? (W - big) / 2 : inset
            let artY: CGFloat = isArt ? extra : 2
            let headerY: CGFloat = isArt ? extra + big + gap : 0
            let titleX: CGFloat = isArt ? (W - full) / 2 : inset + 52 + 12
            let trailing: CGFloat = isArt ? (W - full) / 2 : inset
            let playing: Bool = player.isPlaying
            ZStack(alignment: .topLeading) {
                Group {
                    if panel == .lyrics {
                        LyricsView(track: track, edit: { editLyrics = true })
                            .padding(.horizontal, 18)
                            .simultaneousGesture(DragGesture(minimumDistance: 14).onChanged { _ in if !focus { setFocus(true) } })
                            .transition(.opacity)
                    } else if panel == .queue {
                        VStack(alignment: .leading, spacing: 0) {
                            queueHeader.padding(.horizontal, 26).padding(.top, 8)
                            QueueView(bare: true).padding(.horizontal, 10)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(width: W, height: max(0, H - headerH - 8), alignment: .top)
                .offset(y: headerH + 8)

                headerContent(track)
                    .keyframeAnimator(initialValue: 1.0, trigger: isArt) { content, o in
                        content.opacity(o)
                    } keyframes: { _ in
                        // The title row sits out the middle of the morph, so it never runs through the big cover.
                        KeyframeTrack {
                            CubicKeyframe(0.0, duration: 0.15)
                            CubicKeyframe(0.0, duration: 0.17)
                            CubicKeyframe(1.0, duration: 0.23)
                        }
                    }
                    .padding(.leading, titleX)
                    .padding(.trailing, trailing)
                    .frame(width: W, height: headerH, alignment: .leading)
                    .offset(y: headerY)

                ArtworkView(track: track, radius: isArt ? artRadius(big) : 8)
                    .animatedCover()
                    .frame(width: artSize, height: artSize)
                    .scaleEffect(isArt && !playing ? 0.84 : 1)
                    .shadow(color: Color.black.opacity(isArt ? (playing ? 0.5 : 0.22) : 0), radius: isArt ? 26 : 0, y: isArt ? 16 : 0)
                    .animation(.spring(duration: 0.6, bounce: 0.3), value: playing)
                    .opacity(isArt && (style == .hidden || style == .vinyl) ? 0 : 1)
                    .offset(x: artX, y: artY)
                    .contentShape(Rectangle())

                if isArt && style == .vinyl {
                    VinylArtwork(track: track, spinning: playing)
                        .frame(width: big, height: big)
                        .offset(x: artX, y: artY)
                        .transition(.opacity)
                }
            }
            .frame(width: W, height: H, alignment: .topLeading)
        }
        .animation(.spring(duration: 0.55, bounce: 0.08), value: panel)
    }

    private func artRadius(_ size: CGFloat) -> CGFloat {
        switch design.artShape {
        case .rounded: 14
        case .square: 0
        case .circle: size / 2
        }
    }

    private func headerContent(_ track: Track) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: track.title, centered: false, centerShift: 0)
                    .font(.system(size: 19, weight: .bold))
                MarqueeText(text: track.artist, centered: false, centerShift: 0)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(track.id)
            .transition(.blurReplace)

            FavoriteStarButton(isFavorite: track.isFavorite) { library.toggleFavorite(track) }

            Menu {
                menuContent(track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(TransportPressStyle(scales: false, highlight: true))
        }
        .animation(.smooth(duration: 0.4), value: track.id)
    }

    @ViewBuilder private func menuContent(_ track: Track) -> some View {
        if panel == .lyrics {
            Button { settings.wordLyrics.toggle() } label: {
                Label(settings.wordLyrics ? "Line by Line" : "Word by Word", systemImage: "text.word.spacing")
            }
            Button { showTiming = true } label: { Label("Adjust Timing…", systemImage: "clock.arrow.2.circlepath") }
            Button { lyricsService.findAnywhere(track) } label: { Label("Find Other Lyrics", systemImage: "globe") }
            Picker("Translate To", selection: Binding(get: { settings.translationTarget }, set: { settings.translationTarget = $0 })) {
                ForEach(LyricsLanguages.targets, id: \.0) { Text($0.1).tag($0.0) }
            }
            Divider()
        }
        ForEach(ThemeStore.shared.current.player.menu.filter(\.visible)) { entry in menuItem(entry.item, track) }
        Divider()
        Button {
            showCustomize = true
        } label: { Label("Customize Player", systemImage: "slider.horizontal.below.square.and.square.filled") }
    }

    @ViewBuilder private func menuItem(_ item: PlayerMenuItem, _ track: Track) -> some View {
        switch item {
        case .addToPlaylist:
            Button { showPicker = true } label: { Label("Add to Playlist…", systemImage: item.icon) }
        case .share:
            if let song = SharedSong(track) {
                ShareLink(item: song, preview: SharePreview(track.title)) { Label("Share Song", systemImage: item.icon) }
            } else {
                ShareLink(item: ShareItem.text(for: track), subject: Text(track.title)) { Label("Share Song", systemImage: item.icon) }
            }
        case .download: downloadItem(track)
        case .station:
            Button {
                player.startStation(from: track)
                withAnimation(.smooth(duration: 0.45)) { panel = .queue }
            } label: { Label("Create Station", systemImage: item.icon) }
        case .mix:
            if player.upcoming.first != nil {
                Button { player.mixNow() } label: { Label("Mix Into Next Song", systemImage: item.icon) }
            }
        case .goArtist:
            Button { router.open(.artist(track.artist)) } label: { Label("Go to Artist", systemImage: item.icon) }
        case .goAlbum:
            Button { router.open(.album("\(track.artist)|\(track.album)")) } label: { Label("Go to Album", systemImage: item.icon) }
        case .editMetadata:
            Button { showMetadata = true } label: { Label("Edit Metadata…", systemImage: item.icon) }
        case .designCover:
            Button { showCover = true } label: { Label("Design Cover…", systemImage: item.icon) }
        case .editLyrics:
            Button { editLyrics = true } label: { Label("Edit Lyrics", systemImage: item.icon) }
        case .saveQueue:
            Button {
                library.createPlaylist(name: player.queueTitle.isEmpty ? "Queue" : player.queueTitle, trackIDs: player.queue.map(\.trackID))
            } label: { Label("Save Queue as Playlist", systemImage: item.icon) }
        case .sleep:
            Menu { SleepTimerMenuItems() } label: { Label("Sleep Timer", systemImage: item.icon) }
        case .equalizer:
            Button { showEQ = true } label: { Label("Equalizer", systemImage: item.icon) }
        }
    }

    /// Download / Remove Download for streaming songs.
    @ViewBuilder private func downloadItem(_ track: Track) -> some View {
        let t = library.trackByID[track.id] ?? track
        if t.isRemote {
            if t.isDownloaded {
                Button(role: .destructive) { downloads.removeDownloads([t]) } label: { Label("Remove Download", systemImage: "xmark.circle") }
            } else {
                switch downloads.state(t.id) {
                case .downloading(let p):
                    Button {} label: { Label("Downloading… \(Int(p * 100))%", systemImage: "arrow.down.circle.dotted") }.disabled(true)
                case .queued:
                    Button {} label: { Label("Waiting to Download…", systemImage: "arrow.down.circle.dotted") }.disabled(true)
                case .failed:
                    Button { downloads.download([t]) } label: { Label("Download Failed – Try Again", systemImage: "exclamationmark.arrow.circlepath") }
                case nil:
                    Button { downloads.download([t]) } label: { Label("Download Song", systemImage: "arrow.down.circle") }
                }
            }
        }
    }

    // MARK: Scrubber

    private var scrubberBlock: some View {
        AMScrubber(showTimes: design.showTimes)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            SkipButton(direction: .previous, size: 28, frame: 72) { player.previous() }
                .sensoryFeedback(.impact(weight: .light), trigger: player.currentIndex)
            Spacer(minLength: 0)

            Button { player.togglePlay() } label: {
                PlayPauseIcon(isPlaying: player.isPlaying, size: 58)
                    .frame(width: 96, height: 96)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportPressStyle(scales: true, highlight: true))
            .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)

            Spacer(minLength: 0)
            SkipButton(direction: .next, size: 28, frame: 72) { player.next() }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 6)
    }

    // MARK: Volume

    private var volumeRow: some View {
        AMVolumeRow()
    }

    // MARK: Bottom row: lyrics · AirPlay · queue

    private var bottomRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(design.bottom) { b in
                bottomButton(b)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private func bottomButton(_ b: PlayerBottomButton) -> some View {
        switch b {
        case .lyrics: panelButton("quote.bubble", target: .lyrics, label: "Lyrics")
        case .queue: panelButton("list.bullet", target: .queue, label: "Up Next")
        case .airplay:
            AirPlayButton()
                .frame(width: 30, height: 30)
                .scaleEffect(1.15)
                .frame(width: 60, height: 44)
                .contentShape(Rectangle())
        case .share:
            if let t = player.current {
                ShareLink(item: ShareItem.text(for: t), subject: Text(t.title)) {
                    Image(systemName: b.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.white).frame(width: 60, height: 44)
                }
            }
        case .equalizer:
            Button { showEQ = true } label: {
                Image(systemName: b.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.white).frame(width: 60, height: 44)
            }
        case .sleep:
            Menu { SleepTimerMenuItems() } label: {
                Image(systemName: b.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.white).frame(width: 60, height: 44)
            }
        }
    }

    private func panelButton(_ symbol: String, target: Panel, label: String) -> some View {
        let on = panel == target
        return Button {
            withAnimation(.smooth(duration: 0.5)) { panel = on ? .artwork : target }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? Color.black.opacity(0.8) : Color.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(on ? 0.85 : 0)))
                .frame(width: 60, height: 44)
                .contentShape(Rectangle())
                .animation(.smooth(duration: 0.3), value: on)
        }
        .buttonStyle(TransportPressStyle(scales: false, highlight: true))
        .accessibilityLabel(label)
        .sensoryFeedback(.selection, trigger: panel)
    }

    // MARK: Queue header (Playing Next · shuffle · repeat)

    private var queueHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                pill("shuffle", on: player.shuffle) { player.setShuffle(!player.shuffle) }
                pill(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) { player.cycleRepeat() }
                pill("infinity", on: settings.continuousPlayback) { settings.continuousPlayback.toggle() }
                automixPill
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Continue Playing").font(.system(size: 17, weight: .bold))
                if !player.queueTitle.isEmpty {
                    Text(player.queueTitle).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1)
                }
            }
        }
    }

    private var automixPill: some View {
        let on: Bool = settings.crossfadeEnabled
        return Button { settings.crossfadeEnabled.toggle() } label: {
            AutomixIcon(color: on ? Color.black.opacity(0.8) : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(on ? Color.white.opacity(0.88) : Color.white.opacity(0.18)))
                .animation(.smooth(duration: 0.25), value: on)
        }
        .buttonStyle(TransportPressStyle(scales: false, highlight: true))
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityLabel("Automix")
    }

    private func pill(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(on ? Color.black.opacity(0.8) : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(on ? Color.white.opacity(0.88) : Color.white.opacity(0.18)))
                .contentTransition(.symbolEffect(.replace))
                .animation(.smooth(duration: 0.25), value: on)
        }
        .buttonStyle(TransportPressStyle(scales: false, highlight: true))
        .sensoryFeedback(.selection, trigger: on)
    }

    // MARK: Dismiss

    private func setFocus(_ on: Bool) {
        withAnimation(.smooth(duration: 0.38)) { focus = on }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { g in
                guard g.translation.height > 0 || dragOffset > 0 else { return }
                let y = max(0, g.translation.height)
                dragOffset = y < 40 ? y * 0.6 : y - 16
            }
            .onEnded { g in
                let velocity = g.predictedEndTranslation.height - g.translation.height
                if g.translation.height > 120 || velocity > 260 { close(velocity: velocity) }
                else { withAnimation(.spring(duration: 0.4, bounce: 0.25)) { dragOffset = 0 } }
            }
    }

    private func close(velocity: CGFloat = 0) {
        let remaining = max(1, screenHeight - dragOffset)
        let speed = min(max(velocity / remaining, 0), 6)
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 260, damping: 32, initialVelocity: speed)) {
            dragOffset = screenHeight + 40
        } completion: {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }
}

// MARK: - Background

/// Blurred, slowly drifting artwork with the cover's colour washed over it, like Apple Music's moving backdrop.
private struct AMBackground: View {
    let track: Track?
    let drift: Bool
    var mode: PlayerBackgroundStyle = .artwork

    var body: some View {
        let tint: Color = ArtworkCache.tint(for: track)
        ZStack {
            Color.black
            LinearGradient(colors: [tint, tint.opacity(0.55), Color.black], startPoint: .top, endPoint: .bottom)
            if mode == .artwork, let track {
                ArtworkView(track: track, radius: 0)
                    .scaledToFill()
                    .frame(width: 520, height: 520)
                    .blur(radius: 70)
                    .opacity(0.75)
                    .rotationEffect(.degrees(drift ? 14 : -14))
                    .offset(x: drift ? 40 : -40, y: drift ? -60 : 40)
                    .scaleEffect(drift ? 1.25 : 1.0)
                    .id(track.id)
                    .transition(.opacity)
                ArtworkView(track: track, radius: 0)
                    .scaledToFill()
                    .frame(width: 420, height: 420)
                    .blur(radius: 60)
                    .opacity(0.55)
                    .rotationEffect(.degrees(drift ? -20 : 20))
                    .offset(x: drift ? -70 : 60, y: drift ? 200 : 120)
                    .id("b-\(track.id)")
                    .transition(.opacity)
            }
            Color.black.opacity(mode == .black ? 1 : 0.28)
        }
        .animation(.easeInOut(duration: 16).repeatForever(autoreverses: true), value: drift)
        .animation(.easeInOut(duration: 0.9), value: track?.id)
        .clipped()
        .ignoresSafeArea()
    }
}

// MARK: - Scrubber

/// A thin bar. It only reacts when you touch its knob (the spot the song is at), then follows your finger;
/// elapsed time is on the left and remaining time on the right.
private struct AMScrubber: View {
    var showTimes = true
    @Environment(PlayerModel.self) private var player
    @State private var dragging = false
    @State private var dragValue = 0.0
    @State private var grabOffset: CGFloat = 0

    var body: some View {
        let shown: Double = dragging ? dragValue : player.position
        let total: Double = player.duration
        let progress: Double = total > 0 ? min(1, max(0, shown / total)) : 0
        let remaining: Double = max(0, total - shown)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width: CGFloat = max(1, geo.size.width)
                AMBar(fraction: CGFloat(progress), thick: dragging)
                    .frame(width: width, height: geo.size.height)
                .frame(width: width, height: geo.size.height, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !dragging {
                                // Only a touch on the knob starts a drag.
                                let startKnob: CGFloat = width * CGFloat(progress)
                                guard abs(g.startLocation.x - startKnob) <= 34 else { return }
                                dragging = true
                                grabOffset = g.startLocation.x - startKnob
                            }
                            let f: Double = min(1, max(0, Double((g.location.x - grabOffset) / width)))
                            dragValue = f * player.duration
                        }
                        .onEnded { _ in
                            if dragging { player.seek(to: dragValue) }
                            dragging = false
                        }
                )
                .animation(.spring(duration: 0.25, bounce: 0.25), value: dragging)
            }
            .frame(height: 30)

            HStack {
                Text(formatTime(shown)).contentTransition(.numericText())
                Spacer()
                Text("-" + formatTime(remaining))
            }
            .opacity(showTimes ? 1 : 0)
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(dragging ? 0.85 : 0.55))
            .animation(.smooth(duration: 0.25), value: dragging)
        }
    }
}

// MARK: - Volume

/// Reads and sets the real system volume. The system's own volume control is kept off screen, hidden.
private enum VolumeBridge {
    static let view: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        v.showsRouteButton = false
        return v
    }()

    static var current: Double { Double(AVAudioSession.sharedInstance().outputVolume) }

    static func set(_ value: Double) {
        for sub in view.subviews {
            if let slider = sub as? UISlider { slider.value = Float(min(1, max(0, value))) }
        }
    }
}

private struct VolumeHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { VolumeBridge.view }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Speaker icons that follow the level (slashed at zero, waves filling up to full), and a slider that only
/// responds when its knob is touched.
struct AMVolumeRow: View {
    @State private var volume: Double = VolumeBridge.current
    @State private var dragging = false
    @State private var grabOffset: CGFloat = 0
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 13))
                .frame(width: 22)
                .contentTransition(.symbolEffect(.replace))
            GeometryReader { geo in
                let width: CGFloat = max(1, geo.size.width)
                AMBar(fraction: CGFloat(volume), thick: dragging)
                    .frame(width: width, height: geo.size.height)
                .frame(width: width, height: geo.size.height, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !dragging {
                                guard abs(g.startLocation.x - width * CGFloat(volume)) <= 34 else { return }
                                dragging = true
                                grabOffset = g.startLocation.x - width * CGFloat(volume)
                            }
                            let f: Double = min(1, max(0, Double((g.location.x - grabOffset) / width)))
                            volume = f
                            VolumeBridge.set(f)
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.spring(duration: 0.25, bounce: 0.25), value: dragging)
            }
            .frame(height: 34)
            Image(systemName: "speaker.wave.3.fill", variableValue: volume)
                .font(.system(size: 13))
                .frame(width: 26)
        }
        .foregroundStyle(Color.white.opacity(0.65))
        .background(VolumeHost().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false))
        .onReceive(ticker) { _ in
            if !dragging { volume = VolumeBridge.current }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume * 100)) percent")
    }
}

// MARK: - Apple-style bar

/// A rounded track with a lighter fill whose end is cut straight, like Apple Music. It thickens while touched.
private struct AMBar: View {
    let fraction: CGFloat
    let thick: Bool

    var body: some View {
        GeometryReader { geo in
            let f: CGFloat = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Color.white.opacity(0.22)
                Color(white: 0.82).opacity(0.85)
                    .frame(width: geo.size.width * f)
            }
            .clipShape(Capsule())
            .frame(height: thick ? 12 : 7)
            .frame(maxHeight: .infinity)
            .animation(.spring(duration: 0.25, bounce: 0.2), value: thick)
        }
    }
}

/// Apple's Automix mark: an outlined circle overlapping a solid one with a hole in it.
/// The crossfade glyph: two soft curves that cross over, one rising while the other falls.
struct CrossfadeCurves: Shape {
    var rising: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let startY: CGFloat = rising ? rect.maxY : rect.minY
        let endY: CGFloat = rising ? rect.minY : rect.maxY
        p.move(to: CGPoint(x: rect.minX, y: startY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: endY),
                   control1: CGPoint(x: rect.minX + rect.width * 0.55, y: startY),
                   control2: CGPoint(x: rect.minX + rect.width * 0.45, y: endY))
        return p
    }
}

struct AutomixIcon: View {
    var color: Color
    var body: some View {
        ZStack {
            CrossfadeCurves(rising: true).stroke(color, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            CrossfadeCurves(rising: false).stroke(color, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }
        .frame(width: 22, height: 13)
        .padding(1.3)
    }
}

// MARK: - Customize ▸ Player

/// Customize ▸ Player ▸ Overflow Menu: switch items on or off and drag them into order.
struct PlayerMenuSettings: View {
    var body: some View {
        ThemeEditForm(title: "Overflow Menu") { theme in
            Section {
                ForEach(theme.wrappedValue.player.menu) { entry in
                    Toggle(isOn: Binding<Bool>(
                        get: { entry.visible },
                        set: { on in
                            if let i = theme.wrappedValue.player.menu.firstIndex(where: { $0.item == entry.item }) {
                                theme.wrappedValue.player.menu[i].visible = on
                            }
                        })) {
                        Label(entry.item.title, systemImage: entry.item.icon)
                    }
                }
                .onMove { from, to in theme.wrappedValue.player.menu.move(fromOffsets: from, toOffset: to) }
            } footer: { Text("Items that are switched off disappear from the menu. “Customize Player” always stays at the bottom.") }
        }
    }
}
