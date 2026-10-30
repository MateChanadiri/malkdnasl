import SwiftUI

/// One Browse Categories / genre station page, filled by the extensions.
struct CategoryTracksView: View {
    let category: ModuleCategory
    @State private var tracks: [ModuleTrack] = []
    @State private var loading: Bool = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(tracks) { (t: ModuleTrack) in
                    ModuleResultRow(track: t, others: tracks)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
            .padding(.bottom, 20)
        }
        .overlay {
            if loading {
                ProgressView()
            } else if tracks.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "music.note")
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.large)
        .task {
            tracks = await ModuleStore.shared.categoryTracks(category.name, id: category.id)
            loading = false
        }
    }
}

/// A picture tile: artwork when the extension gives one, a colour gradient otherwise.
struct CategoryTile: View {
    let name: String
    var image: String? = nil
    var height: CGFloat = 104

    var body: some View {
        let c = placeholderColors(seed: name)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [c.0, c.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image, let url = URL(string: image) {
                AsyncImage(url: url) { (img: Image) in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .frame(height: height)
                .clipped()
            }
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            Text(name)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.white)
                .lineLimit(2)
                .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Radio Non-Stop Music

/// The stations on Radio's "Non-Stop Music" shelf and in Search's categories.
enum NonStopStations {
    static let all: [(name: String, query: String)] = [
        ("Top Songs", "top hits"), ("Hip-Hop", "hip hop hits"), ("80s", "80s hits"), ("90s", "90s hits"),
        ("K-Pop", "kpop hits"), ("Rock", "rock hits"), ("Alternative", "alternative hits"), ("Pop", "pop hits"),
        ("Amapiano", "amapiano"), ("Disco & Funk", "disco funk"), ("Classical", "classical music")
    ]
}

/// One non-stop station: songs from your extensions for the genre, with Play and Shuffle.
struct NonStopStationView: View {
    let name: String
    let query: String
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var tracks: [ModuleTrack] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !tracks.isEmpty {
                    HStack(spacing: 12) {
                        Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                        Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
                ForEach(tracks) { (t: ModuleTrack) in
                    ModuleResultRow(track: t, others: tracks)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
            .padding(.bottom, 20)
        }
        .overlay {
            if loading {
                ProgressView()
            } else if tracks.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("Add an extension in Settings › Sources to fill this station."))
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.large)
        .task {
            if name == "Top Songs", !ModuleStore.shared.chartTracks.isEmpty {
                tracks = ModuleStore.shared.chartTracks
            } else {
                var found: [ModuleTrack] = []
                for m in ModuleStore.shared.enabled where m.canSearch {
                    if let list = try? await ModuleStore.shared.searchTracks(m, query, limit: 40) { found.append(contentsOf: list) }
                }
                var seen = Set<String>()
                tracks = found.filter { seen.insert($0.id).inserted }
            }
            loading = false
        }
    }

    private func play(shuffled: Bool) {
        let list: [ModuleTrack] = shuffled ? tracks.shuffled() : tracks
        player.play(library.addModuleTracks(list), title: name)
    }
}

/// Cover pictures for the Non-Stop stations, taken from the first song an extension returns and remembered.
@MainActor @Observable
final class StationCovers {
    static let shared = StationCovers()
    private let key = "stationCovers"
    private(set) var covers: [String: String]
    @ObservationIgnored private var loading = Set<String>()

    private init() { covers = (UserDefaults.standard.dictionary(forKey: "stationCovers") as? [String: String]) ?? [:] }

    func load(name: String, query: String) async {
        guard covers[name] == nil, !loading.contains(name) else { return }
        loading.insert(name)
        defer { loading.remove(name) }
        var found: String?
        if name == "Top Songs" { found = ModuleStore.shared.chartTracks.first(where: { $0.cover != nil })?.cover }
        if found == nil {
            for m in ModuleStore.shared.enabled where m.canSearch {
                if let list = try? await ModuleStore.shared.searchTracks(m, query, limit: 5), let c = list.first(where: { $0.cover != nil })?.cover {
                    found = c
                    break
                }
            }
        }
        if let found {
            covers[name] = found
            UserDefaults.standard.set(covers, forKey: key)
        }
    }
}

/// A Non-Stop station tile with its cover picture.
struct StationTile: View {
    let name: String
    let query: String
    var height: CGFloat = 110

    var body: some View {
        CategoryTile(name: name, image: StationCovers.shared.covers[name], height: height)
            .task { await StationCovers.shared.load(name: name, query: query) }
    }
}
