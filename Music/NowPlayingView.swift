import SwiftUI
import Translation

// MARK: - Full player

struct NowPlayingView: View {
    enum Mode { case artwork, lyrics, queue }

    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(EQModel.self) private var eq
    @Environment(Router.self) private var router
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .artwork
    @State private var showEQ = false
    @State private var editLyrics = false
    @State private var showPicker = false
    @State private var showCover = false
    @State private var showMetadata = false
    @State private var dragOffset: CGFloat = 0
    @State private var fullLyrics = false
    @State private var sharing = false
    // Edit mode: a working copy of the theme the player draws from until Done.
    @State private var draft: AppTheme?
    @State private var editTarget: PlayerEditTarget?
    @State private var draggingID: String?
    @State private var wiggle = false
    @State private var showAllSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ns
    private var theme: AppTheme { draft ?? ThemeStore.shared.current }
    private var editing: Bool { draft != nil }
    private var cfg: PlayerConfig { theme.player }

    var body: some View {
        let track = player.current
        ZStack {
            background(track)
                .contentShape(Rectangle())
                .gesture(dismissDrag)
                .onTapGesture { if editing { withAnimation(.smooth(duration: 0.3)) { editTarget = editTarget == nil ? .screen : nil } } }
                .onLongPressGesture(minimumDuration: 0.45) { if !editing { enterEdit() } }
            if let track {
                // Rows in the theme's order. Lyrics and queue take the artwork's place, with a small title on top.
                // One ForEach for both layouts: the scrubber, controls and bar keep their identity when the
                // mode changes, so they glide into place instead of being rebuilt (which made the bar jump in size).
                VStack(spacing: cfg.spacing.gap) {
                    if mode == .artwork {
                        if editing { hiddenTray }
                        if !cfg.visibleBlocks.contains(.artwork) { Spacer(minLength: 0) }
                    } else {
                        titleRow(track, compact: true)
                            .contentShape(Rectangle())
                            .gesture(dismissDrag)
                        Group {
                            if mode == .lyrics { LyricsView(track: track, edit: { editLyrics = true }, expand: { fullLyrics = true }) } else { QueueView() }
                        }
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                    }
                    let blocks = mode == .artwork ? cfg.visibleBlocks : cfg.visibleBlocks.filter { $0 != .artwork && $0 != .title }
                    ForEach(Array(blocks.enumerated()), id: \.element) { i, b in editable(b, index: i, track) }
                }
                .padding(.horizontal, 24)
                .padding(.top, editing ? 76 : 34)
                .padding(.bottom, 8 + cfg.spacing.bottomLift)
                .animation(.smooth(duration: 0.45), value: mode)
                .sheet(isPresented: $showEQ) { EqualizerSheet() }
                .sheet(isPresented: $editLyrics) { LyricsEditor(track: track) }
                .sheet(isPresented: $showPicker) { PlaylistPicker(trackIDs: [track.id]) }
                .sheet(isPresented: $showCover) { CoverDesigner(track: track) }
                .sheet(isPresented: $showMetadata) {
                    NavigationStack {
                        TrackEditor(track: library.trackByID[track.id] ?? track)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showMetadata = false } } }
                    }
                }
                .fullScreenCover(isPresented: $fullLyrics) { FullScreenLyricsView() }
            }
            if editing { editToolbar } else { grabber }
            if editing, let target = editTarget {
                // Options for what you tapped, on the side away from it so it stays visible while you change it.
                let bottomHalf: Bool = {
                    guard case .block(let b) = target, let i = cfg.visibleBlocks.firstIndex(of: b) else { return false }
                    return i >= cfg.visibleBlocks.count / 2
                }()
                VStack {
                    if !bottomHalf { Spacer() }
                    PlayerElementPanel(target: target, theme: draftBinding, close: { withAnimation(.smooth(duration: 0.3)) { editTarget = nil } },
                                       hide: hideAction(target))
                        .id(target)
                        .padding(.horizontal, 12)
                        .padding(.top, bottomHalf ? 58 : 0)
                        .padding(.bottom, bottomHalf ? 0 : 10)
                    if bottomHalf { Spacer() }
                }
                .transition(.move(edge: bottomHalf ? .top : .bottom).combined(with: .opacity))
                .zIndex(2)
            }
            if player.isBuffering {
                VStack { Spacer(); BufferingBadge().padding(.bottom, 250) }.allowsHitTesting(false)
            }
        }
        // Dark only inside the player. preferredColorScheme would flip the whole window behind the sheet,
        // re-rendering the app mid-animation every time the player opens or closes.
        .environment(\.colorScheme, .dark)
        // While dragging, the player becomes a card: rounded corners, slightly smaller, the app visible behind it.
        .mask { RoundedRectangle(cornerRadius: dragOffset > 0 ? min(44, 12 + dragOffset * 0.3) : 0, style: .continuous).ignoresSafeArea() }
        .scaleEffect(1 - min(dragOffset / screenHeight, 1) * 0.06, anchor: .top)
        .offset(y: dragOffset)
        .presentationBackground(.clear)
        .animation(.smooth(duration: 0.35), value: editing)
        .animation(.smooth(duration: 0.35), value: editTarget)
        .onDrop(of: [.text], isTargeted: nil) { _ in draggingID = nil; return true }
        .sheet(isPresented: $showAllSettings) {
            NavigationStack {
                PlayerLayoutEditor(theme: draftBinding)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAllSettings = false } } }
            }
        }
        .onAppear {
            if router.editPlayerOnOpen { router.editPlayerOnOpen = false; enterEdit() }
        }
        .onChange(of: track == nil) { _, gone in if gone { dismiss() } }
    }

    // MARK: Pieces

    @ViewBuilder private func block(_ b: PlayerBlock, _ track: Track) -> some View {
        switch b {
        case .artwork:
            artwork(track).frame(maxHeight: .infinity).contentShape(Rectangle()).gesture(dismissDrag)
                .onLongPressGesture(minimumDuration: 0.45) { if !editing { enterEdit() } }
        case .title: titleRow(track, compact: false).contentShape(Rectangle()).gesture(dismissDrag)
        case .scrubber: ScrubberSection(showEQ: { showEQ = true }, showPreset: cfg.showEQBadge, showTimes: cfg.showTimes)
        case .controls: controls
        case .bar: bottomBar
        }
    }

    private func background(_ track: Track?) -> some View {
        let tint = ArtworkCache.tint(for: track)
        return ZStack {
            Color.black
            switch theme.nowPlaying {
            case .artworkTint:
                LinearGradient(colors: [tint, tint.opacity(0.6), .black], startPoint: .top, endPoint: .bottom)
            case .blurredArtwork:
                Color.clear
                    .overlay {
                        if let track {
                            ArtworkView(track: track, radius: 0)
                                .scaledToFill()
                                .blur(radius: 30 + theme.blur * 70)
                                .opacity(1 - theme.transparency * 0.5)
                                .id(track.id)
                                .transition(.opacity)
                        }
                    }
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            case .themeColors:
                LinearGradient(colors: theme.colors, startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [tint.opacity(0.35 * (1 - theme.transparency)), .clear], startPoint: .top, endPoint: .center)
            case .black:
                EmptyView()
            }
            ThemeTexture(kind: theme.texture).environment(\.colorScheme, .dark)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.9), value: track?.id)
    }

    @ViewBuilder private func artwork(_ track: Track) -> some View {
        switch theme.playerLayout {
        case .classic:
            ArtworkView(track: track, radius: 20).animatedCover()
                .frame(maxHeight: 380 * theme.artworkScale)
                .matchedGeometryEffect(id: "art", in: ns)
                .scaleEffect(player.isPlaying ? 1 : 0.84)
                .shadow(color: .black.opacity(player.isPlaying ? 0.45 : 0.2), radius: player.isPlaying ? 28 : 10, y: player.isPlaying ? 16 : 6)
                .animation(.spring(duration: 0.55, bounce: 0.28), value: player.isPlaying)
                .id(track.id)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        case .large:
            ArtworkView(track: track, radius: 12).animatedCover()
                .frame(maxHeight: 470 * theme.artworkScale)
                .matchedGeometryEffect(id: "art", in: ns)
                .scaleEffect(player.isPlaying ? 1 : 0.94)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
                .animation(.spring(duration: 0.55, bounce: 0.2), value: player.isPlaying)
                .id(track.id)
                .transition(.opacity)
                .padding(.horizontal, -8)
        case .vinyl:
            VinylArtwork(track: track, spinning: player.isPlaying)
                .frame(maxHeight: 350 * theme.artworkScale)
                .matchedGeometryEffect(id: "art", in: ns)
                .id(track.id)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .minimal:
            VStack(spacing: 18) {
                ArtworkView(track: track, radius: 14)
                    .frame(width: 120 * theme.artworkScale, height: 120 * theme.artworkScale)
                    .matchedGeometryEffect(id: "art", in: ns)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            }
            .id(track.id)
            .transition(.opacity)
        }
    }

    private func titleRow(_ track: Track, compact: Bool) -> some View {
        HStack(spacing: 12) {
            if compact {
                ArtworkView(track: track, radius: 9)
                    .frame(width: 54, height: 54)
                    .matchedGeometryEffect(id: "art", in: ns)
            }
            let centered = !compact && cfg.titleAlignment == .center
            let buttons = (cfg.showStar ? 1 : 0) + (cfg.showTitleMenu ? 1 : 0)
            // A centred title sits in the middle of the whole row; long ones use the room up to the buttons, then scroll.
            let shift = buttons == 0 ? 0 : CGFloat(buttons * 42 + (buttons - 1) * 12 + 12) / 2
            VStack(alignment: centered ? .center : .leading, spacing: 2) {
                MarqueeText(text: track.title, centered: centered, centerShift: shift)
                    .font(.system(size: compact ? 17 : 22, weight: .bold))
                MarqueeText(text: track.artist, centered: centered, centerShift: shift)
                    .font(.system(size: compact ? 15 : 19))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .id(track.id)
            .transition(.blurReplace)
            if buttons > 0 { titleButtons(track) }
        }
        .animation(.smooth, value: track.id)
    }

    private func titleButtons(_ track: Track) -> some View {
        HStack(spacing: 12) {
            if cfg.showStar {
            Button { library.toggleFavorite(track) } label: {
                Image(systemName: track.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(track.isFavorite ? .yellow : .white)
                    .frame(width: 42, height: 42)
                    .contentTransition(.symbolEffect(.replace))
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: track.isFavorite)
            }
            if cfg.showTitleMenu { moreMenu(track, size: 42) }
        }
    }

    private func moreMenu(_ track: Track, size: CGFloat) -> some View {
        Menu {
            ForEach(cfg.menu.filter(\.visible)) { entry in menuItem(entry.item, track) }
            Divider()
            Button { enterEdit() } label: { Label("Customize Player", systemImage: "slider.horizontal.below.square.and.square.filled") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
                .overlay { downloadRing(track) }
        }
        .buttonStyle(.plain)
    }

    private var screenHeight: CGFloat { UIScreen.main.bounds.height }

    /// Pull-down to close. Only on the artwork, the title and empty space: the progress bar, the buttons and
    /// the Artwork · Lyrics · Queue switch keep their own drags (the switch's glass lens can be slid).
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { g in
                guard !editing, g.translation.height > 0 || dragOffset > 0 else { return }
                // A little resistance at the start, then it follows the finger 1:1.
                let y = max(0, g.translation.height)
                dragOffset = y < 40 ? y * 0.6 : y - 16
            }
            .onEnded { g in
                guard !editing else { return }
                let velocity = g.predictedEndTranslation.height - g.translation.height
                if g.translation.height > 120 || velocity > 260 { close(velocity: velocity) }
                else { withAnimation(.spring(duration: 0.4, bounce: 0.25)) { dragOffset = 0 } }
            }
    }

    /// Slides the player the rest of the way down, carrying the finger's speed, and removes it once it's off screen.
    private func close(velocity: CGFloat = 0) {
        let remaining = max(1, screenHeight - dragOffset)
        let speed = min(max(velocity / remaining, 0), 6)
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 260, damping: 32, initialVelocity: speed)) {
            dragOffset = screenHeight + 40
        } completion: {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }

    // MARK: Edit mode

    private var draftBinding: Binding<AppTheme> {
        Binding(get: { draft ?? ThemeStore.shared.current }, set: { draft = $0 })
    }

    private func enterEdit() {
        withAnimation(.smooth(duration: 0.35)) {
            mode = .artwork
            draft = ThemeStore.shared.current
            editTarget = nil
        }
        wiggle = true
    }

    private func finishEdit(save: Bool) {
        if save, var t = draft, t != ThemeStore.shared.current {
            // A built-in theme stays untouched: your layout becomes your own copy of it.
            if t.builtIn {
                let copy = ThemeStore.shared.duplicate(t)
                t.id = copy.id; t.name = copy.name; t.author = copy.author; t.builtIn = false
            }
            ThemeStore.shared.save(t)
            ThemeStore.shared.apply(t, edited: true)
        }
        withAnimation(.smooth(duration: 0.35)) { draft = nil; editTarget = nil }
        wiggle = false
    }

    private func hideAction(_ target: PlayerEditTarget) -> (() -> Void)? {
        guard case .block(let b) = target, b != .controls else { return nil }
        return {
            withAnimation(.smooth(duration: 0.35)) {
                if let i = draft?.player.blocks.firstIndex(where: { $0.block == b }) { draft?.player.blocks[i].visible = false }
                editTarget = nil
            }
        }
    }

    private var editToolbar: some View {
        VStack {
            HStack(spacing: 10) {
                Button("Cancel") { finishEdit(save: false) }
                    .buttonStyle(.glass)
                Spacer()
                Menu {
                    Section("Start From a Layout") {
                        ForEach(AppTheme.builtIns) { t in
                            Button(t.inspiredBy.map { "\(t.name) (\($0))" } ?? t.name) {
                                withAnimation(.smooth(duration: 0.45)) {
                                    draft?.player = t.player
                                    draft?.playerLayout = t.playerLayout
                                }
                            }
                        }
                    }
                    Button { showAllSettings = true } label: { Label("“…” Menu & All Settings", systemImage: "list.bullet") }
                } label: {
                    Label("Layouts", systemImage: "square.grid.2x2")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 36)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Done") { finishEdit(save: true) }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            Text(editTarget == nil ? "Drag to move · Tap to change · Tap the background for colors" : " ")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .foregroundStyle(.white)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Rows you hid, ready to be put back with one tap.
    @ViewBuilder private var hiddenTray: some View {
        let hidden = cfg.blocks.filter { !$0.visible }.map(\.block)
        if !hidden.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(hidden) { b in
                        Button {
                            withAnimation(.smooth(duration: 0.35)) {
                                if let i = draft?.player.blocks.firstIndex(where: { $0.block == b }) { draft?.player.blocks[i].visible = true }
                            }
                        } label: {
                            Label(b.title, systemImage: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).frame(height: 32)
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
            .transition(.opacity)
        }
    }

    /// One row of the player. In edit mode it wiggles, shows its outline, can be dragged to a new place and tapped for its options.
    @ViewBuilder private func editable(_ b: PlayerBlock, index: Int, _ track: Track) -> some View {
        if editing {
            let selected = editTarget == .block(b)
            block(b, track)
                .allowsHitTesting(b == .bar)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(selected ? 0.12 : 0.04))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(selected ? 0.9 : 0.35), style: StrokeStyle(lineWidth: selected ? 2 : 1.2, dash: selected ? [] : [6, 5]))
                }
                .overlay(alignment: .topLeading) {
                    if b != .controls && b != .bar {
                        Button {
                            withAnimation(.smooth(duration: 0.35)) {
                                if let i = draft?.player.blocks.firstIndex(where: { $0.block == b }) { draft?.player.blocks[i].visible = false }
                                if editTarget == .block(b) { editTarget = nil }
                            }
                        } label: {
                            Image(systemName: "minus").font(.system(size: 12, weight: .heavy)).foregroundStyle(.black)
                                .frame(width: 24, height: 24).background(Circle().fill(.white))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .offset(x: -8, y: -8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Adding buttons sits on the outline, not in the row, so the row looks exactly like it will.
                    if b == .bar {
                        Button { withAnimation(.smooth(duration: 0.3)) { editTarget = .block(.bar) } } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .heavy)).foregroundStyle(.black)
                                .frame(width: 24, height: 24).background(Circle().fill(.white))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 8, y: -8)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { withAnimation(.smooth(duration: 0.3)) { editTarget = selected ? nil : .block(b) } }
                .onDrag {
                    draggingID = b.rawValue
                    return NSItemProvider(object: b.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: PlayerReorderDrop(target: b.rawValue, dragging: $draggingID) { from, to in moveBlock(from, to) })
                .rotationEffect(.degrees(wiggleAngle(index)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.13 + Double(index % 3) * 0.02).repeatForever(autoreverses: true), value: wiggle)
                .sensoryFeedback(.selection, trigger: cfg.blocks)
        } else {
            block(b, track)
        }
    }

    private func wiggleAngle(_ i: Int) -> Double {
        guard editing, !reduceMotion else { return 0 }
        let a = i == 0 && cfg.visibleBlocks.first == .artwork ? 0.35 : 0.7
        return (wiggle ? a : -a) * (i.isMultiple(of: 2) ? 1 : -1)
    }

    private func moveBlock(_ from: String, _ to: String) {
        guard var blocks = draft?.player.blocks,
              let f = blocks.firstIndex(where: { $0.block.rawValue == from }),
              let t = blocks.firstIndex(where: { $0.block.rawValue == to }) else { return }
        blocks.move(fromOffsets: [f], toOffset: t > f ? t + 1 : t)
        draft?.player.blocks = blocks
    }

    private func moveBarItem(_ from: String, _ to: String) {
        guard var bar = draft?.player.bar,
              let f = bar.firstIndex(where: { $0.id.uuidString == from }),
              let t = bar.firstIndex(where: { $0.id.uuidString == to }) else { return }
        bar.move(fromOffsets: [f], toOffset: t > f ? t + 1 : t)
        draft?.player.bar = bar
    }

    private var grabber: some View {
        VStack {
            Button { close() } label: {
                Capsule().fill(.white.opacity(0.35)).frame(width: 40, height: 5).padding(.vertical, 12).padding(.horizontal, 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Player")
            Spacer()
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func menuItem(_ item: PlayerMenuItem, _ track: Track) -> some View {
        switch item {
        case .addToPlaylist:
            Button { showPicker = true } label: { Label("Add to Playlist…", systemImage: item.icon) }
        case .share:
            // One share action: the audio file when it is on this iPhone, otherwise the song's name.
            if let song = SharedSong(track) {
                ShareLink(item: song, preview: SharePreview(track.title)) { Label("Share Song", systemImage: item.icon) }
            } else {
                ShareLink(item: ShareItem.text(for: track), subject: Text(track.title)) { Label("Share Song", systemImage: item.icon) }
            }
        case .download: downloadItem(track)
        case .station:
            Button {
                player.startStation(from: track)
                withAnimation(.smooth(duration: 0.45)) { mode = .queue }
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

    /// Download / Remove Download for streaming songs in the "…" menu.
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

    /// Ring around the "…" button while saving; a small badge once the song is on this iPhone (or if it failed).
    @ViewBuilder private func downloadRing(_ track: Track) -> some View {
        let t = library.trackByID[track.id] ?? track
        if t.isRemote {
            let phase = downloads.phase(t)
            ZStack {
                if phase.kind == 1 {
                    DownloadRing(fraction: phase.fraction, lineWidth: 2.5, tint: Theme.accent, track: .white.opacity(0.12))
                        .transition(.opacity.combined(with: .scale(scale: 1.15)))
                }
                if phase == .done || phase == .failed {
                    Image(systemName: phase == .done ? "arrow.down.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white, phase == .done ? Theme.accent : .red)
                        .offset(x: 15, y: 15)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.4), value: phase.kind)
            .sensoryFeedback(.success, trigger: phase.kind) { _, new in new == 2 }
            .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        let c = cfg.controlScale
        return GlassEffectContainer(spacing: 18) {
            HStack(spacing: 0) {
                if cfg.showShuffleRepeat {
                    toggleIcon("shuffle", on: player.shuffle) { player.setShuffle(!player.shuffle) }
                    Spacer()
                }
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 34 * c)).frame(width: 64 * c, height: 64 * c)
                }
                .buttonStyle(PressScale())
                .sensoryFeedback(.impact(weight: .light), trigger: player.currentIndex)
                Spacer()
                Button { player.togglePlay() } label: { playButton(c) }
                    .buttonStyle(PressScale())
                    .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
                Spacer()
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 34 * c)).frame(width: 64 * c, height: 64 * c)
                }
                .buttonStyle(PressScale())
                if cfg.showShuffleRepeat {
                    Spacer()
                    toggleIcon(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) { player.cycleRepeat() }
                }
            }
            .frame(maxWidth: cfg.showShuffleRepeat ? .infinity : 280 * c)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func playButton(_ c: CGFloat) -> some View {
        let symbol = Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
        switch cfg.playStyle {
        case .glass:
            symbol.font(.system(size: 28 * c, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                .frame(width: 74 * c, height: 74 * c)
                .contentTransition(.symbolEffect(.replace))
                .glassEffect(.regular.tint(.white.opacity(0.92)).interactive(), in: .circle)
        case .accent:
            symbol.font(.system(size: 28 * c, weight: .bold)).foregroundStyle(.white)
                .frame(width: 74 * c, height: 74 * c)
                .contentTransition(.symbolEffect(.replace))
                .glassEffect(.regular.tint(theme.accentColor).interactive(), in: .circle)
        case .plain:
            symbol.font(.system(size: 46 * c, weight: .bold))
                .frame(width: 74 * c, height: 74 * c)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private func toggleIcon(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Circle().frame(width: 4, height: 4).opacity(on ? 1 : 0)
            }
            .foregroundStyle(on ? .white : .white.opacity(0.45))
            .frame(width: 44, height: 44)
            .animation(.smooth, value: on)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }

    private var bottomBar: some View {
        // Everything in this row is exactly 48 pt tall, on one centre line, in the theme's order.
        // Without a spacer or the view switcher nothing stretches, so the row is centred.
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if !cfg.barHasFlexible { Spacer(minLength: 0) }
                ForEach(cfg.bar) { e in
                    if editing { editableBarItem(e) } else { barItem(e.item) }
                }
                if !cfg.barHasFlexible { Spacer(minLength: 0) }
            }
        }
        .foregroundStyle(.white)
    }

    /// A button of the row in edit mode: shown but not working, draggable, with a "–" to take it out.
    private func editableBarItem(_ e: PlayerBarEntry) -> some View {
        Group {
            if e.item == .spacer {
                Capsule().strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                    .overlay { Image(systemName: "arrow.left.and.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.6)) }
                    .frame(minWidth: 36, maxWidth: .infinity)
                    .frame(height: Self.barHeight)
            } else {
                barItem(e.item).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { withAnimation(.smooth(duration: 0.3)) { draft?.player.bar.removeAll { $0.id == e.id } } } label: {
                Image(systemName: "minus").font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: 20, height: 20).background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .offset(x: -6, y: -6)
        }
        .contentShape(Rectangle())
        .onDrag {
            draggingID = e.id.uuidString
            return NSItemProvider(object: e.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: PlayerReorderDrop(target: e.id.uuidString, dragging: $draggingID) { from, to in moveBarItem(from, to) })
    }

    @ViewBuilder private func barItem(_ item: PlayerBarItem) -> some View {
        switch item {
        case .spacer:
            Spacer(minLength: 0)
        case .modes:
            PlayerModeSwitch(mode: $mode, height: Self.barHeight)
        case .lyrics, .queue:
            let target: Mode = item == .lyrics ? .lyrics : .queue
            Button { withAnimation(.smooth(duration: 0.45)) { mode = mode == target ? .artwork : target } } label: {
                bubble(item.icon, on: mode == target)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: mode)
        case .sleep:
            Menu { SleepTimerMenuItems() } label: { bubble("moon.zzz", on: player.sleepActive) }
        case .airplay:
            AirPlayButton()
                .frame(width: 24, height: 24)
                .frame(width: Self.barHeight, height: Self.barHeight)
                .glassEffect(.regular.interactive(), in: .circle)
        case .equalizer:
            Button { showEQ = true } label: { bubble("slider.vertical.3", on: eq.enabled && !eq.isFlat) }
                .buttonStyle(.plain)
        case .favorite:
            if let track = player.current {
                Button { library.toggleFavorite(track) } label: {
                    Image(systemName: track.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(track.isFavorite ? .yellow : .white)
                        .frame(width: Self.barHeight, height: Self.barHeight)
                        .contentTransition(.symbolEffect(.replace))
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: track.isFavorite)
            }
        case .share:
            if let track = player.current {
                if let song = SharedSong(track) {
                    ShareLink(item: song, preview: SharePreview(track.title)) { bubble("square.and.arrow.up", on: false) }.buttonStyle(.plain)
                } else {
                    ShareLink(item: ShareItem.text(for: track), subject: Text(track.title)) { bubble("square.and.arrow.up", on: false) }.buttonStyle(.plain)
                }
            }
        case .more:
            if let track = player.current { moreMenu(track, size: Self.barHeight) }
        }
    }

    private static let barHeight: CGFloat = 48

    private func bubble(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(on ? .black : .white)
            .frame(width: Self.barHeight, height: Self.barHeight)
            .glassEffect(on ? .regular.tint(.white.opacity(0.92)).interactive() : .regular.interactive(), in: .circle)
            .animation(.smooth(duration: 0.3), value: on)
    }
}

/// Artwork · Lyrics · Queue: the system segmented control, so the selection is the real Liquid Glass lens
/// you can tap or slide. Its size is fixed — it sits centred in the bar's height and never resizes while sliding.
private struct PlayerModeSwitch: View {
    @Binding var mode: NowPlayingView.Mode
    let height: CGFloat

    private static let modes: [(mode: NowPlayingView.Mode, symbol: String, title: String)] = [
        (.artwork, "music.note", "Artwork"), (.lyrics, "quote.bubble", "Lyrics"), (.queue, "list.bullet", "Queue")
    ]

    var body: some View {
        Picker("View", selection: Binding(get: { mode }, set: { m in withAnimation(.smooth(duration: 0.45)) { mode = m } })) {
            ForEach(Self.modes, id: \.mode) { m in
                Image(systemName: m.symbol).accessibilityLabel(m.title).tag(m.mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .sensoryFeedback(.selection, trigger: mode)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

// MARK: - Scrubber

struct ScrubberSection: View {
    @Environment(PlayerModel.self) private var player
    @Environment(EQModel.self) private var eq
    var showEQ: () -> Void
    var showPreset = true
    var showTimes = true

    @State private var dragging = false
    @State private var dragValue = 0.0

    var body: some View {
        let shown = dragging ? dragValue : player.position
        let progress = player.duration > 0 ? min(1, max(0, shown / player.duration)) : 0
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: max(0, geo.size.width * progress))
                }
                .frame(height: dragging ? 12 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            dragValue = min(1, max(0, g.location.x / geo.size.width)) * player.duration
                        }
                        .onEnded { _ in
                            player.seek(to: dragValue)
                            dragging = false
                        }
                )
                .animation(.spring(duration: 0.3, bounce: 0.3), value: dragging)
            }
            .frame(height: 22)

            if showTimes || (showPreset && eq.enabled && !eq.isFlat) {
            HStack {
                Text(formatTime(shown)).contentTransition(.numericText()).opacity(showTimes ? 1 : 0)
                Spacer()
                if showPreset && eq.enabled && !eq.isFlat {
                    Button(action: showEQ) {
                        Label(eq.activeName, systemImage: "slider.vertical.3")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                Spacer()
                Text(formatTime(player.duration)).opacity(showTimes ? 1 : 0)
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
            .animation(.smooth, value: eq.activeName)
            }
        }
    }
}

// MARK: - Sleep timer

struct SleepTimerMenuItems: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if player.sleepActive {
            Button(role: .destructive) { player.setSleepTimer(minutes: nil) } label: {
                Label("Turn Off Timer", systemImage: "xmark")
            }
            Divider()
        }
        ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { m in
            Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
        }
        Button("End of Track") { player.setSleepAtTrackEnd() }
        Button(player.queueTitle.isEmpty ? "End of Queue" : "End of “\(player.queueTitle)”") { player.setSleepAtQueueEnd() }
    }
}

// MARK: - Lyrics

struct LyricsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LyricsService.self) private var service
    @Environment(AppSettings.self) private var settings
    let track: Track
    var edit: () -> Void
    var expand: (() -> Void)? = nil
    var fullScreen = false
    // Parsed up front, so the first frame already shows lyrics instead of flashing "No Lyrics" / the visualizer.
    @State private var lines: [LyricLine]
    @State private var parsedKey: String
    /// Audio-route latency, read once: asking AVAudioSession on every frame for every line is what made the tab switch stutter.
    @State private var latency = PlayerModel.currentOutputLatency()
    @State private var translations: [Int: String] = [:]
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var adjusting = false
    /// The line being sung, as last reported by `LyricsCursor` for the lyrics in `cursorKey`.
    @State private var cursor: Int?
    @State private var cursorKey: String?
    /// The lyrics are being scrolled by hand.
    @State private var browsing = false
    @State private var browseReturn: Task<Void, Never>?
    /// Remembered: songs without lyrics open straight into the visualizer.
    @AppStorage("lyricsVisualizer") private var visualizer = false
    /// Karaoke: the line being sung is bigger and fills in word by word.
    @State private var singStart: CGFloat?
    @State private var singOpen = false
    @State private var translating = false
    @State private var translateNote: String?
    private var karaoke: Bool { player.lab.vocalCut > 0.02 }
    @Namespace private var glass

    init(track: Track, edit: @escaping () -> Void, expand: (() -> Void)? = nil, fullScreen: Bool = false) {
        self.track = track
        self.edit = edit
        self.expand = expand
        self.fullScreen = fullScreen
        _lines = State(initialValue: LyricsParser.parse(track.lyrics ?? ""))
        _parsedKey = State(initialValue: "\(track.id)\(track.lyrics ?? "")")
    }

    private var theme: AppTheme { ThemeStore.shared.current }
    private var timed: Bool { lines.first?.time != nil }
    private var shift: Double { (track.lyricsOffset ?? 0) - latency }
    private func smoothNow(at date: Date) -> Double { player.smoothPosition(at: date) + shift }
    /// Only `LyricsCursor` follows the 50 ms position tick, so the lines re-render when the sung line changes,
    /// not 20 times a second. Its first report arrives after the first frame, which reads the position directly.
    private var currentIndex: Int? {
        if cursorKey == parsedKey { return cursor }
        return LyricsCursor.index(in: lines, at: player.positionSnapshot + shift)
    }
    private var fontSize: CGFloat { CGFloat(theme.lyricsSize) * (fullScreen ? 1.2 : 1) }

    var body: some View {
        let current = currentIndex
        return Group {
            if lines.isEmpty {
                VStack(spacing: 12) {
                    switch service.state(track.id) {
                    case .running(let phase):
                        ProgressView().controlSize(.large).tint(.white)
                        Text(phase).font(.system(size: 20, weight: .bold)).contentTransition(.opacity)
                        Text("Language first, then lyrics. All on this device.")
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                    default:
                        if visualizer {
                            LiquidVisualizer(track: track, tint: ArtworkCache.tint(for: track).mix(with: .white, by: 0.25))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                // Full screen is just for watching: the player's own controls are enough there.
                                .overlay(alignment: .bottom) { if !fullScreen { noLyricsActions(compact: true).padding(.bottom, 8) } }
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        } else {
                            Spacer(minLength: 0)
                            Image(systemName: "quote.bubble").font(.system(size: 34))
                            Text("No Lyrics").font(.system(size: 22, weight: .bold))
                            Group {
                                if case .failed(let message) = service.state(track.id) {
                                    Text(message)
                                } else if service.state(track.id) == .notFound || track.lyricsChecked == true {
                                    Text("Nothing recognisable was sung or spoken.")
                                } else {
                                    Text("Let \(Brand.name) listen and write them, add your own, or watch the music instead.")
                                }
                            }
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.65))
                            noLyricsActions(compact: false).padding(.top, 10)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(duration: 0.5, bounce: 0.2), value: visualizer)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: theme.lyricsCentered ? .center : .leading, spacing: 24) {
                            ForEach(lines) { line in lineView(line, current: current) }
                        }
                        .multilineTextAlignment(theme.lyricsCentered ? .center : .leading)
                        .padding(.top, 50)
                        .padding(.bottom, 160)
                        .frame(maxWidth: .infinity, alignment: theme.lyricsCentered ? .center : .leading)
                    }
                    // Fixed-height fades: lines melt away under the buttons and above the scrubber instead of
                    // being cut off by the scroll view's edge.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 56)
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 48)
                        }
                    }
                    .background {
                        LyricsCursor(lines: lines, key: parsedKey, shift: shift) { idx, key in
                            cursor = idx
                            cursorKey = key
                        }
                    }
                    .onChange(of: current) { _, idx in
                        guard let idx, !browsing else { return }
                        withAnimation(.smooth(duration: 0.7)) { proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.25)) }
                    }
                    // Scrolling by hand: every line sharp, no pulling back mid-read. A moment after you let go
                    // it returns to the line being sung.
                    .onScrollPhaseChange { _, phase in
                        // Only a finger counts: following the song scrolls too (as `.animating`).
                        if phase == .interacting {
                            browseReturn?.cancel()
                            if !browsing { withAnimation(.smooth(duration: 0.3)) { browsing = true } }
                        } else if phase == .idle, browsing {
                            browseReturn?.cancel()
                            browseReturn = Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2.5))
                                guard !Task.isCancelled else { return }
                                withAnimation(.smooth(duration: 0.7)) {
                                    browsing = false
                                    if let idx = currentIndex { proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.25)) }
                                }
                            }
                        }
                    }
                    .onDisappear { browseReturn?.cancel() }
                }
                .overlay(alignment: .bottom) { bottomBar }
            }
        }
        .task(id: "\(track.id)\(track.lyrics ?? "")") {
            latency = PlayerModel.currentOutputLatency()
            let key = "\(track.id)\(track.lyrics ?? "")"
            if key != parsedKey { lines = LyricsParser.parse(track.lyrics ?? ""); parsedKey = key }
            translations = [:]
            if settings.translateLyrics { requestTranslation() }
        }
        .translationTask(translationConfig) { session in
            let requests = lines.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: "\($0.id)") }
            nonisolated(unsafe) let batch = requests
            nonisolated(unsafe) let translator = session
            guard !batch.isEmpty, let responses = try? await translator.translations(from: batch) else { return }
            var map: [Int: String] = [:]
            for r in responses {
                if let id = r.clientIdentifier.flatMap(Int.init), r.targetText.caseInsensitiveCompare(r.sourceText) != .orderedSame { map[id] = r.targetText }
            }
            withAnimation(.smooth) {
                translations = map
                translating = false
                translateNote = map.isEmpty ? "Nothing to translate" : nil
            }
        }
        .sheet(isPresented: $adjusting) { LyricsTimingSheet(track: track) }
        .onChange(of: settings.translationTarget) { _, _ in
            if settings.translateLyrics { requestTranslation() }
        }
    }

    /// Apple Music's lyrics footer: Translate on the left, Sing (karaoke) on the right, a status in between.
    private var bottomBar: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack {
                roundButton("translate", on: settings.translateLyrics) {
                    settings.translateLyrics.toggle()
                    if settings.translateLyrics { requestTranslation() } else { translating = false; translateNote = nil }
                }
                .accessibilityLabel("Translate")
                Spacer()
                if settings.translateLyrics, translating {
                    Text("Translating…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.55))
                } else if settings.translateLyrics, let note = translateNote {
                    Text(note).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.55))
                } else if karaoke {
                    KaraokeStatusLabel(trackID: track.id)
                }
                Spacer()
                if singOpen {
                    Color.clear.frame(width: 44, height: 44)
                } else {
                    Button {
                        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { singOpen = true }
                    } label: {
                        singIcon(color: karaoke ? Color(white: 0.25) : Color.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.white.opacity(karaoke ? 0.9 : 0.22)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sing")
                }
            }
            if singOpen {
                singPill
                    .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func singIcon(color: Color) -> some View {
        ZStack {
            Image(systemName: "music.mic").font(.system(size: 18, weight: .semibold))
            Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).offset(x: -11, y: -9)
            Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).offset(x: 10, y: 9)
        }
        .foregroundStyle(color)
    }

    /// Slide up: less voice (all the way is no vocals). Slide down to the bottom: vocals back. Tap the mic to close.
    private var singPill: some View {
        let height: CGFloat = 176
        let base: CGFloat = 52
        let cut: CGFloat = CGFloat(player.lab.vocalCut)
        return ZStack(alignment: .bottom) {
            Color.white.opacity(0.3)
            Color.white.frame(height: base + (height - base) * cut)
            Button {
                withAnimation(.spring(duration: 0.4, bounce: 0.2)) { singOpen = false }
            } label: {
                singIcon(color: Color(white: 0.28)).frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 52, height: height)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .gesture(
            // Moves relative to where the finger first touched, so the level never jumps under it.
            DragGesture(minimumDistance: 3)
                .onChanged { g in
                    if singStart == nil { singStart = cut }
                    let v: CGFloat = (singStart ?? cut) - g.translation.height / (height - base)
                    player.lab.vocalCut = Float(min(1, max(0, v)))
                }
                .onEnded { _ in singStart = nil }
        )
        .sensoryFeedback(.selection, trigger: Int(cut * 10))
        .accessibilityLabel("Vocals")
        .accessibilityValue("\(Int(cut * 100)) percent removed")
    }

    private func roundButton(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? Color.black.opacity(0.85) : Color.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(on ? 0.9 : 0.22)))
                .animation(.smooth(duration: 0.25), value: on)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }

    /// The four ways out of "no lyrics", as one Liquid Glass group; in the visualizer they shrink to a single row.
    @ViewBuilder private func noLyricsActions(compact: Bool) -> some View {
        let playable = MediaLocator.isPlayableNow(track)
        GlassEffectContainer(spacing: 10) {
            if compact {
                HStack(spacing: 8) {
                    Button { visualizer = false } label: { Label("Lyrics", systemImage: "quote.bubble") }
                        .buttonStyle(.glass)
                        .glassEffectID("lyrics", in: glass)
                    Button { service.detect(track) } label: { Image(systemName: "sparkles") }
                        .buttonStyle(.glass)
                        .glassEffectID("detect", in: glass)
                        .disabled(!playable)
                        .accessibilityLabel("Detect with AI")
                    Button(action: edit) { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.glass)
                        .glassEffectID("add", in: glass)
                        .accessibilityLabel("Add Lyrics")
                }
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button { service.detect(track) } label: { Label("Detect with AI", systemImage: "sparkles").frame(maxWidth: .infinity) }
                            .buttonStyle(.glassProminent)
                            .glassEffectID("detect", in: glass)
                            .disabled(!playable)
                        Button { visualizer = true } label: { Label("Visualizer", systemImage: "waveform") .frame(maxWidth: .infinity) }
                            .buttonStyle(.glass)
                            .glassEffectID("lyrics", in: glass)
                    }
                    HStack(spacing: 10) {
                        Button(action: edit) { Label("Add Lyrics", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                            .buttonStyle(.glass)
                            .glassEffectID("add", in: glass)
                        Button { service.findAnywhere(track) } label: { Label("Search Online", systemImage: "globe").frame(maxWidth: .infinity) }
                            .buttonStyle(.glass)
                            .glassEffectID("search", in: glass)
                    }
                }
                .frame(maxWidth: 340)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .controlSize(.large)
    }

    @ViewBuilder private func lineView(_ line: LyricLine, current: Int?) -> some View {
        let active = current == line.id
        let distance = current.map { abs($0 - line.id) } ?? 0
        let wordMode = (settings.wordLyrics || karaoke) && timed && active
        let lineSize: CGFloat = fontSize
        VStack(alignment: theme.lyricsCentered ? .center : .leading, spacing: 6) {
            if wordMode {
                let end = lines.first(where: { $0.id == line.id + 1 })?.time
                let words = LyricsParser.wordTimings(for: line, end: end)
                // Redrawn every frame from the interpolated clock, so the fill glides instead of stepping with the 50 ms tick.
                TimelineView(.animation(minimumInterval: 1 / 60, paused: !player.isPlaying)) { ctx in
                    WordLine(words: words, end: end, now: smoothNow(at: ctx.date), size: lineSize, centered: theme.lyricsCentered)
                }
            } else {
                Text(line.text)
                    .font(.system(size: lineSize, weight: .bold))
                    .foregroundStyle(.white.opacity(!timed ? 0.85 : active ? 1 : browsing ? 0.5 : (karaoke ? 0.22 : 0.32)))
            }
            if settings.translateLyrics, let tr = translations[line.id] {
                Text(tr)
                    .font(.system(size: fontSize * 0.55, weight: .semibold))
                    .foregroundStyle(.white.opacity(active || !timed ? 0.7 : 0.25))
                    .transition(.opacity)
            }
        }
        .shadow(color: theme.lyricsGlow && active ? .white.opacity(0.55) : .clear, radius: 12)
        .blur(radius: timed && !active && !browsing ? min(3, Double(distance) * 0.7) : 0)
        .scaleEffect(timed && !active ? 0.95 : 1, anchor: theme.lyricsCentered ? .center : .leading)
        .animation(.smooth(duration: 0.5), value: active)
        .id(line.id)
        .contentShape(Rectangle())
        .onTapGesture { if let t = line.time { player.seek(to: max(0, t - (track.lyricsOffset ?? 0))) } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if timed {
                chip(settings.wordLyrics ? "text.word.spacing" : "text.alignleft", on: settings.wordLyrics) { settings.wordLyrics.toggle() }
                    .accessibilityLabel(settings.wordLyrics ? "Line by Line" : "Word by Word")
            }
            chip("translate", on: settings.translateLyrics) {
                settings.translateLyrics.toggle()
                if settings.translateLyrics { requestTranslation() }
            }
            .accessibilityLabel("Translate")
            Menu {
                Button { adjusting = true } label: { Label("Adjust Timing…", systemImage: "clock.arrow.2.circlepath") }
                Button(action: edit) { Label("Edit Lyrics", systemImage: "pencil") }
                Button { service.findAnywhere(track) } label: { Label("Find Other Lyrics", systemImage: "globe") }
                Picker("Translate To", selection: Binding(get: { settings.translationTarget }, set: { settings.translationTarget = $0; requestTranslation() })) {
                    ForEach(LyricsLanguages.targets, id: \.0) { Text($0.1).tag($0.0) }
                }
            } label: { chipLabel("ellipsis", on: false) }
            if let expand {
                chip("arrow.up.left.and.arrow.down.right", on: false, action: expand).accessibilityLabel("Full Screen Lyrics")
            }
        }
        .padding(.top, 2)
    }

    private func requestTranslation() {
        translating = true
        translateNote = nil
        let target = Locale.Language(identifier: settings.translationTarget)
        if translationConfig?.target == target { translationConfig?.invalidate() }
        else { translationConfig = TranslationSession.Configuration(source: nil, target: target) }
    }

    private func chip(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(symbol, on: on) }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: on)
    }

    private func chipLabel(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(on ? .black : .white)
            .frame(width: 34, height: 34)
            .glassEffect(on ? .regular.tint(.white.opacity(0.9)).interactive() : .regular.interactive(), in: .circle)
    }
}

