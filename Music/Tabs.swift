import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Studio

struct StudioView: View {
    @Environment(EQModel.self) private var eq
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var settings = settings
        @Bindable var player = player
        List {
            Section("Effects") {
                NavigationLink(value: Route.equalizer) {
                    HStack(spacing: 14) {
                        SettingIcon(symbol: "slider.vertical.3", size: 32)
                        Text("Equalizer")
                        Spacer()
                        Text(eq.activeName).foregroundStyle(.secondary)
                    }
                }
                NavigationLink(value: Route.trackMix) {
                    HStack(spacing: 14) {
                        SettingIcon(symbol: "point.topleft.down.to.point.bottomright.curvepath", size: 32)
                        Text("Track Mix & Crossfade")
                        Spacer()
                        Text(settings.djMode ? "DJ" : settings.crossfadeEnabled ? "\(Int(settings.crossfadeSeconds)) s" : "Off").foregroundStyle(.secondary)
                    }
                }
                NavigationLink(value: Route.queueRules) {
                    HStack(spacing: 14) {
                        SettingIcon(symbol: "wand.and.rays", size: 32)
                        Text("Queue Presets")
                    }
                }
            }

            AudioLabSections(part: .sound)

            Section {
                Toggle(isOn: $settings.continuousPlayback) { Label("Continuous Playback", systemImage: "infinity") }
                if settings.continuousPlayback {
                    Picker(selection: $settings.continuationMode) {
                        ForEach(ContinuationMode.allCases.filter { $0 != .stop }) { mode in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(mode.title, systemImage: mode.symbol)
                                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(mode)
                        }
                    } label: { Label("When the Queue Ends", systemImage: "arrow.turn.down.right") }
                    .pickerStyle(.navigationLink)
                    if settings.continuationMode == .continuePlaylist {
                        Picker("Playlist", selection: $settings.continuationPlaylist) {
                            Text("Choose…").tag("")
                            ForEach(player.library.playlists) { Text($0.name).tag($0.id.uuidString) }
                        }
                    }
                }
                Toggle(isOn: $settings.smartShuffle.animation()) { Label("Smart Shuffle", systemImage: "sparkles") }
                if settings.smartShuffle {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $settings.shuffleFamiliarity, in: 0...1)
                        HStack {
                            Text("Random").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Familiar").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Playback") } footer: {
                Text(settings.continuousPlayback ? settings.continuationMode.detail + (settings.smartShuffle ? " Smart shuffle spaces out artists and albums and weighs favorites, plays, skips, genre and tempo." : "")
                     : "Continuous playback keeps music going with songs from your library when the queue ends.")
            }

            Section("Speed") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Playback Speed", systemImage: "gauge.with.dots.needle.50percent")
                        Spacer()
                        Text(String(format: "%.2f×", player.playbackRate)).foregroundStyle(.secondary).monospacedDigit()
                        if player.playbackRate != 1 {
                            Button("Reset") { withAnimation { player.playbackRate = 1 } }.font(.footnote)
                        }
                    }
                    Slider(value: $player.playbackRate, in: 0.5...2, step: 0.05)
                }
            }

            Section("Sleep Timer") {
                Menu {
                    SleepTimerMenuItems()
                } label: {
                    HStack {
                        Label("Sleep Timer", systemImage: "moon.zzz")
                        Spacer()
                        Group {
                            if let end = player.sleepEndsAt {
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    Text(formatTime(max(0, end.timeIntervalSince(ctx.date)))).monospacedDigit()
                                }
                            } else if player.sleepAtTrackEnd {
                                Text("End of Track")
                            } else if player.sleepAtQueueEnd {
                                Text("End of Queue")
                            } else {
                                Text("Off")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                Picker(selection: $settings.sleepFadeSeconds) {
                    Text("Off").tag(0.0); Text("3 s").tag(3.0); Text("10 s").tag(10.0); Text("20 s").tag(20.0); Text("30 s").tag(30.0)
                } label: { Label("Fade Out", systemImage: "speaker.wave.1") }
            }

            KaraokeModelSection()

            AudioLabSections(part: .rules)
        }
        .navigationTitle("Sound")
    }
}

// MARK: - Equalizer

struct EqualizerView: View {
    @Environment(EQModel.self) private var eq
    @State private var saving = false
    @State private var newName = ""
    @State private var renaming: EQPreset?
    @State private var renameText = ""

