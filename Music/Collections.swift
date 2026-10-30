import SwiftUI

// MARK: - Downloads / offline

struct DownloadsView: View {
    enum Scope: String, CaseIterable, Identifiable { case all = "On This iPhone", downloaded = "Downloaded", streaming = "Not Downloaded"; var id: String { rawValue } }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(SourceManager.self) private var sources
    @State private var scope: Scope = .all
    @State private var confirmRemove = false
    @State private var editMode: EditMode = .inactive
    @AppStorage("downloadSort") private var sortRaw = "Custom"
    private static let sorts: [String] = ["Title", "Artist", "Date Added"]

    private var tracks: [Track] {
        let scope = scope
        let sortRaw = sortRaw
        // Order changes invalidate these memoized lists; read it here for observation.
        _ = library.downloadOrder
        return library.memo("downloads|\(scope.rawValue)|\(sortRaw)") {
            let list: [Track]
            switch scope {
            case .all: list = library.tracks.filter(\.isOffline)
            case .downloaded: list = library.tracks.filter(\.isDownloaded)
            case .streaming: list = library.tracks.filter { $0.isRemote && !$0.isDownloaded }
            }
            switch sortRaw {
            case "Title": return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            case "Artist": return list.sorted { ($0.artist, $0.album, $0.trackNumber) < ($1.artist, $1.album, $1.trackNumber) }
            case "Date Added": return list.sorted { $0.addedAt > $1.addedAt }
            default: return library.orderedDownloads(SmartShuffle.libraryOrder(list))
            }
        }
    }

    var body: some View {
        let list = tracks
        let running = downloads.runningIDs.compactMap { library.trackByID[$0] }.filter { downloads.state($0.id) != nil }
        let queued = downloads.queue.compactMap { library.trackByID[$0] }
        let failed = library.orderedDownloads(SmartShuffle.libraryOrder(downloads.states.compactMap { id, state in
            state.isFailed ? library.trackByID[id] : nil
        }))
        let canReorder = list.count > 1 || queued.count > 1
        List {
            if sources.hasSources || !ModuleStore.shared.modules.isEmpty {
                Picker("Show", selection: $scope) { ForEach(Scope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
            }
            if !running.isEmpty {
                Section("Downloading") {
                    ForEach(running) { t in
                        DownloadRow(track: t, state: downloads.state(t.id))
                    }
                }
            }
            if !queued.isEmpty {
                Section {
                    ForEach(queued) { t in
                        DownloadRow(track: t, state: downloads.state(t.id))
                    }
                    .onMove { from, to in
                        var ids = queued.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        downloads.setQueueOrder(ids)
                    }
                    Button("Cancel Remaining", role: .destructive) { downloads.cancelAll() }
                } header: { Text("Waiting") } footer: {
                    Text("Downloads start from top to bottom. Tap Edit Order to move waiting songs.")
                }
            }
            if !failed.isEmpty {
                Section("Failed Downloads") {
                    ForEach(failed) { t in
                        DownloadRow(track: t, state: downloads.state(t.id))
                    }
                    Button("Retry Failed") { downloads.download(failed) }
                }
            }
            if !list.isEmpty {
                PlayShuffleBar(tracks: list, title: scope.rawValue)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                Section {
                    ForEach(list) { t in
                        TrackRow(track: t) { player.play(list, startAt: list.firstIndex(of: t) ?? 0, title: scope.rawValue) }
                    }
                    .onMove { from, to in
                        var ids = list.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        library.setDownloadOrder(ids)
                        sortRaw = "Custom"
                    }
                } footer: {
                    Text("\(songCount(list.count)) · \(ByteCountFormatter.string(fromByteCount: size(list), countStyle: .file))")
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if list.isEmpty && downloads.states.isEmpty {
                ContentUnavailableView(scope == .streaming ? "Everything Is Downloaded" : "No Downloads",
                                       systemImage: "arrow.down.circle",
                                       description: Text("Long-press an album, playlist or artist from your server and choose Download, or tap the arrow next to a song from an extension."))
            }
        }
        .toolbar {
            if canReorder || editMode.isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode.isEditing ? "Done" : "Edit Order") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortRaw) { ForEach(Self.sorts, id: \.self) { Text($0).tag($0) } }
                    Button {
                        sortRaw = "Custom"
                        withAnimation { editMode = .active }
                    } label: { Label("Custom Reordering", systemImage: "arrow.up.arrow.down") }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
            }
            if scope == .streaming, !list.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { downloads.download(list) } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("Download All")
                }
            }
            if scope == .downloaded, !list.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }.accessibilityLabel("Remove Downloads")
                }
            }
        }
        .confirmationDialog("Remove all downloaded songs from this iPhone? They stay in your library for streaming.", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Downloads", role: .destructive) { downloads.removeDownloads(list) }
        }
    }

    private func size(_ list: [Track]) -> Int64 {
        list.reduce(0) { sum, t in
            guard !t.path.isEmpty else { return sum }
            return sum + ((try? FileManager.default.attributesOfItem(atPath: Paths.url(for: t).path)[.size] as? Int64) ?? 0)
        }
    }
}

