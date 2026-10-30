import AVFoundation
import AudioToolbox
import Observation
import SwiftUI

nonisolated struct DeviceProfile: Codable, Hashable, Sendable, Identifiable {
    var id: String          // route uid
    var name: String
    var eqPresetID: String?
    var preamp: Float
    var bass: Float
    var treble: Float
    var balance: Float
}

/// Everything after the equalizer: tone, loudness, dynamics, channels and spatial rendering,
/// plus EQ rules per song / album / output device.
@Observable
final class AudioLab {
    private let d = UserDefaults.standard

    var preamp: Float { didSet { applyTone(); d.set(preamp, forKey: "labPreamp") } }
    var bass: Float { didSet { applyTone(); d.set(bass, forKey: "labBass") } }
    var treble: Float { didSet { applyTone(); d.set(treble, forKey: "labTreble") } }
    /// Karaoke: 0 keeps the vocals, 1 cuts the voice range as far as an equalizer can.
    var vocalCut: Float { didSet { applyTone(); onKaraokeChange() } }
    /// The song on the deck is already an instrumental made by the vocal model: the voice-cut unit stays out.
    var stemActive = false { didSet { applyTone() } }
    @ObservationIgnored var onKaraokeChange: () -> Void = {}
    var balance: Float { didSet { balanceMixer.pan = balance; d.set(balance, forKey: "labBalance") } }
    var mono: Bool { didSet { if mono != oldValue { rewire() }; d.set(mono, forKey: "labMono") } }
    var spatial: Bool { didSet { if spatial != oldValue { rewire() }; d.set(spatial, forKey: "labSpatial") } }
    var headTracking: Bool { didSet { environment.isListenerHeadTrackingEnabled = headTracking; d.set(headTracking, forKey: "labHeadTracking") } }
    var normalize: Bool { didSet { d.set(normalize, forKey: "labNormalize"); onGainRulesChanged() } }
    var preferReplayGain: Bool { didSet { d.set(preferReplayGain, forKey: "labReplayGain"); onGainRulesChanged() } }
    var targetLoudness: Double { didSet { d.set(targetLoudness, forKey: "labTarget"); onGainRulesChanged() } }
    var limiter: Bool { didSet { limiterUnit.bypass = !limiter; d.set(limiter, forKey: "labLimiter") } }
    var compressor: Bool { didSet { compressorUnit.bypass = !compressor; d.set(compressor, forKey: "labCompressor") } }
    var compression: Float { didSet { applyCompressor(); d.set(compression, forKey: "labCompression") } }

    var songEQ: [String: String] { didSet { saveMap(songEQ, "labSongEQ") } }
    var albumEQ: [String: String] { didSet { saveMap(albumEQ, "labAlbumEQ") } }
    var deviceProfiles: [DeviceProfile] { didSet { if let data = try? JSONEncoder().encode(deviceProfiles) { d.set(data, forKey: "labDevices") } } }

    private(set) var routeName = "iPhone"
    private(set) var routeID = "speaker"
    private(set) var routeSupportsSpatial = false
    private(set) var activeProfile: DeviceProfile?

    @ObservationIgnored var onGainRulesChanged: () -> Void = {}

    // Nodes
    @ObservationIgnored let tone = AVAudioUnitEQ(numberOfBands: 6)
    @ObservationIgnored let karaokeNode = KaraokeUnit.makeNode()
    @ObservationIgnored let compressorUnit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    @ObservationIgnored let limiterUnit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    @ObservationIgnored let balanceMixer = AVAudioMixerNode()
    @ObservationIgnored let environment = AVAudioEnvironmentNode()
    @ObservationIgnored private weak var engine: AVAudioEngine?
    @ObservationIgnored private var routeTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        preamp = d.object(forKey: "labPreamp") as? Float ?? 0
        bass = d.object(forKey: "labBass") as? Float ?? 0
        treble = d.object(forKey: "labTreble") as? Float ?? 0
        vocalCut = 0
        balance = d.object(forKey: "labBalance") as? Float ?? 0
        mono = d.bool(forKey: "labMono")
        spatial = d.bool(forKey: "labSpatial")
        headTracking = d.bool(forKey: "labHeadTracking")
        normalize = d.bool(forKey: "labNormalize")
        preferReplayGain = d.object(forKey: "labReplayGain") as? Bool ?? true
        targetLoudness = d.object(forKey: "labTarget") as? Double ?? -14
        limiter = d.object(forKey: "labLimiter") as? Bool ?? false
        compressor = d.bool(forKey: "labCompressor")
        compression = d.object(forKey: "labCompression") as? Float ?? 0.4
        songEQ = (d.dictionary(forKey: "labSongEQ") as? [String: String]) ?? [:]
        albumEQ = (d.dictionary(forKey: "labAlbumEQ") as? [String: String]) ?? [:]
        deviceProfiles = (d.data(forKey: "labDevices").flatMap { try? JSONDecoder().decode([DeviceProfile].self, from: $0) }) ?? []