nonisolated enum LyricsLanguages {
    static let targets: [(String, String)] = [
        ("en", "English"), ("de", "Deutsch"), ("es", "Español"), ("fr", "Français"), ("it", "Italiano"), ("pt", "Português"),
        ("nl", "Nederlands"), ("pl", "Polski"), ("tr", "Türkçe"), ("ru", "Русский"), ("uk", "Українська"), ("ja", "日本語"),
        ("ko", "한국어"), ("zh", "中文"), ("ar", "العربية"), ("hi", "हिन्दी")
    ]
}

/// Follows the playback position on its own (it re-renders on every tick, but is empty) and reports
/// only when the line being sung changes.
private struct LyricsCursor: View {
    @Environment(PlayerModel.self) private var player
    let lines: [LyricLine]
    /// Identifies `lines`, so new lyrics are reported even when the line number stays the same.
    let key: String
    let shift: Double
    var report: (Int?, String) -> Void

    private struct Mark: Equatable { let index: Int?; let key: String }

    static func index(in lines: [LyricLine], at now: Double) -> Int? {
        guard lines.first?.time != nil else { return nil }
        return lines.lastIndex { ($0.time ?? .infinity) <= now + 0.25 }
    }

    var body: some View {
        let mark = Mark(index: Self.index(in: lines, at: player.position + shift), key: key)
        Color.clear
            .onChange(of: mark, initial: true) { _, m in report(m.index, m.key) }
    }
}

