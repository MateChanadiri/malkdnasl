import AVFoundation
import CoreImage
import MediaPlayer
import UIKit

// MARK: - Style

nonisolated enum LockArtLayout: String, CaseIterable, Identifiable, Sendable {
    /// The cover fills the whole Lock Screen.
    case fill
    /// The cover sits on a blurred copy of itself, so nothing is cropped.
    case framed
    var id: String { rawValue }
    var title: String { self == .fill ? "Fill" : "Framed" }
}

nonisolated enum LockArtMotion: String, CaseIterable, Identifiable, Sendable {
    case still, breathe, drift
    var id: String { rawValue }
    var title: String {
        switch self {
        case .still: "Still"
        case .breathe: "Breathe"
        case .drift: "Drift"
        }
    }
    /// Length of one seamless loop.
    var loop: Double { self == .drift ? 20 : self == .breathe ? 12 : 2 }
    var fps: Int32 { self == .still ? 1 : 24 }
}

// MARK: - Now Playing artwork

/// Artwork for the system Now Playing (Lock Screen, Dynamic Island, Control Center, CarPlay).
/// Built once per song and style — handing the system a new object on every update makes it reload the image.
@MainActor
final class NowPlayingArtwork {
    static let shared = NowPlayingArtwork()

    private var squareKey = ""
    private var square: MPMediaItemArtwork?
    private var tallKey = ""
    private var tall: MPMediaItemAnimatedArtwork?
    private var tallJob: LockArtJob?
    private var tallGeneration = 0

    func invalidateFullscreen() {
        tall = nil
        tallGeneration += 1
    }

    static var supportsFullscreen: Bool {
        MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork)
    }

    func square(for t: Track) -> MPMediaItemArtwork? {
        let key = Self.key(t)
        if key != squareKey {
            squareKey = key
            square = Self.cover(t).map(Self.makeArtwork)
        }
        return square
    }

    /// The tall, full-screen Lock Screen artwork, rendered as a short looping video from the cover.
    func fullscreen(for t: Track, settings: AppSettings) -> MPMediaItemAnimatedArtwork? {
        guard settings.lockArtwork, Self.supportsFullscreen else { tall = nil; return nil }
        let style = LockArtStyle(layout: settings.lockArtLayout, motion: settings.lockArtMotion)
        let key = "\(Self.key(t))-\(style.id)"
        if key == tallKey, let tall { return tall }
        if key != tallKey {
            tallKey = key
            tallJob = Self.cover(t)?.cgImage.map { LockArtJob(key: key, cover: $0, style: style) }
        }
        guard let job = tallJob else { return nil }
        // Prepare local assets before the screen locks, rather than starting the encoder
        // only when the system first asks for a video in the background. Reuse any in-flight job.
        Task { await job.prepare() }
        tall = Self.makeAnimated(job, artworkID: "\(key)-request-\(tallGeneration)")
        return tall
    }

    private static func key(_ t: Track) -> String { "\(t.id.uuidString)-\(t.artVersion ?? 0)-\(t.hasArtwork)" }

    private static func cover(_ t: Track) -> UIImage? {
        ArtworkCache.image(for: t) ?? CoverKit.image(CoverKit.auto(t.album + t.artist), side: 1000)
    }

    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Kept nonisolated: the system calls these handlers on its own queues.
    nonisolated private static func makeAnimated(_ job: LockArtJob, artworkID: String) -> MPMediaItemAnimatedArtwork {
        MPMediaItemAnimatedArtwork(artworkID: artworkID) { _, done in
            // Called exactly once, from any queue (see MPMediaItemAnimatedArtwork).
            nonisolated(unsafe) let done = done
            Task { done(await job.preview()) }
        } videoAssetFileURLRequestHandler: { _, done in
            nonisolated(unsafe) let done = done
            Task { done(await job.video()) }
        }
    }
}

// MARK: - Rendering

nonisolated struct LockArtStyle: Hashable, Sendable {
    var layout: LockArtLayout
    var motion: LockArtMotion
    var id: String { "\(layout.rawValue)-\(motion.rawValue)-v\(LockArtRenderer.version)" }
}

/// Prepares and reuses the preview and video off the main thread; failed renders can be retried.
actor LockArtJob {
    nonisolated let key: String
    private let cover: CGImage
    private let style: LockArtStyle
    private var renderer: LockArtRenderer?
    private var rendering: Task<URL?, Never>?
    private var previewImage: UIImage?
    private let asset: LockArtAsset?

    init(key: String, cover: CGImage, style: LockArtStyle) {
        self.key = key
        self.cover = cover
        self.style = style
        asset = LockArtRenderer.cacheDir.map { LockArtAsset(url: $0.appendingPathComponent("\(key).mp4")) }
    }

    private func make() -> LockArtRenderer {
        if let renderer { return renderer }
        let r = LockArtRenderer(cover: cover, style: style)
        renderer = r
        return r
    }

    func preview() -> UIImage? {
        if let previewImage { return previewImage }
        previewImage = make().frame(at: 0).map(UIImage.init(cgImage:))
        return previewImage
    }

    func prepare() async {
        _ = preview()
        _ = await video()
    }

    func video() async -> URL? {
        if let rendering { return await rendering.value }
        guard let url = asset?.url else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let r = make()
        let task = Task.detached(priority: .utility) { await r.writeVideo(to: url) ? url : nil }
        rendering = task
        // Give an in-flight render time to finish if the user locks the phone while paused.
        let background = await LockArtBackgroundTask(rendering: task)
        let result = await task.value
        await background.end()
        rendering = nil // A failed attempt must not poison all subsequent requests.
        return result
    }
}

