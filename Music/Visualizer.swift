import Accelerate
import AVFoundation
import Synchronization
import SwiftUI

// MARK: - Spectrum

/// Live spectrum of what's playing, fed by a tap on the engine's main mixer while a visualizer is on screen.
@Observable
final class Spectrum {
    static let shared = Spectrum()
    static let bandCount = 32

    @ObservationIgnored let analyzer = SpectrumAnalyzer(bandCount: bandCount)
    @ObservationIgnored private var previous = [Float](repeating: 0, count: bandCount)
    @ObservationIgnored private var target = [Float](repeating: 0, count: bandCount)
    @ObservationIgnored private var stamp = Date()
    @ObservationIgnored private var interval = 0.1

    /// Bands eased between the last two analyses, so drawing stays smooth although taps arrive ~10×/s.
    func bands(at date: Date) -> [Float] {
        let p = Float(min(1, max(0, date.timeIntervalSince(stamp) / interval)))
        return zip(previous, target).map { $0 + ($1 - $0) * p }
    }

    func push(_ raw: [Float]) {
        let now = Date()
        let current = bands(at: now)
        interval = min(0.25, max(0.02, now.timeIntervalSince(stamp)))
        previous = current
        // Rise fast, fall slowly.
        target = zip(current, raw).map { old, new in new > old ? new : old + (new - old) * 0.45 }
        stamp = now
    }
}

/// Hann window → FFT → log-spaced bands from 40 Hz to 16 kHz, each 0…1.
nonisolated final class SpectrumAnalyzer: @unchecked Sendable {
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private var window: [Float]
    private let bandCount: Int
    // Scratch buffers, reused: the tap delivers ~10 buffers a second, always on the same thread.
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private let active = Atomic<Bool>(false)
    /// Read on the audio thread, so it's atomic.
    var isActive: Bool {
        get { active.load(ordering: .relaxed) }
        set { active.store(newValue, ordering: .relaxed) }
    }

    init(bandCount: Int) {
        self.bandCount = bandCount
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&window, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
        samples = [Float](repeating: 0, count: 1024)
        real = [Float](repeating: 0, count: 512)
        imag = [Float](repeating: 0, count: 512)
        power = [Float](repeating: 0, count: 512)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func analyze(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let data = buffer.floatChannelData, Int(buffer.frameLength) >= n else { return nil }
        samples.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: data[0], count: n)
            if buffer.format.channelCount > 1 { vDSP_vadd(dst.baseAddress!, 1, data[1], 1, dst.baseAddress!, 1, vDSP_Length(n)) }
            vDSP_vmul(dst.baseAddress!, 1, window, 1, dst.baseAddress!, 1, vDSP_Length(n))
        }

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }

        let binHz = Float(buffer.format.sampleRate) / Float(n)
        let lo: Float = 40, hi: Float = 16_000
        var out = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let f0 = lo * pow(hi / lo, Float(b) / Float(bandCount))
            let f1 = lo * pow(hi / lo, Float(b + 1) / Float(bandCount))
            let i0 = max(1, Int(f0 / binHz))
            let i1 = min(n / 2 - 1, max(i0 + 1, Int(f1 / binHz)))
            var sum: Float = 0
            for i in i0..<i1 { sum += power[i] }
            let db = 10 * log10f(sum / Float(i1 - i0) + 1e-12)
            // Music has less energy up high; tilt so the treble moves too.
            out[b] = min(1, max(0, (db + 6 + Float(b) * 0.9) / 52))
        }
        return out
    }

    /// Built outside the main actor: the engine calls it on its audio thread.
    static func tapBlock(_ analyzer: SpectrumAnalyzer) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard analyzer.isActive, let bands = analyzer.analyze(buffer) else { return }
            Task { @MainActor in Spectrum.shared.push(bands) }
        }
    }
}

// MARK: - Visualizer

/// The cover turns like a record; the spectrum stands around it as a ring of fine bars, mirrored left and right.
/// The bass breathes the cover and a soft halo in the song's color. Still when paused.
struct LiquidVisualizer: View {
    let track: Track
    var tint: Color
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || !player.isPlaying)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let bands = player.isPlaying ? Spectrum.shared.bands(at: ctx.date) : [Float](repeating: 0, count: Spectrum.bandCount)
            let bass = CGFloat(bands.prefix(4).reduce(0, +) / 4)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let cover = side * 0.5
                ZStack {
                    Circle()
                        .fill(tint)
                        .frame(width: cover * (1.15 + bass * 0.35), height: cover * (1.15 + bass * 0.35))
                        .blur(radius: side * 0.12)
                        .opacity(0.35 + Double(bass) * 0.4)
                    Canvas { g, size in
                        Self.ring(in: &g, size: size, inner: cover / 2 + side * 0.035, reach: side * 0.17, bands: bands)
                    }
                    ArtworkView(track: track, radius: 0)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                        .overlay { Circle().fill(.black.opacity(0.85)).frame(width: cover * 0.07, height: cover * 0.07) }
                        .frame(width: cover, height: cover)
                        .rotationEffect(.degrees(reduceMotion ? 0 : t * 14))
                        .scaleEffect(1 + bass * 0.045)
                        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onAppear { player.setSpectrum(true) }
        .onDisappear { player.setSpectrum(false) }
        .accessibilityLabel("Visualizer")
    }

    /// 96 bars: bass at the top, treble at the bottom, the same on both sides.
    private static func ring(in g: inout GraphicsContext, size: CGSize, inner: CGFloat, reach: CGFloat, bands: [Float]) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let perSide = 48
        for side in [-1.0, 1.0] {
            for i in 0..<perSide {
                let f = Double(i) / Double(perSide - 1)
                // Sample the bands smoothly instead of in steps.
                let x = f * Double(bands.count - 1)
                let lo = Int(x), hi = min(bands.count - 1, lo + 1)
                let v = CGFloat(Double(bands[lo]) + (Double(bands[hi]) - Double(bands[lo])) * (x - Double(lo)))
                let angle = -Double.pi / 2 + side * (0.04 + f * (Double.pi - 0.08))
                let dir = CGPoint(x: cos(angle), y: sin(angle))
                let len = 3 + reach * v
                var p = Path()
                p.move(to: CGPoint(x: c.x + dir.x * inner, y: c.y + dir.y * inner))
                p.addLine(to: CGPoint(x: c.x + dir.x * (inner + len), y: c.y + dir.y * (inner + len)))
                g.stroke(p, with: .color(.white.opacity(0.35 + 0.6 * Double(v))), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
    }
}
