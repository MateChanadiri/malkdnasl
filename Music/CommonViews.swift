import SwiftUI
import AVKit

extension PlayerModel {
    func play(_ e: LibraryEntry, shuffled: Bool = false) { play(e.tracks, title: e.title, shuffled: shuffled, context: e.kind) }
}

// MARK: - Track row

struct TrackRow: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(DownloadManager.self) private var downloads

    let track: Track
    var showArtwork = true
    /// Replaces "Artist • 3:45" (e.g. on the artist page, where the artist is a given).
    var subtitle: String? = nil
    var onPlay: () -> Void

    @State private var showPicker = false
    @State private var confirmDelete = false
    @State private var showCover = false

    private var isCurrent: Bool { player.current?.id == track.id }

    @Environment(\.editMode) private var editMode
    private var editing: Bool { editMode?.wrappedValue.isEditing ?? false }

    var body: some View {
        // Looked up once per render: the ⋯ menu and the context menu are both built right away.
        let song = SharedSong(track)
        Group {
            if editing {
                rowContent
            } else {
                HStack(spacing: 4) {
                    Button(action: onPlay) { rowContent.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                    Menu { menu(song) } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .contextMenu { menu(song) }
        .sheet(isPresented: $showPicker) { PlaylistPicker(trackIDs: [track.id]) }
        .sheet(isPresented: $showCover) { CoverDesigner(track: track) }
        .confirmationDialog("Delete \"\(track.title)\" from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { library.delete([track.id]) }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if showArtwork { ArtworkView(track: track).thumbnail().frame(width: 52, height: 52) }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                Text(subtitle ?? "\(track.artist) • \(formatTime(track.duration))")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            }
            if track.isRemote {
                let phase = downloads.phase(track)
                if phase == .idle || phase == .done {
                    Image(systemName: track.origin.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(track.isDownloaded ? Theme.accent : Color.secondary)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel(track.origin.title)
                } else {
                    DownloadIndicator(phase: phase, size: 16)
                }
            }
        }
    }

    @ViewBuilder private func menu(_ song: SharedSong?) -> some View {
        Button { player.playNext([track]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.playAfter([track]) } label: { Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Divider()
        Button { player.startStation(from: track) } label: { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
        Button { library.toggleFavorite(track) } label: {
            Label(track.isFavorite ? "Unfavorite" : "Favorite", systemImage: track.isFavorite ? "star.slash" : "star")
        }
        Button { showPicker = true } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        Button { showCover = true } label: { Label("Design Cover…", systemImage: "paintpalette") }
        if track.isRemote {
            if track.isDownloaded {
                Button { downloads.removeDownloads([track]) } label: { Label("Remove Download", systemImage: "xmark.circle") }
            } else {
                Button { downloads.download([track]) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
        if let song {
            ShareLink(item: song, preview: SharePreview(track.title)) { Label("Share File…", systemImage: "square.and.arrow.up") }
        } else {
            ShareLink(item: ShareItem.text(for: track)) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        Divider()
        Button { router.open(.artist(track.artist)) } label: { Label("Go to Artist", systemImage: "music.mic") }
        Button { router.open(.album("\(track.artist)|\(track.album)")) } label: { Label("Go to Album", systemImage: "square.stack") }
        Divider()
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete from Library", systemImage: "trash") }
    }
}

// MARK: - Playlist picker

struct PlaylistPicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let trackIDs: [UUID]
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Button { creating = true } label: {
                    Label("New Playlist…", systemImage: "plus")
                        .font(.system(size: 17, weight: .medium))
                }
                ForEach(library.playlistEntries) { entry in
                    Button {
                        if let id = UUID(uuidString: entry.key) { library.add(trackIDs, to: id) }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(entry: entry, radius: 8).thumbnail().frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.system(size: 16, weight: .medium))
                                Text(entry.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $name)
                Button("Create") {
                    library.createPlaylist(name: name, trackIDs: trackIDs)
                    name = ""
                    dismiss()
                }
                Button("Cancel", role: .cancel) { name = "" }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Play / Shuffle

struct PlayShuffleBar: View {
    @Environment(PlayerModel.self) private var player
    let tracks: [Track]
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            button("Play", "play.fill") { player.play(tracks, title: title) }
            button("Shuffle", "shuffle") { player.play(tracks, title: title, shuffled: true) }
        }
    }

    private func button(_ text: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(Theme.accent)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
        .sensoryFeedback(.impact(weight: .light), trigger: player.currentIndex)
    }
}

// MARK: - Entry menu (pin / favourite / play)

struct EntryMenuItems: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    let entry: LibraryEntry

    var body: some View {
        let pinned = library.isPinned(entry)
        let fav = library.isFavorite(entry)
        ControlGroup {
            Button { library.togglePin(entry) } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
            }
            Button { library.toggleFavorite(entry) } label: {
                Label(fav ? "Unfavorite" : "Favorite", systemImage: fav ? "star.slash" : "star")
            }
        }
        Divider()
        Button { player.play(entry) } label: { Label("Play", systemImage: "play") }
        Button { player.play(entry, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
        Divider()
        Button { player.playNext(entry.tracks) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.playAfter(entry.tracks) } label: { Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward") }
        let remote = entry.tracks.filter(\.isRemote)
        if !remote.isEmpty {
            Divider()
            if remote.contains(where: { !$0.isDownloaded }) {
                Button { downloads.download(remote) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            if remote.contains(where: \.isDownloaded) {
                Button(role: .destructive) { downloads.removeDownloads(remote) } label: { Label("Remove Downloads", systemImage: "xmark.circle") }
            }
        }
        ShareLink(item: ShareItem.text(for: entry), subject: Text(entry.title)) { Label("Share…", systemImage: "square.and.arrow.up") }
        let files = entry.tracks.prefix(300).compactMap(SharedSong.init)
        if !files.isEmpty {
            ShareLink(items: files) { _ in SharePreview(entry.title) } label: { Label("Share Files…", systemImage: "square.and.arrow.up.on.square") }
        }
    }
}

// MARK: - Misc

/// Settings and list icons: one plain symbol in the primary colour (black in light mode, white in dark mode).
/// `colors` is kept so old call sites compile; it is ignored on purpose.
struct GradientIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.56, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
    }
}

struct EmptyLibraryCard: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Your library is empty")
                .font(.system(size: 19, weight: .semibold))
            Text("Bring in songs from this iPhone, a folder or your music server.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Music") { router.openAddMusic() }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .white
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = tint
        v.activeTintColor = tint
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { uiView.tintColor = tint }
}

struct ImportOverlay: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let s = library.importStatus {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 14, weight: .semibold))
                    if s.total > 0 { Text("\(s.done) of \(s.total)").font(.system(size: 12)).foregroundStyle(.secondary).contentTransition(.numericText()) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.smooth, value: s.done)
        }
    }
}

/// Always-available "add music" button for the floating bar; opens the Add Music sheet.
struct AddMusicMenu: View {
    @Environment(Router.self) private var router
    var size: CGFloat = 44

    var body: some View {
        Button { router.openAddMusic() } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Add Music")
    }
}

/// The single place to bring music in: first "where from?", then only the step that choice needs.
struct AddMusicSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SourceManager.self) private var sources
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var folderName = MusicFolder.name
    @State private var showMore = false
    @State private var addingExtension = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    choice("Files on This iPhone", "Songs from Files, iCloud Drive or a USB drive.", "iphone", .teal) {
                        router.startImport(.audioFiles)
                    }
                    if let folderName {
                        choice("Scan “\(folderName)”", "Picks up songs added to your music folder.", "folder.fill", .orange) {
                            dismiss()
                            Task { await library.scanChosenFolder() }
                        }
                    } else {
                        choice("A Music Folder", "Choose a folder once — \(Brand.name) keeps it in sync.", "folder.fill", .orange) {
                            router.startImport(.musicFolder)
                        }
                    }
                    choice("From Another App", "8SPINE, Documents, Downloads… pick its folder once and every song comes in.", "square.and.arrow.down.on.square.fill", .green) {
                        router.startImport(.otherApp)
                    }
                    ForEach([SourceKind.jellyfin, .subsonic]) { kind in
                        NavigationLink { ServerLoginView(kind: kind, embedded: true) } label: {
                            label(kind.title, serverDetail(kind), kind.symbol, kind == .jellyfin ? .purple : .indigo)
                        }
                    }
                    choice("A Server Extension", "Add an extension from a link, a repository or a file.", "puzzlepiece.extension.fill", .red) {
                        addingExtension = true
                    }
                    choice("A Song List", "Paste “Artist – Title” lines to build a playlist.", "list.bullet.rectangle", .pink) {
                        router.startSongListImport()
                    }
                } header: {
                    Text("Where’s your music?")
                }

                Section {
                    DisclosureGroup("More Ways", isExpanded: $showMore) {
                        if folderName != nil {
                            Button { router.startImport(.musicFolder) } label: { Label("Choose Different Folder…", systemImage: "folder") }
                            Button(role: .destructive) { MusicFolder.clear(); folderName = nil } label: { Label("Forget Music Folder", systemImage: "xmark.circle") }
                        }
                        Button { router.startImport(.playlistFolders) } label: { Label("Import Playlist Folders", systemImage: "music.note.list") }
                        Button { router.startImport(.artistFolders) } label: { Label("Import Artist Folders", systemImage: "music.mic") }
                        Button { dismiss(); Task { await library.scanMusicFolder() } } label: { Label("Scan \(Brand.name) Folder in Files", systemImage: "folder.badge.gearshape") }
                    }
                } footer: {
                    Text("From 8SPINE: Files → On My iPhone → 8SPINE (or Share a song → “Music”) works too. Folder imports turn each folder into a playlist or artist. You can also drop files into Files → On My iPhone → \(Brand.name) → \(Brand.name)Music.")
                }
            }
            .tint(.primary)
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: sources.accounts.count) { old, new in if new > old { dismiss() } }
            .navigationDestination(for: String.self) { _ in serverPicker }
            .sheet(isPresented: $addingExtension) { AddModuleSheet() }
            .onAppear {
                if router.addMusicAtServer { path = ["server"]; router.addMusicAtServer = false }
            }
        }
    }

    private var serverPicker: some View {
        List {
            Section {
                ForEach([SourceKind.jellyfin, .subsonic]) { kind in
                    NavigationLink { ServerLoginView(kind: kind, embedded: true) } label: {
                        label(kind.title, serverDetail(kind), kind.symbol, kind == .jellyfin ? .purple : .indigo)
                    }
                }
            } footer: {
                Text("Songs from your server join your library next to local files. Download them for offline listening any time.")
            }
        }
        .tint(.primary)
        .navigationTitle("Music Server")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func serverDetail(_ kind: SourceKind) -> String {
        switch kind {
        case .jellyfin: return "Sign in with your Jellyfin user."
        case .subsonic: return "Navidrome, Gonic, Airsonic, Ampache, Nextcloud Music …"
        }
    }

    private func choice(_ title: String, _ detail: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { label(title, detail, symbol, color) }
    }

    private func label(_ title: String, _ detail: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 14) {
            GradientIcon(symbol: symbol, colors: [color.opacity(0.8), color], size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Scrolling text

/// One line of text that scrolls sideways when it doesn't fit, like the song title in Apple Music: it rests,
/// glides to its end and comes round again. Text that fits stays still. With `centered`, short text is centred
/// on a row `centerShift` points wider to the right (the player's title has its buttons there) but never runs under them.
struct MarqueeText: View {
    let text: String
    var centered = false
    var centerShift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var moving = false

    private let gap: CGFloat = 40
    private let fade: CGFloat = 16
    private let speed: CGFloat = 32

    var body: some View {
        Text(text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity)
            .background {
                Text(text).lineLimit(1).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    if reduceMotion && textWidth > width + 0.5 {
                        Text(text).lineLimit(1).frame(width: width, alignment: centered ? .center : .leading)
                    } else if textWidth > width + 0.5 {
                        HStack(spacing: gap) { line; line }
                            .offset(x: offset)
                            .frame(width: width, height: geo.size.height, alignment: .leading)
                            .mask { edgeFade(width) }
                            .task(id: "\(text)|\(Int(width))") { await scroll(textWidth + gap) }
                    } else if centered {
                        let half = textWidth / 2
                        line.position(x: min(max(width / 2 + centerShift, half), width - half), y: geo.size.height / 2)
                    } else {
                        line.frame(width: width, height: geo.size.height, alignment: .leading)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(text)
    }

    private var line: some View { Text(text).lineLimit(1).fixedSize() }

    /// Soft edges while scrolling; the leading edge only fades once the text is on its way.
    private func edgeFade(_ width: CGFloat) -> some View {
        let f = min(fade / max(width, 1), 0.2)
        return LinearGradient(stops: [.init(color: moving ? .clear : .black, location: 0), .init(color: .black, location: f),
                                      .init(color: .black, location: 1 - f), .init(color: .clear, location: 1)],
                              startPoint: .leading, endPoint: .trailing)
    }

    private func scroll(_ distance: CGFloat) async {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { offset = 0; moving = false }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2.5))
            if Task.isCancelled { return }
            let duration = Double(distance / speed)
            withAnimation(.easeOut(duration: 0.25)) { moving = true }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            if Task.isCancelled { return }
            // The second copy now sits exactly where the first started, so jumping back is invisible.
            withTransaction(still) { offset = 0 }
            withAnimation(.easeOut(duration: 0.25)) { moving = false }
        }
    }
}

/// Reports scroll direction so the floating pills can collapse together with the tab bar.
struct TrackScroll: ViewModifier {
    @Environment(Router.self) private var router
    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { old, new in
            router.scrolled(from: old, to: new)
        }
    }
}
extension View { func trackScroll() -> some View { modifier(TrackScroll()) } }

// MARK: - Download state

/// One look for download state everywhere (search results, song rows, the player).
enum DownloadPhase: Equatable {
    case idle, waiting, progress(Double), done, failed

    /// Changes between these animate; progress ticks don't count as a change.
    var kind: Int {
        switch self { case .idle: 0; case .waiting, .progress: 1; case .done: 2; case .failed: 3 }
    }
    /// nil while waiting or while the server doesn't say how big the file is.
    var fraction: Double? { if case .progress(let p) = self, p > 0 { p } else { nil } }
}

extension DownloadManager {
    func phase(_ track: Track?) -> DownloadPhase {
        guard let track else { return .idle }
        if track.isDownloaded { return .done }
        switch state(track.id) {
        case .queued: return .waiting
        case .downloading(let p): return .progress(p)
        case .failed: return .failed
        case nil: return .idle
        }
    }
}

/// A thin ring: fills with known progress, otherwise a short arc spins smoothly.
struct DownloadRing: View {
    var fraction: Double?
    var lineWidth: CGFloat = 2
    var tint: Color = Theme.accent
    var track: Color = Theme.accent.opacity(0.18)

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            if let fraction {
                Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
            } else {
                TimelineView(.animation) { ctx in
                    let turn = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360 - 90))
                }
            }
        }
        .padding(lineWidth / 2)
    }
}