struct DownloadRow: View {
    let track: Track
    let state: DownloadManager.State?
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track).thumbnail().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                switch state {
                case .downloading(let p): ProgressView(value: p).tint(Theme.accent)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(1)
                default: Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Favorites

struct FavoritesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let songs = library.memo("favorites.songs") {
            library.tracks.filter(\.isFavorite).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let entries = (library.playlistEntries + library.albumEntries + library.artistEntries).filter { library.isFavorite($0) }
        List {
            if !entries.isEmpty {
                Section("Collections") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(entries) { e in
                                NavigationLink(value: e.route) {
                                    VStack(spacing: 6) {
                                        ArtworkView(entry: e, radius: 12).thumbnail(340).frame(width: 110, height: 110)
                                        Text(e.title).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(width: 110)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            if !songs.isEmpty {
                Section {
                    PlayShuffleBar(tracks: songs, title: "Favorites").listRowSeparator(.hidden)
                    ForEach(songs) { t in
                        TrackRow(track: t) { player.play(songs, startAt: songs.firstIndex(of: t) ?? 0, title: "Favorites") }
                    }
                } header: { Text("Songs") }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if songs.isEmpty && entries.isEmpty {
                ContentUnavailableView("No Favorites", systemImage: "star", description: Text("Star songs in the player, or long-press artists, albums and playlists."))
            }
        }
    }
}

// MARK: - Radio

struct RadioView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings

    private var topArtists: [LibraryEntry] {
        library.memo("radio.topArtists") {
            library.artistEntries.sorted { a, b in
                a.tracks.reduce(0) { $0 + ($1.playCount ?? 0) } > b.tracks.reduce(0) { $0 + ($1.playCount ?? 0) }
            }.prefix(12).map { $0 }
        }
    }

    private var genres: [(String, [Track])] {
        library.memo("radio.genres") {
            Dictionary(grouping: library.tracks.filter { $0.genre != nil }, by: { $0.genre! })
                .filter { $0.value.count >= 5 }
                .sorted { $0.value.count > $1.value.count }
                .prefix(12).map { ($0.key, $0.value) }
        }
    }

    @AppStorage("sec.radio.madeForYou") private var showMadeForYou = true
    @AppStorage("sec.radio.stationsForYou") private var showStationsForYou = true
    @AppStorage("sec.radio.moreStations") private var showMoreStations = true
    @Environment(MixService.self) private var mixService

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 14) {
                    header("Non-Stop Music", "Endless music, one genre at a time")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(NonStopStations.all, id: \.name) { st in
                                NavigationLink { NonStopStationView(name: st.name, query: st.query) } label: {
                                    StationTile(name: st.name, query: st.query).frame(width: 150)
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(ModuleStore.shared.categories.filter { c in !NonStopStations.all.contains { $0.name.lowercased() == c.name.lowercased() } }) { (cat: ModuleCategory) in
                                NavigationLink { CategoryTracksView(category: cat) } label: {
                                    CategoryTile(name: cat.name, image: cat.image, height: 110).frame(width: 150)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                if showMadeForYou {
                    VStack(alignment: .leading, spacing: 14) {
                        header("Made for You", "Stations and mixes built from your music")
                        VStack(spacing: 0) {
                            let fresh: [Track] = library.tracks.filter { ($0.playCount ?? 0) == 0 }
                            let stars: [Track] = library.tracks.filter(\.isFavorite)
                            stationRow("Your Station", "Everything you own, shuffled", "sparkles", library.tracks, shuffled: true)
                            stationRow("Favorites Radio", "Starred songs, shuffled", "star.fill", stars, shuffled: true)
                            if let t = player.current {
                                let like: [Track] = library.tracks.filter { $0.artist == t.artist || ($0.genre != nil && $0.genre == t.genre) }
                                stationRow("More Like This", t.title, "dot.radiowaves.left.and.right", like, shuffled: true, seed: t)
                            }
                            stationRow("Discovery", "Songs you've never played", "binoculars.fill", fresh.isEmpty ? library.tracks : fresh, shuffled: true)
                        }
                        .padding(.horizontal, 20)
                    }
                }

                if showStationsForYou, !topArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        header("Stations for You", "Endless music that starts with an artist you play")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(topArtists) { a in
                                    Button { if let seed = a.tracks.randomElement() { player.startStation(from: seed) } } label: {
                                        VStack(spacing: 8) {
                                            ArtworkView(entry: a).thumbnail(370).frame(width: 140, height: 140)
                                                .overlay(alignment: .bottomTrailing) {
                                                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 13, weight: .bold))
                                                        .foregroundStyle(.white).frame(width: 32, height: 32).glassEffect(.regular, in: .circle)
                                                        .padding(6)
                                                }
                                            Text(a.title).font(.system(size: 14, weight: .medium)).lineLimit(1).frame(width: 140)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }

                if showMoreStations {
                    let upbeat = library.tracks.filter { ($0.bpm ?? 0) >= 118 }
                    let calm = library.tracks.filter { ($0.bpm ?? 200) < 95 }
                    if upbeat.count >= 10 || calm.count >= 10 {
                        VStack(alignment: .leading, spacing: 14) {
                            header("More Stations", "By mood")
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                if upbeat.count >= 10 {
                                    station("Energy", "Fast songs, beat-matched", "bolt.fill", [.yellow, .red]) {
                                        player.play(upbeat.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }, title: "Energy")
                                    }
                                }
                                if calm.count >= 10 {
                                    station("Calm", "Slow and easy", "leaf.fill", [.green, .teal]) { player.play(calm, title: "Calm", shuffled: true) }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 20)
        }
        .navigationTitle("Radio")
        .task { await ModuleStore.shared.refreshDiscovery() }
    }

    /// A row that opens its own sub menu: Play, Shuffle and the songs the station is made of.
    private func stationRow(_ title: String, _ subtitle: String, _ icon: String, _ tracks: [Track], shuffled: Bool, seed: Track? = nil) -> some View {
        NavigationLink {
            StationListView(title: title, subtitle: subtitle, tracks: tracks, shuffled: shuffled, seed: seed)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 19, weight: .semibold))
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 62)
                Divider().padding(.leading, 48)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func station(_ title: String, _ subtitle: String, _ icon: String, _ colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 8)
                Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).opacity(0.8).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20 * ThemeStore.shared.current.cornerScale, style: .continuous))
        }
        .buttonStyle(PressScale())
        .sensoryFeedback(.impact(weight: .light), trigger: player.queueTitle)
    }
}

struct StationListView: View {
    @Environment(PlayerModel.self) private var player
    let title: String
    let subtitle: String
    let tracks: [Track]
    let shuffled: Bool
    var seed: Track? = nil

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Button {
                        if let seed { player.startStation(from: seed) } else { player.play(tracks, title: title, shuffled: shuffled) }
                    } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { player.play(tracks, title: title, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .listRowSeparator(.hidden)
            } footer: { Text(subtitle) }
            Section {
                ForEach(tracks.prefix(100)) { t in
                    TrackRow(track: t) { player.play(tracks, startAt: tracks.firstIndex(of: t) ?? 0, title: title) }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if tracks.isEmpty { ContentUnavailableView("No Songs", systemImage: "music.note") } }
    }
}

// MARK: - Recently played

struct RecentlyPlayedView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let played = library.memo("recentlyPlayed") { library.tracks.filter { $0.lastPlayed != nil }.sorted { $0.lastPlayed! > $1.lastPlayed! } }
        let groups = Dictionary(grouping: played.prefix(300)) { Calendar.current.startOfDay(for: $0.lastPlayed!) }
        List {
            ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                Section(dayTitle(day)) {
                    ForEach(groups[day]!) { t in
                        TrackRow(track: t) { player.play(played, startAt: played.firstIndex(of: t) ?? 0, title: "Recently Played") }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recently Played")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if played.isEmpty { ContentUnavailableView("Nothing Played Yet", systemImage: "clock") } }
    }

    private func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month())
    }
}

// MARK: - Queue as a tab

struct QueueTabView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        ZStack {
            LinearGradient(colors: [ArtworkCache.tint(for: player.current), .black], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            if player.current == nil {
                ContentUnavailableView("Queue Is Empty", systemImage: "list.bullet", description: Text("Play something to build a queue."))
            } else {
                QueueView().padding(.horizontal, 16)
            }
        }
        .environment(\.colorScheme, .dark)
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { player.undoQueueChange() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!player.canUndo)
            }
        }
    }
}

