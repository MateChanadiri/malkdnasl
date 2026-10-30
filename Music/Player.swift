import AVFoundation
import MediaPlayer
import Observation
import UIKit

enum RepeatMode: Int { case off, all, one }

struct QueueItem: Identifiable, Hashable {
    let id: UUID
    let trackID: UUID
    var order: Int
    init(id: UUID = UUID(), trackID: UUID, order: Int) {
        self.id = id
        self.trackID = trackID
        self.order = order
    }
}

private final class Deck {
    let node = AVAudioPlayerNode()
    /// [0] low-pass, [1] high-pass (filter sweeps), [2] low shelf (bass swap). globalGain = loudness normalization.
    let fx = AVAudioUnitEQ(numberOfBands: 3)
    let delay = AVAudioUnitDelay()
    /// Tempo adjustment for beat-matched transitions (bypassed otherwise).
    let pitch = AVAudioUnitTimePitch()
    let index: Int
    var file: AVAudioFile?
    /// The file is the vocal-free instrumental made by the karaoke model.
    var usesStem = false
    var trackID: UUID?
    /// Loudness normalization the deck is gliding to (`fx.globalGain` follows it in small steps while playing).
    var gain: Float = 0
    var startOffset = 0.0
    var duration = 0.0
    var pausedAt: Double?
    var mix: Float = 1
    init(index: Int) {
        self.index = index
        fx.bands[0].filterType = .lowPass
        fx.bands[1].filterType = .highPass
        fx.bands[2].filterType = .lowShelf
        fx.bands[2].frequency = 200
        resetFX()
        delay.wetDryMix = 0
        delay.feedback = 45
        delay.lowPassCutoff = 9000
        pitch.bypass = true
    }
    func resetFX() {
        fx.bands[0].bypass = true; fx.bands[0].frequency = 20000
        fx.bands[1].bypass = true; fx.bands[1].frequency = 20
        fx.bands[2].bypass = true; fx.bands[2].gain = 0
        delay.wetDryMix = 0
    }
}

private struct Transition {
    let out: Deck
    let inc: Deck
    let itemID: UUID
    let track: Track
    let startAt: Date
    let length: Double
    let style: TransitionStyle
    let effect: TransitionEffect
    var switched = false
}

private nonisolated struct StoredQueue: Codable {
    struct Item: Codable { var id: UUID; var trackID: UUID; var order: Int }
    var items: [Item]
    var currentIndex: Int
    var position: Double
    var title: String
    var shuffle: Bool
    var repeatMode: Int
}

@Observable
final class PlayerModel {
    // MARK: Observable state
    private(set) var queue: [QueueItem] = [] { didSet { scheduleQueueSave() } }
    private(set) var currentIndex = 0 { didSet { if currentIndex != oldValue { scheduleQueueSave() } } }
    private(set) var isPlaying = false {
        didSet {
            if isPlaying && !oldValue { startTick() }
            if !isPlaying && oldValue { idleEngine() }
        }
    }
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var shuffle = false
    private(set) var sleepEndsAt: Date?
    private(set) var sleepAtTrackEnd = false
    private(set) var sleepAtQueueEnd = false
    /// A streaming song is being fetched before it can start.
    private(set) var isBuffering = false
    private(set) var isMixing = false
    private(set) var lastError: String?
    private(set) var undoStack: [[QueueItem]] = []
    var queueTitle = "" { didSet { scheduleQueueSave() } }
    @ObservationIgnored var onTrackStarted: (Track) -> Void = { _ in }
    /// Called whenever what's playing / play state / position meaningfully changes (widgets, Live Activity).
    @ObservationIgnored var onStateChanged: () -> Void = {}
    var repeatMode: RepeatMode = .off { didSet { scheduleQueueSave() } }
    var playbackRate: Double = UserDefaults.standard.object(forKey: "rate") as? Double ?? 1 {
        didSet {
            timePitch.rate = Float(playbackRate)
            timePitch.bypass = playbackRate == 1
            UserDefaults.standard.set(playbackRate, forKey: "rate")
            updateNowPlaying()
        }
    }

    // MARK: Dependencies
    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let eq: EQModel
    @ObservationIgnored let lab: AudioLab
    @ObservationIgnored let rules: QueueRules
    @ObservationIgnored var sources: SourceManager?

    // MARK: Engine
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let mixer = AVAudioMixerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private let decks = [Deck(index: 0), Deck(index: 1)]
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var transition: Transition?
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var lastInfoUpdate = Date.distantPast
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var bufferingID: UUID?
    @ObservationIgnored private var wantsToPlay = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var recentIDs: [UUID] = []
    @ObservationIgnored private var reportedRemote: (String, String)?
    @ObservationIgnored private var spectrumUsers = 0
    /// Where the song was at the last tick, for `smoothPosition(at:)`.
    @ObservationIgnored private var clock: (position: Double, at: Date, speed: Double)?
    @ObservationIgnored private var spectrumTapped = false
    @ObservationIgnored private let automation = MixAutomation()

    var current: Track? {
        queue.indices.contains(currentIndex) ? library.trackByID[queue[currentIndex].trackID] : nil
    }
    var upcoming: [QueueItem] { currentIndex + 1 < queue.count ? Array(queue[(currentIndex + 1)...]) : [] }
    var history: [QueueItem] { currentIndex > 0 && currentIndex <= queue.count ? Array(queue[..<currentIndex]) : [] }
    var canUndo: Bool { !undoStack.isEmpty }

    init(library: LibraryStore, settings: AppSettings, eq: EQModel, lab: AudioLab = AudioLab(), rules: QueueRules = QueueRules()) {
        self.library = library
        self.settings = settings
        self.eq = eq
        self.lab = lab
        self.rules = rules

        for d in decks { engine.attach(d.node); engine.attach(d.fx); engine.attach(d.delay); engine.attach(d.pitch) }
        engine.attach(mixer)
        engine.attach(timePitch)
        engine.attach(eq.unit)
        engine.connect(mixer, to: timePitch, format: nil)
        engine.connect(timePitch, to: eq.unit, format: nil)
        lab.attach(to: engine, after: eq.unit)
        lab.onKaraokeChange = { [weak self] in self?.karaokeChanged() }
        KaraokeStems.shared.onReady = { [weak self] _ in self?.refreshKaraokeSource() }
        // Both decks are wired once, in one format: the player node converts each file's sample rate and
        // channels itself, so a new song never rewires the running engine (which is audible).
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let deckFormat = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2)
        for d in decks { connect(d, format: deckFormat) }
        timePitch.rate = Float(playbackRate)
        // At normal speed the time stretcher would only cost render time and colour the sound.
        timePitch.bypass = playbackRate == 1

