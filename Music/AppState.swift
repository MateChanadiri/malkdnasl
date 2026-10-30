import SwiftUI
import AVFoundation
import Observation

// MARK: - Router

extension EnvironmentValues {
    /// True inside the Settings sheet, where screens hide their own Settings button.
    @Entry var inSettings = false
}

enum AppTab: Hashable { case home, library, studio, files, search, custom(String) }

enum Route: Hashable {
    case songs, playlists, artists, albums
    case playlist(UUID)
    case artist(String)
    case album(String)
    case equalizer
    case metadata
    case files
    case studio
    case audioLab
    case trackMix
    case downloads
    case favorites
    case radio
    case recentlyPlayed
    case sources
    case organize
    case queueRules
    case feed(FeedItem)
}

@Observable
final class Router {
    var tab: AppTab = .home
    var libraryPath: [Route] = []
    var showPlayer = false
    /// Opens the player straight into its edit mode (Customize ▸ Music Player).
    var editPlayerOnOpen = false
    var showSettings = false
    /// Settings opens straight on Customize › Colors (from the welcome screens).
    var openColors = false
    var importKind: ImportKind?
    var showImporter = false
    var searchActive = false
    var showAdd = false
    var collapsed = false
    var searchText = ""
    /// Navigation paths of tabs other than Library (custom tab layouts).
    var paths: [String: [Route]] = [:]
    var showFullLyrics = false
    var showSongListImport = false
    var showOnboarding = false
    var showGoodbye = false
    /// Add Music opens straight on the server step (from the welcome flow).
    var addMusicAtServer = false
    var moduleInstall: ModuleInstallPrompt?

    func startSongListImport() {
        showAdd = false
        showSettings = false
        showOnboarding = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            showSongListImport = true
        }
    }
    var showThemes = false
    /// Set by the custom tab layout; `open(_:)` falls back to the current tab when Library is hidden.
    @ObservationIgnored var hasLibraryTab = true

    func closeSearch() {
        searchActive = false
        collapsed = false
        searchText = ""
    }

    /// Pushes onto the stack the user is already in (so Back returns there); starts a fresh stack when switching tabs.
    func open(_ route: Route) {
        showPlayer = false
        showSettings = false
        if searchActive { closeSearch() }
        func push(_ path: inout [Route]) {
            if path.last != route { path.append(route) }
        }
        if hasLibraryTab || tab == .library {
            if tab == .library { push(&libraryPath) } else { tab = .library; libraryPath = [route] }
        } else {
            push(&paths[tabKey(tab), default: []])
        }
    }

    /// The one "Add Music" flow; closes whatever sheet is up first.
    func openAddMusic(atServer: Bool = false) {
        let wait = showSettings || showPlayer || showOnboarding
        showSettings = false
        showPlayer = false
        showOnboarding = false
        addMusicAtServer = atServer
        Task {
            if wait { try? await Task.sleep(for: .milliseconds(450)) }
            showAdd = true
        }
    }

    func replayOnboarding() {
        showSettings = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            showOnboarding = true
        }
    }

    func tabKey(_ tab: AppTab) -> String {
        switch tab {
        case .home: "home"
        case .library: "library"
        case .studio: "studio"
        case .files: "files"
        case .search: "search"
        case .custom(let id): id
        }
    }

    func startImport(_ kind: ImportKind) {
        showAdd = false
        showSettings = false
        showOnboarding = false
        importKind = kind
        // The file importer can't appear while another sheet is still dismissing.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            showImporter = true
        }
    }

    /// Called by scroll views: collapse the add/search pills when scrolling down, restore on scroll up.
    func scrolled(from old: CGFloat, to new: CGFloat) {
        if new < 20 { if collapsed { collapsed = false }; return }
        if new > old + 6, !collapsed { collapsed = true }
        else if new < old - 6, collapsed { collapsed = false }
    }
}

// MARK: - Settings

@Observable
final class AppSettings {
    private let d = UserDefaults.standard

