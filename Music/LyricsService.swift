import Speech
import AVFoundation
import NaturalLanguage
import Observation

/// Finds lyrics on device: transcribes the song with Apple's on-device speech model and builds timed (LRC) lines.
@Observable
final class LyricsService {
    enum State: Equatable { case running(String), notFound, failed(String) }
    func isRunning(_ id: UUID) -> Bool { if case .running = states[id] { return true }; return false }

    private(set) var states: [UUID: State] = [:]
    @ObservationIgnored private var pending: [Track] = []
    @ObservationIgnored private var pumping = false
    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored var sources: SourceManager?
    /// Online lookups in flight, so a song is never searched twice at once (autoplay + Clean Library).
    @ObservationIgnored private var onlineLookups: [UUID: Task<Bool, Never>] = [:]

    init(library: LibraryStore, settings: AppSettings) {
        self.library = library
        self.settings = settings
    }

    func state(_ id: UUID) -> State? { states[id] }

    /// Called whenever a song starts: only tries once per song, and only if it has no lyrics yet.
    /// Order: embedded tags / .lrc (at import) → your server → LRCLIB → on-device recognition.
    func autoDetect(for track: Track) {
        if track.lyrics != nil {
            upgradeToSynced(track)
            return
        }
        if track.onlineLyricsChecked != true, settings.serverLyrics || settings.onlineLyrics {
            Task {
                if await fetchOnline(track) { return }
                if let fresh = library.trackByID[track.id], settings.autoLyrics, fresh.lyrics == nil, fresh.lyricsChecked != true, MediaLocator.isPlayableNow(fresh) {
                    detect(fresh)
                }
            }
            return
        }
        guard settings.autoLyrics, track.lyricsChecked != true, MediaLocator.isPlayableNow(track) else { return }
        detect(track)
    }

    /// Server lyrics, then LRCLIB. Returns true when lyrics were found.
    @discardableResult
    func fetchOnline(_ track: Track, force: Bool = false) async -> Bool {
        if let running = onlineLookups[track.id] { return await running.value }
        let task = Task { await lookUpOnline(track, force: force) }
        onlineLookups[track.id] = task
        defer { onlineLookups[track.id] = nil }
        return await task.value
    }

    private func lookUpOnline(_ track: Track, force: Bool) async -> Bool {
        guard NetworkMonitor.shared.isOnline, !settings.offlineMode || force else { return false }
        states[track.id] = .running("Looking for lyrics…")
        defer { if case .running = states[track.id] { states[track.id] = nil } }
        var found: (String, String)?
        if settings.serverLyrics || force, track.isRemote, let rid = track.remoteID, let client = sources?.client(for: track.sourceID),
           let lrc = await client.lyrics(remoteID: rid), !lrc.isEmpty {
            found = (lrc, "server")
        }
        if found == nil, let source = track.sourceID, source.hasPrefix("module:"),
           let lrc = await ModuleStore.shared.lyrics(moduleID: String(source.dropFirst(7)), track: track) {
            found = (lrc, "extension")
        }
        if found == nil, settings.onlineLyrics || force, let lrc = await LRCLib.lookup(title: track.title, artist: track.artist, album: track.album, duration: track.duration) {
            found = (lrc, "lrclib")
        }
        library.update(track.id) {
            $0.onlineLyricsChecked = true
            if let (lrc, source) = found, $0.lyrics == nil || force { $0.lyrics = lrc; $0.lyricsSource = source }
        }
        return found != nil
    }

    /// Lyrics without timestamps (from tags, a server or plain LRCLIB text) can't follow the song.
    /// Once per song, look for a synced version of the same recording and swap it in. Lyrics you typed stay.
    func upgradeToSynced(_ track: Track) {
        guard let lyrics = track.lyrics, track.lyricsSource != "user", track.syncedLyricsChecked != true,
              settings.onlineLyrics, !settings.offlineMode, NetworkMonitor.shared.isOnline,
              !LyricsParser.isTimed(lyrics) else { return }
        Task {
            let lrc = await LRCLib.lookup(title: track.title, artist: track.artist, album: track.album, duration: track.duration, syncedOnly: true)
            library.update(track.id) {
                $0.syncedLyricsChecked = true
                if let lrc, $0.lyrics == lyrics { $0.lyrics = lrc; $0.lyricsSource = "lrclib" }
            }
        }
    }

    /// "Find Lyrics" button: every source, in order.
    func findAnywhere(_ track: Track) {
        Task {
            if await fetchOnline(track, force: true) { return }
            if let fresh = library.trackByID[track.id], MediaLocator.isPlayableNow(fresh) { detect(fresh) }
            else { states[track.id] = .failed("No lyrics found online, and the song isn't on this iPhone for recognition.") }
        }
    }