// MARK: - Track Mix

struct TrackMixView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerModel.self) private var player
    @Environment(AudioLab.self) private var lab
    @Environment(AnalysisService.self) private var analysis

    var body: some View {
        @Bindable var settings = settings
        @Bindable var lab = lab
        List {
            Section {
                Toggle(isOn: $settings.djMode.animation()) { Label("DJ Mode", systemImage: "dial.medium") }
            } footer: {
                Text("DJ Mode turns on everything for real mixes: longer blends that start at the outro, beat matching, bass swaps and matched volume.")
            }

            Section {
                Toggle(isOn: $settings.crossfadeEnabled.animation(.smooth)) { Label { Text("Crossfade") } icon: { AutomixIcon(color: .accentColor) } }
                if settings.effectiveCrossfade {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Transition Length"); Spacer(); Text("\(Int(settings.crossfadeSeconds)) s").foregroundStyle(.secondary).monospacedDigit() }
                        Slider(value: $settings.crossfadeSeconds, in: 1...20, step: 1)
                    }
                    Picker("Curve", selection: $settings.transitionStyle) { ForEach(TransitionStyle.allCases) { Text($0.title).tag($0) } }
                    Picker("Effect", selection: $settings.transitionEffect) { ForEach(TransitionEffect.allCases) { Text($0.title).tag($0) } }
                }
                Toggle(isOn: $settings.gapless) { Label("Gapless Playback", systemImage: "arrow.right.to.line") }
            } header: { Text("Transitions") } footer: {
                Text("Gapless joins songs without a pause when crossfade is off, sample-accurate — perfect for live albums and DJ sets.")
            }

            Section {
                Toggle(isOn: $settings.smartTransitions) { Label("Automatic Intro/Outro Detection", systemImage: "waveform.badge.magnifyingglass") }
                Toggle(isOn: $settings.beatMatch) { Label("Beat-Matched Transitions", systemImage: "metronome") }
                Toggle(isOn: $lab.normalize) { Label("Volume Matching", systemImage: "speaker.wave.2.bubble") }
                Toggle(isOn: $settings.skipSilence) { Label("Skip Silence", systemImage: "forward.end") }
            } header: { Text("Automatic") } footer: {
                Text("Transitions start when a song's outro begins, and the next song comes in on the beat with its tempo matched (within ±8 %).")
            }

            Section {
                Button { player.mixNow() } label: { Label("Mix Into Next Song Now", systemImage: "arrow.triangle.merge") }
                    .disabled(!player.isPlaying)
                if let t = player.current {
                    LabeledContent("Now Playing", value: t.title)
                    LabeledContent("Tempo", value: t.bpm.map { String(format: "%.0f BPM", $0) } ?? "Not measured")
                    LabeledContent("Loudness", value: t.loudness.map { String(format: "%.1f LUFS", $0) } ?? "Not measured")
                    if let o = t.outroStart, t.duration > 0 { LabeledContent("Outro Starts", value: formatTime(o)) }
                }
            } header: { Text("Manual") }

            Section {
                if analysis.running {
                    HStack {
                        ProgressView()
                        Text("Analyzing \(analysis.done + 1) of \(max(analysis.total, analysis.done + 1))…").foregroundStyle(.secondary)
                    }
                } else {
                    let pending = analysis.pendingCount
                    Button { analysis.analyzeLibrary() } label: { Label(pending == 0 ? "All Songs Analyzed" : "Analyze \(songCount(pending))", systemImage: "waveform") }
                        .disabled(pending == 0)
                }
            } header: { Text("Analysis") } footer: {
                Text("Tempo, beats, loudness and silence are measured on this iPhone. Streaming songs are measured once they're cached or downloaded.")
            }
        }
        .navigationTitle("Track Mix")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sources (Jellyfin, Subsonic)

