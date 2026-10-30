import SwiftUI

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(Router.self) private var router
    @Environment(SourceManager.self) private var sources
    @Environment(LayoutStore.self) private var layout
    @AppStorage(LibraryRowsStore.key) private var rowsRaw = ""
    @State private var editingRows = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if library.tracks.isEmpty {
                    EmptyLibraryCard().padding(.bottom, 18)
                }

                if !library.pinnedEntries.isEmpty {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(library.pinnedEntries) { entry in
                            NavigationLink(value: entry.route) { PinnedCell(entry: entry) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    EntryMenuItems(entry: entry)
                                } preview: {
                                    PinnedPreview(entry: entry)
                                }
                        }
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity)
                } else if !library.tracks.isEmpty {
                    Text("Touch and hold a playlist, artist or album and choose Pin to show it here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 12)
                }

                if !library.tracks.isEmpty { categories }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .animation(.smooth, value: library.pinned)
        .animation(.smooth, value: library.tracks.isEmpty)
        .trackScroll()
        .navigationTitle("Library")
        .sheet(isPresented: $editingRows) { LibraryRowsEditor() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Edit") { editingRows = true }
            }
            if !layout.usesClassicBar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.openAddMusic() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Music")
                }
            }
            if !library.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.organize) { Image(systemName: "wand.and.stars") }
                        .accessibilityLabel("Organize")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.showSettings = true } label: { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Settings")
            }
        }
    }

    /// Apple Music's Library list: red symbols, big titles, hairlines between the rows.
    private var categories: some View {
        let rows: [LibraryRowEntry] = LibraryRowsStore.decode(rowsRaw).filter(\.visible)
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                row(e.row.title, e.row.symbol, e.row.route, count(e.row), last: i == rows.count - 1)
            }
        }
    }

    private func count(_ r: LibraryRow) -> Int {
        switch r {
        case .songs: library.tracks.count
        case .playlists: library.playlists.count
        case .artists: library.artistEntries.count
        case .albums: library.albumEntries.count
        case .favorites: library.tracks.filter(\.isFavorite).count
        case .downloads: library.tracks.filter(\.isDownloaded).count
        }
    }

    private func row(_ title: String, _ symbol: String, _ route: Route, _ count: Int?, last: Bool = false) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34)
                    Text(title).font(.system(size: 22))
                    Spacer()
                    if let count { Text("\(count)").font(.system(size: 15)).foregroundStyle(.tertiary) }
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 56)
                if !last { Divider().padding(.leading, 48) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PinnedCell: View {
    let entry: LibraryEntry
    var body: some View {
        VStack(spacing: 8) {
            ArtworkView(entry: entry, radius: 12)
            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }
}

struct PinnedPreview: View {
    let entry: LibraryEntry
    var body: some View {
        VStack(spacing: 10) {
            ArtworkView(entry: entry, radius: 16).frame(width: 190, height: 190)
            Text(entry.title).font(.system(size: 16, weight: .semibold))
        }
        .padding(14)
    }
}
