import AVFoundation
import Observation
import UIKit

nonisolated struct AnalysisResult: Sendable {
    var loudness: Double?       // integrated loudness, LUFS (ITU-R BS.1770 with gating)
    var bpm: Double?
    var beatOffset: Double?     // first beat, seconds
    var leadIn: Double          // first audible moment
    var trailEnd: Double        // last audible moment
    var outroStart: Double      // where the ending fade / outro begins
}

/// One pass over the file: K-weighted loudness, an onset envelope for tempo + beat phase, and silence/outro detection.
nonisolated enum AudioAnalyzer {
    /// Bump when the analysis improves; songs measured with an older version are measured again.
    static let version = 2

    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
        static func highShelf(fs: Double) -> Biquad {
            let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
            let a = pow(10, g / 40), w0 = 2 * .pi * f0 / fs, alpha = sin(w0) / (2 * q), c = cos(w0), s = 2 * sqrt(a) * alpha
            let a0 = (a + 1) - (a - 1) * c + s
            return Biquad(b0: a * ((a + 1) + (a - 1) * c + s) / a0, b1: -2 * a * ((a - 1) + (a + 1) * c) / a0,
                          b2: a * ((a + 1) + (a - 1) * c - s) / a0, a1: 2 * ((a - 1) - (a + 1) * c) / a0, a2: ((a + 1) - (a - 1) * c - s) / a0)
        }
        static func highPass(fs: Double) -> Biquad {
            let f0 = 38.13547087602444, q = 0.5003270373238773
            let w0 = 2 * .pi * f0 / fs, alpha = sin(w0) / (2 * q), c = cos(w0), a0 = 1 + alpha
            return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }
        static func lowPass(fs: Double, f0: Double) -> Biquad {
            let q = 0.707, w0 = 2 * .pi * f0 / fs, alpha = sin(w0) / (2 * q), c = cos(w0), a0 = 1 + alpha
            return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }
    }

    @concurrent
    static func analyze(url: URL) async -> AnalysisResult? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let fs = format.sampleRate
        let channels = Int(format.channelCount)
        guard fs > 0, channels > 0, file.length > Int64(fs) else { return nil }
        let chunk: AVAudioFrameCount = 32768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        var shelves = (0..<channels).map { _ in Biquad.highShelf(fs: fs) }
        var passes = (0..<channels).map { _ in Biquad.highPass(fs: fs) }
        var bassFilter = Biquad.lowPass(fs: fs, f0: 180)

        // 100 ms blocks for loudness gating, ~11.6 ms hops for onsets and silence.
        let blockLen = Int(fs * 0.1)
        let hop = max(256, Int(fs / 86))
        var blockSums: [Double] = []
        var blockAcc = 0.0, blockN = 0
        var hopEnergy: [Float] = []        // full-band RMS per hop (silence / outro)
        var hopBass: [Float] = []          // low-band energy per hop (kick / bass onsets)
        var hopFull: [Float] = []          // full-band energy per hop (other onsets)
        var hAcc = 0.0, hBass = 0.0, hN = 0
        let maxOnsetHops = Int(240 * fs) / hop

        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var ms = 0.0, mono = 0.0
                for c in 0..<channels {
                    let x = Double(data[c][i])
                    mono += x
                    let k = passes[c].process(shelves[c].process(x))
                    ms += k * k
                }
                mono /= Double(channels)
                blockAcc += ms; blockN += 1
                if blockN == blockLen { blockSums.append(blockAcc / Double(blockLen)); blockAcc = 0; blockN = 0 }
                let b = bassFilter.process(mono)
                hAcc += mono * mono; hBass += b * b; hN += 1
                if hN == hop {
                    hopEnergy.append(Float(sqrt(hAcc / Double(hop))))
                    if hopBass.count < maxOnsetHops { hopBass.append(Float(hBass / Double(hop))); hopFull.append(Float(hAcc / Double(hop))) }
                    hAcc = 0; hBass = 0; hN = 0
                }
            }
        }
        guard !hopEnergy.isEmpty else { return nil }
        let hopSec = Double(hop) / fs

        // Loudness (400 ms windows with 75 % overlap, absolute + relative gates).
        var windows: [Double] = []
        if blockSums.count >= 4 { for i in 0...(blockSums.count - 4) { windows.append((blockSums[i] + blockSums[i + 1] + blockSums[i + 2] + blockSums[i + 3]) / 4) } }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-12)) }
        var loudness: Double?
        let audible = windows.filter { lufs($0) > -70 }
        if !audible.isEmpty {
            let rel = lufs(audible.reduce(0, +) / Double(audible.count)) - 10
            let gated = audible.filter { lufs($0) > rel }
            if !gated.isEmpty { loudness = lufs(gated.reduce(0, +) / Double(gated.count)) }
        }

        // Silence: -50 dBFS.
        let threshold: Float = 0.00316
        let first = hopEnergy.firstIndex { $0 > threshold } ?? 0
        let last = hopEnergy.lastIndex { $0 > threshold } ?? (hopEnergy.count - 1)
        let leadIn = Double(first) * hopSec
        let trailEnd = Double(last + 1) * hopSec

        // Outro: walking back from the end, where the 2 s average drops under half the song's typical level.
        let sorted = hopEnergy[first...last].sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let win = max(1, Int(2 / hopSec))
        var outroHop = last
        var i = last
        let limit = max(first, last - Int(35 / hopSec))
        var acc: Float = 0
        var q: [Float] = []
        while i > limit {
            q.append(hopEnergy[i]); acc += hopEnergy[i]
            if q.count > win { acc -= q.removeFirst() }
            if q.count == win, acc / Float(win) >= median * 0.5 { outroHop = i + win / 2; break }
            i -= 1
        }
        let outroStart = min(trailEnd, Double(outroHop) * hopSec)

        // Tempo: autocorrelation of the half-wave rectified log-energy flux, with a prior around 120 BPM.
        var bpm: Double?
        var beatOffset: Double?
        if hopBass.count > Int(20 / hopSec) {
            let logB = hopBass.map { log(1 + 1000 * $0) }
            let logF = hopFull.map { log(1 + 1000 * $0) }
            var onset = [Float](repeating: 0, count: logB.count)
            for j in 1..<logB.count { onset[j] = max(0, logB[j] - logB[j - 1]) + 0.6 * max(0, logF[j] - logF[j - 1]) }
            let mean = onset.reduce(0, +) / Float(onset.count)
            onset = onset.map { $0 - mean }
            let minLag = Int((60.0 / 190.0) / hopSec), maxLag = Int((60.0 / 60.0) / hopSec)
            var best = (lag: 0, score: -Double.infinity)
            var scores = [Double](repeating: 0, count: maxLag + 2)
            let span = onset.count - maxLag - 1
            if span > 100 {
                for lag in minLag...maxLag {
                    var s = 0.0
                    var j = 0
                    while j < span { s += Double(onset[j] * onset[j + lag]); j += 1 }
                    let b = 60 / (Double(lag) * hopSec)
                    let prior = exp(-0.5 * pow(log2(b / 120) / 0.9, 2))
                    scores[lag] = s
                    if s * prior > best.score { best = (lag, s * prior) }
                }
                if best.lag > minLag, best.lag < maxLag {
                    let a = scores[best.lag - 1], b = scores[best.lag], c = scores[best.lag + 1]
                    let denom = a - 2 * b + c
                    let shift = denom != 0 ? 0.5 * (a - c) / denom : 0
                    let period = (Double(best.lag) + max(-0.5, min(0.5, shift))) * hopSec
                    // Fold into the range most music is counted in (half/double-time ambiguity).
                    var tempo = 60 / period
                    while tempo < 78 { tempo *= 2 }
                    while tempo >= 185 { tempo /= 2 }
                    bpm = (tempo * 10).rounded() / 10
                    // Beat phase: the offset whose comb collects the most onset energy.
                    let p = Double(best.lag) + shift
                    var phase = (idx: 0, score: -Float.infinity)
                    for off in 0..<best.lag {
                        var s: Float = 0
                        var pos = Double(off)
                        while Int(pos) < onset.count { s += onset[Int(pos)]; pos += p }
                        if s > phase.score { phase = (off, s) }
                    }
                    var firstBeat = Double(phase.idx) * hopSec
                    while firstBeat < leadIn { firstBeat += period }
                    beatOffset = firstBeat
                }
            }
        }
        return AnalysisResult(loudness: loudness, bpm: bpm, beatOffset: beatOffset, leadIn: leadIn, trailEnd: trailEnd, outroStart: outroStart)
    }
}

