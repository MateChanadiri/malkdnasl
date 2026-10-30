import SwiftUI

// MARK: - Matching "artist - title" lines against the library

nonisolated struct SongLineMatch: Identifiable, Sendable {
    enum Status: Sendable { case found, check, missing }
    let id: Int
    let line: String
    var trackID: UUID?
    var title = ""
    var artist = ""
    var score = 0.0
    var alternatives: [UUID] = []
    /// Found through a module instead of the library; added to the library when the playlist is created.
    var online: ModuleTrack?
    var onlineSource: String?
    var status: Status { trackID == nil && online == nil ? .missing : score >= 0.82 ? .found : .check }
}

/// Fuzzy song matching for pasted lists from other apps, so typos like "defrones - lhabia" still find
/// "Deftones – Lhabia". Works on the whole unified library (local files and streaming sources).
nonisolated enum SongListMatcher {
    struct Entry: Sendable { let id: UUID; let title: String; let artist: String; let rawTitle: String; let rawArtist: String }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        // Drop "(Remastered 2011)", "[Live]", "feat. …".
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = String(t.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return t.split(separator: " ").joined(separator: " ")
    }

    /// Splits one pasted line into (left, right) parts, e.g. "Deftones - Lhabia", "Lhabia by Deftones", "1. A – B".
    static func split(_ raw: String) -> (String, String)? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacingOccurrences(of: #"^\s*(\d+[\.\)]|[-•*·])\s*"#, with: "", options: .regularExpression)
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        guard !line.isEmpty else { return nil }
        for sep in [" - ", " – ", " — ", "\t", " | ", " -", "- "] {
            if let r = line.range(of: sep) {
                let a = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let b = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && !b.isEmpty { return (a, b) }
            }
        }
        if let r = line.range(of: " by ", options: .caseInsensitive) {
            return (String(line[r.upperBound...]), String(line[..<r.lowerBound]))   // "Title by Artist" → artist first
        }
        return ("", line)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        let lev = 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
        // Word overlap helps with extra/missing words ("the", "remix", …).
        let wa = Set(a.split(separator: " ")), wb = Set(b.split(separator: " "))
        let overlap = Double(wa.intersection(wb).count) / Double(max(1, max(wa.count, wb.count)))
        let contains = (a.contains(b) || b.contains(a)) ? 0.9 : 0
        let lenRatio: Double = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        let containsScore: Double = contains * min(1.0, lenRatio + 0.3)
        return max(lev, overlap * 0.95, containsScore)
    }

    private static func grams(_ s: String) -> Set<String> {
        let c = Array(s.replacingOccurrences(of: " ", with: ""))
        guard c.count >= 3 else { return [String(c)] }
        return Set((0...(c.count - 3)).map { String(c[$0..<$0 + 3]) })
    }

    @concurrent
    static func match(lines: [String], entries: [Entry]) async -> [SongLineMatch] {
        // Trigram index over titles so each line only scores plausible candidates.
        var index: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() { for g in grams(e.title) { index[g, default: []].append(i) } }

        var out: [SongLineMatch] = []
        for (n, raw) in lines.enumerated() {
            guard let (left, right) = split(raw) else { continue }
            let l = normalize(left), r = normalize(right)
            var candidates = Set<Int>()
            for part in [l, r] where !part.isEmpty {
                for g in grams(part) { for i in index[g] ?? [] { candidates.insert(i) } }
            }
            var scored: [(Int, Double)] = []
            for i in candidates {
                let e = entries[i]
                // "artist - title" is the usual order, but try the other one too.
                let forward = l.isEmpty ? similarity(r, e.title) : 0.62 * similarity(r, e.title) + 0.38 * similarity(l, e.artist)
                let backward = l.isEmpty ? 0 : 0.62 * similarity(l, e.title) + 0.38 * similarity(r, e.artist)
                scored.append((i, max(forward, backward)))
            }
            scored.sort { $0.1 > $1.1 }
            var m = SongLineMatch(id: n, line: raw)
            if let best = scored.first, best.1 >= 0.55 {
                let e = entries[best.0]
                m.trackID = e.id; m.title = e.rawTitle; m.artist = e.rawArtist; m.score = best.1
                m.alternatives = scored.dropFirst().prefix(4).filter { $0.1 >= 0.45 }.map { entries[$0.0].id }
            }
            out.append(m)
        }
        return out
    }
}

