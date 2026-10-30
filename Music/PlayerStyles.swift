import SwiftUI
import Observation

// MARK: - Player styles and your own player designs
//
// A player design is a small, shareable recipe: which look to use (Apple Music), the accent colour,
// the artwork shape and size, which rows show, and which buttons sit in the bottom row, in which order.
// Designs can be saved, switched, shared as a text code and imported from one.

nonisolated enum PlayerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    var id: String { rawValue }
    var title: String { "Apple Music" }
    var symbol: String { "applelogo" }
    /// Players saved with a look that no longer exists open as Apple Music.
    init(from decoder: Decoder) throws { self = .apple }
}

nonisolated enum PlayerArtShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case rounded, square, circle
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

nonisolated enum PlayerBackgroundStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case artwork, gradient, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .artwork: "Moving Artwork"
        case .gradient: "Cover Colour"
        case .black: "Black"
        }
    }
}

nonisolated enum PlayerBottomButton: String, Codable, CaseIterable, Identifiable, Sendable {
    case lyrics, airplay, queue, share, equalizer, sleep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lyrics: "Lyrics"
        case .airplay: "AirPlay"
        case .queue: "Up Next"
        case .share: "Share"
        case .equalizer: "Equalizer"
        case .sleep: "Sleep Timer"
        }
    }
    var symbol: String {
        switch self {
        case .lyrics: "quote.bubble"
        case .airplay: "airplayaudio"
        case .queue: "list.bullet"
        case .share: "square.and.arrow.up"
        case .equalizer: "slider.vertical.3"
        case .sleep: "moon.zzz"
        }
    }
}

/// The rows of the player you can hide or put in another order.
nonisolated enum PlayerRow: String, Codable, CaseIterable, Identifiable, Sendable {
    case lyricLine, title, scrubber, controls, volume, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lyricLine: "Lyric Line"
        case .title: "Song Title"
        case .scrubber: "Progress Bar"
        case .controls: "Play Controls"
        case .volume: "Volume Slider"
        case .bottom: "Bottom Buttons"
        }
    }
    var symbol: String {
        switch self {
        case .lyricLine: "quote.opening"
        case .title: "textformat"
        case .scrubber: "slider.horizontal.below.rectangle"
        case .controls: "playpause"
        case .volume: "speaker.wave.2"
        case .bottom: "rectangle.bottomthird.inset.filled"
        }
    }
    /// The rows each look can arrange. (The Apple look keeps its song title in the header above the cover.)
    static func available(for style: PlayerStyle) -> [PlayerRow] {
        [.scrubber, .controls, .volume, .bottom]
    }
}

nonisolated struct PlayerDesign: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = "My Player"
    var style: PlayerStyle = .apple
    /// Hex colour for the accent ; nil keeps the style's own.
    var accent: String?
    var artShape: PlayerArtShape = .rounded
    /// 0.55 … 1 of the full artwork size.
    var artScale = 1.0
    var background: PlayerBackgroundStyle = .artwork
    /// Apple Music look only: Large, Classic, Vinyl, Minimal or Hidden (AMArtStyle). Optional so older saved designs still load.
    var artStyleRaw: String?
    var showVolume = true
    var showTimes = true
    var showFavorite = true
    var bottom: [PlayerBottomButton] = [.lyrics, .airplay, .queue]
    /// Your own order and the rows you switched off. Optional so older saved players still load.
    var rowOrder: [PlayerRow]?
    var hiddenRows: [PlayerRow]?

    static let apple = PlayerDesign(name: "Apple Music", style: .apple)
}

/// The design in use, the ones you saved, and sharing.
@MainActor @Observable
final class PlayerDesignStore {
    static let shared = PlayerDesignStore()

    var current: PlayerDesign { didSet { save() } }
    private(set) var saved: [PlayerDesign] = []