@MainActor
private final class LockArtBackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(rendering: Task<URL?, Never>) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Lock Screen Artwork") { [weak self] in
            rendering.cancel()
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let active = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(active)
    }
}

/// The request handlers retain the job, so its file must survive cache pruning for that lifetime.
nonisolated final class LockArtAsset: @unchecked Sendable {
    let url: URL
    private static let lock = NSLock()
    nonisolated(unsafe) private static var retained: [URL: Int] = [:]

    init(url: URL) {
        self.url = url
        Self.lock.withLock { Self.retained[url, default: 0] += 1 }
    }

    deinit {
        Self.lock.withLock {
            let count = (Self.retained[url] ?? 1) - 1
            Self.retained[url] = count > 0 ? count : nil
        }
    }

    static func prune(in dir: URL) {
        lock.withLock {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let unused = files.filter { $0.pathExtension == "mp4" && retained[$0] == nil }
            let old = unused.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }.dropFirst(6)
            for file in old { try? fm.removeItem(at: file) }
        }
    }
}

nonisolated struct LockArtRenderer: Sendable {
    static let width = 1080, height = 1440
    /// Bump when the drawing changes, so cached loops are rebuilt.
    static let version = 3

    let cover: CGImage
    let backdrop: CGImage?
    let style: LockArtStyle

    init(cover: CGImage, style: LockArtStyle) {
        self.cover = cover
        self.style = style
        backdrop = style.layout == .framed ? Self.blurred(cover) : nil
    }

    static var cacheDir: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("LockArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func frame(at t: Double) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(in: ctx, at: t)
        return ctx.makeImage()
    }

    private func draw(in ctx: CGContext, at t: Double) {
        let W = Double(Self.width), H = Double(Self.height)
        let p = t / style.motion.loop
        let wave = (1 - cos(2 * .pi * p)) / 2   // 0 → 1 → 0, loops cleanly
        ctx.interpolationQuality = .high
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        switch style.layout {
        case .fill:
            var zoom = 1.0, panX = 0.0, panY = 0.0
            switch style.motion {
            case .still: break
            case .breathe: zoom = 1 + 0.08 * wave
            case .drift: zoom = 1.06; panX = sin(2 * .pi * p); panY = 0.6 * cos(2 * .pi * p)
            }
            drawFilled(cover, in: ctx, zoom: zoom, panX: panX, panY: panY)
        case .framed:
            if let backdrop {
                let drifting = style.motion == .drift
                drawFilled(backdrop, in: ctx, zoom: drifting ? 1.12 : 1.04,
                           panX: drifting ? sin(2 * .pi * p) : 0, panY: drifting ? 0.6 * cos(2 * .pi * p) : 0)
            }
            let side = W * 0.74 * (style.motion == .breathe ? 1 + 0.04 * wave : 1)
            let rect = CGRect(x: (W - side) / 2, y: H * 0.54 - side / 2, width: side, height: side)
            let path = CGPath(roundedRect: rect, cornerWidth: side * 0.05, cornerHeight: side * 0.05, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: UIColor.black.withAlphaComponent(0.55).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.draw(cover, in: rect)
            ctx.restoreGState()
        }
    }

    /// Aspect-fills the frame; `panX`/`panY` (-1…1) move across whatever overflows.
    private func drawFilled(_ image: CGImage, in ctx: CGContext, zoom: Double, panX: Double, panY: Double) {
        let W = Double(Self.width), H = Double(Self.height)
        let iw = Double(image.width), ih = Double(image.height)
        let s = max(W / iw, H / ih) * zoom
        let dw = iw * s, dh = ih * s
        let x = (W - dw) / 2 + panX * (dw - W) / 2
        let y = (H - dh) / 2 + panY * (dh - H) / 2
        ctx.draw(image, in: CGRect(x: x, y: y, width: dw, height: dh))
    }

    private static func blurred(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(image.width) * 0.04)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.18, kCIInputSaturationKey: 1.2])
            .cropped(to: input.extent)
        // A Lock Screen request can arrive while the app is in the background, where GPU work
        // is unavailable. The backdrop is rendered only once per job.
        return CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]).createCGImage(output, from: input.extent)
    }

    func writeVideo(to url: URL) async -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".rendering")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mp4) else { return false }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width,
            AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let fps = style.motion.fps
        let count = Int(style.motion.loop * Double(fps))
        for i in 0..<count {
            let deadline = ContinuousClock.now + .seconds(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, !Task.isCancelled, ContinuousClock.now < deadline else { return false }
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
            }
            guard writer.status == .writing, !Task.isCancelled, let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return false }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
            guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Self.width, height: Self.height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                return false
            }
            draw(in: ctx, at: Double(i) / Double(fps))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: fps)) else { return false }
        }
        guard !Task.isCancelled else { return false }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(count), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { return false }

        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard (try? fm.moveItem(at: tmp, to: url)) != nil else { return false }
        // The system must be able to read the finished asset while the device is locked.
        do { try fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path) }
        catch { try? fm.removeItem(at: url); return false }
        LockArtAsset.prune(in: url.deletingLastPathComponent())
        return true
    }
}