    var body: some View {
        @Bindable var eq = eq
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 14) {
                    HStack {
                        Text("Bands").font(.system(size: 18, weight: .bold))
                        Spacer()
                        Text("Active: \(eq.activeName)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .contentTransition(.interpolate)
                    }
                    ForEach(0..<10, id: \.self) { i in bandRow(i) }
                    HStack {
                        Toggle("Enabled", isOn: $eq.enabled).font(.system(size: 15, weight: .medium))
                    }
                    .padding(.top, 4)
                }
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(EQModel.presets) { chip($0) }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("My Presets").font(.system(size: 18, weight: .bold))
                    Text("Press and hold a preset to edit or delete.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if !eq.custom.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(eq.custom) { p in
                                chip(p).contextMenu {
                                    Button { renameText = p.name; renaming = p } label: { Label("Rename", systemImage: "pencil") }
                                    Button { eq.overwrite(p) } label: { Label("Update with Current Settings", systemImage: "arrow.triangle.2.circlepath") }
                                    Button(role: .destructive) { withAnimation { eq.delete(p) } } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                    }
                    Button { newName = ""; saving = true } label: {
                        Label("Save Current Settings", systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .padding(16)
            .animation(.smooth, value: eq.custom)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Save Preset", isPresented: $saving) {
            TextField("Name", text: $newName)
            Button("Save") { eq.saveCurrent(as: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let p = renaming { eq.rename(p, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func bandRow(_ i: Int) -> some View {
        @Bindable var eq = eq
        let gain = Binding<Double>(get: { Double(eq.gains[i]) }, set: { eq.gains[i] = Float($0) })
        return HStack(spacing: 8) {
            Text(EQModel.labels[i]).font(.system(size: 14, weight: .semibold)).frame(width: 34, alignment: .leading)
            step("minus") { gain.wrappedValue = max(-12, gain.wrappedValue - 0.5) }
            Slider(value: gain, in: -12...12, step: 0.5).tint(Theme.accent)
            step("plus") { gain.wrappedValue = min(12, gain.wrappedValue + 0.5) }
            Text(String(format: "%.1f dB", gain.wrappedValue))
                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
        .opacity(eq.enabled ? 1 : 0.45)
    }

    private func step(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ p: EQPreset) -> some View {
        let active = eq.enabled && eq.activePreset?.id == p.id
        return Button { withAnimation(.smooth) { eq.select(p) } } label: {
            HStack(spacing: 6) {
                if active { Image(systemName: "checkmark.circle.fill") }
                Text(p.name).lineLimit(1)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(active ? Theme.accent : Color(.systemGray), in: Capsule())
        }
        .buttonStyle(PressScale())
        .sensoryFeedback(.selection, trigger: active)
    }
}

struct EqualizerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            EqualizerView()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Files

struct FilesView: View {
    @Environment(\.inSettings) private var inSettings
    @Environment(LibraryStore.self) private var library
    @Environment(Router.self) private var router
    @State private var confirmDeleteAll = false

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.metadata) { iconRow("Tags & Metadata", "tag.fill", .green) }
                NavigationLink(value: Route.organize) { iconRow("Organize My Library", "wand.and.stars", .pink) }
                Button { Task { await library.fullScan() } } label: { iconRow("Full Scan", "arrow.triangle.2.circlepath", .blue) }
            } header: { Text("Metadata") } footer: { Text("Re-reads metadata from all files.") }

            Section {
                LabeledContent("Songs", value: "\(library.tracks.count)")
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: library.totalSize, countStyle: .file))
                Button(role: .destructive) { confirmDeleteAll = true } label: { Label("Delete All Music", systemImage: "trash") }
                    .disabled(library.tracks.isEmpty)
            } header: { Text("Library") } footer: {
                Text("Drop audio files into the “\(Brand.name)Music” folder (Files app → On My iPhone → \(Brand.name)) and run Scan.")
            }
        }
        .tint(.primary)
        .navigationTitle("Library & Files")
        .toolbar {
            if !inSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
            }
        }
        .confirmationDialog("Delete all \(songCount(library.tracks.count)) from \(Brand.name)?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All Music", role: .destructive) {
                library.deleteAll()
                StreamCache.clear()
            }
        } message: {
            Text("Imported files, downloads and the streaming cache are removed from this iPhone. Playlists stay but will be empty. Songs from your servers come back on the next sync.")
        }
    }

    private func iconRow(_ title: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 14) {
            SettingIcon(symbol: symbol, size: 32)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }
}

struct MetadataListView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var batch = false

    private var list: [Track] {
        let all = library.tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) || $0.album.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(list, selection: $selection) { track in
            NavigationLink {
                TrackEditor(track: track)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(track: track).thumbnail().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                        Text("\(track.artist) — \(track.album)").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .tag(track.id)
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .environment(\.editMode, $editMode)
        .navigationTitle("Tags & Metadata")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if library.tracks.isEmpty { ContentUnavailableView("No Songs", systemImage: "tag") } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active; selection.removeAll() }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editMode.isEditing {
                    Button(selection.count == list.count ? "Deselect All" : "Select All") {
                        selection = selection.count == list.count ? [] : Set(list.map(\.id))
                    }
                    Spacer()
                    Button("Edit \(selection.count) Songs") { batch = true }.disabled(selection.isEmpty)
                }
            }
        }
        .toolbarVisibility(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
        .sheet(isPresented: $batch) {
            BatchTagEditor(ids: Array(selection)) { editMode = .inactive; selection.removeAll() }
        }
    }
}