    private let currentKey = "playerDesign.current"
    private let savedKey = "playerDesign.saved"

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: currentKey), let v = try? JSONDecoder().decode(PlayerDesign.self, from: data) { current = v }
        else { current = .apple }
        if let data = d.data(forKey: savedKey), let v = try? JSONDecoder().decode([PlayerDesign].self, from: data) { saved = v }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(current) { UserDefaults.standard.set(data, forKey: currentKey) }
    }

    private func saveList() {
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: savedKey) }
    }

    func use(_ design: PlayerDesign) { current = design }

    /// The look that is on right now decides what "reset" means: Apple Music's defaults.
    var lookName: String { current.style.title }

    func resetToLookDefaults() {
        ThemeStore.shared.resetToDefault()
        var d = PlayerDesign.apple
        d.id = current.id
        current = d
    }

    func saveCurrent() {
        var copy = current
        if let i = saved.firstIndex(where: { $0.id == copy.id }) { saved[i] = copy }
        else { copy.id = current.id; saved.append(copy) }
        saveList()
    }

    func delete(_ design: PlayerDesign) {
        saved.removeAll { $0.id == design.id }
        saveList()
    }

    // MARK: Sharing

    static let prefix = "mmusic-player:"

    /// A text code anybody can paste into Customize ▸ Player ▸ Import.
    func code(for design: PlayerDesign) -> String {
        var copy = design
        copy.id = UUID()
        let data = (try? JSONEncoder().encode(copy)) ?? Data()
        return Self.prefix + data.base64EncodedString()
    }

    /// Reads a shared code (or the bare JSON). Returns the design, not yet in use.
    func design(fromCode raw: String) -> PlayerDesign? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(Self.prefix) { text.removeFirst(Self.prefix.count) }
        let data: Data? = text.hasPrefix("{") ? text.data(using: .utf8) : Data(base64Encoded: text)
        guard let data, var v = try? JSONDecoder().decode(PlayerDesign.self, from: data) else { return nil }
        v.id = UUID()
        return v
    }
}

extension PlayerDesign {
    /// The rows to draw, top to bottom: your order, minus the ones switched off. The volume row follows its old switch too.
    var activeRows: [PlayerRow] {
        let all = PlayerRow.available(for: style)
        var order = (rowOrder ?? all).filter { all.contains($0) }
        for r in all where !order.contains(r) { order.append(r) }
        let hidden = Set(hiddenRows ?? [])
        return order.filter { r in
            if hidden.contains(r) { return false }
            if r == .volume { return showVolume }
            return true
        }
    }

    /// The accent colour of this design, or `fallback`.
    func accentColor(_ fallback: Color) -> Color { accent.map(Color.init(hex:)) ?? fallback }
}

// MARK: - Customize ▸ Player

struct PlayerStyleSettings: View {
    @State private var store = PlayerDesignStore.shared
    @State private var importText = ""
    @State private var importFailed = false
    @State private var naming = false
    @State private var newName = ""