    var continuousPlayback: Bool { didSet { d.set(continuousPlayback, forKey: "continuous") } }
    var crossfadeEnabled: Bool { didSet { d.set(crossfadeEnabled, forKey: "crossfade") } }
    var crossfadeSeconds: Double { didSet { d.set(crossfadeSeconds, forKey: "crossfadeSeconds") } }
    var appearance: Int { didSet { d.set(appearance, forKey: "appearance") } }
    var listenBrainzEnabled: Bool { didSet { d.set(listenBrainzEnabled, forKey: "lbEnabled") } }
    var listenBrainzToken: String { didSet { d.set(listenBrainzToken, forKey: "lbToken") } }
    var autoLyrics: Bool { didSet { d.set(autoLyrics, forKey: "autoLyrics") } }
    var lyricsLanguage: String { didSet { d.set(lyricsLanguage, forKey: "lyricsLanguage") } }

    // Playback continuation
    var continuationMode: ContinuationMode { didSet { d.set(continuationMode.rawValue, forKey: "continuationMode") } }
    var continuationPlaylist: String { didSet { d.set(continuationPlaylist, forKey: "continuationPlaylist") } }

    // Shuffle
    var smartShuffle: Bool { didSet { d.set(smartShuffle, forKey: "smartShuffle") } }
    /// 0 = completely random, 1 = familiar favourites.
    var shuffleFamiliarity: Double { didSet { d.set(shuffleFamiliarity, forKey: "shuffleFamiliarity") } }

    // Sleep timer
    var sleepFadeSeconds: Double { didSet { d.set(sleepFadeSeconds, forKey: "sleepFade") } }

    // Track mix
    var transitionStyle: TransitionStyle { didSet { d.set(transitionStyle.rawValue, forKey: "transitionStyle") } }
    var transitionEffect: TransitionEffect { didSet { d.set(transitionEffect.rawValue, forKey: "transitionEffect") } }
    var gapless: Bool { didSet { d.set(gapless, forKey: "gapless") } }
    var smartTransitions: Bool { didSet { d.set(smartTransitions, forKey: "smartTransitions") } }
    var beatMatch: Bool { didSet { d.set(beatMatch, forKey: "beatMatch") } }
    var djMode: Bool { didSet { d.set(djMode, forKey: "djMode") } }
    var skipSilence: Bool { didSet { d.set(skipSilence, forKey: "skipSilence") } }

    // Lyrics
    var wordLyrics: Bool { didSet { d.set(wordLyrics, forKey: "wordLyrics") } }
    var onlineLyrics: Bool { didSet { d.set(onlineLyrics, forKey: "onlineLyrics") } }
    var serverLyrics: Bool { didSet { d.set(serverLyrics, forKey: "serverLyrics") } }
    var translateLyrics: Bool { didSet { d.set(translateLyrics, forKey: "translateLyrics") } }
    var translationTarget: String { didSet { d.set(translationTarget, forKey: "translationTarget") } }

    // Integration
    /// Extra Live Activity with the current lyric line. Off by default: the system Now Playing already owns
    /// the Dynamic Island and Lock Screen player, a second activity just splits the Island.
    var liveLyrics: Bool { didSet { d.set(liveLyrics, forKey: "liveLyrics") } }
    var lockArtwork: Bool { didSet { d.set(lockArtwork, forKey: "lockArtwork") } }
    var lockArtLayout: LockArtLayout { didSet { d.set(lockArtLayout.rawValue, forKey: "lockArtLayout") } }
    var lockArtMotion: LockArtMotion { didSet { d.set(lockArtMotion.rawValue, forKey: "lockArtMotion") } }
    var offlineMode: Bool { didSet { d.set(offlineMode, forKey: "offlineMode") } }
    var onlineLookups: Bool { didSet { d.set(onlineLookups, forKey: "onlineLookups") } }

