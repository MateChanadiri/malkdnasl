import Foundation
import SwiftUI
import CoreML
import Accelerate
import AVFoundation
import Observation

// MARK: - Real karaoke: vocal separation with the UVR MDX-Net model
//
// The model (UVR-MDX-NET-Inst_HQ_3, MIT licence, by Kimberley Jensen / Anjok07, converted to Core ML by gyoom) is not
// part of the app: it is downloaded once (about 32 MB) from Hugging Face and compiled on the device.
// A song is run through it once and the instrumental is kept in the cache; playing with the vocals removed then
// plays that file instead of the original.

// MARK: Model download

@MainActor @Observable
final class VocalModelStore {
    static let shared = VocalModelStore()

    enum State: Equatable { case missing, downloading(Double), compiling, ready, failed(String) }
    private(set) var state: State

    nonisolated static let repos = ["gyoom/UVR-MDX-CoreML", "gyoom-sa/UVR-MDX-CoreML"]
    nonisolated static let package = "UVR-MDX-NET-Inst_HQ_3.mlpackage"

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    nonisolated static var compiledURL: URL { folder.appendingPathComponent("UVR-MDX-NET-Inst_HQ_3.mlmodelc", isDirectory: true) }

    private init() {
        state = FileManager.default.fileExists(atPath: Self.compiledURL.path) ? .ready : .missing
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .compiling: true
        default: false
        }
    }

    func download() {
        guard !isBusy, state != .ready else { return }
        state = .downloading(0)
        Task {
            do {
                try await fetchAndCompile()
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Fetches the model quietly in the background the first time the app runs online (not on mobile data).
    func autoInstall() {
        guard state == .missing, NetworkMonitor.shared.isOnline, !NetworkMonitor.shared.isExpensive else { return }
        download()
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.compiledURL)
        KaraokeStems.shared.clear()
        state = .missing
    }

    private func fetchAndCompile() async throws {
        let fm = FileManager.default
        let work = Self.folder.appendingPathComponent("download.mlpackage", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let files: [(path: String, from: Double, span: Double)] = [
            ("Manifest.json", 0, 0.01),
            ("Data/com.apple.CoreML/model.mlmodel", 0.01, 0.03),
            ("Data/com.apple.CoreML/weights/weight.bin", 0.04, 0.96)
        ]
        for file in files {
            let from = file.from, span = file.span
            try await Self.fetch(file.path, to: work.appendingPathComponent(file.path)) { p in
                Task { @MainActor in VocalModelStore.shared.state = .downloading(from + span * p) }
            }
        }
        state = .compiling
        let compiled = try await MLModel.compileModel(at: work)
        try? fm.removeItem(at: Self.compiledURL)
        try fm.moveItem(at: compiled, to: Self.compiledURL)
    }

    nonisolated private static func fetch(_ path: String, to dest: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var lastError: Error = URLError(.badServerResponse)
        for repo in repos {
            guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(package)/\(path)") else { continue }
            do {
                let (tmp, response) = try await URLSession.shared.download(for: URLRequest(url: url), delegate: DownloadProgress(progress))
                guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
                    try? FileManager.default.removeItem(at: tmp)
                    lastError = URLError(.badServerResponse)
                    continue
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    nonisolated private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Double) -> Void
        private var last = -1.0
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            guard p - last >= 0.01 || p >= 1 else { return }
            last = p
            report(p)
        }
    }
}

// MARK: Instrumentals made so far

@MainActor @Observable
final class KaraokeStems {
    static let shared = KaraokeStems()

    enum Status: Equatable { case working(Double), failed(String) }
    private(set) var status: [UUID: Status] = [:]
    /// Called when a song's instrumental is ready.
    @ObservationIgnored var onReady: (UUID) -> Void = { _ in }

    nonisolated static var folder: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Karaoke", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static func fileURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).caf") }

    func url(for id: UUID) -> URL? {
        let u = Self.fileURL(id)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Starts separating this song (if the model is installed and the song is a local file).
    func prepare(_ track: Track) {
        guard VocalModelStore.shared.state == .ready, url(for: track.id) == nil,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        if case .working = status[track.id] { return }
        guard let source = MediaLocator.localURL(for: track) else { return }
        let id = track.id
        let destination = Self.fileURL(id)
        let model = VocalModelStore.compiledURL
        status[id] = .working(0)
        Task.detached(priority: .utility) {
            do {
                try VocalSeparator.separate(modelURL: model, source: source, destination: destination) { p in
                    Task { @MainActor in KaraokeStems.shared.setProgress(id, p) }
                }
                await MainActor.run { KaraokeStems.shared.finished(id, error: nil) }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                await MainActor.run { KaraokeStems.shared.finished(id, error: error.localizedDescription) }
            }
        }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        if case .working = status[id] { status[id] = .working(p) }
    }

    private func finished(_ id: UUID, error: String?) {
        if let error { status[id] = .failed(error); return }
        status[id] = nil
        trim(keeping: id)
        onReady(id)
    }

    func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
        status = [:]
    }

    /// The cache keeps the newest instrumentals only.
    private func trim(keeping id: UUID) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys)) ?? []
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        var total: Int64 = 0
        for f in files {
            let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            total += size
            if total > 800_000_000, !f.lastPathComponent.hasPrefix(id.uuidString) { try? FileManager.default.removeItem(at: f) }
        }
    }
}