        library.onTracksDeleted = { [weak self] ids in self?.removeDeleted(ids) }
        lab.onGainRulesChanged = { [weak self] in self?.applyGain() }
        lab.onRouteChanged = { [weak self] in self?.applyEQRules() }
        Self.registerRemoteCommands(self)
        observeSystem()
        restoreQueue()
        startTick()
    }

    /// 20 Hz while playing on screen. With the screen off nothing needs the position that often (transitions
    /// are scheduled on the audio clock, blends run on their own timer), and paused only the sleep timer is
    /// checked. Restarted when playback starts, so it never lags behind a resume.
    private func startTick() {
        tickTask?.cancel()
        lastTick = Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                let ms = self?.tickInterval ?? 1000
                try? await Task.sleep(for: .milliseconds(ms))
                if Task.isCancelled { return }
                self?.tick()
            }
        }
    }

    private var tickInterval: Int {
        guard isPlaying else { return 1000 }
        return UIApplication.shared.applicationState == .background ? 250 : 50
    }

    @ObservationIgnored private var lastTick = Date()

    /// `position` without observing it, for a view's first frame when only a small child view follows the position.
    var positionSnapshot: Double { _position }

    /// Playback position for frame-by-frame animation (word-by-word lyrics). `position` only changes on the
    /// 50 ms tick; this runs on from the last tick at playback speed, so a 120 Hz display gets 120 steps.
    func smoothPosition(at date: Date) -> Double {
        guard isPlaying, !isBuffering, let c = clock else { return position }
        let elapsed = date.timeIntervalSince(c.at)
        // A stale clock (paused, seeked, new song) falls back to the plain position.
        guard elapsed >= 0, elapsed < 0.25, abs(c.position - position) < 0.1 else { return position }
        return min(duration, c.position + elapsed * c.speed)
    }

    /// How long sound takes from the engine to your ears (Bluetooth adds the most). Lyrics subtract it.
    var outputLatency: Double { Self.currentOutputLatency() }

    static func currentOutputLatency() -> Double {
        let s = AVAudioSession.sharedInstance()
        return min(0.5, max(0, s.outputLatency + s.ioBufferDuration))
    }

    /// Live spectrum for the visualizer. The tap only analyses while a visualizer is on screen. It is installed
    /// before the engine first starts (see `ensureEngine`): adding a tap to the running engine glitches the sound.
    func setSpectrum(_ on: Bool) {
        spectrumUsers = max(0, spectrumUsers + (on ? 1 : -1))
        Spectrum.shared.analyzer.isActive = spectrumUsers > 0
        if on { installSpectrumTap() }
    }

    private func installSpectrumTap() {
        guard !spectrumTapped else { return }
        spectrumTapped = true
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: SpectrumAnalyzer.tapBlock(Spectrum.shared.analyzer))
    }

    /// Builds one deck's chain (once, at launch).
    private func connect(_ d: Deck, format: AVAudioFormat?) {
        engine.connect(d.node, to: d.fx, format: format)
        engine.connect(d.fx, to: d.delay, format: format)
        engine.connect(d.delay, to: d.pitch, format: format)
        engine.connect(d.pitch, to: mixer, fromBus: 0, toBus: d.index, format: format)
    }

    // MARK: - Public playback API

    func play(_ tracks: [Track], startAt: Int = 0, title: String, shuffled: Bool = false, context: LibraryEntry.Kind? = nil) {
        guard !tracks.isEmpty else { return }
        pushUndo()
        var items = tracks.enumerated().map { QueueItem(trackID: $1.id, order: $0) }
        var start = min(max(0, startAt), items.count - 1)
        if shuffled || shuffle {
            if shuffled {
                shuffle = true
                start = Int.random(in: 0..<items.count)
            }
            let first = items.remove(at: start)
            items = shuffledItems(items)
            items.insert(first, at: 0)
            start = 0
        }
        // Queue presets: "whenever I play an album, add my favourites afterwards" etc.
        let base = (items.map(\.order).max() ?? 0) + 1
        var extra: [Track] = []
        for rule in rules.matching(context) {
            extra += rules.tracks(for: rule, seed: tracks + extra, library: library, familiarity: settings.shuffleFamiliarity)
        }
        items += extra.enumerated().map { QueueItem(trackID: $1.id, order: base + $0) }
        queue = items
        queueTitle = title
        currentIndex = start
        loadCurrent(autoplay: true)
    }

    /// "Start radio": the seed song, then its artist, then everything else, shuffled.
    func startRadio(from seed: Track) {
        let others = library.tracks.filter { $0.id != seed.id }
        let sameArtist = others.filter { $0.artist == seed.artist }.shuffled()
        var rest = others.filter { $0.artist != seed.artist }
        rest = settings.smartShuffle ? SmartShuffle.order(rest, options: .init(familiarity: settings.shuffleFamiliarity)) : rest.shuffled()
        startStationQueue(seed: seed, list: sameArtist + rest, title: "\(seed.title) Radio")
    }

    /// Station from a streaming server's instant mix when possible, the local radio otherwise.
    func startStation(from seed: Track) {
        guard seed.isRemote, let rid = seed.remoteID, let client = sources?.client(for: seed.sourceID), NetworkMonitor.shared.isOnline else {
            startRadio(from: seed); return
        }
        Task {
            if let ids = try? await client.instantMix(remoteID: rid, limit: 60) {
                let byRemote = Dictionary(library.tracks.compactMap { t in t.remoteID.map { ($0, t) } }, uniquingKeysWith: { a, _ in a })
                let list = ids.compactMap { byRemote[$0] }.filter { $0.id != seed.id }
                if list.count >= 5 { startStationQueue(seed: seed, list: list, title: "\(seed.title) Station"); return }
            }
            startRadio(from: seed)
        }
    }

    /// If the seed is already playing it keeps playing (no restart); only what comes after it is replaced.
    private func startStationQueue(seed: Track, list: [Track], title: String) {
        guard !list.isEmpty else { return }
        guard current?.id == seed.id, queue.indices.contains(currentIndex) else { play([seed] + list, title: title); return }
        pushUndo()
        let cur = queue[currentIndex]
        queue = [cur] + list.enumerated().map { QueueItem(trackID: $1.id, order: cur.order + 1 + $0) }
        currentIndex = 0
        queueTitle = title
        prefetchUpcoming()
    }

    func togglePlay() {
        if current == nil { return }
        if isBuffering { wantsToPlay.toggle(); isPlaying = wantsToPlay; return }
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        if isBuffering { wantsToPlay = true; isPlaying = true; return }
        if decks[active].file == nil { loadCurrent(autoplay: true, offset: position); return }
        guard ensureEngine() else { return }
        for d in decks where d.file != nil && (d === decks[active] || transition?.switched == true) { d.node.play(); d.pausedAt = nil }
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        finishCrossfade()
        if isBuffering { wantsToPlay = false; isPlaying = false; updateNowPlaying(); return }
        let d = decks[active]
        d.pausedAt = time(of: d)
        position = d.pausedAt ?? position
        d.node.pause()
        isPlaying = false
        updateNowPlaying()
        saveQueueNow()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if let cur = current, duration > 0, position < min(30, duration * 0.5) { library.recordSkip(cur.id) }
        if let idx = nextIndex(auto: false) {
            currentIndex = idx
            loadCurrent(autoplay: true)
        } else {
            currentIndex = 0
            loadCurrent(autoplay: false)
        }
    }

    /// Back button: restarts the song after 3 seconds. `always` (swiping the mini player) goes to the previous song.
    func previous(always: Bool = false) {
        if !always && position > 3 || currentIndex == 0 && repeatMode != .all { seek(to: 0); return }
        currentIndex = currentIndex == 0 ? queue.count - 1 : currentIndex - 1
        loadCurrent(autoplay: true)
    }

    /// Ends playback and empties the queue (swiping the mini player away). The mini player, Lock Screen
    /// controls and Live Activity disappear with it; playing anything starts fresh.
    func stop() {
        guard !queue.isEmpty else { return }
        pause()
        queue = []
        currentIndex = 0
        position = 0
        duration = 0
        updateNowPlaying()
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        saveQueueNow()
    }

    /// The karaoke slider moved: start making the instrumental for this song, and use it as soon as it exists.
    private func karaokeChanged() {
        if lab.vocalCut > 0.02, let c = current { KaraokeStems.shared.prepare(c) }
        refreshKaraokeSource()
    }

    /// Swaps the playing file between the original and the instrumental, keeping the place in the song.
    func refreshKaraokeSource() {
        guard let track = current, transition == nil else { return }
        let d = decks[active]
        guard d.file != nil, d.trackID == track.id else { return }
        let instrumental = lab.vocalCut > 0.02 ? KaraokeStems.shared.url(for: track.id) : nil
        let wantStem = instrumental != nil
        if wantStem == d.usesStem { lab.stemActive = d.usesStem; return }
        guard let url = instrumental ?? MediaLocator.localURL(for: track), let file = try? AVAudioFile(forReading: url) else { return }
        let target = min(max(0, position), max(0, d.duration - 0.1))
        let wasPlaying = d.node.isPlaying
        d.file = file
        d.usesStem = wantStem
        schedule(d, from: target)
        d.pausedAt = target
        if wasPlaying, ensureEngine() { d.node.play(); d.pausedAt = nil }
        lab.stemActive = wantStem
    }

    func seek(to t: Double) {
        finishCrossfade()
        let d = decks[active]
        guard d.file != nil else { position = max(0, t); return }
        let target = min(max(0, t), max(0, d.duration - 0.1))
        let wasPlaying = isPlaying
        schedule(d, from: target)
        d.pausedAt = target
        if wasPlaying, ensureEngine() { d.node.play(); d.pausedAt = nil }
        position = target
        updateNowPlaying()
    }

    func jump(toQueueIndex i: Int) {
        guard queue.indices.contains(i) else { return }
        currentIndex = i
        loadCurrent(autoplay: true)
    }

    /// Manual transition: blend into the next song right now.
    func mixNow() {
        guard isPlaying, transition == nil, let idx = nextIndex(auto: false), idx != currentIndex else { next(); return }
        let len = max(2, settings.effectiveFadeSeconds)
        if !startTransition(to: idx, length: min(len, max(1, duration - position - 0.2)), handOverAt: nil, beatMatch: settings.effectiveBeatMatch) { next() }
    }

    // MARK: Queue editing

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty { play(tracks, title: "Queue"); return }
        pushUndo()
        let items = tracks.map { QueueItem(trackID: $0.id, order: queue[currentIndex].order) }
        queue.insert(contentsOf: items, at: currentIndex + 1)
        prefetchUpcoming()
    }

    func playAfter(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty { play(tracks, title: "Queue"); return }
        pushUndo()
        let base = (queue.map(\.order).max() ?? 0) + 1
        queue.append(contentsOf: tracks.enumerated().map { QueueItem(trackID: $1.id, order: base + $0) })
    }

    func moveUpcoming(from: IndexSet, to: Int) {
        pushUndo()
        var up = upcoming
        up.move(fromOffsets: from, toOffset: to)
        queue = Array(queue[...currentIndex]) + up
        prefetchUpcoming()
    }

    func removeUpcoming(at offsets: IndexSet) {
        pushUndo()
        var up = upcoming
        up.remove(atOffsets: offsets)
        queue = Array(queue[...currentIndex]) + up
    }

    /// Removes several queue entries (upcoming or history) at once.
    func removeItems(_ ids: Set<UUID>) {
        guard !ids.isEmpty, queue.indices.contains(currentIndex) else { return }
        pushUndo()
        let cur = queue[currentIndex]
        let before = queue.prefix(currentIndex).filter { ids.contains($0.id) }.count
        queue.removeAll { ids.contains($0.id) && $0.id != cur.id }
        currentIndex = max(0, currentIndex - before)
    }

    func clearUpcoming() {
        if !queue.isEmpty { pushUndo(); queue = Array(queue[...currentIndex]) }
    }

    func clearHistory() {
        guard currentIndex > 0 else { return }
        pushUndo()
        queue = Array(queue[currentIndex...])
        currentIndex = 0
    }

    func setShuffle(_ on: Bool) {
        shuffle = on
        guard queue.count > 1, queue.indices.contains(currentIndex) else { return }
        pushUndo()
        var up = upcoming
        if on { up = shuffledItems(up) } else { up.sort { $0.order < $1.order } }
        queue = Array(queue[...currentIndex]) + up
        prefetchUpcoming()
    }

    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    /// Restores the queue as it was before the last change, keeping the current song playing.
    func undoQueueChange() {
        guard let snapshot = undoStack.popLast(), queue.indices.contains(currentIndex) else { return }
        let cur = queue[currentIndex]
        if let i = snapshot.firstIndex(where: { $0.id == cur.id }) {
            queue = snapshot
            currentIndex = i
        } else if let i = snapshot.firstIndex(where: { $0.trackID == cur.trackID }) {
            queue = snapshot
            currentIndex = i
        } else {
            queue = [cur] + snapshot
            currentIndex = 0
        }
    }

    private func pushUndo() {
        guard !queue.isEmpty else { return }
        undoStack.append(queue)
        if undoStack.count > 30 { undoStack.removeFirst() }
    }

    private func shuffledItems(_ items: [QueueItem]) -> [QueueItem] {
        guard settings.smartShuffle else { return items.shuffled() }
        let tracks = items.compactMap { library.trackByID[$0.trackID] }
        let ordered = SmartShuffle.order(tracks, options: .init(familiarity: settings.shuffleFamiliarity, recent: Set(recentIDs)))
        var byTrack = Dictionary(grouping: items, by: \.trackID)
        var out: [QueueItem] = []
        for t in ordered { if let item = byTrack[t.id]?.popLast() { out.append(item) } }
        for rest in byTrack.values { out += rest }
        return out
    }

    private func removeDeleted(_ ids: Set<UUID>) {
        guard !queue.isEmpty else { return }
        undoStack.removeAll()
        let currentItem = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
        let removingCurrent = currentItem.map { ids.contains($0.trackID) } ?? false
        let before = queue.prefix(currentIndex).filter { ids.contains($0.trackID) }.count
        queue.removeAll { ids.contains($0.trackID) }
        if removingCurrent {
            stopDecks()
            isPlaying = false
            currentIndex = min(max(0, currentIndex - before), max(0, queue.count - 1))
            if queue.isEmpty { position = 0; duration = 0; updateNowPlaying() } else { loadCurrent(autoplay: false) }
        } else {
            currentIndex = max(0, currentIndex - before)
        }
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepAtTrackEnd = false
        sleepAtQueueEnd = false
        sleepEndsAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        restoreVolume()
    }

    func setSleepAtTrackEnd() {
        sleepEndsAt = nil
        sleepAtQueueEnd = false
        sleepAtTrackEnd = true
    }

    /// Stops when the album / playlist / queue is finished (no continuation).
    func setSleepAtQueueEnd() {
        sleepEndsAt = nil
        sleepAtTrackEnd = false
        sleepAtQueueEnd = true
    }

    var sleepActive: Bool { sleepEndsAt != nil || sleepAtTrackEnd || sleepAtQueueEnd }

    private var onLastItem: Bool { currentIndex + 1 >= queue.count && repeatMode != .all }

    /// Volume factor for the sleep fade: 1 normally, ramping to 0 over the last `sleepFadeSeconds`.
    private func sleepFactor() -> Float {
        let fade = settings.sleepFadeSeconds
        guard fade > 0 else { return 1 }
        var remaining: Double?
        if let end = sleepEndsAt { remaining = end.timeIntervalSinceNow }
        else if sleepAtTrackEnd || (sleepAtQueueEnd && onLastItem) { remaining = (duration - position) / max(0.25, playbackRate) }
        guard let r = remaining, r < fade else { return 1 }
        return Float(max(0, min(1, r / fade)))
    }

    private func stopForSleep() {
        sleepEndsAt = nil
        sleepAtTrackEnd = false
        sleepAtQueueEnd = false
        pause()
        restoreVolume()
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    // MARK: - Loading

    private func loadCurrent(autoplay: Bool, offset: Double = 0) {
        finishCrossfade()
        bufferingID = nil
        isBuffering = false
        guard let track = current else { stopDecks(); isPlaying = false; return }
        let deck = decks[active]
        var attempts = 0
        var candidate = track
        while true {
            if candidate.isRemote, !MediaLocator.isPlayableNow(candidate), canStream(candidate) {
                startBuffering(candidate, autoplay: autoplay, offset: offset)
                return
            }
            if load(candidate, into: deck, at: startOffset(for: candidate, requested: offset)) { break }
            if candidate.isRemote, !canStream(candidate) {
                let why = settings.offlineMode ? "Offline mode is on." : !NetworkMonitor.shared.isOnline ? "You're offline."
                    : "its extension isn't installed or is switched off (source: \(candidate.sourceID ?? "none"))."
                lastError = "Can't stream “\(candidate.title)”: \(why)"
            } else {
                lastError = "Couldn't play “\(candidate.title)”: the file isn't readable audio."
            }
            // A streamed song that fails stops here, and the cached copy goes so the next try starts clean. Only local files are skipped.
            if candidate.isRemote { StreamCache.remove(candidate.id); isPlaying = false; return }
            attempts += 1
            guard attempts < queue.count, let idx = nextIndex(auto: false, mutating: false) else {
                isPlaying = false; return
            }
            currentIndex = idx
            guard let t = current else { return }
            candidate = t
        }
        started(autoplay: autoplay, deck: deck)
    }

    private func started(autoplay: Bool, deck: Deck) {
        scrobbled = false
        lab.stemActive = deck.usesStem
        if let c = current { KaraokeStems.shared.prepare(c) }
        if autoplay, let played = current { trackDidStart(played) }
        duration = deck.duration
        position = deck.startOffset
        deck.pausedAt = deck.startOffset
        restoreVolume()
        applyEQRules()
        if autoplay, ensureEngine() {
            deck.node.play()
            deck.pausedAt = nil
            isPlaying = true
        } else {
            isPlaying = false
        }
        updateNowPlaying(force: true)
        prefetchUpcoming()
    }

    private func trackDidStart(_ t: Track) {
        library.recordPlay(t.id)
        onTrackStarted(t)
        recentIDs.append(t.id)
        if recentIDs.count > 50 { recentIDs.removeFirst() }
        reportRemote(t)
    }

    private func reportRemote(_ t: Track) {
        if let (source, rid) = reportedRemote, let client = sources?.client(for: source) {
            let pos = position
            Task { await client.reportPlayback(remoteID: rid, started: false, positionSeconds: pos) }
            reportedRemote = nil
        }
        guard t.isRemote, let rid = t.remoteID, let source = t.sourceID, let client = sources?.client(for: source) else { return }
        reportedRemote = (source, rid)
        Task { await client.reportPlayback(remoteID: rid, started: true, positionSeconds: 0) }
    }

    private func canStream(_ t: Track) -> Bool {
        !settings.offlineMode && NetworkMonitor.shared.isOnline && StreamLoader.shared.canStream(t)
    }

    private func startBuffering(_ track: Track, autoplay: Bool, offset: Double) {
        stopDecks()
        isBuffering = true
        bufferingID = track.id
        wantsToPlay = autoplay
        isPlaying = autoplay
        duration = track.duration
        position = offset
        lastError = nil
        updateNowPlaying(force: true)
        Task {
            do {
                do { _ = try await StreamLoader.shared.fetch(track) }
                catch {
                    // One quiet retry with a fresh link: stream links can be one-shot or the first request can time out.
                    guard bufferingID == track.id else { return }
                    try await Task.sleep(for: .milliseconds(600))
                    _ = try await StreamLoader.shared.fetch(track)
                }
                guard bufferingID == track.id, current?.id == track.id else { return }
                let play = wantsToPlay
                isBuffering = false
                bufferingID = nil
                loadCurrent(autoplay: play, offset: offset)
            } catch {
                guard bufferingID == track.id else { return }
                isBuffering = false
                bufferingID = nil
                lastError = "Couldn't load “\(track.title)”: \(error.localizedDescription)"
                // No jumping to the next song: a failing song stops and says why.
                isPlaying = false
                updateNowPlaying()
            }
        }
    }

    private func prefetchUpcoming() {
        let next = queue.dropFirst(currentIndex + 1).prefix(2).compactMap { library.trackByID[$0.trackID] }
        var keep = Set(queue.prefix(currentIndex + 4).map(\.trackID))
        if let c = current { keep.insert(c.id) }
        StreamLoader.shared.prefetch(next, keep: keep)
    }

    private func startOffset(for track: Track, requested: Double) -> Double {
        guard requested == 0, settings.skipSilence || settings.effectiveSmartTransitions, let lead = track.leadIn, lead > 0.3 else { return requested }
        return lead
    }

    private func load(_ track: Track, into deck: Deck, at offset: Double) -> Bool {
        var source = MediaLocator.localURL(for: track)
        var stem = false
        if lab.vocalCut > 0.02, let instrumental = KaraokeStems.shared.url(for: track.id) { source = instrumental; stem = true }
        guard let url = source, let file = try? AVAudioFile(forReading: url) else { return false }
        deck.usesStem = stem
        deck.node.stop()
        deck.node.volume = 1
        deck.mix = 1
        deck.resetFX()
        deck.pitch.rate = 1
        deck.pitch.bypass = true
        deck.file = file
        deck.trackID = track.id
        deck.duration = Double(file.length) / file.processingFormat.sampleRate
        deck.gain = lab.normalizationGain(for: track)
        deck.fx.globalGain = deck.gain
        schedule(deck, from: offset)
        return true
    }

    private func schedule(_ deck: Deck, from offset: Double) {
        guard let file = deck.file else { return }
        let sr = file.processingFormat.sampleRate
        deck.node.stop()
        let start = AVAudioFramePosition(max(0, min(offset, deck.duration - 0.1)) * sr)
        let frames = AVAudioFrameCount(max(0, file.length - start))
        deck.startOffset = Double(start) / sr
        guard frames > 0 else { return }
        deck.node.scheduleSegment(file, startingFrame: start, frameCount: frames, at: nil)
    }

    private func stopDecks() {
        finishCrossfade()
        for d in decks { d.node.stop(); d.file = nil; d.trackID = nil }
    }

    /// Nothing is playing: stop the engine rendering silence. iOS counts a running engine as audio playing, so
    /// the Lock Screen and Control Center kept showing "playing" after a pause (and it costs battery).
    /// The paused decks keep their place; `ensureEngine` starts the engine again and playback continues there.
    private func idleEngine() {
        guard engine.isRunning, !decks.contains(where: { $0.node.isPlaying }) else { return }
        engine.pause()
    }

    @discardableResult
    private func ensureEngine() -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .default { try? session.setCategory(.playback, mode: .default) }
        try? session.setActive(true)
        if !engine.isRunning {
            installSpectrumTap()
            engine.prepare()
            do { try engine.start() } catch { return false }
        }
        return true
    }

    /// Where the deck is in its song at the engine's last render cycle, and that cycle's host time.
    /// Start times computed from this pair are on the audio clock itself, not on the 50 ms tick.
    private func renderAnchor(_ deck: Deck) -> (position: Double, host: UInt64)? {
        guard deck.node.isPlaying, let nt = deck.node.lastRenderTime, nt.isHostTimeValid,
              let pt = deck.node.playerTime(forNodeTime: nt), pt.sampleRate > 0 else { return nil }
        return (min(deck.duration, deck.startOffset + max(0, Double(pt.sampleTime) / pt.sampleRate)), nt.hostTime)
    }

    private func time(of deck: Deck) -> Double {
        guard deck.node.isPlaying, let nt = deck.node.lastRenderTime, let pt = deck.node.playerTime(forNodeTime: nt), pt.sampleRate > 0
        else { return deck.pausedAt ?? deck.startOffset }
        return min(deck.duration, deck.startOffset + max(0, Double(pt.sampleTime) / pt.sampleRate))
    }

    // MARK: EQ + loudness per song

    func applyEQRules() {
        let o = lab.eqOverride(for: current, eq: eq)
        if o?.name != eq.override?.name || o?.gains != eq.override?.gains { eq.override = o }
    }

    /// A song measured while it plays (or a changed loudness setting) glides to its new level in the tick;
    /// setting it at once would be an audible jump in the middle of the song.
    private func applyGain() {
        for d in decks {
            guard let id = d.trackID, let t = library.trackByID[id] else { continue }
            d.gain = lab.normalizationGain(for: t)
            if !d.node.isPlaying { d.fx.globalGain = d.gain }
        }
    }

    /// Analysis finished for a song that is loaded right now: pick up its loudness immediately.
    func trackAnalyzed(_ id: UUID) {
        if decks.contains(where: { $0.trackID == id }) { applyGain() }
    }

    // MARK: - Next index / continuous playback

    private func nextIndex(auto: Bool, mutating: Bool = true) -> Int? {
        if auto && repeatMode == .one { return currentIndex }
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if repeatMode == .all, !queue.isEmpty { return 0 }
        if sleepAtQueueEnd { return nil }
        if settings.continuousPlayback, settings.continuationMode == .repeatQueue, !queue.isEmpty { return 0 }
        if settings.continuousPlayback, mutating, refillQueue(), currentIndex + 1 < queue.count { return currentIndex + 1 }
        return nil
    }

    private func available(_ t: Track) -> Bool {
        t.isOffline || (!settings.offlineMode && NetworkMonitor.shared.isOnline)
    }

    /// Appends songs so playback can go on ("continuous playback"), according to the chosen continuation mode.
    private func refillQueue() -> Bool {
        let inQueue = Set(queue.map(\.trackID))
        let all = library.tracks.filter(available)
        guard !all.isEmpty else { return false }
        let lastTrack = queue.last.flatMap { library.trackByID[$0.trackID] }
        var add: [Track] = []

        func continueInOrder(_ list: [Track], wrapTo: [Track]?) -> [Track] {
            let ordered = SmartShuffle.libraryOrder(list)
            let start = lastTrack.flatMap { lt in ordered.firstIndex { $0.id == lt.id } }.map { $0 + 1 } ?? 0
            var out = Array(ordered[min(start, ordered.count)...].prefix(15))
            if out.isEmpty, let wrap = wrapTo { out = Array(SmartShuffle.libraryOrder(wrap).prefix(15)) }
            return out
        }

        switch settings.continuationMode {
        case .stop: return false
        case .repeatQueue: return false
        case .continueLibrary: add = continueInOrder(all, wrapTo: nil)
        case .continueDownloads: add = continueInOrder(all.filter(\.isOffline), wrapTo: all.filter(\.isOffline))
        case .startOver: add = continueInOrder(all, wrapTo: all.filter(\.isOffline))
        case .continueFavorites:
            var favs = all.filter { $0.isFavorite && !inQueue.contains($0.id) }
            if favs.isEmpty { favs = all.filter(\.isFavorite) }
            add = Array(favs.shuffled().prefix(15))
        case .continuePlaylist:
            let list = library.playlists.first { $0.id.uuidString == settings.continuationPlaylist }.map { library.tracks(for: $0.trackIDs) } ?? []
            add = list.filter(available)
        case .shuffleLibrary:
            var pool = all.filter { !inQueue.contains($0.id) }
            if pool.isEmpty { pool = all }
            add = Array(pool.shuffled().prefix(15))
        case .smartShuffle:
            var pool = all.filter { !inQueue.contains($0.id) }
            if pool.isEmpty { pool = all }
            add = Array(SmartShuffle.order(pool, options: .init(familiarity: settings.shuffleFamiliarity, recent: Set(recentIDs))).prefix(15))
        }
        guard !add.isEmpty else { return false }
        let base = (queue.map(\.order).max() ?? 0) + 1
        queue.append(contentsOf: add.enumerated().map { QueueItem(trackID: $1.id, order: base + $0) })
        return true
    }

    // MARK: - Tick

    private func tick() {
        guard current != nil, decks[active].file != nil else { return }

        if let sleepEnd = sleepEndsAt, sleepEnd.timeIntervalSinceNow <= 0 {
            stopForSleep()
            return
        }

        guard isPlaying else { return }
        let deck = decks[active]
        let now = time(of: deck)
        if abs(now - position) > 0.02 { position = now }
        clock = (now, Date(), max(0.25, playbackRate) * Double(deck.pitch.bypass ? 1 : deck.pitch.rate))

        if var tr = transition {
            let date = Date()
            if !tr.switched, date >= tr.startAt {
                if !performSwitch(&tr) { cancelTransition(); return }
            }
            if tr.switched {
                let p = tr.length <= 0.01 ? 1 : min(1, date.timeIntervalSince(tr.startAt) / tr.length)
                // Real blends are drawn by `automation` on its own clock; only a hard cut is set here.
                if !automation.isRunning { applyMix(tr, progress: p) }
                transition = tr
                if p >= 1 { finishCrossfade() }
            } else {
                transition = tr
            }
        } else {
            considerTransition(deck: deck, now: now)
        }

        // After a beat-matched blend, glide the tempo back to normal (at the same speed whatever the tick rate).
        let tickNow = Date()
        let steps = Float(min(10, max(0, tickNow.timeIntervalSince(lastTick) / 0.05)))
        lastTick = tickNow
        let a = decks[active]
        if transition == nil, !a.pitch.bypass, abs(a.pitch.rate - 1) > 0.0005 {
            a.pitch.rate += (1 - a.pitch.rate) * (1 - pow(0.98, steps))
        }

        let factor = sleepFactor()
        automation.sleepFactor = factor
        // During a blend the automation owns the volumes of both decks.
        if !automation.isRunning {
            for d in decks where d.file != nil { d.node.volume = d.mix * factor }
        }
        for d in decks where d.file != nil {
            let diff = d.gain - d.fx.globalGain
            if abs(diff) > 0.01 { d.fx.globalGain += max(-0.25 * steps, min(0.25 * steps, diff)) }
        }

        let endPoint = settings.skipSilence ? min(deck.duration, (library.trackByID[deck.trackID ?? UUID()]?.trailEnd).map { $0 + 0.4 } ?? deck.duration) : deck.duration
        if transition == nil, now >= endPoint - 0.03 { trackEnded() }

        if !scrobbled, settings.listenBrainzEnabled, !settings.listenBrainzToken.isEmpty, let t = current,
           now > min(t.duration / 2, 240) {
            scrobbled = true
            let token = settings.listenBrainzToken
            let listened = Int(Date().timeIntervalSince1970 - now)
            Task { await ListenBrainz.submit(token: token, title: t.title, artist: t.artist, album: t.album, listenedAt: listened) }
        }

        if Date().timeIntervalSince(lastInfoUpdate) > 5 { updateNowPlaying() }
    }

    /// Starts a crossfade / gapless hand-over when the current song is about to end.
    private func considerTransition(deck: Deck, now: Double) {
        guard let track = current, repeatMode != .one, !sleepAtTrackEnd, !(sleepAtQueueEnd && onLastItem) else { return }
        let speed = max(0.25, playbackRate) * Double(deck.pitch.bypass ? 1 : deck.pitch.rate)
        let smart = settings.effectiveSmartTransitions
        let end = smart || settings.skipSilence ? min(deck.duration, (track.trailEnd ?? deck.duration) + 0.2) : deck.duration

        if settings.effectiveCrossfade {
            var len = settings.effectiveFadeSeconds
            if smart, let outro = track.outroStart, outro < end {
                len = max(len * 0.5, min(len * 1.6, end - outro))
            }
            guard len > 0, deck.duration > len * 2 + 1, end - now <= len else { return }
            guard let idx = peekNext(), let next = library.trackByID[queue[idx].trackID], MediaLocator.isPlayableNow(next) else { return }
            _ = startTransition(to: idx, length: max(0.5, min(len, end - now)), handOverAt: nil, beatMatch: settings.effectiveBeatMatch)
        } else if settings.gapless {
            // Scheduled well ahead on the audio clock, so a busy main thread can't make the hand-over late.
            let remaining = (end - now) / speed
            guard remaining <= 1.5, remaining > 0.02 else { return }
            guard let idx = peekNext(), let next = library.trackByID[queue[idx].trackID], MediaLocator.isPlayableNow(next) else { return }
            _ = startTransition(to: idx, length: 0, handOverAt: end, beatMatch: false)
        }
    }

    /// Next index for an automatic hand-over (may refill the queue once).
    private func peekNext() -> Int? {
        guard let idx = nextIndex(auto: true), idx != currentIndex, queue.indices.contains(idx) else { return nil }
        return idx
    }

    private func trackEnded() {
        if sleepAtTrackEnd || (sleepAtQueueEnd && onLastItem) {
            if let idx = nextIndex(auto: true, mutating: false) { currentIndex = idx } else { currentIndex = 0 }
            loadCurrent(autoplay: false)
            stopForSleep()
            return
        }
        if let idx = nextIndex(auto: true) {
            currentIndex = idx
            loadCurrent(autoplay: true)
        } else {
            currentIndex = 0
            loadCurrent(autoplay: false)
        }
    }

    // MARK: - Transitions (crossfade, gapless, beat matching, effects)

    /// `handOverAt`: the moment in the current song (seconds) where the next one starts; nil starts it now.
    @discardableResult
    private func startTransition(to idx: Int, length: Double, handOverAt: Double?, beatMatch: Bool) -> Bool {
        guard queue.indices.contains(idx), let track = library.trackByID[queue[idx].trackID], ensureEngine() else { return false }
        let out = decks[active]
        let inc = decks[1 - active]
        let outTrack = current
        let anchor = renderAnchor(out)
        let outSpeed = max(0.25, playbackRate) * Double(out.pitch.bypass ? 1 : out.pitch.rate)
        /// Host time at which the song reaches `t`, measured from the same render cycle as the position.
        func hostTime(at t: Double) -> UInt64 {
            let pos = anchor?.position ?? time(of: out)
            let base = anchor?.host ?? mach_absolute_time()
            return base + AVAudioTime.hostTime(forSeconds: max(0, t - pos) / outSpeed)
        }

        var startHost = handOverAt.map(hostTime(at:))
        var offset = startOffset(for: track, requested: 0)
        var rate: Float = 1
        if beatMatch, let bo = outTrack?.bpm, let bi = track.bpm, bo > 0, bi > 0 {
            // Compare at the closest octave (half / double time).
            let candidates = [bi, bi * 2, bi / 2]
            let target = candidates.min { abs($0 - bo) < abs($1 - bo) } ?? bi
            let ratio = bo / target
            if abs(ratio - 1) <= 0.08 {
                rate = Float(ratio)
                let period = 60 / bo
                let ob = outTrack?.beatOffset ?? 0
                let pos = anchor?.position ?? time(of: out)
                let k = ((pos + 0.12 - ob) / period).rounded(.up)
                let nextBeat = ob + k * period
                startHost = hostTime(at: nextBeat)
                if let ib = track.beatOffset { offset = ib }
            }
        }

        guard load(track, into: inc, at: offset) else { return false }
        if rate != 1 { inc.pitch.bypass = false; inc.pitch.rate = rate }
        let style: TransitionStyle = length <= 0.01 ? .cut : settings.transitionStyle
        let effect: TransitionEffect = length <= 0.01 ? .none : settings.effectiveEffect
        inc.mix = style == .cut ? (length <= 0.01 ? 1 : 0) : 0
        inc.node.volume = inc.mix
        if effect == .filterSweep { inc.fx.bands[0].bypass = false; inc.fx.bands[0].frequency = 350 }
        if effect == .bassSwap { inc.fx.bands[2].bypass = false; inc.fx.bands[2].gain = -24 }
        if effect == .echoOut, let bpm = outTrack?.bpm { out.delay.delayTime = min(2, 60 / bpm * 0.75) } else { out.delay.delayTime = 0.375 }

        let nowHost = mach_absolute_time()
        let startDelay = startHost.map { $0 > nowHost ? AVAudioTime.seconds(forHostTime: $0 - nowHost) : 0 } ?? 0
        if let startHost, startDelay > 0.005 {
            inc.node.play(at: AVAudioTime(hostTime: startHost))
        } else {
            inc.node.play()
        }
        inc.pausedAt = nil
        transition = Transition(out: out, inc: inc, itemID: queue[idx].id, track: track,
                                startAt: Date().addingTimeInterval(startDelay), length: length, style: style, effect: effect)
        if length > 0.01, let tr = transition { automation.start(mixPlan(tr)) }
        if startDelay <= 0.005, var tr = transition {
            if performSwitch(&tr) { transition = tr } else { cancelTransition(); return false }
        }
        return true
    }

    /// The moment the incoming song becomes "the" song.
    private func performSwitch(_ tr: inout Transition) -> Bool {
        guard let idx = queue.firstIndex(where: { $0.id == tr.itemID }) else { return false }
        tr.switched = true
        currentIndex = idx
        trackDidStart(tr.track)
        active = tr.inc.index
        duration = tr.inc.duration
        position = tr.inc.startOffset
        scrobbled = false
        isMixing = tr.length > 0.01
        applyEQRules()
        updateNowPlaying(force: true)
        prefetchUpcoming()
        return true
    }

    private func applyMix(_ tr: Transition, progress p: Double) {
        let (o, i) = MixAutomation.levels(tr.style, p)
        tr.out.mix = o
        tr.inc.mix = i
        MixAutomation.applyEffect(tr.effect, p, out: (tr.out.fx, tr.out.delay), inc: tr.inc.fx)
    }

    private func mixPlan(_ tr: Transition) -> MixAutomation.Plan {
        MixAutomation.Plan(out: tr.out.node, outFX: tr.out.fx, outDelay: tr.out.delay, inc: tr.inc.node, incFX: tr.inc.fx,
                           startAt: tr.startAt, length: tr.length, style: tr.style, effect: tr.effect)
    }

    private func cancelTransition() {
        guard let tr = transition else { return }
        automation.stop()
        tr.inc.node.stop()
        tr.inc.file = nil
        tr.inc.trackID = nil
        tr.out.mix = 1
        tr.out.resetFX()
        transition = nil
        isMixing = false
    }

    private func finishCrossfade() {
        guard let tr = transition else { return }
        guard tr.switched else { cancelTransition(); return }
        automation.stop()
        tr.out.node.stop()
        tr.out.file = nil
        tr.out.trackID = nil
        tr.out.mix = 1
        tr.out.node.volume = 1
        tr.out.resetFX()
        tr.inc.mix = 1
        tr.inc.node.volume = 1
        tr.inc.resetFX()
        transition = nil
        isMixing = false
    }

    private func restoreVolume() {
        for d in decks where transition == nil { d.mix = 1; d.node.volume = 1 }
    }

    // MARK: - Queue persistence

    private func scheduleQueueSave() {
        guard !restoring else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            self?.saveQueueNow()
        }
    }

    func saveQueueNow(sync: Bool = false) {
        let stored = StoredQueue(items: queue.map { .init(id: $0.id, trackID: $0.trackID, order: $0.order) },
                                 currentIndex: currentIndex, position: position, title: queueTitle,
                                 shuffle: shuffle, repeatMode: repeatMode.rawValue)
        let write: @Sendable () -> Void = {
            if let data = try? JSONEncoder().encode(stored) { try? data.write(to: Paths.queueFile, options: .atomic) }
        }
        if sync { write() } else { Task.detached(priority: .utility) { write() } }
    }

    /// The app was swiped away in the App Switcher: stop for real and leave no player behind
    /// on the Lock Screen or in Control Center. The queue is kept for the next launch.
    func shutdown() {
        if isPlaying { pause() }
        saveQueueNow(sync: true)
        tickTask?.cancel()
        for d in decks { d.node.stop() }
        engine.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restoreQueue() {
        guard let data = try? Data(contentsOf: Paths.queueFile), let s = try? JSONDecoder().decode(StoredQueue.self, from: data) else { return }
        restoring = true
        defer { restoring = false }
        let items = s.items.filter { library.trackByID[$0.trackID] != nil }.map { QueueItem(id: $0.id, trackID: $0.trackID, order: $0.order) }
        guard !items.isEmpty else { return }
        queue = items
        currentIndex = min(max(0, s.currentIndex), items.count - 1)
        queueTitle = s.title
        shuffle = s.shuffle
        repeatMode = RepeatMode(rawValue: s.repeatMode) ?? .off
        position = s.position
        duration = current?.duration ?? 0
        updateNowPlaying(force: true)
    }

    // MARK: - System integration

    private func observeSystem() {
        let session = AVAudioSession.sharedInstance()
        observers.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification, object: session) {
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
                if type == .began { self?.pause() } else if type == .ended, opts?.contains(.shouldResume) == true { self?.resume() }
            }
        })
        observers.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification, object: session) {
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: nil) {
                // Several of these arrive back to back while a route switches; recover once, after they settle.
                try? await Task.sleep(for: .milliseconds(250))
                self?.recoverEngine()
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.saveQueueNow()
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                self?.refreshNowPlaying()
            }
        })
    }

    private func recoverEngine() {
        guard current != nil, decks[active].file != nil else { return }
        // Opening the AirPlay picker (or a route change) posts this even when nothing broke: if the engine
        // is still rendering, reloading the song would only make it stutter.
        if engine.isRunning && (!isPlaying || decks[active].node.isPlaying) { return }
        let wasPlaying = isPlaying
        let pos = isPlaying ? time(of: decks[active]) : position
        loadCurrent(autoplay: false, offset: pos)
        if wasPlaying { resume() }
    }

    /// Re-sends the Now Playing info, e.g. after the Lock Screen artwork style changed.
    func refreshNowPlaying() {
        // iOS may have cached an unsuccessful asset request. A fresh object gives it another
        // chance, including while playback is paused and there are no periodic info updates.
        NowPlayingArtwork.shared.invalidateFullscreen()
        updateNowPlaying()
    }

    private func updateNowPlaying(force: Bool = false) {
        lastInfoUpdate = Date()
        defer { onStateChanged() }
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isBuffering ? playbackRate : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count
        ]
        if let g = t.genre { info[MPMediaItemPropertyGenre] = g }
        if let art = NowPlayingArtwork.shared.square(for: t) { info[MPMediaItemPropertyArtwork] = art }
        if let tall = NowPlayingArtwork.shared.fullscreen(for: t, settings: settings) { info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = tall }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        let c = MPRemoteCommandCenter.shared()
        c.likeCommand.isActive = t.isFavorite
        c.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        c.changeRepeatModeCommand.currentRepeatType = repeatMode == .one ? .one : repeatMode == .all ? .all : .off
    }

    nonisolated private static func registerRemoteCommands(_ player: PlayerModel) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in Task { @MainActor in player.resume() }; return .success }
        c.pauseCommand.addTarget { _ in Task { @MainActor in player.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in player.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { _ in Task { @MainActor in player.next() }; return .success }
        c.previousTrackCommand.addTarget { _ in Task { @MainActor in player.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            let t = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in player.seek(to: t) }
            return .success
        }
        c.likeCommand.localizedTitle = "Favorite"
        c.likeCommand.addTarget { _ in
            Task { @MainActor in if let t = player.current { player.library.toggleFavorite(t); player.updateNowPlaying() } }
            return .success
        }
        c.changeShuffleModeCommand.addTarget { event in
            let on = (event as? MPChangeShuffleModeCommandEvent)?.shuffleType != .off
            Task { @MainActor in player.setShuffle(on) }
            return .success
        }
        c.changeRepeatModeCommand.addTarget { event in
            let type = (event as? MPChangeRepeatModeCommandEvent)?.repeatType ?? .off
            Task { @MainActor in player.repeatMode = type == .one ? .one : type == .all ? .all : .off }
            return .success
        }
    }
}