/// Edits several songs at once: only switched-on fields are written.
struct BatchTagEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let ids: [UUID]
    var done: () -> Void

    enum Field: String, CaseIterable, Identifiable {
        case artist = "Artist", album = "Album", albumArtist = "Album Artist", genre = "Genre", year = "Year",
             disc = "Disc Number", composer = "Composer", copyright = "Copyright", bpm = "BPM"
        var id: String { rawValue }
    }
    @State private var values: [Field: String] = [:]
    @State private var enabled: Set<Field> = []
    @State private var numberTracks = false
    @State private var photo: PhotosPickerItem?
    @State private var art: Data?

    private var tracks: [Track] { library.tracks(for: ids) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(songCount(ids.count)) selected. Only fields you switch on are changed.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Fields") {
                    ForEach(Field.allCases) { f in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(f.rawValue, isOn: Binding(get: { enabled.contains(f) }, set: { if $0 { enabled.insert(f) } else { enabled.remove(f) } }))
                            if enabled.contains(f) {
                                TextField(placeholder(f), text: Binding(get: { values[f] ?? "" }, set: { values[f] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(f == .year || f == .disc || f == .bpm ? .numbersAndPunctuation : .default)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Number Tracks in Current Order", isOn: $numberTracks)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(art == nil ? "Set Artwork for All…" : "Artwork Chosen", systemImage: "photo")
                    }
                } footer: { Text("Numbering follows the album order of the selection.") }
            }
            .navigationTitle("Edit Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(enabled.isEmpty && !numberTracks && art == nil) }
            }
            .onAppear {
                for f in Field.allCases {
                    let vals = Set(tracks.map { value(f, of: $0) })
                    if vals.count == 1, let v = vals.first { values[f] = v }
                }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { art = try? await item.loadTransferable(type: Data.self) }
            }
        }
    }

    private func placeholder(_ f: Field) -> String {
        Set(tracks.map { value(f, of: $0) }).count > 1 ? "Mixed" : f.rawValue
    }

    private func value(_ f: Field, of t: Track) -> String {
        switch f {
        case .artist: t.artist
        case .album: t.album
        case .albumArtist: t.albumArtist ?? ""
        case .genre: t.genre ?? ""
        case .year: t.year.map(String.init) ?? ""
        case .disc: t.discNumber.map(String.init) ?? ""
        case .composer: t.composer ?? ""
        case .copyright: t.copyright ?? ""
        case .bpm: t.bpm.map { String(format: "%.0f", $0) } ?? ""
        }
    }

    private func save() {
        let set = Set(ids)
        let order = SmartShuffle.libraryOrder(tracks).map(\.id)
        library.updateMany(set) { t in
            for f in enabled {
                let v = (values[f] ?? "").trimmingCharacters(in: .whitespaces)
                switch f {
                case .artist: t.artist = v.isEmpty ? "Unknown Artist" : v
                case .album: t.album = v.isEmpty ? "Unknown Album" : v
                case .albumArtist: t.albumArtist = v.isEmpty ? nil : v
                case .genre: t.genre = v.isEmpty ? nil : v
                case .year: t.year = Int(v)
                case .disc: t.discNumber = Int(v)
                case .composer: t.composer = v.isEmpty ? nil : v
                case .copyright: t.copyright = v.isEmpty ? nil : v
                case .bpm: t.bpm = Double(v.replacingOccurrences(of: ",", with: ".")); t.bpmAnalyzed = nil
                }
            }
            if numberTracks, let i = order.firstIndex(of: t.id) { t.trackNumber = i + 1 }
            t.metadataLocked = true
        }
        if let art {
            for id in ids where ArtworkWriter.writeJPEG(from: art, for: id) { ArtworkCache.evict(id) }
            library.updateMany(set) { $0.hasArtwork = true; $0.artSource = .user; $0.artVersion = ($0.artVersion ?? 0) + 1 }
        }
        done()
        dismiss()
    }
}