// MARK: The separation itself

nonisolated enum VocalSeparator {
    nonisolated enum SeparationError: LocalizedError {
        case unreadable, model(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: "The song couldn't be read."
            case .model(let m): "The vocal model failed: \(m)"
            }
        }
    }

    static let nFFT = 6144
    static let hop = 1024
    static let dimF = 3072
    static let dimT = 256
    static let chunk = hop * (dimT - 1)          // 261 120 samples ≈ 5.9 s
    static let trim = nFFT / 2
    static let gen = chunk - 2 * trim            // samples kept from each chunk
    static let sampleRate = 44_100.0
    /// UVR's volume compensation for this model's instrumental.
    static let compensate: Float = 1.035

    // MARK: FFT (complex DFT of 6144 points, so no packed-format guesswork)

    nonisolated final class FFT {
        let n = VocalSeparator.nFFT
        private let forwardSetup: vDSP_DFT_Setup
        private let inverseSetup: vDSP_DFT_Setup
        private let zeros: [Float]
        private var scratchRe: [Float]
        private var scratchIm: [Float]
        /// Multiplier that turns the inverse transform into a true inverse (measured, not assumed).
        let inverseScale: Float

        init?() {
            let n = VocalSeparator.nFFT
            guard let f = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
                  let i = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE) else { return nil }
            forwardSetup = f
            inverseSetup = i
            zeros = [Float](repeating: 0, count: n)
            scratchRe = [Float](repeating: 0, count: n)
            scratchIm = [Float](repeating: 0, count: n)
            // Round trip a test signal to learn the scale.
            var x = [Float](repeating: 0, count: n)
            for k in 0..<n { x[k] = Float(sin(Double(k) * 0.05) + 0.3 * cos(Double(k) * 0.31)) }
            var fr = [Float](repeating: 0, count: n), fi = [Float](repeating: 0, count: n)
            var br = [Float](repeating: 0, count: n), bi = [Float](repeating: 0, count: n)
            let zeroes = [Float](repeating: 0, count: n)
            vDSP_DFT_Execute(f, x, zeroes, &fr, &fi)
            vDSP_DFT_Execute(i, fr, fi, &br, &bi)
            var best: Float = 1
            var bestMag: Float = 0
            for k in 0..<n where abs(x[k]) > bestMag { bestMag = abs(x[k]); best = br[k] / x[k] }
            inverseScale = (best > 0.5 && best < 1e6) ? 1 / best : 1 / Float(n)
        }

        deinit {
            vDSP_DFT_DestroySetup(forwardSetup)
            vDSP_DFT_DestroySetup(inverseSetup)
        }

        /// Spectrum of one real frame: bins 0 ..< count go to `re` / `im`.
        func forward(_ frame: [Float], re: inout [Float], im: inout [Float]) {
            vDSP_DFT_Execute(forwardSetup, frame, zeros, &re, &im)
        }

        /// Real signal from a spectrum given for bins 0 ... n/2 (the rest by symmetry).
        func inverse(halfRe: [Float], halfIm: [Float], into out: inout [Float]) {
            let half = n / 2
            for k in 0...half {
                scratchRe[k] = halfRe[k]
                scratchIm[k] = halfIm[k]
            }
            if half + 1 < n {
                for k in (half + 1)..<n {
                    scratchRe[k] = halfRe[n - k]
                    scratchIm[k] = -halfIm[n - k]
                }
            }
            var imagOut = [Float](repeating: 0, count: n)
            vDSP_DFT_Execute(inverseSetup, scratchRe, scratchIm, &out, &imagOut)
            let s = inverseScale
            for k in 0..<n { out[k] *= s }
        }
    }

    // MARK: Entry point

    static func separate(modelURL: URL, source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model: MLModel
        do { model = try MLModel(contentsOf: modelURL, configuration: config) }
        catch { throw SeparationError.model(error.localizedDescription) }
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        let outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "output"

        guard let fft = FFT() else { throw SeparationError.model("FFT setup") }
        let (left, right) = try readStereo(source)
        let n = left.count
        guard n > 0 else { throw SeparationError.unreadable }

        let chunks = (n + gen - 1) / gen
        let paddedLength = chunks * gen + 2 * trim
        var padL = [Float](repeating: 0, count: paddedLength)
        var padR = [Float](repeating: 0, count: paddedLength)
        padL.replaceSubrange(trim..<(trim + n), with: left)
        padR.replaceSubrange(trim..<(trim + n), with: right)

        var window = [Float](repeating: 0, count: nFFT)
        for i in 0..<nFFT { window[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(nFFT))) }
        var envelope = [Float](repeating: 0, count: chunk + nFFT)
        for t in 0..<dimT {
            for i in 0..<nFFT { envelope[t * hop + i] += window[i] * window[i] }
        }

        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let plane = dimF * dimT
        let input = try MLMultiArray(shape: [1, 4, NSNumber(value: dimF), NSNumber(value: dimT)], dataType: .float16)

        var spec = [[Float]](repeating: [Float](repeating: 0, count: plane), count: 4)
        var frameRe = [Float](repeating: 0, count: nFFT)
        var frameIm = [Float](repeating: 0, count: nFFT)
        var frame = [Float](repeating: 0, count: nFFT)

        for c in 0..<chunks {
            let start = c * gen
            for ch in 0..<2 {
                let segment = Array((ch == 0 ? padL : padR)[start..<(start + chunk)])
                let padded = reflectPad(segment, by: trim)
                for t in 0..<dimT {
                    let o = t * hop
                    for i in 0..<nFFT { frame[i] = padded[o + i] * window[i] }
                    fft.forward(frame, re: &frameRe, im: &frameIm)
                    for f in 0..<dimF {
                        spec[ch * 2][f * dimT + t] = frameRe[f]
                        spec[ch * 2 + 1][f * dimT + t] = frameIm[f]
                    }
                }
            }
            // Pack into the model's input (fp16, channels L_re, L_im, R_re, R_im).
            let inPtr = input.dataPointer.bindMemory(to: Float16.self, capacity: 4 * plane)
            for p in 0..<4 {
                let base = p * plane
                let s = spec[p]
                for k in 0..<plane { inPtr[base + k] = Float16(s[k]) }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)])
            let result: MLFeatureProvider
            do { result = try model.prediction(from: provider) } catch { throw SeparationError.model(error.localizedDescription) }
            guard let output = result.featureValue(for: outputName)?.multiArrayValue else { throw SeparationError.model("no output") }

            // Read the output through its own strides (the Neural Engine pads rows).
            let strides = output.strides.map(\.intValue)
            guard strides.count == 4 else { throw SeparationError.model("unexpected output shape") }
            let isHalf = output.dataType == .float16
            let halfPtr = output.dataPointer.assumingMemoryBound(to: Float16.self)
            let floatPtr = output.dataPointer.assumingMemoryBound(to: Float.self)
            func value(_ p: Int, _ f: Int, _ t: Int) -> Float {
                let idx = p * strides[1] + f * strides[2] + t * strides[3]
                return isHalf ? Float(halfPtr[idx]) : floatPtr[idx]
            }

            for ch in 0..<2 {
                var wave = [Float](repeating: 0, count: chunk + nFFT)
                var halfRe = [Float](repeating: 0, count: nFFT / 2 + 1)
                var halfIm = [Float](repeating: 0, count: nFFT / 2 + 1)
                var time = [Float](repeating: 0, count: nFFT)
                for t in 0..<dimT {
                    for f in 0..<dimF {
                        halfRe[f] = value(ch * 2, f, t)
                        halfIm[f] = value(ch * 2 + 1, f, t)
                    }
                    halfRe[dimF] = 0
                    halfIm[dimF] = 0
                    fft.inverse(halfRe: halfRe, halfIm: halfIm, into: &time)
                    let o = t * hop
                    for i in 0..<nFFT { wave[o + i] += time[i] * window[i] }
                }
                // Undo the overlapping windows, drop the centre padding, then the chunk's edges.
                let keepFrom = nFFT / 2 + trim
                let outStart = start
                let count = min(gen, n - outStart)
                if count > 0 {
                    for i in 0..<count {
                        let w = wave[keepFrom + i]
                        let e = envelope[keepFrom + i]
                        let v = (e > 1e-6 ? w / e : 0) * compensate
                        if ch == 0 { outL[outStart + i] = v } else { outR[outStart + i] = v }
                    }
                }
            }
            progress(Double(c + 1) / Double(chunks))
        }

        try write(left: outL, right: outR, to: destination)
    }

    // MARK: Helpers

    private static func reflectPad(_ x: [Float], by pad: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: n + 2 * pad)
        for i in 0..<pad { out[i] = x[pad - i] }
        out.replaceSubrange(pad..<(pad + n), with: x)
        for j in 0..<pad { out[pad + n + j] = x[n - 2 - j] }
        return out
    }

    nonisolated private final class ReadContext: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var finished = false
        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) { self.file = file; self.buffer = buffer }
    }

    /// The song as 44.1 kHz stereo floats.
    private static func readStereo(_ url: URL) throws -> ([Float], [Float]) {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)
        else { throw SeparationError.unreadable }
        let context = ReadContext(file: file, buffer: inBuffer)
        var left: [Float] = [], right: [Float] = []
        let expected = Int(Double(file.length) * sampleRate / max(1, file.processingFormat.sampleRate))
        left.reserveCapacity(expected)
        right.reserveCapacity(expected)
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if context.finished { outStatus.pointee = .endOfStream; return nil }
                do { try context.file.read(into: context.buffer, frameCount: 32_768) } catch {
                    context.finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if context.buffer.frameLength == 0 {
                    context.finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return context.buffer
            }
            let frames = Int(outBuffer.frameLength)
            if frames > 0, let data = outBuffer.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
                right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: frames))
            }
            if status == .endOfStream || status == .error { break }
        }
        if left.isEmpty { throw SeparationError.unreadable }
        return (left, right)
    }

    private static func write(left: [Float], right: [Float], to url: URL) throws {
        let temp = url.deletingPathExtension().appendingPathExtension("part")
        try? FileManager.default.removeItem(at: temp)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100),
              let data = buffer.floatChannelData else { throw SeparationError.unreadable }
        var position = 0
        while position < left.count {
            let count = min(44_100, left.count - position)
            for i in 0..<count {
                data[0][i] = max(-1, min(1, left[position + i]))
                data[1][i] = max(-1, min(1, right[position + i]))
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            position += count
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }
}