    init() {
        let d = UserDefaults.standard
        continuousPlayback = d.object(forKey: "continuous") as? Bool ?? true
        crossfadeEnabled = d.bool(forKey: "crossfade")
        crossfadeSeconds = d.object(forKey: "crossfadeSeconds") as? Double ?? 6
        appearance = d.integer(forKey: "appearance")
        listenBrainzEnabled = d.bool(forKey: "lbEnabled")
        listenBrainzToken = d.string(forKey: "lbToken") ?? ""
        autoLyrics = d.object(forKey: "autoLyrics") as? Bool ?? true
        lyricsLanguage = d.string(forKey: "lyricsLanguage") ?? "auto"
        continuationMode = d.string(forKey: "continuationMode").flatMap(ContinuationMode.init) ?? .shuffleLibrary
        continuationPlaylist = d.string(forKey: "continuationPlaylist") ?? ""
        smartShuffle = d.bool(forKey: "smartShuffle")
        shuffleFamiliarity = d.object(forKey: "shuffleFamiliarity") as? Double ?? 0.5
        sleepFadeSeconds = d.object(forKey: "sleepFade") as? Double ?? 10
        transitionStyle = d.string(forKey: "transitionStyle").flatMap(TransitionStyle.init) ?? .equalPower
        transitionEffect = d.string(forKey: "transitionEffect").flatMap(TransitionEffect.init) ?? .none
        gapless = d.object(forKey: "gapless") as? Bool ?? true
        smartTransitions = d.bool(forKey: "smartTransitions")
        beatMatch = d.bool(forKey: "beatMatch")
        djMode = d.bool(forKey: "djMode")
        skipSilence = d.bool(forKey: "skipSilence")
        wordLyrics = d.bool(forKey: "wordLyrics")
        onlineLyrics = d.object(forKey: "onlineLyrics") as? Bool ?? true
        serverLyrics = d.object(forKey: "serverLyrics") as? Bool ?? true
        translateLyrics = d.bool(forKey: "translateLyrics")
        translationTarget = d.string(forKey: "translationTarget") ?? (Locale.current.language.languageCode?.identifier ?? "en")
        liveLyrics = d.bool(forKey: "liveLyrics")
        lockArtwork = d.object(forKey: "lockArtwork") as? Bool ?? true
        lockArtLayout = d.string(forKey: "lockArtLayout").flatMap(LockArtLayout.init) ?? .fill
        lockArtMotion = d.string(forKey: "lockArtMotion").flatMap(LockArtMotion.init) ?? .breathe
        offlineMode = d.bool(forKey: "offlineMode")
        onlineLookups = d.object(forKey: "onlineLookups") as? Bool ?? true
    }

    /// DJ mode bundles the "real mix" options.
    var effectiveCrossfade: Bool { crossfadeEnabled || djMode }
    var effectiveSmartTransitions: Bool { smartTransitions || djMode }
    var effectiveBeatMatch: Bool { beatMatch || djMode }
    var effectiveEffect: TransitionEffect { djMode && transitionEffect == .none ? .bassSwap : transitionEffect }
    var effectiveFadeSeconds: Double { djMode ? max(crossfadeSeconds, 10) : crossfadeSeconds }

    /// Locales to try, in order. "Auto" tries English first (most music), then the system language.
    var lyricsLocales: [Locale] {
        switch lyricsLanguage {
        case "auto":
            var list = [Locale(identifier: "en-US")]
            if Locale.current.language.languageCode?.identifier != "en" { list.append(.current) }
            return list
        case "system": return [.current]
        default: return [Locale(identifier: lyricsLanguage)]
        }
    }

    var colorScheme: ColorScheme? { appearance == 1 ? .light : appearance == 2 ? .dark : nil }
}

nonisolated enum ContinuationMode: String, CaseIterable, Identifiable, Sendable {
    case stop, repeatQueue, continueLibrary, continueDownloads, continueFavorites, continuePlaylist, shuffleLibrary, smartShuffle, startOver
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stop: "Stop After Queue"
        case .repeatQueue: "Repeat Queue"
        case .continueLibrary: "Continue Library"
        case .continueDownloads: "Continue Downloads"
        case .continueFavorites: "Continue Favorites"
        case .continuePlaylist: "Continue Playlist"
        case .shuffleLibrary: "Shuffle Library"
        case .smartShuffle: "Smart Shuffle"
        case .startOver: "Start Over When Library Ends"
        }
    }
    var symbol: String {
        switch self {
        case .stop: "stop.circle"
        case .repeatQueue: "repeat"
        case .continueLibrary: "books.vertical"
        case .continueDownloads: "arrow.down.circle"
        case .continueFavorites: "star"
        case .continuePlaylist: "music.note.list"
        case .shuffleLibrary: "shuffle"
        case .smartShuffle: "sparkles"
        case .startOver: "arrow.counterclockwise"
        }
    }
    var detail: String {
        switch self {
        case .stop: "Playback stops when the queue is finished."
        case .repeatQueue: "The queue starts again from the top."
        case .continueLibrary: "Keeps going through your library in order."
        case .continueDownloads: "Keeps going through music that's on this iPhone."
        case .continueFavorites: "Plays your starred songs."
        case .continuePlaylist: "Continues with a playlist you choose."
        case .shuffleLibrary: "Random songs from your whole library."
        case .smartShuffle: "A shuffle that knows what you like."
        case .startOver: "Goes through your library, then starts again from the beginning of your downloaded music."
        }
    }
}