// MARK: - ListenBrainz

nonisolated enum ListenBrainz {
    @concurrent
    static func submit(token: String, title: String, artist: String, album: String, listenedAt: Int) async {
        guard let url = URL(string: "https://api.listenbrainz.org/1/submit-listens") else { return }
        let body: [String: Any] = [
            "listen_type": "single",
            "payload": [[
                "listened_at": listenedAt,
                "track_metadata": ["artist_name": artist, "track_name": title, "release_name": album]
            ]]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Blend automation

/// Draws a crossfade's volume and effect curves on its own high-priority clock (every 10 ms). Driven from the
/// main thread's 50 ms tick, a blend stalled and then jumped whenever the UI was busy (opening the player,
/// scrolling, applying a theme …); here it stays smooth, in finer steps.
nonisolated final class MixAutomation: @unchecked Sendable {
    struct Plan: @unchecked Sendable {
        let out: AVAudioPlayerNode
        let outFX: AVAudioUnitEQ
        let outDelay: AVAudioUnitDelay
        let inc: AVAudioPlayerNode
        let incFX: AVAudioUnitEQ
        let startAt: Date
        let length: Double
        let style: TransitionStyle
        let effect: TransitionEffect
    }

    private let queue = DispatchQueue(label: "com.local.music.mix", qos: .userInteractive)
    /// Held while a step writes, so nothing is written to the decks once `stop()` returned.
    private let lock = NSLock()
    private var plan: Plan?
    private var timer: DispatchSourceTimer?
    private var factor: Float = 1

    var isRunning: Bool { lock.withLock { plan != nil } }
    /// The sleep timer's fade, applied on top of the blend.
    var sleepFactor: Float {
        get { lock.withLock { factor } }
        set { lock.withLock { factor = newValue } }
    }

    func start(_ plan: Plan) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.step() }
        lock.withLock {
            timer?.cancel()
            self.plan = plan
            timer = t
        }
        step()
        t.resume()
    }

    func stop() {
        lock.withLock {
            plan = nil
            timer?.cancel()
            timer = nil
        }
    }

    private func step() {
        lock.lock()
        defer { lock.unlock() }
        guard let plan else { return }
        let p = plan.length <= 0.01 ? 1 : max(0, min(1, Date().timeIntervalSince(plan.startAt) / plan.length))
        let (o, i) = Self.levels(plan.style, p)
        plan.out.volume = o * factor
        plan.inc.volume = i * factor
        Self.applyEffect(plan.effect, p, out: (plan.outFX, plan.outDelay), inc: plan.incFX)
    }

    /// Volume of the outgoing and the incoming song at blend progress `p` (0…1).
    static func levels(_ style: TransitionStyle, _ p: Double) -> (Float, Float) {
        let o: Double, i: Double
        switch style {
        case .equalPower: o = cos(p * .pi / 2); i = sin(p * .pi / 2)
        case .linear: o = 1 - p; i = p
        case .fadeOutIn: o = max(0, 1 - 2 * p); i = max(0, 2 * p - 1)
        case .cut: o = p < 0.5 ? 1 : 0; i = p < 0.5 ? 0 : 1
        }
        return (Float(o), Float(i))
    }

    static func applyEffect(_ effect: TransitionEffect, _ p: Double, out: (fx: AVAudioUnitEQ, delay: AVAudioUnitDelay), inc: AVAudioUnitEQ) {
        switch effect {
        case .none: break
        case .filterSweep:
            out.fx.bands[1].bypass = false
            out.fx.bands[1].frequency = Float(20 * pow(120, p))              // 20 Hz → 2.4 kHz
            inc.bands[0].frequency = Float(350 * pow(57, min(1, p * 1.25)))  // 350 Hz → 20 kHz
        case .bassSwap:
            let s = max(0, min(1, (p - 0.42) / 0.16))
            out.fx.bands[2].bypass = false
            out.fx.bands[2].gain = Float(-24 * s)
            inc.bands[2].gain = Float(-24 * (1 - s))
        case .echoOut:
            out.delay.wetDryMix = Float(min(60, p * 90))
        }
    }
}