    func detect(_ track: Track) {
        guard !isRunning(track.id), !pending.contains(where: { $0.id == track.id }) else { return }
        states[track.id] = .running("Waiting…")
        pending.append(track)
        pump()
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        Task {
            while !pending.isEmpty {
                let track = pending.removeFirst()
                await run(track)
            }
            pumping = false
        }
    }

    private func run(_ track: Track) async {
        do {
            let id = track.id
            guard let url = MediaLocator.localURL(for: track) else { states[track.id] = .failed("The song isn't available offline."); return }
            let locales = settings.lyricsLocales
            let report: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in self?.states[id] = .running(message) }
            }
            // Recognition starts right when a song starts; below user priority it doesn't compete with playback and the UI.
            let lrc = try await Task.detached(priority: .utility) {
                try await LyricsTranscriber.transcribe(url: url, locales: locales, progress: report)
            }.value
            library.update(track.id) {
                $0.lyricsChecked = true
                if let lrc, !lrc.isEmpty { $0.lyrics = lrc; $0.lyricsSource = "ai" }
            }
            states[track.id] = (lrc?.isEmpty ?? true) ? .notFound : nil
        } catch {
            states[track.id] = .failed(error.localizedDescription)
        }
    }
}

nonisolated enum LyricsTranscriber {
    struct Word: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    enum Failure: LocalizedError {
        case unavailable, unsupportedLanguage, denied
        var errorDescription: String? {
            switch self {
            case .unavailable: "On-device speech recognition isn't available on this device."
            case .unsupportedLanguage: "This language isn't available for on-device recognition on this device."
            case .denied: "Speech recognition permission was denied. You can enable it in Settings."
            }
        }
    }

    /// Step 1: identify the language on a ~30 s excerpt (transcribe with each candidate model, check which
    /// transcript actually reads as that language). Step 2: transcribe the whole song with the winner.
    @concurrent
    static func transcribe(url: URL, locales: [Locale], progress: @escaping @Sendable (String) -> Void) async throws -> String? {
        var candidates = locales
        if locales.count > 1 {
            for installed in await SpeechTranscriber.installedLocales where candidates.count < 4 {
                if !candidates.contains(where: { $0.language.languageCode == installed.language.languageCode }) { candidates.append(installed) }
            }
        }
        let (excerpt, isWhole) = try makeExcerpt(url)
        defer { if !isWhole { try? FileManager.default.removeItem(at: excerpt) } }

        var best: (locale: Locale, score: Double, lrc: String)?
        var lastError: Error?
        if candidates.count > 1 { progress("Detecting language…") }
        for locale in candidates {
            do {
                guard let lrc = try await transcribe(url: excerpt, locale: locale) else { continue }
                let score = languageScore(lrc, expected: locale)
                if best == nil || score > best!.score { best = (locale, score, lrc) }
                if score >= 100 { break }
            } catch { lastError = error }
        }
        guard let winner = best else {
            if let lastError { throw lastError }
            return nil
        }
        let name = Locale.current.localizedString(forLanguageCode: winner.locale.language.languageCode?.identifier ?? "") ?? "lyrics"
        if isWhole { return winner.lrc }
        progress("Transcribing (\(name))…")
        return try await transcribe(url: url, locale: winner.locale) ?? winner.lrc
    }

    /// 100 + text length bonus when the recognised text's dominant language matches the model's language.
    private static func languageScore(_ lrc: String, expected: Locale) -> Double {
        let plain = lrc.replacingOccurrences(of: #"\[[0-9:.]+\] "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[0-9:.]+>"#, with: "", options: .regularExpression)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(plain)
        let want = expected.language.languageCode?.identifier ?? ""
        let match = recognizer.languageHypotheses(withMaximum: 5)[NLLanguage(rawValue: want)] ?? 0
        return (match > 0.8 ? 100 : match * 100) + Double(min(plain.count, 500)) / 100
    }

    /// ~30 s from a quarter into the song; the whole file if it is short.
    private static func makeExcerpt(_ url: URL, seconds: Double = 30) throws -> (URL, Bool) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let total = Double(file.length) / rate
        if total <= seconds + 15 { return (url, true) }
        file.framePosition = AVAudioFramePosition(total * 0.25 * rate)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let target = try AVAudioFile(forWriting: out, settings: file.processingFormat.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return (url, true) }
        var remaining = AVAudioFramePosition(seconds * rate)
        while remaining > 0 {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, remaining)))
            if buffer.frameLength == 0 { break }
            try target.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return (out, false)
    }

    @concurrent
    static func transcribe(url: URL, locale: Locale) async throws -> String? {
        guard SpeechTranscriber.isAvailable else { return try await transcribeLegacy(url: url, locale: locale) }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])

        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        if !installed.contains(supported.identifier(.bcp47)),
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .whileInUse))
        let collector = Task { () throws -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { words.append(Word(start: range.start.seconds, end: range.end.seconds, text: text)) }
                }
            }
            return words
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return enhancedLRC(from: try await collector.value)
    }

    private final class Once: @unchecked Sendable { var done = false }

    /// Fallback for devices/simulators without the new SpeechAnalyzer: classic on-device recognition with segment timestamps.
    @concurrent
    static func transcribeLegacy(url: URL, locale: Locale) async throws -> String? {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure.denied }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else { throw Failure.unsupportedLanguage }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let once = Once()
        let words: [Word] = try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                guard !once.done else { return }
                if let result, result.isFinal {
                    once.done = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        Word(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                    })
                } else if let error {
                    once.done = true
                    continuation.resume(throwing: error)
                }
            }
        }
        return enhancedLRC(from: words)
    }

    /// Groups recognised words into short lyric lines at natural pauses.
    static func lrc(from words: [Word]) -> String? {
        guard !words.isEmpty else { return nil }
        var lines: [(Double, String)] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first else { return }
            lines.append((first.start, current.map(\.text).joined(separator: " ")))
            current = []
        }
        for w in words {
            if let last = current.last, w.start - last.end > 0.8 || current.count >= 8 || w.end - (current.first?.start ?? w.start) > 7 { flush() }
            current.append(w)
        }
        flush()
        return lines.map { start, text in
            String(format: "[%02d:%05.2f] %@", Int(start) / 60, start.truncatingRemainder(dividingBy: 60), text)
        }.joined(separator: "\n")
    }

    /// Enhanced LRC: line times plus `<mm:ss.xx>` before every word, for word-by-word highlighting.
    static func enhancedLRC(from words: [Word]) -> String? {
        guard !words.isEmpty else { return nil }
        func stamp(_ t: Double) -> String { String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
        var out: [String] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first else { return }
            out.append("[\(stamp(first.start))] " + current.map { "<\(stamp($0.start))>\($0.text)" }.joined(separator: " "))
            current = []
        }
        for w in words {
            if let last = current.last, w.start - last.end > 0.8 || current.count >= 8 || w.end - (current.first?.start ?? w.start) > 7 { flush() }
            current.append(w)
        }
        flush()
        return out.joined(separator: "\n")
    }
}