        tone.bands[0].filterType = .lowShelf
        tone.bands[0].frequency = 110
        tone.bands[1].filterType = .highShelf
        tone.bands[1].frequency = 7500
        for b in tone.bands { b.bypass = false; b.bandwidth = 1 }
        let voiceBands: [Float] = [320, 900, 1900, 3600]
        for (i, f) in voiceBands.enumerated() {
            let b = tone.bands[i + 2]
            b.filterType = .parametric
            b.frequency = f
            b.bandwidth = 1.5
        }
        applyTone()
        compressorUnit.bypass = !compressor
        limiterUnit.bypass = !limiter
        applyCompressor()
        balanceMixer.pan = balance
        environment.isListenerHeadTrackingEnabled = headTracking
        observeRoute()
    }

    private func saveMap(_ m: [String: String], _ key: String) { d.set(m, forKey: key) }

    // MARK: Graph

    /// Inserts the lab between `input` and the engine's main mixer.
    func attach(to engine: AVAudioEngine, after input: AVAudioNode) {
        self.engine = engine
        for n in [tone, karaokeNode, compressorUnit, limiterUnit, balanceMixer, environment] as [AVAudioNode] { engine.attach(n) }
        engine.connect(input, to: tone, format: nil)
        engine.connect(tone, to: karaokeNode, format: nil)
        engine.connect(karaokeNode, to: compressorUnit, format: nil)
        engine.connect(compressorUnit, to: limiterUnit, format: nil)
        engine.connect(limiterUnit, to: balanceMixer, format: nil)
        connectTail()
    }

    private func connectTail() {
        guard let engine else { return }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate > 0 ? engine.outputNode.outputFormat(forBus: 0).sampleRate : 44100
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
        engine.disconnectNodeOutput(balanceMixer)
        engine.disconnectNodeOutput(environment)
        if spatial {
            balanceMixer.sourceMode = .ambienceBed
            balanceMixer.renderingAlgorithm = .auto
            environment.outputType = .auto
            engine.connect(balanceMixer, to: environment, format: mono ? monoFormat : stereo)
            engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        } else {
            engine.connect(balanceMixer, to: engine.mainMixerNode, format: mono ? monoFormat : stereo)
        }
        balanceMixer.pan = balance
    }

    private func rewire() { connectTail() }

    private func applyTone() {
        tone.globalGain = preamp
        tone.bands[0].gain = bass
        tone.bands[1].gain = treble
        // The vocal removal is the karaoke unit; the equalizer's voice bands stay flat so the song doesn't sound muffled.
        for i in 2..<6 { tone.bands[i].gain = 0 }
        (karaokeNode.auAudioUnit as? KaraokeUnit)?.amount = stemActive ? 0 : vocalCut
    }

    private func applyCompressor() {
        guard let au = compressorUnit.audioUnit as AudioUnit? else { return }
        // 0 → gentle (-10 dB threshold), 1 → strong (-35 dB threshold) with make-up gain.
        let c = max(0, min(1, compression))
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -10 - 25 * c, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 8 - 5 * c, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.12, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 6 * c, 0)
    }

    // MARK: Loudness

    /// dB of gain that brings this song to the target loudness (0 when normalization is off or unknown).
    func normalizationGain(for track: Track) -> Float {
        guard normalize else { return 0 }
        var gain: Double?
        if preferReplayGain, let rg = track.replayGain { gain = rg + (targetLoudness + 18) }
        else if let lufs = track.loudness { gain = targetLoudness - lufs }
        else if let rg = track.replayGain { gain = rg + (targetLoudness + 18) }
        return Float(max(-12, min(12, gain ?? 0)))
    }

    // MARK: EQ rules

    static func albumKey(_ t: Track) -> String { "\(t.artist)|\(t.album)" }

    /// Song rule > album rule > device profile > the user's own EQ.
    func eqOverride(for track: Track?, eq: EQModel) -> (name: String, gains: [Float])? {
        if let t = track, let id = songEQ[t.id.uuidString], let p = eq.preset(id: id) { return ("\(p.name) · Song", p.gains) }
        if let t = track, let id = albumEQ[Self.albumKey(t)], let p = eq.preset(id: id) { return ("\(p.name) · Album", p.gains) }
        if let prof = activeProfile, let id = prof.eqPresetID, let p = eq.preset(id: id) { return ("\(p.name) · \(prof.name)", p.gains) }
        return nil
    }

    // MARK: Output devices

    private func observeRoute() {
        updateRoute()
        routeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                self?.updateRoute()
            }
        }
    }

    @ObservationIgnored var onRouteChanged: () -> Void = {}

    func updateRoute() {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first
        routeName = out?.portName ?? "iPhone"
        routeID = out?.uid ?? "speaker"
        routeSupportsSpatial = out?.isSpatialAudioEnabled ?? false
        let profile = deviceProfiles.first { $0.id == routeID }
        if profile != activeProfile {
            activeProfile = profile
            if let p = profile { preamp = p.preamp; bass = p.bass; treble = p.treble; balance = p.balance }
        }
        onRouteChanged()
    }

    func saveProfileForCurrentDevice(eqPresetID: String?) {
        let p = DeviceProfile(id: routeID, name: routeName, eqPresetID: eqPresetID, preamp: preamp, bass: bass, treble: treble, balance: balance)
        deviceProfiles.removeAll { $0.id == routeID }
        deviceProfiles.append(p)
        activeProfile = p
        onRouteChanged()
    }

    func removeProfile(_ id: String) {
        deviceProfiles.removeAll { $0.id == id }
        if activeProfile?.id == id { activeProfile = nil }
        onRouteChanged()
    }
}