    private var accentBinding: Binding<Color> {
        Binding(get: { store.current.accentColor(.green) },
                set: { store.current.accent = $0.hexString })
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Artwork") {
                Picker("Style", selection: Binding(get: { store.current.artStyleRaw ?? "large" }, set: { store.current.artStyleRaw = $0 })) {
                    ForEach(AMArtStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Shape", selection: $store.current.artShape) {
                    ForEach(PlayerArtShape.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading) {
                    Text("Size")
                    Slider(value: $store.current.artScale, in: 0.55...1)
                }
            }

            Section("Colours") {
                ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
                Picker("Background", selection: $store.current.background) {
                    ForEach(PlayerBackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Rows") {
                Toggle("Favorite Button", isOn: $store.current.showFavorite)
                Toggle("Times Under the Bar", isOn: $store.current.showTimes)
                Toggle("Volume Slider", isOn: $store.current.showVolume)
            }

            Section {
                NavigationLink { PlayerRowsSettings().environment(\.editMode, .constant(.active)) } label: {
                    Label("Arrange Rows", systemImage: "arrow.up.arrow.down")
                }
            } footer: { Text("Hide rows or drag them into the order you want. The player updates right away.") }

            Section {
                NavigationLink { PlayerBottomRowSettings().environment(\.editMode, .constant(.active)) } label: {
                    Label("Bottom Row", systemImage: "rectangle.bottomthird.inset.filled")
                }
            } footer: { Text("Pick the buttons under the player controls and put them in your own order.") }

            Section {
                NavigationLink { PlayerMenuSettings().environment(\.editMode, .constant(.active)) } label: {
                    Label("Overflow Menu", systemImage: "ellipsis.circle")
                }
            } footer: { Text("Choose what the “…” button in the player shows, and drag the items into your own order.") }

            Section("Share") {
                ShareLink(item: store.code(for: store.current)) { Label("Share This Player", systemImage: "square.and.arrow.up") }
                Button { newName = store.current.name; naming = true } label: { Label("Save to My Players", systemImage: "square.and.arrow.down") }
                TextField("Paste a player code", text: $importText, axis: .vertical).lineLimit(1...3)
                Button {
                    if let d = store.design(fromCode: importText) { store.use(d); importText = "" } else { importFailed = true }
                } label: { Label("Import Player", systemImage: "arrow.down.doc") }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !store.saved.isEmpty {
                Section("My Players") {
                    ForEach(store.saved) { d in
                        Button { store.use(d) } label: {
                            HStack(spacing: 12) {
                                PlayerStyleLogo(style: d.style, size: 26)
                                Text(d.name)
                                Spacer()
                                if store.current.id == d.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions { Button("Delete", role: .destructive) { store.delete(d) } }
                    }
                }
            }
        }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
        .alert("That isn't a player code", isPresented: $importFailed) { Button("OK", role: .cancel) {} }
        .alert("Name This Player", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                store.current.name = newName.isEmpty ? "My Player" : newName
                store.saveCurrent()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct PlayerRowsSettings: View {
    @State private var store = PlayerDesignStore.shared

    var body: some View {
        @Bindable var store = store
        let all = PlayerRow.available(for: store.current.style)
        let order = (store.current.rowOrder ?? all).filter { all.contains($0) } + all.filter { !(store.current.rowOrder ?? all).contains($0) }
        Form {
            Section {
                ForEach(order) { r in
                    HStack {
                        Label(r.title, systemImage: r.symbol)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !(store.current.hiddenRows ?? []).contains(r) && (r != .volume || store.current.showVolume) },
                            set: { on in
                                var h = store.current.hiddenRows ?? []
                                h.removeAll { $0 == r }
                                if !on { h.append(r) }
                                store.current.hiddenRows = h
                                if r == .volume { store.current.showVolume = on }
                            })).labelsHidden()
                    }
                }
                .onMove { from, to in
                    var o = order
                    o.move(fromOffsets: from, toOffset: to)
                    store.current.rowOrder = o
                }
            } footer: { Text("Drag to reorder. The switch hides a row.") }
            Section {
                Button("Reset rows", role: .destructive) { store.current.rowOrder = nil; store.current.hiddenRows = nil }
            }
        }
        .navigationTitle("Arrange Rows")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlayerBottomRowSettings: View {
    @State private var store = PlayerDesignStore.shared

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach(store.current.bottom) { b in
                    Label(b.title, systemImage: b.symbol)
                }
                .onMove { store.current.bottom.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { store.current.bottom.remove(atOffsets: $0) }
            } header: { Text("Shown") } footer: { Text("Drag to reorder, swipe to remove.") }
            let missing = PlayerBottomButton.allCases.filter { !store.current.bottom.contains($0) }
            if !missing.isEmpty {
                Section("Available") {
                    ForEach(missing) { b in
                        Button { store.current.bottom.append(b) } label: { Label("Add \(b.title)", systemImage: b.symbol) }
                    }
                }
            }
        }
        .navigationTitle("Bottom Row")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - Logos

/// Apple's logo for the Apple Music look.
struct PlayerStyleLogo: View {
    var style: PlayerStyle
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: "applelogo").font(.system(size: size * 0.8)).frame(width: size, height: size)
    }
}