// MARK: - LRCLIB (free, open lyrics database)

nonisolated enum LRCLib {
    private struct Hit: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
        let instrumental: Bool?
    }

    /// Synced lyrics whose recording is the same length as ours come first (a radio edit or live version would drift),
    /// then any synced lyrics close in length, and plain text only if nothing synced exists.
    @concurrent
    static func lookup(title: String, artist: String, album: String, duration: Double, syncedOnly: Bool = false) async -> String? {
        func request(_ path: String, _ items: [URLQueryItem]) -> URLRequest? {
            var c = URLComponents(string: "https://lrclib.net/api/\(path)")
            c?.queryItems = items
            guard let url = c?.url else { return nil }
            var r = URLRequest(url: url)
            r.setValue("\(Brand.name)/1.0 (iOS music player)", forHTTPHeaderField: "User-Agent")
            r.timeoutInterval = 12
            return r
        }
        var hits: [Hit] = []
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty, album != "Unknown Album" { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: "\(Int(duration.rounded()))")) }
        if let req = request("get", items), let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200, let hit = try? JSONDecoder().decode(Hit.self, from: data) {
            if hit.instrumental == true { return nil }
            hits.append(hit)
        }
        if !(hits.first.map { ($0.syncedLyrics ?? "").isEmpty == false } ?? false),
           let req = request("search", [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]),
           let (data, _) = try? await URLSession.shared.data(for: req), let found = try? JSONDecoder().decode([Hit].self, from: data) {
            hits += found.filter { $0.instrumental != true }
        }
        func gap(_ h: Hit) -> Double { duration > 0 ? abs((h.duration ?? duration) - duration) : 0 }
        let synced = hits.filter { !($0.syncedLyrics ?? "").isEmpty }.sorted { gap($0) < gap($1) }
        if let s = synced.first(where: { gap($0) <= 3 }) ?? synced.first(where: { gap($0) <= 8 }) { return s.syncedLyrics }
        if syncedOnly { return nil }
        return hits.sorted { gap($0) < gap($1) }.lazy.compactMap { h in (h.plainLyrics ?? "").isEmpty ? nil : h.plainLyrics }.first
    }
}