/// Karaoke-style line: every word fills in while it is sung.
struct WordLine: View {
    let words: [LyricWord]
    let end: Double?
    let now: Double
    let size: CGFloat
    let centered: Bool

    var body: some View {
        FlowLayout(spacing: size * 0.26, lineSpacing: size * 0.12, centered: centered) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                let next = i + 1 < words.count ? words[i + 1].time : (end ?? w.time + 0.6)
                let fill = max(0, min(1, (now - w.time) / max(0.08, next - w.time)))
                Text(w.text)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.white.opacity(0.32))
                    .overlay {
                        Text(w.text)
                            .font(.system(size: size, weight: .bold))
                            .foregroundStyle(.white)
                            .mask(alignment: .leading) {
                                GeometryReader { g in Rectangle().frame(width: g.size.width * fill) }
                            }
                    }
                    .scaleEffect(fill > 0 && fill < 1 ? 1.04 : 1, anchor: .bottom)
                    .animation(.smooth(duration: 0.2), value: fill > 0 && fill < 1)
            }
        }
    }
}

/// Simple wrapping layout for words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let h = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = centered ? bounds.minX + (bounds.width - row.width) / 2 : bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let extra = row.items.isEmpty ? s.width : row.width + spacing + s.width
            if extra > width, !row.items.isEmpty { rows.append(row); row = Row() }
            row.width = row.items.isEmpty ? s.width : row.width + spacing + s.width
            row.height = max(row.height, s.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Shift all timestamps, or re-time the song by tapping along.
struct LyricsTimingSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var offset = 0.0
    @State private var syncing = false
    @State private var confirmRemove = false

    private var isTimed: Bool { LyricsParser.parse(library.trackByID[track.id]?.lyrics ?? track.lyrics ?? "").first?.time != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Text(String(format: "%+.1f s", offset)).font(.system(size: 34, weight: .bold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(offset == 0 ? "In sync" : offset > 0 ? "Lyrics appear earlier" : "Lyrics appear later")
                            .font(.footnote).foregroundStyle(.secondary)
                        Slider(value: $offset, in: -5...5, step: 0.1)
                        HStack {
                            ForEach([-0.5, -0.1, 0.1, 0.5], id: \.self) { d in
                                Button(String(format: "%+.1f", d)) { offset = max(-5, min(5, (offset + d) * 10).rounded() / 10) }
                                    .buttonStyle(.bordered)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } footer: { Text("Changes apply live while the song plays. Saved for this song only.") }

                Section {
                    Button { syncing = true } label: { Label("Sync by Tapping…", systemImage: "hand.tap") }
                    Button(role: .destructive) { offset = 0 } label: { Label("Reset Offset", systemImage: "arrow.counterclockwise") }
                        .disabled(offset == 0)
                    if isTimed {
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Remove Timing", systemImage: "text.alignleft") }
                    }
                } footer: {
                    Text("Tap along with the song to set the start of every line — also turns plain lyrics into synced lyrics. Remove Timing turns them back into plain lyrics.")
                }
            }
            .navigationTitle("Lyrics Timing")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { offset = track.lyricsOffset ?? 0 }
            .onChange(of: offset) { _, v in library.update(track.id) { $0.lyricsOffset = v == 0 ? nil : v } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $syncing) { LyricsSyncEditor(track: library.trackByID[track.id] ?? track) }
            .confirmationDialog("Remove the timing from these lyrics?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove Timing", role: .destructive) {
                    let plain = LyricsParser.parse(library.trackByID[track.id]?.lyrics ?? track.lyrics ?? "").map(\.text).joined(separator: "\n")
                    offset = 0
                    library.update(track.id) { $0.lyrics = plain; $0.lyricsOffset = nil; $0.lyricsSource = "user" }
                }
            } message: { Text("The text stays; lines will no longer follow the song.") }
        }
        .presentationDetents([.medium, .large])
    }
}