struct SourcesView: View {
    @Environment(SourceManager.self) private var sources
    @State private var showAddMusic = false

    var body: some View {
        List {
            Section {
                Button { showAddMusic = true } label: {
                    HStack(spacing: 14) {
                        GradientIcon(symbol: "plus", colors: [Color(red: 0.1, green: 0.75, blue: 0.7), Color(red: 0.1, green: 0.55, blue: 0.9)], size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add Music").font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                            Text("Songs from this iPhone, Jellyfin, Subsonic or an extension.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !sources.accounts.isEmpty {
                Section {
                    ForEach(sources.accounts) { acc in
                        NavigationLink { ServerDetailView(accountID: acc.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 12) {
                                    GradientIcon(symbol: acc.kind.symbol, colors: [Color(red: 0.55, green: 0.3, blue: 0.95), Color(red: 0.1, green: 0.6, blue: 0.95)], size: 36)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(acc.name).font(.headline)
                                        Text("\(acc.userName) · \(URL(string: acc.baseURL)?.host() ?? acc.baseURL)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if sources.syncing.contains(acc.id) { ProgressView() }
                                }
                                HStack {
                                    Text("\(acc.trackCount) songs").font(.caption).foregroundStyle(.secondary)
                                    if let d = acc.lastSync { Text("· synced \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                                }
                                if let e = sources.lastError[acc.id] { Text(e).font(.caption).foregroundStyle(.red) }
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { sources.remove(acc.id) }
                            Button("Sync") { Task { await sources.sync(acc.id) } }.tint(.blue)
                        }
                    }
                } header: { Text("Servers") }
            }

            ModulesSection()
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddMusic) { AddMusicSheet() }
    }
}

/// A server's own page: sync, pause or remove it, plus the streaming and offline settings.
struct ServerDetailView: View {
    let accountID: String
    @Environment(SourceManager.self) private var sources
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let acc = sources.accounts.first(where: { $0.id == accountID }) {
            List {
                Section {
                    LabeledContent("Server", value: URL(string: acc.baseURL)?.host() ?? acc.baseURL)
                    LabeledContent("User", value: acc.userName)
                    LabeledContent("Songs", value: "\(acc.trackCount)")
                    Toggle("Enabled", isOn: Binding(get: { acc.enabled }, set: { sources.setEnabled(acc.id, $0) }))
                    Button { Task { await sources.sync(acc.id) } } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(sources.syncing.contains(acc.id))
                }
                StreamingOfflineSections()
                Section {
                    Button("Remove Server", role: .destructive) { sources.remove(acc.id); dismiss() }
                }
            }
            .navigationTitle(acc.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Server Removed", systemImage: "server.rack")
        }
    }
}

/// Streaming quality and offline settings, shown on the page of a server or extension.
struct StreamingOfflineSections: View {
    @Environment(SourceManager.self) private var sources
    @Environment(AppSettings.self) private var settings
    @State private var cacheSize: Int64 = 0
    @AppStorage("streamCacheMB") private var cacheMB = 1024

    var body: some View {
        @Bindable var sources = sources
        @Bindable var settings = settings
        Section("Streaming") {
            Picker("Wi-Fi Quality", selection: $sources.streamBitrate) { qualityOptions }
            Picker("Cellular Quality", selection: $sources.cellularBitrate) { qualityOptions }
            Picker("Download Quality", selection: $sources.downloadBitrate) { qualityOptions }
            Toggle("Sync on Launch", isOn: $sources.autoSync)
            Toggle("Skip Songs I Have Locally", isOn: $sources.skipLocalDuplicates)
        }
        Section {
            Toggle(isOn: $settings.offlineMode) { Label("Offline Mode", systemImage: "icloud.slash") }
            Picker("Stream Cache", selection: $cacheMB) {
                Text("256 MB").tag(256); Text("512 MB").tag(512); Text("1 GB").tag(1024); Text("2 GB").tag(2048); Text("5 GB").tag(5120)
            }
            LabeledContent("Cache in Use", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
            Button("Clear Stream Cache", role: .destructive) { StreamCache.clear(); cacheSize = 0 }
            if !sources.pending.isEmpty {
                LabeledContent("Waiting to Sync", value: "\(sources.pending.count) changes")
            }
        } header: { Text("Offline") } footer: {
            Text("Offline Mode only plays music on this iPhone. Favorites and plays made offline are sent to your server when you're back online.")
        }
        .task { cacheSize = await Task.detached { StreamCache.size }.value }
    }

    @ViewBuilder private var qualityOptions: some View {
        Text("Original").tag(0)
        Text("320 kbps").tag(320)
        Text("256 kbps").tag(256)
        Text("192 kbps").tag(192)
        Text("128 kbps").tag(128)
    }
}

struct ServerLoginView: View {
    let kind: SourceKind
    /// Pushed inside another flow (Add Music) instead of presented as its own sheet.
    var embedded = false
    @Environment(SourceManager.self) private var sources
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var user = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        if embedded { form } else { NavigationStack { form } }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Server Address", text: $server, prompt: Text(kind == .jellyfin ? "jellyfin.local:8096" : "navidrome.local:4533"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.URL)
                TextField("User Name", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.username)
                SecureField("Password", text: $password).textContentType(.password)
            } footer: {
                Text(kind == .jellyfin
                     ? "Your password is only used to sign in; \(Brand.name) keeps the access token in the Keychain."
                     : "Subsonic servers check the password on every request, so \(Brand.name) keeps it in the Keychain and sends a salted hash where the server supports it.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .toolbar {
            if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else {
                    Button("Sign In") {
                        working = true
                        error = nil
                        Task {
                            do {
                                switch kind {
                                case .jellyfin: try await sources.addJellyfin(server: server, user: user, password: password)
                                case .subsonic: try await sources.addSubsonic(server: server, user: user, password: password)
                                }
                                dismiss()
                            } catch let e {
                                error = e.localizedDescription
                            }
                            working = false
                        }
                    }
                    .disabled(server.isEmpty || user.isEmpty)
                }
            }
        }
    }
}

// MARK: - New

/// Apple Music's New tab, built from what the library and your servers really have: nothing here is made up.
struct NewMusicView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @AppStorage("sec.new.todaysHits") private var showHits = true
    @AppStorage("sec.new.newAlbums") private var showAlbums = true
    @AppStorage("sec.new.playlists") private var showPlaylists = true

    private func title(_ text: String, _ route: Route? = nil) -> some View {
        Group {
            if let route {
                NavigationLink(value: route) {
                    HStack(spacing: 5) {
                        Text(text).font(.system(size: 22, weight: .bold))
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(text).font(.system(size: 22, weight: .bold))
            }
        }
        .padding(.horizontal, 20)
    }

    var body: some View {
        let hits: [Track] = Array(library.mostPlayed.prefix(20))
        let charts: [ModuleTrack] = ModuleStore.shared.chartTracks
        let moduleHits: [ModuleTrack] = charts.isEmpty
            ? Array(library.newToYou(ModuleStore.shared.suggestions.flatMap(\.tracks)).prefix(20))
            : Array(charts.prefix(20))
        let albums: [LibraryEntry] = Array(library.albumsByRecent.prefix(12))
        let lists: [LibraryEntry] = Array(library.playlistEntries.prefix(12))
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if showHits, !moduleHits.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        title("Today's Hits")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(moduleHits) { (m: ModuleTrack) in
                                    Button {
                                        let start: Int = moduleHits.firstIndex(where: { $0.id == m.id }) ?? 0
                                        player.play(library.addModuleTracks(moduleHits), startAt: start, title: "Today's Hits")
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            AsyncImage(url: m.cover.flatMap(URL.init(string:))) { (img: Image) in
                                                img.resizable().scaledToFill()
                                            } placeholder: {
                                                GeneratedCover(spec: CoverKit.auto(m.album + m.artist))
                                            }
                                            .frame(width: 240, height: 240)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                            Text(m.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                            Text(m.artist).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(width: 240, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                } else if showHits, !hits.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        title("Today's Hits")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(hits) { t in
                                    Button { player.play(hits, startAt: hits.firstIndex(of: t) ?? 0, title: "Today's Hits") } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ArtworkView(track: t, radius: 12).thumbnail(400).frame(width: 150, height: 150)
                                            Text(t.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                            Text(t.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(width: 150, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                if showAlbums, !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        title("New Releases", .albums)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(albums) { album in
                                    NavigationLink(value: album.route) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ArtworkView(entry: album, radius: 12).frame(width: 150, height: 150)
                                            Text(album.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                            Text(album.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(width: 150, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                if showPlaylists, !lists.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        title("Playlists", .playlists)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(lists) { p in
                                    NavigationLink(value: p.route) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ArtworkView(entry: p, radius: 12).frame(width: 150, height: 150)
                                            Text(p.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        }
                                        .frame(width: 150, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 20)
        }
        .task(id: library.tracks.count / 10) {
            await ModuleStore.shared.refreshSuggestions(seeds: Array(library.mostPlayed.prefix(10)))
        }
        .task { await ModuleStore.shared.refreshDiscovery() }
        .navigationTitle("New")
        .overlay {
            if library.tracks.isEmpty && ModuleStore.shared.chartTracks.isEmpty {
                ContentUnavailableView("Nothing New Yet", systemImage: "square.grid.2x2", description: Text("Songs you add show up here."))
            }
        }
    }
}
