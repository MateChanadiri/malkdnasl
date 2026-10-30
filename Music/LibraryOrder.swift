import SwiftUI

// MARK: - Your own order for a list

/// A saved order for one list (songs, playlists, artists, albums). Anything new goes to the end.
enum CustomOrder {
    private static func key(_ name: String) -> String { "customOrder." + name }

    static func ids(_ name: String) -> [String] { UserDefaults.standard.stringArray(forKey: key(name)) ?? [] }
    static func save(_ ids: [String], _ name: String) { UserDefaults.standard.set(ids, forKey: key(name)) }

    static func apply<T>(_ items: [T], _ name: String, id: (T) -> String) -> [T] {
        let saved: [String] = ids(name)
        if saved.isEmpty { return items }
        var rank: [String: Int] = [:]
        for (i, k) in saved.enumerated() { rank[k] = i }
        let known: [T] = items.filter { rank[id($0)] != nil }.sorted { (rank[id($0)] ?? 0) < (rank[id($1)] ?? 0) }
        let rest: [T] = items.filter { rank[id($0)] == nil }
        return known + rest
    }

    static func move<T>(_ items: [T], from: IndexSet, to: Int, _ name: String, id: (T) -> String) {
        var list: [T] = items
        list.move(fromOffsets: from, toOffset: to)
        save(list.map(id), name)
    }
}

struct ReorderItem: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
}

/// Drag the rows into the order you like; Done keeps it and switches the list to Custom.
struct ReorderSheet: View {
    let title: String
    let name: String
    let items: [ReorderItem]
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var order: [ReorderItem] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(order) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                        if !item.subtitle.isEmpty { Text(item.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .onMove { from, to in order.move(fromOffsets: from, toOffset: to) }
            }
            .environment(\.editMode, .constant(.active))
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        CustomOrder.save(order.map(\.id), name)
                        onSaved()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { order = items }
    }
}

// MARK: - Library rows

/// The rows of the Library screen: switch them off and drag them into your own order.
enum LibraryRow: String, CaseIterable, Identifiable, Codable {
    case songs, playlists, artists, albums, favorites, downloads
    var id: String { rawValue }
    var title: String {
        switch self {
        case .songs: "Songs"
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .albums: "Albums"
        case .favorites: "Favorites"
        case .downloads: "Downloads"
        }
    }
    var symbol: String {
        switch self {
        case .songs: "music.note"
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .favorites: "star"
        case .downloads: "arrow.down.circle"
        }
    }
    var route: Route {
        switch self {
        case .songs: .songs
        case .playlists: .playlists
        case .artists: .artists
        case .albums: .albums
        case .favorites: .favorites
        case .downloads: .downloads
        }
    }
}

struct LibraryRowEntry: Codable, Identifiable, Hashable {
    var row: LibraryRow
    var visible: Bool = true
    var id: String { row.rawValue }
}

enum LibraryRowsStore {
    static let key = "libraryRows"

    static func decode(_ raw: String) -> [LibraryRowEntry] {
        var list: [LibraryRowEntry] = (raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([LibraryRowEntry].self, from: $0) }) ?? []
        for r in LibraryRow.allCases where !list.contains(where: { $0.row == r }) { list.append(LibraryRowEntry(row: r)) }
        return list
    }

    static func encode(_ list: [LibraryRowEntry]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct LibraryRowsEditor: View {
    @AppStorage(LibraryRowsStore.key) private var raw = ""
    @Environment(\.dismiss) private var dismiss
    var embedded = false

    var body: some View {
        if embedded { list } else { NavigationStack { list.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } } }
    }

    private var list: some View {
        let entries: [LibraryRowEntry] = LibraryRowsStore.decode(raw)
        return List {
            Section {
                ForEach(entries) { e in
                    Toggle(isOn: Binding(get: { e.visible }, set: { on in
                        var l = LibraryRowsStore.decode(raw)
                        if let i = l.firstIndex(where: { $0.row == e.row }) { l[i].visible = on }
                        raw = LibraryRowsStore.encode(l)
                    })) {
                        Label(e.row.title, systemImage: e.row.symbol)
                    }
                }
                .onMove { from, to in
                    var l = LibraryRowsStore.decode(raw)
                    l.move(fromOffsets: from, toOffset: to)
                    raw = LibraryRowsStore.encode(l)
                }
            } footer: { Text("Drag the handles to put the rows in your own order. Switch a row off to hide it.") }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
    }
}