struct LyricsSyncEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var lines: [LyricLine] = []
    /// Times tapped in this session; untapped lines keep their old time (shown faded).
    @State private var times: [Double?] = []
    @State private var next = 0
    @State private var latency = PlayerModel.currentOutputLatency()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Button { jump(to: i) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Group {
                                        if let t = times[i] { Text(formatTime(t)).foregroundStyle(Theme.accent) }
                                        else if let t = line.time { Text(formatTime(t)).foregroundStyle(.tertiary) }
                                        else { Text("–").foregroundStyle(.secondary) }
                                    }
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 44, alignment: .leading)
                                    Text(line.text).font(.system(size: 17, weight: i == next ? .bold : .regular))
                                        .foregroundStyle(i < next ? .secondary : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(i)
                            .listRowBackground(i == next ? Theme.accent.opacity(0.12) : Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: next) { _, n in withAnimation { proxy.scrollTo(max(0, n - 2), anchor: .top) } }
                }
                VStack(spacing: 12) {
                    PlaybackTimeLabel()
                    Text("Tap a line to sync again from there.").font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button { restart() } label: {
                            Image(systemName: "backward.end.fill").frame(width: 50, height: 50)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Start Over")
                        Button { undo() } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 50, height: 50)
                        }
                        .buttonStyle(.glass)
                        .disabled(next == 0)
                        .accessibilityLabel("Undo Last Tap")
                        Button { tap() } label: {
                            Label(next < lines.count ? "Tap: Line \(next + 1)" : "All Set", systemImage: "hand.tap.fill").frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(next >= lines.count)
                        .sensoryFeedback(.impact(weight: .medium), trigger: next)
                    }
                    .font(.system(size: 17, weight: .semibold))
                }
                .padding(16)
            }
            .navigationTitle("Sync by Tapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(times.allSatisfy { $0 == nil })
                }
            }
            .onAppear {
                lines = LyricsParser.parse(track.lyrics ?? "")
                times = Array(repeating: nil, count: lines.count)
                latency = PlayerModel.currentOutputLatency()
            }
            // Another song started: these taps no longer belong to anything.
            .onChange(of: player.current?.id) { _, id in if id != track.id { dismiss() } }
        }
    }

    private func tap() {
        guard next < lines.count else { return }
        // What you hear lags the engine by the output latency (Bluetooth especially).
        times[next] = max(0, player.position - latency)
        next += 1
    }

    private func undo() {
        guard next > 0 else { return }
        next -= 1
        times[next] = nil
    }

    private func restart() {
        player.seek(to: 0)
        if !player.isPlaying { player.resume() }
        next = 0
        times = times.map { _ in nil }
    }

    /// Re-sync from line `i`: forget the taps from there on and play from a little before it.
    private func jump(to i: Int) {
        for j in i..<times.count { times[j] = nil }
        next = i
        let before = (0..<i).reversed().lazy.compactMap { times[$0] ?? lines[$0].time }.first
        if let t = lines[i].time ?? before { player.seek(to: max(0, t - 3)) }
        if !player.isPlaying { player.resume() }
    }

    private func save() {
        // Every line needs a time in order, or the parser would drop it: an untapped line keeps its old time
        // when that still fits, otherwise it follows right after the line before.
        var previous = -0.01
        let fixed = lines.enumerated().map { i, l -> LyricLine in
            var t = times[i] ?? l.time ?? previous + 0.01
            if t <= previous { t = previous + 0.01 }
            previous = t
            return LyricLine(id: i, time: t, text: l.text)
        }
        library.update(track.id) { $0.lyrics = LyricsParser.lrc(fixed); $0.lyricsOffset = nil; $0.lyricsSource = "user" }
        dismiss()
    }
}