// MARK: - Settings

/// Settings ▸ Sound: the downloadable vocal model behind the karaoke slider.
struct KaraokeModelSection: View {
    @State private var store = VocalModelStore.shared

    var body: some View {
        Section {
            switch store.state {
            case .missing:
                Button { store.download() } label: { Label("Download Vocal Remover (32 MB)", systemImage: "arrow.down.circle") }
            case .downloading(let p):
                HStack {
                    Label("Downloading…", systemImage: "arrow.down.circle.dotted")
                    Spacer()
                    Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: p)
            case .compiling:
                HStack { Label("Preparing the model…", systemImage: "gearshape.2"); Spacer(); ProgressView() }
            case .ready:
                Label("Vocal Remover Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Remove Vocal Remover", role: .destructive) { store.remove() }
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
                Button { store.download() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
            }
        } header: { Text("Karaoke") } footer: {
            Text("Karaoke removes the voice with an AI model (UVR MDX-Net), run on this device. It downloads by itself on Wi-Fi, and each song is prepared in the background while it plays, so the slider works right away. Until a song is ready the slider uses a simple voice cut.")
        }
    }
}

/// One line under the lyrics while karaoke is on: what the voice remover is doing for this song.
struct KaraokeStatusLabel: View {
    let trackID: UUID
    init(trackID: UUID) { self.trackID = trackID }
    @State private var stems = KaraokeStems.shared
    @State private var model = VocalModelStore.shared

    var body: some View {
        Group {
            if model.state != .ready {
                Text("Voice remover: get it in Settings › Sound")
            } else if case .working(let p) = stems.status[trackID] {
                Text("Removing vocals… \(Int(p * 100))%").monospacedDigit()
            } else if case .failed = stems.status[trackID] {
                Text("Couldn't remove the vocals")
            } else if stems.url(for: trackID) != nil {
                Text("Vocals removed")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.55))
    }
}