nonisolated enum TransitionStyle: String, CaseIterable, Identifiable, Sendable {
    case equalPower, linear, fadeOutIn, cut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .equalPower: "Smooth (Equal Power)"
        case .linear: "Linear"
        case .fadeOutIn: "Fade Out, Then In"
        case .cut: "Quick Cut"
        }
    }
}

nonisolated enum TransitionEffect: String, CaseIterable, Identifiable, Sendable {
    case none, filterSweep, bassSwap, echoOut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .filterSweep: "Filter Sweep"
        case .bassSwap: "Bass Swap (EQ Matching)"
        case .echoOut: "Echo Out"
        }
    }
}

// MARK: - Equalizer

nonisolated struct EQPreset: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var gains: [Float]
    var builtIn = false
}

@Observable
final class EQModel {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    static let presets: [EQPreset] = [
        ("Hip-Hop", [5, 4, 2, 3, -1, -1, 1, -1, 2, 3]),
        ("Vocal Booster", [-3, -2, 0, 1, 2, 3, 3, 2, 0, -1]),
        ("Classical", [0, 0, 0, 0, 0, 0, -3, -3, -3, -4]),
        ("Pop", [-1, 1, 3, 4, 3, 0, -1, -1, -1, -2]),
        ("Rock", [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]),
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    ].map { EQPreset(id: $0.0, name: $0.0, gains: $0.1, builtIn: true) }

    let unit = AVAudioUnitEQ(numberOfBands: 10)
    private let d = UserDefaults.standard

    var gains: [Float] { didSet { apply(); d.set(gains.map(Double.init), forKey: "eqGains") } }
    var enabled: Bool { didSet { apply(); d.set(enabled, forKey: "eqEnabled") } }
    var custom: [EQPreset] { didSet { if let data = try? JSONEncoder().encode(custom) { d.set(data, forKey: "eqCustom") } } }
    /// Temporary gains from a per-song / per-album / per-device rule. Never saved over the user's own curve.
    var override: (name: String, gains: [Float])? { didSet { apply() } }

    init() {
        let saved = (d.array(forKey: "eqGains") as? [Double])?.map(Float.init)
        gains = (saved?.count == 10 ? saved : nil) ?? Self.presets[1].gains
        enabled = d.object(forKey: "eqEnabled") as? Bool ?? true
        custom = (d.data(forKey: "eqCustom").flatMap { try? JSONDecoder().decode([EQPreset].self, from: $0) }) ?? []
        for (i, band) in unit.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.frequencies[i]
            band.bandwidth = 1.0
            band.bypass = false
        }
        apply()
    }

    private func apply() {
        let g = override?.gains ?? gains
        for (i, band) in unit.bands.enumerated() { band.gain = enabled ? g[i] : 0 }
    }

    var allPresets: [EQPreset] { Self.presets + custom }
    var activePreset: EQPreset? { allPresets.first { $0.gains == gains } }
    var activeName: String { enabled ? (override?.name ?? activePreset?.name ?? "Custom") : "Off" }
    var isFlat: Bool { (override?.gains ?? gains).allSatisfy { $0 == 0 } }
    func preset(id: String) -> EQPreset? { allPresets.first { $0.id == id } }

    func select(_ p: EQPreset) { enabled = true; gains = p.gains }
    func saveCurrent(as name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        custom.append(EQPreset(id: UUID().uuidString, name: n.isEmpty ? "My Preset" : n, gains: gains))
    }
    func delete(_ p: EQPreset) { custom.removeAll { $0.id == p.id } }
    func rename(_ p: EQPreset, to name: String) {
        if let i = custom.firstIndex(where: { $0.id == p.id }), !name.isEmpty { custom[i].name = name }
    }
    func overwrite(_ p: EQPreset) {
        if let i = custom.firstIndex(where: { $0.id == p.id }) { custom[i].gains = gains }
    }
}