// MARK: - UI

struct SongListImportView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = "Imported Playlist"
    @State private var results: [SongLineMatch] = []
    @State private var excluded = Set<Int>()
    @State private var matching = false
    @State private var progress: (Int, Int)?
    @State private var searchModules = true
    @State private var created: String?
    @FocusState private var editorFocused: Bool

    private var lines: [String] { text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var chosen: [SongLineMatch] { results.filter { !excluded.contains($0.id) && ($0.trackID != nil || $0.online != nil) } }
    private var modulesAvailable: Bool { ModuleStore.shared.hasSearchModules }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    Section {
                        TextField("Playlist Name", text: $name)
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Deftones - Lhabia\nDeftones - Kimdracula\nFrank Ocean - Nights")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                            }
                            TextEditor(text: $text)
                                .focused($editorFocused)
                                .frame(minHeight: 220)
                                .font(.system(size: 15, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        if modulesAvailable {
                            Toggle("Search Extensions for Missing Songs", isOn: $searchModules)
                        }
                        HStack {
                            // The system paste button inserts without the "Allow Paste?" prompt.
                            PasteButton(payloadType: String.self) { strings in
                                if let s = strings.first { text = text.isEmpty ? s : text + "\n" + s }
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonBorderShape(.capsule)
                            Spacer()
                            Text("\(lines.count) lines").font(.footnote).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    } header: { Text("Song List") } footer: {
                        Text("One song per line: “Artist - Title”. Copy the list from another app (another music app, a note…). Typos are fine. \(Brand.name) finds the closest songs in your library, on your server and, if you have extensions, through them.")
                    }
                } else {
                    let found = results.filter { $0.status == .found }.count
                    let check = results.filter { $0.status == .check }.count
                    let missing = results.filter { $0.status == .missing }.count
                    Section {
                        TextField("Playlist Name", text: $name)
                        HStack(spacing: 16) {
                            stat("\(found)", "Found", .green)
                            stat("\(check)", "Check", .orange)
                            stat("\(missing)", "Missing", .secondary)
                        }
                    }
                    Section("Songs") {
                        ForEach(results) { r in row(r) }
                    }
                }
            }
            .navigationTitle("Import Song List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(results.isEmpty ? "Cancel" : "Back") {
                        if results.isEmpty { dismiss() } else { results = []; excluded = [] }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if matching {
                        HStack(spacing: 6) {
                            ProgressView()
                            if let (d, t) = progress { Text("\(d)/\(t)").font(.caption).monospacedDigit() }
                        }
                    }
                    else if results.isEmpty {
                        Button("Find Songs") { Task { await runMatch() } }.disabled(lines.isEmpty)
                    } else {
                        Button("Create") { create() }.disabled(chosen.isEmpty)
                    }
                }
            }
            .alert(created ?? "", isPresented: Binding(get: { created != nil }, set: { if !$0 { created = nil; dismiss() } })) {
                Button("OK") {}
            }
            .onAppear { editorFocused = true }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func row(_ r: SongLineMatch) -> some View {
        let has = r.trackID != nil || r.online != nil
        let on = !excluded.contains(r.id) && has
        HStack(spacing: 12) {
            Button {
                guard has else { return }
                if excluded.contains(r.id) { excluded.remove(r.id) } else { excluded.insert(r.id) }
            } label: {
                Image(systemName: !has ? "xmark.circle" : on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(!has ? Color.secondary : r.status == .check ? .orange : Theme.accent)
            }
            .buttonStyle(.plain)
            if let id = r.trackID, let t = library.trackByID[id] {
                ArtworkView(track: t, radius: 6).thumbnail().frame(width: 40, height: 40)
            } else if let o = r.online {
                AsyncImage(url: o.cover.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if has {
                    Text(r.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(r.artist + (r.onlineSource.map { " · from \($0)" } ?? "") + (r.status == .check ? " · please check" : ""))
                        .font(.caption).foregroundStyle(r.status == .check ? .orange : .secondary).lineLimit(1)
                } else {
                    Text("Not in your library").font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !r.alternatives.isEmpty {
                Menu {
                    ForEach(r.alternatives, id: \.self) { alt in
                        if let t = library.trackByID[alt] {
                            Button("\(t.title) — \(t.artist)") { replace(r.id, with: t) }
                        }
                    }
                } label: { Image(systemName: "arrow.triangle.swap").foregroundStyle(.secondary) }
            }
        }
    }

    private func replace(_ id: Int, with t: Track) {
        guard let i = results.firstIndex(where: { $0.id == id }) else { return }
        results[i].trackID = t.id
        results[i].title = t.title
        results[i].artist = t.artist
        results[i].score = 1
        results[i].online = nil
        results[i].onlineSource = nil
        excluded.remove(id)
    }

    private func runMatch() async {
        matching = true
        let entries = library.tracks.map {
            SongListMatcher.Entry(id: $0.id, title: SongListMatcher.normalize($0.title), artist: SongListMatcher.normalize($0.artist),
                                  rawTitle: $0.title, rawArtist: $0.artist)
        }
        var found = await SongListMatcher.match(lines: lines, entries: entries)
        // Songs that aren't in the library: ask the installed modules, best fuzzy match wins.
        if searchModules, modulesAvailable {
            let todo = found.indices.filter { found[$0].trackID == nil || found[$0].score < 0.7 }
            for (n, i) in todo.enumerated() {
                progress = (n + 1, todo.count)
                guard let (left, right) = SongListMatcher.split(found[i].line) else { continue }
                let query = [left, right].filter { !$0.isEmpty }.joined(separator: " ")
                let l = SongListMatcher.normalize(left), r = SongListMatcher.normalize(right)
                var best: (ModuleTrack, String, Double)?
                for (m, tracks) in await ModuleStore.shared.search(query, limit: 8) {
                    for t in tracks {
                        let tt = SongListMatcher.normalize(t.title), ta = SongListMatcher.normalize(t.artist)
                        let fwd = l.isEmpty ? SongListMatcher.similarity(r, tt) : 0.62 * SongListMatcher.similarity(r, tt) + 0.38 * SongListMatcher.similarity(l, ta)
                        let bwd = l.isEmpty ? 0 : 0.62 * SongListMatcher.similarity(l, tt) + 0.38 * SongListMatcher.similarity(r, ta)
                        let sc = max(fwd, bwd)
                        if sc > (best?.2 ?? 0) { best = (t, m.name, sc) }
                    }
                }
                if let (t, name, sc) = best, sc >= 0.6, sc > found[i].score {
                    found[i].trackID = nil
                    found[i].online = t
                    found[i].onlineSource = name
                    found[i].title = t.title
                    found[i].artist = t.artist
                    found[i].score = sc
                    found[i].alternatives = []
                }
            }
            progress = nil
        }
        results = found
        excluded = Set(found.filter { $0.status == .missing }.map(\.id))
        matching = false
    }

    private func create() {
        var seen = Set<UUID>()
        let ids = chosen.compactMap { r in r.trackID ?? r.online.map { library.addModuleTrack($0).id } }.filter { seen.insert($0).inserted }
        library.createPlaylist(name: name, trackIDs: ids)
        let missing = results.filter { $0.trackID == nil && $0.online == nil }.count
        created = "“\(name.isEmpty ? "New Playlist" : name)” created with \(songCount(ids.count))" + (missing > 0 ? ". \(missing) couldn't be found." : ".")
    }
}