/// The playback time on its own, so the 50 ms tick redraws only this label.
private struct PlaybackTimeLabel: View {
    @Environment(PlayerModel.self) private var player
    var body: some View { Text(formatTime(player.position)).font(.title3.monospacedDigit().bold()) }
}

/// Lyrics filling the screen, with minimal controls.
struct FullScreenLyricsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    var body: some View {
        ZStack {
            if let t = player.current {
                // The blurred cover is an overlay so its "fill" size never widens the layout.
                Color.black
                    .overlay {
                        ArtworkView(track: t, radius: 0).scaledToFill().blur(radius: 60).opacity(0.7)
                            .id(t.id)
                            .transition(.opacity)
                    }
                    .overlay { LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom) }
                    .clipped()
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.8), value: t.id)
                VStack(spacing: 0) {
                    HStack {
                        ArtworkView(track: t, radius: 8).thumbnail().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.headline).lineLimit(1)
                            Text(t.artist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 15, weight: .semibold))
                                .frame(width: 42, height: 42).glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                    }
                    LyricsView(track: t, edit: { editing = true }, fullScreen: true)
                        .frame(maxHeight: .infinity)
                    HStack(spacing: 44) {
                        Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 26)) }
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30))
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 64, height: 64).glassEffect(.regular.interactive(), in: .circle)
                        }
                        Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 26)) }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 24)
                .foregroundStyle(.white)
                .sheet(isPresented: $editing) { LyricsEditor(track: t) }
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: player.current == nil) { _, gone in if gone { dismiss() } }
    }
}

