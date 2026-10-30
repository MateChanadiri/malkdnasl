import SwiftUI

/// Design a custom cover for a song or a whole album. Saved as real artwork, so it shows everywhere.
struct CoverDesigner: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    let track: Track
    @State private var spec: CoverSpec
    @State private var wholeAlbum = true

    private static let symbols = ["music.note", "moon.stars.fill", "sun.max.fill", "flame.fill", "heart.fill", "bolt.fill",
                                  "leaf.fill", "cloud.rain.fill", "waveform", "star.fill", "sparkles", "headphones"]

    init(track: Track) {
        self.track = track
        _spec = State(initialValue: CoverStore.shared.spec(for: track) ?? CoverKit.auto(track.album + track.artist))
    }

    private var albumTracks: [Track] { library.tracks.filter { $0.album == track.album && $0.artist == track.artist } }
    private var hasCustom: Bool { CoverStore.shared.spec(for: track) != nil && track.hasArtwork }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    GeneratedCover(spec: spec)
                        .frame(width: 250, height: 250)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                        .id(spec.seed)
                        .transition(.opacity)
                        .animation(.smooth(duration: 0.3), value: spec)

                    HStack(spacing: 10) {
                        Button { withAnimation { spec.seed = UInt64.random(in: 1...UInt64.max) } } label: {
                            Label("Shuffle", systemImage: "dice")
                        }
                        .buttonStyle(.glassProminent)
                        Button { withAnimation { spec = CoverKit.auto(track.album + track.artist) } } label: {
                            Label("Match Vibe", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.glass)
                    }

                    section("Style") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(CoverStyle.allCases) { style in
                                    var s = spec
                                    let _ = s.style = style
                                    Button { withAnimation { spec.style = style } } label: {
                                        VStack(spacing: 6) {
                                            GeneratedCover(spec: s).frame(width: 68, height: 68)
                                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                        .stroke(Theme.accent, lineWidth: spec.style == style ? 3 : 0)
                                                }
                                            Text(style.title).font(.system(size: 11, weight: .medium))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }

                    section("Colors") {
                        VStack(spacing: 14) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(CoverKit.palettes, id: \.name) { palette in
                                        Button { withAnimation { spec.colors = palette.colors } } label: {
                                            HStack(spacing: -6) {
                                                ForEach(palette.colors.prefix(3), id: \.self) {
                                                    Circle().fill(Color(hex: $0)).frame(width: 22, height: 22)
                                                        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.5))
                                                }
                                                Text(palette.name).font(.system(size: 13, weight: .medium)).padding(.leading, 14)
                                            }
                                            .padding(.horizontal, 12).frame(height: 40)
                                            .background(Color.primary.opacity(0.07), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            HStack(spacing: 16) {
                                ForEach(0..<3, id: \.self) { i in
                                    ColorPicker("Color \(i + 1)", selection: colorBinding(i), supportsOpacity: false)
                                        .labelsHidden()
                                        .scaleEffect(1.2)
                                }
                            }
                        }
                    }

                    section("Symbol") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                symbolButton(nil)
                                ForEach(Self.symbols, id: \.self) { symbolButton($0) }
                            }
                            .padding(.horizontal, 20)
                        }
                    }

                    VStack(spacing: 14) {
                        Toggle("Film grain", isOn: $spec.grain.animation())
                        Picker("Apply to", selection: $wholeAlbum) {
                            Text("This Song").tag(false)
                            Text("Whole Album (\(albumTracks.count))").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if hasCustom {
                            Button(role: .destructive) { removeCustom() } label: {
                                Label("Back to Generated Cover", systemImage: "arrow.uturn.backward")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Design Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 20)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbolButton(_ name: String?) -> some View {
        let selected = spec.symbol == name
        return Button { withAnimation { spec.symbol = name } } label: {
            Group {
                if let name { Image(systemName: name).font(.system(size: 18, weight: .semibold)) } else { Text("None").font(.system(size: 12, weight: .medium)) }
            }
            .frame(width: 48, height: 48)
            .background(selected ? Theme.accent : Color.primary.opacity(0.07), in: Circle())
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func colorBinding(_ i: Int) -> Binding<Color> {
        Binding(get: { Color(hex: spec.colors[min(i, spec.colors.count - 1)]) },
                set: { if spec.colors.indices.contains(i) { spec.colors[i] = $0.hexString } })
    }

    // MARK: Save

    private func save() {
        let targets = wholeAlbum ? albumTracks : [track]
        guard let data = CoverKit.image(spec)?.jpegData(compressionQuality: 0.92) else { return }
        for t in targets {
            if ArtworkWriter.writeJPEG(from: data, for: t.id) {
                library.update(t.id) { $0.hasArtwork = true; $0.artSource = .user; $0.artVersion = ($0.artVersion ?? 0) + 1 }
                ArtworkCache.evict(t.id)
            }
        }
        CoverStore.shared.set(spec, keys: wholeAlbum ? [CoverStore.shared.albumKey(track)] + targets.map { CoverStore.shared.key(for: $0) }
                                                       : [CoverStore.shared.key(for: track)])
        dismiss()
    }

    private func removeCustom() {
        let targets = wholeAlbum ? albumTracks : [track]
        for t in targets {
            try? FileManager.default.removeItem(at: Paths.artworkURL(for: t.id))
            library.update(t.id) { $0.hasArtwork = false; $0.artVersion = ($0.artVersion ?? 0) + 1 }
            ArtworkCache.evict(t.id)
        }
        CoverStore.shared.set(nil, keys: [CoverStore.shared.albumKey(track)] + targets.map { CoverStore.shared.key(for: $0) })
        dismiss()
    }
}
