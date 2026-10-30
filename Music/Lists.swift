import SwiftUI

// MARK: - Songs

struct SongsView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case custom = "Custom", title = "Title", artist = "Artist", recent = "Date Added", duration = "Duration"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @AppStorage("songSort") private var sortRaw = Sort.title.rawValue
    @AppStorage("songOrigin") private var originRaw = ""
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var showPicker = false
    @State private var confirmDelete = false
    @State private var orderRev = 0

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .title }

    /// Sorted once per change of the library (not on every render), shared with the sections below.
    private var sorted: [Track] {
        let sort = sort, originRaw = originRaw, rev = orderRev
        return library.memo("songs.sorted|\(sort.rawValue)|\(originRaw)|\(rev)") {
            let source = TrackOrigin(rawValue: originRaw).map { o in library.tracks.filter { $0.origin == o } } ?? library.tracks
            return switch sort {
            case .custom: CustomOrder.apply(source, "songs", id: { $0.id.uuidString })
            case .title: source.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            case .artist: source.sorted { ($0.artist, $0.album, $0.trackNumber) < ($1.artist, $1.album, $1.trackNumber) }
            case .recent: source.sorted { $0.addedAt > $1.addedAt }
            case .duration: source.sorted { $0.duration > $1.duration }
            }
        }
    }

    private func sections(_ list: [Track]) -> [(String, [Track])] {
        let sort = sort, originRaw = originRaw
        guard sort == .title || sort == .artist else { return [("", list)] }
        return library.memo("songs.sections|\(sort.rawValue)|\(originRaw)") {
            let groups = Dictionary(grouping: list) { t -> String in
                let s = (sort == .title ? t.title : t.artist).folding(options: .diacriticInsensitive, locale: .current)
                guard let c = s.first?.uppercased(), c.first?.isLetter == true else { return "#" }
                return c
            }
            return groups.keys.sorted { $0 == "#" ? true : $1 == "#" ? false : $0 < $1 }.map { ($0, groups[$0]!) }
        }
    }

    var body: some View {
        let all = sorted
        List(selection: $selection) {
            PlayShuffleBar(tracks: all, title: "All Songs")
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                .selectionDisabled()
            ForEach(sections(all), id: \.0) { letter, tracks in
                Section {
                    ForEach(tracks) { track in
                        TrackRow(track: track) {
                            player.play(all, startAt: all.firstIndex { $0.id == track.id } ?? 0, title: "All Songs")
                        }
                        .tag(track.id)
                    }
                    .onMove(perform: sort == .custom ? { from, to in
                        CustomOrder.move(all, from: from, to: to, "songs", id: { $0.id.uuidString })
                        orderRev += 1
                    } : nil)
                } header: {
                    if !letter.isEmpty { Text(letter).font(.system(size: 20, weight: .bold)).foregroundStyle(.primary) }
                }
                .sectionIndexLabel(letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .environment(\.defaultMinListHeaderHeight, 34)
        .environment(\.editMode, $editMode)
        .navigationTitle("Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
        .overlay {
            if library.tracks.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note", description: Text("Tap + in Library to add music."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.smooth) {
                        editMode = editMode.isEditing ? .inactive : .active
                        selection.removeAll()
                    }
                } label: { Image(systemName: editMode.isEditing ? "checkmark.circle.fill" : "checkmark.shield") }
                    .accessibilityLabel("Select")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    if library.tracks.contains(where: \.isRemote) {
                        Picker("Show", selection: $originRaw) {
                            Text("All Sources").tag("")
                            ForEach(TrackOrigin.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { player.play(all, title: "All Songs", shuffled: true) } label: { Label("Shuffle All", systemImage: "shuffle") }
                    Button { player.playAfter(all) } label: { Label("Add All to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
                } label: { Image(systemName: "ellipsis") }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if editMode.isEditing {
                    Button("Add to Playlist") { showPicker = true }.disabled(selection.isEmpty)
                    Spacer()
                    Text(selection.isEmpty ? "Select Songs" : "\(selection.count) Selected").font(.footnote)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showPicker) { PlaylistPicker(trackIDs: all.filter { selection.contains($0.id) }.map(\.id)) }
        .confirmationDialog("Delete \(selection.count) songs from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(selection)
                selection.removeAll()
                editMode = .inactive
            }
        }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case custom = "Custom", name = "Name", recent = "Date Added", count = "Song Count"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @AppStorage("playlistSort") private var sortRaw = Sort.name.rawValue
    @State private var creating = false
    @State private var name = ""
    @State private var reordering = false
    @State private var orderRev = 0

    private var entries: [LibraryEntry] {
        let list = library.playlistEntries
        _ = orderRev
        switch Sort(rawValue: sortRaw) ?? .name {
        case .custom: return CustomOrder.apply(list, "playlists", id: { $0.key })
        case .name: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recent: return list.reversed()
        case .count: return list.sorted { $0.tracks.count > $1.tracks.count }
        }
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                NavigationLink(value: entry.route) {
                    HStack(spacing: 14) {
                        ArtworkView(entry: entry, radius: 10).thumbnail(200).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.system(size: 17, weight: .medium)).lineLimit(1)
                            Text(entry.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    EntryMenuItems(entry: entry)
                    Divider()
                    Button(role: .destructive) { if let id = UUID(uuidString: entry.key) { library.deletePlaylist(id) } } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { if let id = UUID(uuidString: entry.key) { library.deletePlaylist(id) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if library.playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list", description: Text("Tap + to create one."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New Playlist")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let ids = player.queue.map(\.trackID)
                    library.createPlaylist(name: player.queueTitle.isEmpty ? "Queue" : player.queueTitle, trackIDs: ids)
                } label: { Image(systemName: "music.note.list") }
                    .disabled(player.queue.isEmpty)
                    .accessibilityLabel("Save Queue as Playlist")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortRaw) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Button { reordering = true } label: { Label("Edit Custom Order…", systemImage: "arrow.up.arrow.down") }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
            }
        }
        .sheet(isPresented: $reordering) {
            ReorderSheet(title: "Playlists", name: "playlists",
                         items: CustomOrder.apply(library.playlistEntries, "playlists", id: { $0.key }).map { ReorderItem(id: $0.key, title: $0.title, subtitle: $0.subtitle) }) {
                sortRaw = Sort.custom.rawValue; orderRev += 1
            }
        }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Create") { library.createPlaylist(name: name); name = "" }
            Button("Cancel", role: .cancel) { name = "" }
        }
    }
}

// MARK: - Artists

struct ArtistsView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case custom = "Custom", name = "Name", count = "Song Count"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @State private var reordering = false
    @State private var orderRev = 0
    @AppStorage("artistSort") private var sortRaw = Sort.name.rawValue
    @State private var favoritesOnly = false

    private var entries: [LibraryEntry] {
        var list = library.artistEntries
        if favoritesOnly { list = list.filter { library.isFavorite($0) } }
        _ = orderRev
        if Sort(rawValue: sortRaw) == .count { list.sort { $0.tracks.count > $1.tracks.count } }
        if Sort(rawValue: sortRaw) == .custom { list = CustomOrder.apply(list, "artists", id: { $0.key }) }
        return list
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                NavigationLink(value: entry.route) {
                    HStack(spacing: 14) {
                        ArtworkView(entry: entry).thumbnail(200).frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(entry.title).font(.system(size: 17, weight: .medium)).lineLimit(1)
                                if library.isFavorite(entry) { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow) }
                            }
                            Text(entry.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu { EntryMenuItems(entry: entry) }
            }
        }
        .listStyle(.plain)
        .animation(.smooth, value: favoritesOnly)
        .sheet(isPresented: $reordering) {
            ReorderSheet(title: "Artists", name: "artists",
                         items: CustomOrder.apply(library.artistEntries, "artists", id: { $0.key }).map { ReorderItem(id: $0.key, title: $0.title, subtitle: $0.subtitle) }) {
                sortRaw = Sort.custom.rawValue; orderRev += 1
            }
        }
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(favoritesOnly ? "No Favorite Artists" : "No Artists", systemImage: "music.mic",
                                       description: Text(favoritesOnly ? "Long-press an artist and choose Favorite." : "Import artist folders or audio files."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.startImport(.artistFolders) } label: { Image(systemName: "plus") }.accessibilityLabel("Import Artist Folders")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { favoritesOnly.toggle() } label: { Image(systemName: favoritesOnly ? "star.fill" : "star") }
                    .accessibilityLabel("Favorites")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortRaw) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Button { reordering = true } label: { Label("Edit Custom Order…", systemImage: "arrow.up.arrow.down") }
                    Divider()
                    Button { player.play(library.tracks, title: "All Songs", shuffled: true) } label: { Label("Shuffle All", systemImage: "shuffle") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }
}

// MARK: - Albums

struct AlbumsView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case custom = "Custom", title = "Title", artist = "Artist", count = "Song Count"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @AppStorage("albumSort") private var sortRaw = Sort.title.rawValue
    @State private var reordering = false
    @State private var orderRev = 0

    private var entries: [LibraryEntry] {
        let list = library.albumEntries
        _ = orderRev
        switch Sort(rawValue: sortRaw) ?? .title {
        case .custom: return CustomOrder.apply(list, "albums", id: { $0.key })
        case .title: return list
        case .artist: return list.sorted { $0.subtitle.localizedStandardCompare($1.subtitle) == .orderedAscending }
        case .count: return list.sorted { $0.tracks.count > $1.tracks.count }
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                ForEach(entries) { entry in
                    NavigationLink(value: entry.route) {
                        VStack(alignment: .leading, spacing: 8) {
                            ArtworkView(entry: entry, radius: 14)
                                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Text(entry.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { EntryMenuItems(entry: entry) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $reordering) {
            ReorderSheet(title: "Albums", name: "albums",
                         items: CustomOrder.apply(library.albumEntries, "albums", id: { $0.key }).map { ReorderItem(id: $0.key, title: $0.title, subtitle: $0.subtitle) }) {
                sortRaw = Sort.custom.rawValue; orderRev += 1
            }
        }
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "square.stack", description: Text("Tap + in Library to add music."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.startImport(.audioFiles) } label: { Image(systemName: "plus") }.accessibilityLabel("Import Audio Files")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortRaw) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Button { reordering = true } label: { Label("Edit Custom Order…", systemImage: "arrow.up.arrow.down") }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { player.play(library.tracks, title: "All Songs", shuffled: true) } label: { Label("Shuffle All", systemImage: "shuffle") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }
}

// MARK: - Detail (playlist / artist / album)

struct CollectionDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let kind: LibraryEntry.Kind
    let key: String

    @State private var editMode: EditMode = .inactive
    @State private var renaming = false
    @State private var newName = ""
    @State private var addingSongs = false
    @State private var confirmDelete = false
    @State private var about: AboutInfo?

    private var playlistID: UUID? { kind == .playlist ? UUID(uuidString: key) : nil }

    var body: some View {
        Group {
            if kind == .artist {
                ArtistDetailView(name: key)
            } else if let entry = library.entry(kind, key) {
                content(entry)
            } else {
                ContentUnavailableView("Not Available", systemImage: "questionmark.folder")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ entry: LibraryEntry) -> some View {
        List {
            VStack(spacing: 12) {
                Group {
                    if kind == .album {
                        ArtistCatalogArtwork(entry: entry, radius: 18)
                    } else {
                        ArtworkView(entry: entry, radius: 18)
                    }
                }
                    .frame(width: 210, height: 210)
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                VStack(spacing: 3) {
                    Text(entry.title).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
                    Text(entry.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                PlayShuffleBar(tracks: entry.tracks, title: entry.title).padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))

            Section {
                ForEach(entry.tracks) { track in
                    TrackRow(track: track, showArtwork: kind != .album) {
                        player.play(entry.tracks, startAt: entry.tracks.firstIndex(of: track) ?? 0, title: entry.title)
                    }
                }
                .onMove(perform: playlistID == nil ? nil : { from, to in
                    var ids = entry.tracks.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    if let id = playlistID { library.setPlaylistTracks(id, ids) }
                })
                .onDelete(perform: playlistID == nil ? nil : { offsets in
                    var ids = entry.tracks.map(\.id)
                    ids.remove(atOffsets: offsets)
                    if let id = playlistID { library.setPlaylistTracks(id, ids) }
                })
            }

            if let about {
                AboutCard(info: about)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 12, trailing: 20))
            }
        }
        .listStyle(.plain)
        .task(id: entry.key) {
            guard kind == .album, let artist = entry.tracks.first?.artist else { return }
            let info = await AboutInfo.album(artist: artist, album: entry.title, settings: settings)
            withAnimation(.smooth) { about = info }
        }
        .environment(\.defaultMinListHeaderHeight, 0)
        .environment(\.editMode, $editMode)
        .navigationTitle(entry.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    EntryMenuItems(entry: entry)
                    if let id = playlistID {
                        Divider()
                        Button { addingSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                        Button { withAnimation { editMode = editMode.isEditing ? .inactive : .active } } label: {
                            Label(editMode.isEditing ? "Done Editing" : "Edit Order", systemImage: "arrow.up.arrow.down")
                        }
                        Button { newName = entry.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                            .id(id)
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { if let id = playlistID { library.rename(id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this playlist?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                if let id = playlistID { library.deletePlaylist(id) }
                dismiss()
            }
        }
        .sheet(isPresented: $addingSongs) { if let id = playlistID { SongPicker(playlistID: id) } }
    }
}

struct SongPicker: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var selection = Set<UUID>()

    var body: some View {
        NavigationStack {
            List(library.tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, selection: $selection) { track in
                HStack(spacing: 12) {
                    ArtworkView(track: track).thumbnail().frame(width: 44, height: 44)
                    VStack(alignment: .leading) {
                        Text(track.title).font(.system(size: 16, weight: .medium))
                        Text(track.artist).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .tag(track.id)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        library.add(library.tracks.filter { selection.contains($0.id) }.map(\.id), to: playlistID)
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }
}