struct LyricsEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(size: 16, design: .monospaced))
                .padding(.horizontal, 12)
                .navigationTitle("Lyrics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            library.update(track.id) { $0.lyrics = text.isEmpty ? nil : text; $0.lyricsSource = text.isEmpty ? nil : "user" }
                            dismiss()
                        }
                    }
                }
                .onAppear { text = track.lyrics ?? "" }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Queue

struct QueueView: View {
    /// Only the upcoming songs (no history, no current row, no header) — used under the Apple Music player's own header.
    var bare: Bool = false
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var showHistory = false
    private var compact: Bool { ThemeStore.shared.current.queueLayout == .compact }

    var body: some View {
        Group {
            if selecting {
                List(selection: $selection) { content }
            } else {
                List { content }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListHeaderHeight, 0)
        .listRowInsets(EdgeInsets())
        .environment(\.editMode, .constant(.active))
        .foregroundStyle(.white)
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Button("Cancel") { withAnimation { selecting = false; selection.removeAll() } }
                    Spacer()
                    Text(selection.isEmpty ? "Select Songs" : "\(selection.count) Selected").font(.footnote)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        player.removeItems(selection)
                        withAnimation { selection.removeAll(); selecting = false }
                    }
                    .disabled(selection.isEmpty)
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18).frame(height: 48)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !bare, !player.history.isEmpty {
            Section {
                if showHistory {
                    ForEach(Array(player.history.enumerated()), id: \.element.id) { offset, item in
                        if let t = library.trackByID[item.trackID] {
                            Button { player.jump(toQueueIndex: offset) } label: { row(t, playing: false).opacity(0.55) }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .deleteDisabled(true)
                                .moveDisabled(true)
                                .tag(item.id)
                        }
                    }
                }
            } header: {
                HStack {
                    Button { withAnimation(.smooth) { showHistory.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text("History").font(.system(size: 15, weight: .bold))
                            Text("\(player.history.count)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(showHistory ? 0 : -90))
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if showHistory {
                        Button("Clear") { player.clearHistory() }.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).buttonStyle(.plain)
                    }
                }
                .textCase(nil)
                .padding(.vertical, 4)
            }
        }
        if !bare, let cur = player.current {
            row(cur, playing: true).listRowBackground(Color.clear).listRowSeparator(.hidden).deleteDisabled(true).moveDisabled(true)
                .selectionDisabled()
        }
        Section {
            ForEach(Array(player.upcoming.enumerated()), id: \.element.id) { offset, item in
                if let t = library.trackByID[item.trackID] {
                    Button { player.jump(toQueueIndex: player.currentIndex + 1 + offset) } label: { row(t, playing: false) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .deleteDisabled(true)
                        .tag(item.id)
                        .contextMenu {
                            Button { player.playNext([t]) ; player.removeItems([item.id]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                            Button(role: .destructive) { player.removeUpcoming(at: IndexSet(integer: offset)) } label: {
                                Label("Remove from Queue", systemImage: "minus.circle")
                            }
                        }
                }
            }
            .onMove { player.moveUpcoming(from: $0, to: $1) }
        } header: {
            if !bare { HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Continue Playing").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    if !player.queueTitle.isEmpty {
                        Text("From \(player.queueTitle)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    toggle("shuffle", on: player.shuffle) { player.setShuffle(!player.shuffle) }
                    toggle(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) { player.cycleRepeat() }
                    toggle("infinity", on: player.settings.continuousPlayback) { player.settings.continuousPlayback.toggle() }
                    toggle("waveform.path", on: player.settings.crossfadeEnabled) { player.settings.crossfadeEnabled.toggle() }
                }
                Menu {
                    Button { player.undoQueueChange() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!player.canUndo)
                    Button { withAnimation { selecting = true } } label: { Label("Select Songs…", systemImage: "checkmark.circle") }
                    Button { player.library.createPlaylist(name: player.queueTitle.isEmpty ? "Queue" : player.queueTitle, trackIDs: player.queue.map(\.trackID)) } label: {
                        Label("Save Queue as Playlist", systemImage: "music.note.list")
                    }
                    Menu {
                        Picker("When the Queue Ends", selection: Binding(get: { player.settings.continuousPlayback ? player.settings.continuationMode : .stop },
                                                                        set: { m in player.settings.continuousPlayback = m != .stop; if m != .stop { player.settings.continuationMode = m } })) {
                            ForEach(ContinuationMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                    } label: { Label("When the Queue Ends", systemImage: "infinity") }
                    Divider()
                    Button(role: .destructive) { player.clearUpcoming() } label: { Label("Clear Queue", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32).background(Color.white.opacity(0.14), in: Circle())
                }
            }
            .textCase(nil)
            .padding(.vertical, 6) }
        }
    }

    private func toggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? .black : .white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(on ? Color.white.opacity(0.92) : Color.white.opacity(0.14), in: Circle())
                .animation(.smooth(duration: 0.25), value: on)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
    }

    private func row(_ t: Track, playing: Bool) -> some View {
        let side: CGFloat = compact ? 34 : 44
        return HStack(spacing: compact ? 10 : 12) {
            ArtworkView(track: t, radius: 7).thumbnail().frame(width: side, height: side)
                .overlay {
                    if playing {
                        Image(systemName: "waveform").foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(size: compact ? 14 : 15, weight: .medium)).lineLimit(1)
                if !compact || playing {
                    Text("\(t.artist) • \(formatTime(t.duration))").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer()
            if t.isRemote && !MediaLocator.isPlayableNow(t) {
                Image(systemName: "cloud").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .contentShape(Rectangle())
    }
}

struct BufferingBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("Loading from server…").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .transition(.opacity)
    }
}

/// A record that spins while music plays.
struct VinylArtwork: View {
    let track: Track
    let spinning: Bool
    /// Angle when the record last started turning, and when that was: pausing keeps the angle, so it never jumps.
    @State private var base = 0.0
    @State private var since = Date()

    /// 33⅓ rpm.
    private static let degreesPerSecond = 33.3 / 60 * 360

    var body: some View {
        // Only the rotation changes per frame, at the display's full rate: the record is drawn once
        // (flattened) and the shadow sits outside, since a round shadow looks the same at every angle.
        // 60 fps is smooth for a turning record; ProMotion's 120 would only double the work.
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !spinning)) { ctx in
            PlayerRecord(track: track)
                .equatable()
                .rotationEffect(.degrees(rotation(at: ctx.date)))
        }
        .aspectRatio(1, contentMode: .fit)
        .background { Circle().fill(Color(white: 0.06)).shadow(color: .black.opacity(0.5), radius: 24, y: 12) }
        .onChange(of: spinning) { _, on in
            if on { since = Date() } else { base = rotation(at: Date(), spinning: true) }
        }
    }

    private func rotation(at date: Date, spinning: Bool? = nil) -> Double {
        guard spinning ?? self.spinning else { return base }
        return (base + date.timeIntervalSince(since) * Self.degreesPerSecond).truncatingRemainder(dividingBy: 360)
    }
}

/// The record itself, redrawn only when the song (or its cover) changes.
private struct PlayerRecord: View, Equatable {
    let track: Track

    static func == (a: Self, b: Self) -> Bool {
        a.track.id == b.track.id && a.track.artVersion == b.track.artVersion && a.track.hasArtwork == b.track.hasArtwork
            && a.track.album == b.track.album && a.track.artist == b.track.artist
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            ForEach(0..<6) { i in Circle().stroke(Color.white.opacity(0.05), lineWidth: 1).padding(CGFloat(8 + i * 9)) }
            ArtworkView(tracks: [track], seed: track.album + track.artist, style: .circle).padding(58)
            Circle().fill(Color(white: 0.08)).frame(width: 14, height: 14)
        }
        .aspectRatio(1, contentMode: .fit)
        .drawingGroup()
    }
}