/// Arrow → ring → filled arrow, all the same size so rows never jump.
struct DownloadIndicator: View {
    let phase: DownloadPhase
    var size: CGFloat = 22
    var idleColor: Color = .secondary

    var body: some View {
        ZStack {
            switch phase {
            case .idle:
                Image(systemName: "arrow.down.circle").foregroundStyle(idleColor)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .waiting, .progress:
                DownloadRing(fraction: phase.fraction, lineWidth: max(1.5, size / 11))
                    .overlay {
                        // Stop square like the system's download buttons, only once progress is known.
                        if phase.fraction != nil {
                            RoundedRectangle(cornerRadius: size * 0.06).fill(Theme.accent).frame(width: size * 0.26, height: size * 0.26)
                        }
                    }
                    .padding(size * 0.06)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            case .done:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .font(.system(size: size))
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.4, bounce: 0.35), value: phase.kind)
        .sensoryFeedback(.success, trigger: phase.kind) { _, new in new == 2 }
        .accessibilityElement()
        .accessibilityLabel(phase.label)
    }
}

extension DownloadPhase {
    var label: String {
        switch self {
        case .idle: "Download"
        case .waiting: "Waiting to download"
        case .progress(let p): p > 0 ? "Downloading, \(Int(p * 100)) percent" : "Downloading"
        case .done: "Downloaded"
        case .failed: "Download failed. Try again"
        }
    }
}

// MARK: - Floating mini player

/// Room for the floating mini player at the bottom of every tab, so the last rows and bottom buttons
/// (Organize's "Apply") stay above it. Only the classic bar floats it over content; the system bottom
/// accessory already moves the safe area.
struct MiniPlayerClearance: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @Environment(LayoutStore.self) private var layout
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: layout.usesClassicBar && player.current != nil ? SearchLayer.size + 10 : 0)
        }
    }
}
extension View { func clearsMiniPlayer() -> some View { modifier(MiniPlayerClearance()) } }