// MARK: - UI

/// Audio Lab's sections, shown inside Sound (the one place for everything you hear): `.sound` is tone, loudness,
/// channels and spatial; `.rules` the EQ for this song / album / device.
struct AudioLabSections: View {
    enum Part { case sound, rules }
    let part: Part
    @Environment(AudioLab.self) private var lab
    @Environment(EQModel.self) private var eq
    @Environment(PlayerModel.self) private var player

    var body: some View {
        @Bindable var lab = lab
        switch part {
        case .sound:
            Section("Tone") {
                gainSlider("Preamp", "speaker.wave.2", $lab.preamp)
                gainSlider("Bass", "speaker.wave.3", $lab.bass)
                gainSlider("Treble", "waveform.path.ecg", $lab.treble)
                if lab.preamp != 0 || lab.bass != 0 || lab.treble != 0 {
                    Button("Reset Tone") { withAnimation { lab.preamp = 0; lab.bass = 0; lab.treble = 0 } }
                }
            }

            Section {
                Toggle(isOn: $lab.normalize.animation()) { Label("Loudness Normalization", systemImage: "chart.bar.xaxis") }
                if lab.normalize {
                    Picker("Target", selection: $lab.targetLoudness) {
                        Text("Loud (-11 LUFS)").tag(-11.0)
                        Text("Normal (-14 LUFS)").tag(-14.0)
                        Text("Quiet (-18 LUFS)").tag(-18.0)
                        Text("Broadcast (-23 LUFS)").tag(-23.0)
                    }
                    Toggle(isOn: $lab.preferReplayGain) { Label("Use ReplayGain Tags", systemImage: "tag") }
                }
                Toggle(isOn: $lab.limiter) { Label("Limiter", systemImage: "rectangle.compress.vertical") }
                Toggle(isOn: $lab.compressor.animation()) { Label("Compressor", systemImage: "arrow.down.right.and.arrow.up.left") }
                if lab.compressor {
                    HStack {
                        Text("Gentle").font(.footnote).foregroundStyle(.secondary)
                        Slider(value: $lab.compression, in: 0...1)
                        Text("Strong").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Loudness & Dynamics") } footer: {
                Text("Songs are measured once in the background. ReplayGain tags and Jellyfin's normalization values are used when present. The limiter keeps boosted songs from clipping.")
            }

            Section("Channels") {
                Toggle(isOn: $lab.mono) { Label("Mono Audio", systemImage: "speaker.wave.1") }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Balance", systemImage: "arrow.left.and.right")
                        Spacer()
                        Text(balanceText).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text("L").font(.footnote.bold()).foregroundStyle(.secondary)
                        Slider(value: $lab.balance, in: -1...1)
                        Text("R").font(.footnote.bold()).foregroundStyle(.secondary)
                    }
                    .onTapGesture(count: 2) { lab.balance = 0 }
                }
            }

            Section {
                Toggle(isOn: $lab.spatial.animation()) { Label("Spatial Audio", systemImage: "airpodspro") }
                if lab.spatial {
                    Toggle(isOn: $lab.headTracking) { Label("Head Tracking", systemImage: "person.crop.circle.badge.checkmark") }
                }
                LabeledContent("Output", value: lab.routeName)
                LabeledContent("System Spatial Audio", value: lab.routeSupportsSpatial ? "Available" : "Not on this output")
            } header: { Text("Spatial") } footer: {
                Text("Places the stereo image around you with head-related rendering. Works best with headphones; head tracking needs supported AirPods.")
            }

        case .rules:
            if let t = player.current {
                Section {
                    presetPicker("This Song", selection: binding(\.songEQ, t.id.uuidString))
                    presetPicker("This Album", selection: binding(\.albumEQ, AudioLab.albumKey(t)))
                } header: { Text("EQ for “\(t.title)”") } footer: {
                    Text("A song rule wins over an album rule, which wins over a device profile.")
                }
            }

            Section {
                if let p = lab.activeProfile {
                    LabeledContent("Active Profile", value: p.name)
                    presetPicker("Profile EQ", selection: Binding(get: { p.eqPresetID ?? "" }, set: { lab.saveProfileForCurrentDevice(eqPresetID: $0.isEmpty ? nil : $0) }))
                    Button("Update with Current Tone") { lab.saveProfileForCurrentDevice(eqPresetID: p.eqPresetID) }
                } else {
                    Button { lab.saveProfileForCurrentDevice(eqPresetID: eq.activePreset?.id) } label: {
                        Label("Save Settings for “\(lab.routeName)”", systemImage: "headphones")
                    }
                }
                ForEach(lab.deviceProfiles) { p in
                    HStack {
                        Image(systemName: p.id == lab.routeID ? "checkmark.circle.fill" : "headphones").foregroundStyle(p.id == lab.routeID ? Theme.accent : .secondary)
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text(profileSummary(p)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { lab.removeProfile(p.id) } }
                }
            } header: { Text("Per Headphone / Device") } footer: {
                Text("\(Brand.name) switches automatically when you connect a device that has a profile.")
            }

            if !lab.songEQ.isEmpty || !lab.albumEQ.isEmpty {
                Section("EQ Rules") {
                    ForEach(lab.albumEQ.sorted(by: { $0.key < $1.key }), id: \.key) { key, id in
                        rule(icon: "square.stack", title: key.split(separator: "|").last.map(String.init) ?? key, preset: id) { lab.albumEQ[key] = nil }
                    }
                    ForEach(lab.songEQ.sorted(by: { $0.key < $1.key }), id: \.key) { key, id in
                        let title = UUID(uuidString: key).flatMap { player.library.trackByID[$0]?.title } ?? "Song"
                        rule(icon: "music.note", title: title, preset: id) { lab.songEQ[key] = nil }
                    }
                }
            }
        }
    }

    private var balanceText: String {
        let b = lab.balance
        if abs(b) < 0.02 { return "Center" }
        return b < 0 ? "L \(Int(-b * 100))%" : "R \(Int(b * 100))%"
    }

    private func profileSummary(_ p: DeviceProfile) -> String {
        var parts: [String] = []
        if let id = p.eqPresetID, let preset = eq.preset(id: id) { parts.append(preset.name) }
        if p.preamp != 0 { parts.append(String(format: "Preamp %+.0f dB", p.preamp)) }
        if p.bass != 0 { parts.append(String(format: "Bass %+.0f", p.bass)) }
        if p.treble != 0 { parts.append(String(format: "Treble %+.0f", p.treble)) }
        return parts.isEmpty ? "Flat" : parts.joined(separator: " · ")
    }

    private func binding(_ path: ReferenceWritableKeyPath<AudioLab, [String: String]>, _ key: String) -> Binding<String> {
        Binding(get: { lab[keyPath: path][key] ?? "" }, set: { lab[keyPath: path][key] = $0.isEmpty ? nil : $0; player.applyEQRules() })
    }

    private func presetPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Default").tag("")
            ForEach(eq.allPresets) { Text($0.name).tag($0.id) }
        }
    }

    private func rule(icon: String, title: String, preset: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            Text(title).lineLimit(1)
            Spacer()
            Text(eq.preset(id: preset)?.name ?? "–").foregroundStyle(.secondary)
        }
        .swipeActions { Button("Delete", role: .destructive) { remove(); player.applyEQRules() } }
    }

    private func gainSlider(_ title: String, _ symbol: String, _ value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(String(format: "%+.1f dB", value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: -12...12, step: 0.5)
        }
    }
}