/// Measures songs in the background, one at a time, so loudness matching and smart transitions have data.
@Observable
final class AnalysisService {
    private(set) var running = false
    private(set) var done = 0
    private(set) var total = 0
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored var onAnalyzed: (UUID) -> Void = { _ in }

    init(library: LibraryStore) { self.library = library }

    /// Songs stored on this iPhone that haven't been measured yet (cached streams are measured when played).
    static func needsAnalysis(_ t: Track) -> Bool { t.analyzed != true || (t.analysisVersion ?? 1) < AudioAnalyzer.version }

    var pendingCount: Int { library.tracks.filter { Self.needsAnalysis($0) && $0.isOffline }.count }

    func analyzeLibrary() {
        enqueue(library.tracks.filter { Self.needsAnalysis($0) && $0.isOffline }.map(\.id))
    }

    /// The whole library is measured only while charging; songs are always measured as they're played.
    func analyzeWhenCharging() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        func check() {
            let s = UIDevice.current.batteryState
            if s == .charging || s == .full { analyzeLibrary() }
        }
        check()
        batteryTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIDevice.batteryStateDidChangeNotification) {
                guard self != nil else { return }
                check()
            }
        }
    }
    @ObservationIgnored private var batteryTask: Task<Void, Never>?

    /// Jumps the line (used for the song that just started and the next one).
    func prioritize(_ ids: [UUID]) {
        let fresh = ids.filter { library.trackByID[$0].map(Self.needsAnalysis) ?? false }
        queue.removeAll { fresh.contains($0) }
        queue.insert(contentsOf: fresh, at: 0)
        total = max(total, done + queue.count)
        pump()
    }

    func enqueue(_ ids: [UUID]) {
        let set = Set(queue)
        queue += ids.filter { !set.contains($0) }
        total = done + queue.count
        pump()
    }

    private func pump() {
        guard !running else { return }
        running = true
        Task {
            while !queue.isEmpty {
                let id = queue.removeFirst()
                guard let t = library.trackByID[id], Self.needsAnalysis(t), let url = MediaLocator.localURL(for: t) else { continue }
                let result = await Task.detached(priority: .utility) { await AudioAnalyzer.analyze(url: url) }.value
                library.update(id) { tr in
                    tr.analyzed = true
                    tr.analysisVersion = AudioAnalyzer.version
                    guard let r = result else { return }
                    tr.loudness = r.loudness
                    if tr.bpm == nil || tr.bpmAnalyzed == true, let b = r.bpm { tr.bpm = b; tr.bpmAnalyzed = true }
                    tr.beatOffset = r.beatOffset
                    tr.leadIn = r.leadIn
                    tr.trailEnd = r.trailEnd
                    tr.outroStart = r.outroStart
                }
                done += 1
                onAnalyzed(id)
            }
            running = false
            done = 0
            total = 0
        }
    }
}