struct TrackEditor: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var number = 0
    @State private var lyrics = ""
    @State private var newArt: Data?
    @State private var removeArt = false
    @State private var applyToAlbum = false
    @State private var photo: PhotosPickerItem?
    @State private var pickingLyrics = false
    @State private var pickingArt = false
    @State private var designing = false
    @State private var albumArtist = ""
    @State private var genre = ""
    @State private var year = ""
    @State private var disc = ""
    @State private var composer = ""
    @State private var copyright = ""
    @State private var bpm = ""
    @State private var detectingBPM = false
    @State private var lookingUp = false
    @State private var lookupNote: String?

    /// Same catalog lookup as Clean Library, for this one song: fills the tags and fetches the cover. Nothing is saved until you tap Save.
    private func lookUp() async {
        lookingUp = true; lookupNote = nil
        defer { lookingUp = false }
        let name = title.isEmpty ? track.title : title
        let by = artist == "Unknown Artist" ? "" : artist
        guard let hit = await LookupCache.shared.song(artist: by, title: name) else {
            lookupNote = "Nothing found for “\(name)”. Check the title and artist, then try again."
            return
        }
        if let t = hit.title, !t.isEmpty { title = t }
        if let a = hit.artist, !a.isEmpty { artist = a }
        if !hit.album.isEmpty { album = hit.album }
        if let n = hit.number { number = n }
        if let d = hit.disc { disc = String(d) }
        if let g = hit.genre { genre = g }
        if let y = hit.year { year = String(y) }
        var art = hit.artworkURL
        if art == nil { art = await MetadataLookup.coverArtArchive(artist: hit.artist ?? artist, album: hit.album) }
        if let art, let (data, _) = try? await URLSession.shared.data(from: art), UIImage(data: data) != nil {
            newArt = data; removeArt = false
            lookupNote = "Found tags and cover. Tap Save to keep them."
        } else {
            lookupNote = "Found tags, but no cover. Tap Save to keep them."
        }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await lookUp() }
                } label: {
                    HStack {
                        Label("Find Tags & Cover Online", systemImage: "magnifyingglass")
                        Spacer()
                        if lookingUp { ProgressView() }
                    }
                }
                .disabled(lookingUp || !NetworkMonitor.shared.isOnline)
            } footer: {
                Text(lookupNote ?? (NetworkMonitor.shared.isOnline ? "Looks this song up in the music catalog, like Clean Library does." : "You're offline."))
            }
            Section("Cover Art") {
                HStack(spacing: 16) {
                    Group {
                        if let data = newArt, let img = UIImage(data: data) {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else if removeArt {
                            ArtworkView(tracks: [], seed: track.album + track.artist).frame(width: 96, height: 96)
                        } else {
                            ArtworkView(track: track, radius: 14).frame(width: 96, height: 96)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        PhotosPicker(selection: $photo, matching: .images) { Label("Choose Photo", systemImage: "photo") }
                        Button { pickingArt = true } label: { Label("Choose File", systemImage: "folder") }
                        Button { designing = true } label: { Label("Design Cover", systemImage: "paintpalette") }
                        if track.hasArtwork || newArt != nil {
                            Button(role: .destructive) { newArt = nil; removeArt = true } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    .font(.system(size: 15))
                    .buttonStyle(.borderless)
                }
                Toggle("Apply to whole album", isOn: $applyToAlbum)
            }
            Section("Tags") {
                TextField("Title", text: $title)
                TextField("Artist", text: $artist)
                TextField("Album", text: $album)
                Stepper("Track Number: \(number == 0 ? "–" : "\(number)")", value: $number, in: 0...99)
            }
            Section("Details") {
                TextField("Album Artist", text: $albumArtist)
                TextField("Genre", text: $genre)
                TextField("Year", text: $year).keyboardType(.numberPad)
                TextField("Disc Number", text: $disc).keyboardType(.numberPad)
                TextField("Composer", text: $composer)
                TextField("Copyright", text: $copyright)
                HStack {
                    TextField("BPM", text: $bpm).keyboardType(.decimalPad)
                    if detectingBPM { ProgressView() } else if let url = MediaLocator.localURL(for: track) {
                        Button("Detect") {
                            detectingBPM = true
                            Task {
                                if let r = await AudioAnalyzer.analyze(url: url), let b = r.bpm { bpm = String(format: "%.0f", b) }
                                detectingBPM = false
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section {
                TextEditor(text: $lyrics).frame(minHeight: 180).font(.system(size: 14, design: .monospaced))
                Button { pickingLyrics = true } label: { Label("Import .lrc / .txt", systemImage: "square.and.arrow.down") }
                if !lyrics.isEmpty { Button(role: .destructive) { lyrics = "" } label: { Label("Clear Lyrics", systemImage: "trash") } }
            } header: { Text("Lyrics") } footer: {
                Text("Plain text, or timed lines like [01:23.45] Text for synced lyrics.")
            }
        }
        .sheet(isPresented: $designing) { CoverDesigner(track: track) }
        .navigationTitle("Edit Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) } }
        .onAppear {
            title = track.title; artist = track.artist; album = track.album
            number = track.trackNumber; lyrics = track.lyrics ?? ""
            albumArtist = track.albumArtist ?? ""; genre = track.genre ?? ""; year = track.year.map(String.init) ?? ""
            disc = track.discNumber.map(String.init) ?? ""; composer = track.composer ?? ""; copyright = track.copyright ?? ""
            bpm = track.bpm.map { String(format: "%.0f", $0) } ?? ""
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { newArt = data; removeArt = false }
            }
        }
        .fileImporter(isPresented: $pickingArt, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            if let data = try? Data(contentsOf: url) { newArt = data; removeArt = false }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        .fileImporter(isPresented: $pickingLyrics, allowedContentTypes: [.plainText, .text, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            if let text = try? String(contentsOf: url, encoding: .utf8) { lyrics = text }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func save() {
        let targets = applyToAlbum
            ? library.tracks.filter { $0.album == track.album && $0.artist == track.artist }.map(\.id)
            : [track.id]
        if newArt != nil || removeArt {
            for id in targets {
                if let data = newArt {
                    if ArtworkWriter.writeJPEG(from: data, for: id) {
                        library.update(id) { $0.hasArtwork = true; $0.artSource = .user; $0.artVersion = ($0.artVersion ?? 0) + 1 }
                    }
                } else {
                    try? FileManager.default.removeItem(at: Paths.artworkURL(for: id))
                    library.update(id) { $0.hasArtwork = false; $0.artSource = nil; $0.artVersion = ($0.artVersion ?? 0) + 1 }
                }
                ArtworkCache.evict(id)
            }
        }
        library.update(track.id) {
            $0.title = title.isEmpty ? $0.title : title
            $0.artist = artist.isEmpty ? "Unknown Artist" : artist
            $0.album = album.isEmpty ? "Unknown Album" : album
            $0.trackNumber = number
            $0.lyrics = lyrics.isEmpty ? nil : lyrics
            if !lyrics.isEmpty { $0.lyricsSource = "user" }
            $0.albumArtist = albumArtist.isEmpty ? nil : albumArtist
            $0.genre = genre.isEmpty ? nil : genre
            $0.year = Int(year)
            $0.discNumber = Int(disc)
            $0.composer = composer.isEmpty ? nil : composer
            $0.copyright = copyright.isEmpty ? nil : copyright
            let newBPM = Double(bpm.replacingOccurrences(of: ",", with: "."))
            if newBPM.map({ String(format: "%.0f", $0) }) != $0.bpm.map({ String(format: "%.0f", $0) }) { $0.bpmAnalyzed = nil }
            $0.bpm = newBPM
            $0.metadataLocked = true
        }
        dismiss()
    }
}

// MARK: - Search

struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(LayoutStore.self) private var layout

    private var query: String { router.searchText }
    private var q: String { query.trimmingCharacters(in: .whitespaces) }
    @State private var aiFilter: SmartFilter?
    @State private var aiFor = ""
    @State private var openCategory: ModuleCategory?
    @State private var moduleResults: [(InstalledModule, [ModuleTrack])] = []
    @State private var moduleLoading = false

    private var smartFilter: SmartFilter? {
        guard q.count >= 3 else { return nil }
        // Names are collected once per library change, not on every keystroke.
        let f = SmartSearch.parse(q, artists: library.memo("search.artists") { library.artistEntries.map(\.title) },
                                  albums: library.memo("search.albums") { library.albumEntries.map(\.title) },
                                  genres: library.memo("search.genres") { Array(Set(library.tracks.compactMap(\.genre))) })
        if f.isStructured { return f }
        return aiFor == q ? aiFilter : nil
    }

    private static let categories: [String] = ["Music Radio", "Pop", "Hits", "R&B", "Hip-Hop", "Rock", "Dance", "Country", "Latin",
                                                "Alternative", "Jazz", "Classical", "K-Pop", "Chill", "Workout", "Top Songs", "80s", "90s",
                                                "Amapiano", "Disco & Funk"]

    /// Apple Music's "Browse Categories": tap one to search for it in your library and your extensions.
    private var categoryGrid: some View {
        let remote: [ModuleCategory] = ModuleStore.shared.categories
        let fallback: [String] = Self.categories.filter { $0 != "Music Radio" }
        // The Radio Non-Stop genres are always there, next to whatever an extension provides.
        let have: Set<String> = Set(remote.map { $0.name.lowercased() })
        let extra: [(name: String, query: String)] = NonStopStations.all.filter { !have.contains($0.name.lowercased()) }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            CategoryTile(name: "Music Radio")
                .contentShape(Rectangle())
                .onTapGesture { router.open(.radio) }
            if remote.isEmpty {
                ForEach(fallback, id: \.self) { (name: String) in
                    CategoryTile(name: name)
                        .contentShape(Rectangle())
                        .onTapGesture { router.searchText = name }
                }
            } else {
                ForEach(remote) { (cat: ModuleCategory) in
                    CategoryTile(name: cat.name, image: cat.image)
                        .contentShape(Rectangle())
                        .onTapGesture { openCategory = cat }
                }
                ForEach(extra, id: \.name) { st in
                    StationTile(name: st.name, query: st.query, height: 104)
                        .contentShape(Rectangle())
                        .onTapGesture { router.searchText = st.query }
                }
            }
        }
    }

    private func matches(_ s: String) -> Bool { s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }

    /// Online with Offline Mode off — the same rule Home uses.
    private var connected: Bool { NetworkMonitor.shared.isOnline && !settings.offlineMode }

    /// Before typing: what you play most when connected, otherwise the newest music on this iPhone.
    private var idle: (title: String, tracks: [Track]) {
        guard connected else {
            return ("On This iPhone", Array(library.tracks.filter(\.isOffline).sorted { $0.addedAt > $1.addedAt }.prefix(25)))
        }
        let top = library.mostPlayed
        if top.isEmpty { return ("Recently Added", Array(library.tracks.sorted { $0.addedAt > $1.addedAt }.prefix(25))) }
        return ("Most Played", Array(top.prefix(20)))
    }

    /// Module suggestions, unless "Suggested for You" is switched off for Home.
    private var suggested: [ModuleTrack] {
        guard connected, layout.visibleSections.contains(.suggested) else { return [] }
        return Array(library.newToYou(ModuleStore.shared.suggestions.flatMap(\.tracks)).prefix(10))
    }

    var body: some View {
        let start = q.isEmpty ? self.idle : (title: "", tracks: [Track]())
        let picks = q.isEmpty ? self.suggested : []
        let songs = q.isEmpty ? start.tracks
                              : library.tracks.filter { matches($0.title) || matches($0.artist) || matches($0.album) }
        let artists = q.isEmpty ? [] : library.artistEntries.filter { matches($0.title) }
        let albums = q.isEmpty ? [] : library.albumEntries.filter { matches($0.title) || matches($0.subtitle) }
        let playlists = q.isEmpty ? [] : library.playlistEntries.filter { matches($0.title) }
        let moduleArtists = q.isEmpty ? [] : moduleArtistNames(excluding: artists.map(\.title))

        let smart = smartFilter
        let smartSongs = smart.map { SmartSearch.apply($0, to: library.tracks) } ?? []
        // Stops scanning lyrics after the first 20 hits.
        let songIDs = q.count >= 4 ? Set(songs.map(\.id)) : []
        let lyricHits = q.count >= 4 ? Array(library.tracks.lazy
            .filter { t in !songIDs.contains(t.id) && (t.lyrics.map { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil } ?? false) }
            .prefix(20)) : []
        List {
            if q.isEmpty {
                Section {
                    categoryGrid
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    Text("Browse Categories").font(.system(size: 22, weight: .bold)).textCase(nil).foregroundStyle(.primary)
                }
            }
            if let smart {
                Section {
                    if smartSongs.isEmpty {
                        Text("No songs match.").foregroundStyle(.secondary)
                    } else {
                        PlayShuffleBar(tracks: smartSongs, title: smart.summary)
                            .listRowSeparator(.hidden)
                        ForEach(smartSongs.prefix(100)) { track in
                            TrackRow(track: track) {
                                player.play(smartSongs, startAt: smartSongs.firstIndex(of: track) ?? 0, title: smart.summary)
                            }
                        }
                    }
                } header: {
                    Label(smart.summary, systemImage: "sparkle.magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .textCase(nil)
                }
            }
            if !artists.isEmpty || !moduleArtists.isEmpty {
                Section("Artists") {
                    ForEach(artists) { link($0) }
                    ForEach(moduleArtists, id: \.self) { name in
                        NavigationLink {
                            ModuleArtistView(name: name).themedBackground()
                        } label: {
                            Label(name, systemImage: "music.mic").font(.system(size: 16, weight: .medium)).lineLimit(1)
                        }
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") { ForEach(albums) { link($0) } }
            }
            if !playlists.isEmpty {
                Section("Playlists") { ForEach(playlists) { link($0) } }
            }
            if !q.isEmpty { ModuleSearchSection(results: moduleResults, loading: moduleLoading) }
            if !picks.isEmpty {
                Section("Suggested for You") {
                    ForEach(picks) { t in ModuleResultRow(track: t, others: picks) }
                }
            }
            if !lyricHits.isEmpty {
                Section("In Lyrics") {
                    ForEach(lyricHits) { track in
                        TrackRow(track: track) { player.play(lyricHits, startAt: lyricHits.firstIndex(of: track) ?? 0, title: "Search") }
                    }
                }
            }
            if !songs.isEmpty {
                Section(q.isEmpty ? start.title : "Songs") {
                    ForEach(songs) { track in
                        TrackRow(track: track) {
                            player.play(songs, startAt: songs.firstIndex(of: track) ?? 0, title: q.isEmpty ? start.title : "Search")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .navigationDestination(item: $openCategory) { (cat: ModuleCategory) in CategoryTracksView(category: cat) }
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if !q.isEmpty && songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty && smart == nil && lyricHits.isEmpty
                && moduleResults.isEmpty && !moduleLoading {
                ContentUnavailableView.search(text: q)
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
        .task(id: q) { await searchModules() }
        .task { await ModuleStore.shared.refreshDiscovery() }
        .task(id: connected) {
            guard connected, layout.visibleSections.contains(.suggested) else { return }
            await ModuleStore.shared.refreshSuggestions(seeds: Array(library.mostPlayed.prefix(10)))
        }
        .task(id: q) {
            // Free-form questions ("something calm by Nils Frahm for reading") go to the on-device model.
            guard q.split(separator: " ").count >= 3, SmartSearchAI.available else { return }
            let parsed = SmartSearch.parse(q, artists: library.artistEntries.map(\.title), albums: library.albumEntries.map(\.title),
                                           genres: Array(Set(library.tracks.compactMap(\.genre))))
            guard !parsed.isStructured else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if Task.isCancelled { return }
            let current = q
            let result = await SmartSearchAI.interpret(current, artists: library.artistEntries.map(\.title), genres: Array(Set(library.tracks.compactMap(\.genre))))
            if !Task.isCancelled { aiFilter = result; aiFor = current }
        }
    }

    /// Artists of online results that match what was typed and aren't already in the library.
    private func moduleArtistNames(excluding own: [String]) -> [String] {
        let have = Set(own.map(SmartSearch.norm))
        var seen = Set<String>(), out: [String] = []
        for (_, tracks) in moduleResults {
            for t in tracks where t.artist != "Unknown Artist" && matches(t.artist) {
                let k = SmartSearch.norm(t.artist)
                if !have.contains(k), seen.insert(k).inserted { out.append(t.artist) }
            }
        }
        return Array(out.prefix(5))
    }

    private func searchModules() async {
        let current = q
        guard current.count >= 3, ModuleStore.shared.hasSearchModules else { moduleResults = []; moduleLoading = false; return }
        moduleLoading = true
        try? await Task.sleep(for: .milliseconds(650))
        if Task.isCancelled { return }
        let found = await ModuleStore.shared.search(current, limit: 15)
        if Task.isCancelled { return }
        moduleResults = found
        moduleLoading = false
    }

    private func link(_ e: LibraryEntry) -> some View {
        NavigationLink(value: e.route) {
            HStack(spacing: 12) {
                ArtworkView(entry: e, radius: 8).thumbnail().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                    Text(e.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(SourceManager.self) private var sources
    @Environment(LibraryStore.self) private var library
    @Environment(EQModel.self) private var eq
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var openCustomize = false

    private func sourcesDetail() -> String {
        sources.accounts.isEmpty ? "Local Only" : sources.accounts.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { SourcesView() } label: {
                        HStack(spacing: 14) {
                            SettingIcon(symbol: SettingSymbol.sources, size: 30)
                            Text("Sources")
                            Spacer()
                            Text(sourcesDetail()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    NavigationLink { ConnectionsView() } label: {
                        HStack(spacing: 14) {
                            SettingIcon(symbol: SettingSymbol.connections, size: 30)
                            Text("Connections")
                        }
                    }
                    NavigationLink(value: Route.studio) {
                        HStack(spacing: 14) {
                            SettingIcon(symbol: SettingSymbol.sound, size: 30)
                            Text("Sound")
                            Spacer()
                            Text(eq.activeName).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    NavigationLink(value: Route.files) {
                        HStack(spacing: 14) {
                            SettingIcon(symbol: SettingSymbol.library, size: 30)
                            Text("Library & Files")
                            Spacer()
                            Text(songCount(library.tracks.count)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    NavigationLink { CustomizeView() } label: {
                        HStack(spacing: 14) {
                            SettingIcon(symbol: SettingSymbol.customize, size: 30)
                            Text("Customize")
                            Spacer()
                            Text(PlayerDesignStore.shared.lookName).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Sound has the equalizer, tone, loudness, crossfade and playback. Library & Files tidies tags, scans and frees up space. Customize changes colors, fonts, the player, Lock Screen and Home.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $openCustomize) { CustomizeView(opensColors: true) }
            .onAppear {
                if router.openColors {
                    router.openColors = false
                    openCustomize = true
                }
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Customize ▸ Lyrics: where lyrics come from and how they are found.
struct LyricsSourceSections: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Group {
            Section {
                Toggle("Word-by-Word Lyrics", isOn: $settings.wordLyrics)
                Toggle("Lyrics from Your Server", isOn: $settings.serverLyrics)
                Toggle("Search LRCLIB Online", isOn: $settings.onlineLyrics)
                Toggle("Show Translation", isOn: $settings.translateLyrics)
                if settings.translateLyrics {
                    Picker("Translate To", selection: $settings.translationTarget) {
                        ForEach(LyricsLanguages.targets, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
            } header: { Text("Lyrics Sources") } footer: {
                Text("Lyrics are tried in this order: tags and .lrc files, your server, LRCLIB, then on-device recognition. Online lookups send only title, artist, album and length. Translation uses Apple's on-device Translation.")
            }
            Section {
                Toggle("Detect lyrics automatically", isOn: $settings.autoLyrics)
                Picker("Language", selection: $settings.lyricsLanguage) {
                    Text("Auto").tag("auto")
                    Text("System").tag("system")
                    Text("English").tag("en-US")
                    Text("Deutsch").tag("de-DE")
                    Text("Español").tag("es-ES")
                    Text("Français").tag("fr-FR")
                    Text("Italiano").tag("it-IT")
                    Text("日本語").tag("ja-JP")
                    Text("한국어").tag("ko-KR")
                    Text("Português").tag("pt-BR")
                }
            } header: { Text("Recognition") } footer: {
                Text("Songs without lyrics are transcribed on this device with timestamps. Nothing leaves your iPhone.")
            }
        }
    }
}

/// Settings ▸ Connections: scrobbling and other online services in one place.
struct ConnectionsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("ListenBrainz", isOn: $settings.listenBrainzEnabled)
                if settings.listenBrainzEnabled {
                    SecureField("User Token", text: $settings.listenBrainzToken)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                LabeledContent("Last.fm", value: "Coming soon")
            } header: { Text("Scrobbling") } footer: {
                Text("Songs are submitted to ListenBrainz after half of the track has been played.")
            }
            Section {
                Toggle("Online Lookups for Organizer", isOn: $settings.onlineLookups)
                LabeledContent("Siri & Shortcuts", value: "“Play … in \(Brand.name)”")
            } header: { Text("Integrations") } footer: {
                Text("Say “Shuffle my music in \(Brand.name)” or “Set a sleep timer in \(Brand.name)”. Add \(Brand.name) widgets to your Home and Lock Screen, and the Play/Pause control to Control Center.")
            }
        }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
    }
}
