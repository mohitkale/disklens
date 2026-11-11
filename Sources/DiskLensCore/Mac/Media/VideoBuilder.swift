#if os(macOS)
import AVFoundation
import CoreImage
import CoreText
import Foundation

public struct VideoOptions: Sendable {
    public enum Shape: String, Sendable, CaseIterable, Identifiable {
        case landscape, portrait, square
        public var id: Self { self }
        public var size: CGSize {
            switch self {
            case .landscape: CGSize(width: 1920, height: 1080)
            case .portrait: CGSize(width: 1080, height: 1920)
            case .square: CGSize(width: 1080, height: 1080)
            }
        }
        public var label: String {
            switch self {
            case .landscape: "16:9 landscape (YouTube)"
            case .portrait: "9:16 portrait (Reels, Shorts)"
            case .square: "1:1 square"
            }
        }
    }

    public var shape: Shape = .landscape
    public var fps: Int32 = 30
    public var photoSeconds: Double = 3
    public var transitionSeconds: Double = 0.6
    /// Long clips are trimmed to this many seconds.
    public var maxClipSeconds: Double = 12
    public var title: String?
    public var subtitle: String?
    /// An audio file the user owns (mp3, m4a, wav, aiff).
    public var musicPath: String?
    public var keepClipAudio = true
    public var musicVolume: Float = 0.7
    /// Per-clip trims by item ID: start and length in seconds.
    public var trims: [String: ClipTrim] = [:]

    public init() {}
}

public struct ClipTrim: Sendable, Hashable {
    public var start: Double
    public var length: Double
    public init(start: Double, length: Double) {
        self.start = start
        self.length = length
    }
}

public enum VideoBuilderError: LocalizedError {
    case nothingToRender, writerFailed(String)
    public var errorDescription: String? {
        switch self {
        case .nothingToRender: "None of the selected photos or videos could be read. Items stored only in iCloud are skipped."
        case let .writerFailed(m): "The video couldn't be written: \(m)"
        }
    }
}

public struct VideoBuildResult: Sendable {
    public let url: URL
    public let duration: Double
    /// Items that couldn't be read (e.g. originals only in iCloud).
    public let skipped: Int
}

/// Builds one video from photos and clips: title card, gentle zoom on photos, crossfades, optional music.
public enum VideoBuilder {
    public static func build(items: [MediaItem], options: VideoOptions, output: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> VideoBuildResult {
        let temp = output.deletingLastPathComponent().appendingPathComponent(".disklens-video-\(UUID().uuidString.prefix(8)).mov")
        defer { if ProcessInfo.processInfo.environment["DISKLENS_KEEP_TEMP"] == nil { try? FileManager.default.removeItem(at: temp) } }
        let renderer = try FrameWriter(url: temp, size: options.shape.size, fps: options.fps)
        var clipAudio: [(asset: AVAsset, range: CMTimeRange, at: CMTime)] = []
        var skipped = 0

        if let title = options.title, !title.isEmpty {
            let card = titleCard(title, subtitle: options.subtitle, size: options.shape.size)
            try await renderer.hold(card, seconds: 2.5, transition: 0)
        }
        for (index, item) in items.enumerated() {
            progress(Double(index) / Double(max(items.count, 1)) * 0.85)
            switch item.kind {
            case .photo:
                guard let cg = await MediaLibrary.image(for: item, maxPixels: Int(max(options.shape.size.width, options.shape.size.height) * 1.3)) else {
                    skipped += 1; continue
                }
                let image = CIImage(cgImage: cg)
                let zoomIn = index % 2 == 0
                try await renderer.animate(seconds: options.photoSeconds, transition: options.transitionSeconds) { t in
                    let zoom = zoomIn ? 1 + 0.08 * t : 1.08 - 0.08 * t
                    return compose(image, canvas: options.shape.size, zoom: zoom, drift: CGPoint(x: (zoomIn ? 1 : -1) * 0.02 * t, y: 0.01 * t))
                }
            case .video:
                guard let asset = await MediaLibrary.asset(for: item) else { skipped += 1; continue }
                let start = renderer.time
                let trim = options.trims[item.id]
                guard let used = try await renderer.play(asset, start: trim?.start ?? 0, maxSeconds: trim?.length ?? options.maxClipSeconds,
                                                         transition: options.transitionSeconds,
                                                         compose: { compose($0, canvas: options.shape.size, zoom: 1, drift: .zero) }) else {
                    skipped += 1; continue
                }
                // Only clips that actually have sound join the audio mix (an empty audio track breaks reading).
                if options.keepClipAudio, let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty {
                    clipAudio.append((asset, CMTimeRange(start: CMTime(seconds: trim?.start ?? 0, preferredTimescale: 600), duration: used), start))
                }
            }
        }
        guard renderer.frames > 0, skipped < items.count else {
            renderer.cancel()
            throw VideoBuilderError.nothingToRender
        }
        try await renderer.finish()
        let total = renderer.time
        progress(0.9)

        try? FileManager.default.removeItem(at: output)
        let hasAudio = options.musicPath != nil || !clipAudio.isEmpty
        if hasAudio {
            try await mux(video: temp, music: options.musicPath.map { URL(fileURLWithPath: $0) }, clips: clipAudio,
                          duration: total, musicVolume: options.musicVolume, output: output)
        } else {
            try FileManager.default.moveItem(at: temp, to: output)
        }
        progress(1)
        return VideoBuildResult(url: output, duration: CMTimeGetSeconds(total), skipped: skipped)
    }

    // MARK: Composition helpers

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Fits `image` inside the canvas over a blurred, darkened fill of itself (no black bars).
    static func compose(_ image: CIImage, canvas: CGSize, zoom: CGFloat, drift: CGPoint) -> CIImage {
        let extent = image.extent
        let fill = max(canvas.width / extent.width, canvas.height / extent.height)
        let fit = min(canvas.width / extent.width, canvas.height / extent.height)
        let background = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 40)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 0.9])
        let bgExtent = image.extent.applying(CGAffineTransform(scaleX: fill, y: fill))
        let bg = background.transformed(by: CGAffineTransform(translationX: (canvas.width - bgExtent.width) / 2 - bgExtent.minX,
                                                              y: (canvas.height - bgExtent.height) / 2 - bgExtent.minY))
        // Same-shape images fill the frame; others are fitted. Zoom/drift give the slow "Ken Burns" motion.
        let sameShape = abs(extent.width / extent.height - canvas.width / canvas.height) < 0.12
        let scale = (sameShape ? fill : fit) * zoom
        let w = extent.width * scale, h = extent.height * scale
        let fg = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (canvas.width - w) / 2 + drift.x * canvas.width - extent.minX * scale,
                                               y: (canvas.height - h) / 2 + drift.y * canvas.height - extent.minY * scale))
        return fg.composited(over: bg).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// A title card: large title and a smaller subtitle on a soft gradient.
    /// Music volume over time as points with strictly increasing times: a fade in, a dip to a quarter
    /// while each clip plays its own sound (0.3 s transitions), and a fade out over the last 3 s.
    static func musicEnvelope(duration: Double, volume: Float, clips: [(start: Double, length: Double)]) -> [(time: Double, volume: Float)] {
        guard duration > 0.1 else { return [] }
        let fadeIn = min(1.5, duration / 3), fadeOut = min(3, duration / 3), dip = 0.3
        func base(_ t: Double) -> Double { min(1, t / fadeIn, (duration - t) / fadeOut) }
        func duck(_ t: Double) -> Double {
            var factor = 1.0
            for c in clips {
                let a = c.start, b = c.start + c.length
                let inside: Double
                if t <= a - dip || t >= b + dip { inside = 0 }
                else if t < a { inside = (t - (a - dip)) / dip }
                else if t <= b { inside = 1 }
                else { inside = ((b + dip) - t) / dip }
                factor = min(factor, 1 - 0.75 * inside)
            }
            return factor
        }
        var times: Set<Double> = [0, fadeIn, duration - fadeOut, duration]
        for c in clips { for t in [c.start - dip, c.start, c.start + c.length, c.start + c.length + dip] { times.insert(t) } }
        let sorted = times.filter { $0 >= 0 && $0 <= duration }.map { ($0 * 600).rounded() / 600 }
        var out: [(time: Double, volume: Float)] = []
        for t in Set(sorted).sorted() { out.append((t, Float(max(0, base(t) * duck(t))) * volume)) }
        return out
    }

    public static func titleCard(_ title: String, subtitle: String?, size: CGSize) -> CIImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(red: 0.10, green: 0.18, blue: 0.36, alpha: 1), CGColor(red: 0.04, green: 0.36, blue: 0.32, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        func draw(_ text: String, size pt: CGFloat, weight: CGFloat, y: CGFloat, alpha: CGFloat) {
            let font = CTFontCreateWithName("SF Pro Display" as CFString, pt, nil)
            let traits = [kCTFontWeightTrait: weight] as CFDictionary
            let desc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
            let styled = CTFontCreateCopyWithAttributes(font, pt, nil, desc)
            let attrs: [NSAttributedString.Key: Any] = [.font: styled, .foregroundColor: CGColor(gray: 1, alpha: alpha)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let scale = min(1, (size.width * 0.86) / max(bounds.width, 1))
            ctx.saveGState()
            ctx.translateBy(x: (size.width - bounds.width * scale) / 2, y: y)
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        let base = min(size.width, size.height)
        draw(title, size: base * 0.09, weight: 0.4, y: size.height * 0.5, alpha: 1)
        if let subtitle, !subtitle.isEmpty { draw(subtitle, size: base * 0.04, weight: 0, y: size.height * 0.5 - base * 0.08, alpha: 0.8) }
        return CIImage(cgImage: ctx.makeImage()!)
    }

    // MARK: Audio pass

    /// Adds music (looped, faded, ducked under clip sound) and clip audio; the picture is passed through untouched.
    static func mux(video: URL, music: URL?, clips: [(asset: AVAsset, range: CMTimeRange, at: CMTime)],
                    duration: CMTime, musicVolume: Float, output: URL) async throws {
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        guard let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoBuilderError.writerFailed("no video track")
        }
        let videoRange = try await srcVideo.load(.timeRange)
        let duration = CMTimeMinimum(duration, videoRange.duration)
        try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: srcVideo, at: .zero)

        var params: [AVMutableAudioMixInputParameters] = []
        // A track is only usable while its asset is alive, so the music asset is kept for the whole pass.
        let musicAsset = music.map { AVURLAsset(url: $0) }
        if let musicAsset, let src = try? await musicAsset.loadTracks(withMediaType: .audio).first,
           let mTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let len = try await musicAsset.load(.duration)
            var cursor = CMTime.zero
            while cursor < duration, CMTimeGetSeconds(len) > 0.5 {
                let piece = CMTimeMinimum(len, duration - cursor)
                try mTrack.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: src, at: cursor)
                cursor = cursor + piece
            }
            let p = AVMutableAudioMixInputParameters(track: mTrack)
            // One combined curve (fade in, duck under clip sound, fade out): AVFoundation rejects overlapping ramps.
            let envelope = musicEnvelope(duration: CMTimeGetSeconds(duration), volume: musicVolume,
                                         clips: clips.map { (CMTimeGetSeconds($0.at), CMTimeGetSeconds($0.range.duration)) })
            for (a, b) in zip(envelope, envelope.dropFirst()) {
                p.setVolumeRamp(fromStartVolume: a.volume, toEndVolume: b.volume,
                                timeRange: CMTimeRange(start: CMTime(seconds: a.time, preferredTimescale: 600),
                                                       end: CMTime(seconds: b.time, preferredTimescale: 600)))
            }
            params.append(p)
        }
        if !clips.isEmpty, let cTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            var inserted = false
            for clip in clips {
                if let a = try? await clip.asset.loadTracks(withMediaType: .audio).first,
                   (try? cTrack.insertTimeRange(clip.range, of: a, at: clip.at)) != nil { inserted = true }
            }
            if inserted { params.append(AVMutableAudioMixInputParameters(track: cTrack)) } else { comp.removeTrack(cTrack) }
        }
        if params.isEmpty {   // nothing audible after all: keep the picture as it is
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: video, to: output)
            return
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        try await AudioMuxer.write(composition: comp, audioMix: mix, to: output)
        withExtendedLifetime((videoAsset, musicAsset)) {}
    }
}

/// Writes frames to a movie at a fixed frame rate, with crossfades between segments.
final class FrameWriter: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let size: CGSize
    let fps: Int32
    private(set) var frames: Int64 = 0
    private var lastFrame: CIImage?

    var time: CMTime { CMTime(value: frames, timescale: fps) }

    init(url: URL, size: CGSize, fps: Int32) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(size.width * size.height * 6),
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        self.size = size
        self.fps = fps
        writer.add(input)
        guard writer.startWriting() else { throw VideoBuilderError.writerFailed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CIImage) async throws {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(4)) }
        guard let pool = adaptor.pixelBufferPool else { throw VideoBuilderError.writerFailed(writer.error?.localizedDescription ?? "pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw VideoBuilderError.writerFailed("buffer") }
        VideoBuilder.context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw VideoBuilderError.writerFailed(writer.error?.localizedDescription ?? "append")
        }
        frames += 1
        lastFrame = image
    }

    /// Crossfades from the previous segment's last frame during the first `transition` seconds.
    private func blended(_ image: CIImage, frame: Int, transitionFrames: Int, from previous: CIImage?) -> CIImage {
        guard let previous, frame < transitionFrames else { return image }
        let t = Double(frame + 1) / Double(transitionFrames + 1)
        return previous.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: t])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    func hold(_ image: CIImage, seconds: Double, transition: Double) async throws {
        try await animate(seconds: seconds, transition: transition) { _ in image }
    }

    func animate(seconds: Double, transition: Double, frame make: (CGFloat) -> CIImage) async throws {
        let count = max(1, Int(seconds * Double(fps)))
        let fade = Int(transition * Double(fps))
        let previous = lastFrame
        for i in 0..<count {
            try await append(blended(make(CGFloat(i) / CGFloat(count)), frame: i, transitionFrames: fade, from: previous))
        }
    }

    /// Plays a clip (up to `maxSeconds`) at the output frame rate. Returns how much of it was used.
    func play(_ asset: AVAsset, start: Double = 0, maxSeconds: Double, transition: Double, compose: (CIImage) -> CIImage) async throws -> CMTime? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let from = CMTimeMinimum(CMTime(seconds: max(0, start), preferredTimescale: 600), duration)
        let used = CMTimeMinimum(duration - from, CMTime(seconds: maxSeconds, preferredTimescale: 600))
        guard used > .zero else { return nil }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: from, duration: used)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { return nil }
        let previous = lastFrame
        let fade = Int(transition * Double(fps))
        let start = frames
        var written = 0
        while let sample = out.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - CMTimeGetSeconds(from)
            var image = CIImage(cvPixelBuffer: pixels).transformed(by: transform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let frame = compose(image)
            // Repeat or drop source frames so the clip keeps its real speed at the output frame rate.
            while Double(frames - start) / Double(fps) <= pts {
                try await append(blended(frame, frame: written, transitionFrames: fade, from: previous))
                written += 1
            }
        }
        reader.cancelReading()
        return written > 0 ? CMTime(value: Int64(written), timescale: fps) : nil
    }

    func finish() async throws {
        input.markAsFinished()
        // Gives the last frame its full length, so the file is exactly `time` long.
        writer.endSession(atSourceTime: time)
        await writer.finishWriting()
        if writer.status != .completed { throw VideoBuilderError.writerFailed(writer.error?.localizedDescription ?? "finish") }
    }

    func cancel() { writer.cancelWriting() }
}

/// Copies the video track as-is and encodes the mixed audio to AAC, interleaving both into one file.
enum AudioMuxer {
    static func write(composition: AVComposition, audioMix: AVAudioMix, to url: URL) async throws {
        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        guard let vTrack = try await composition.loadTracks(withMediaType: .video).first else { throw VideoBuilderError.writerFailed("video") }
        let aTracks = try await composition.loadTracks(withMediaType: .audio)

        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        reader.add(vOut)
        let formats = try await vTrack.load(.formatDescriptions)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var aOut: AVAssetReaderAudioMixOutput?
        var aIn: AVAssetWriterInput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            o.audioMix = audioMix
            reader.add(o)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                                          AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            aOut = o
            aIn = i
        }
        guard reader.startReading(), writer.startWriting() else {
            throw VideoBuilderError.writerFailed((writer.error ?? reader.error)?.localizedDescription ?? "start")
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, label: String) {
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "disklens.mux.\(label)")
                        var done = false
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData && !done {
                                if let s = output.copyNextSampleBuffer() { input.append(s) } else {
                                    done = true
                                    input.markAsFinished()
                                    c.resume()
                                }
                            }
                        }
                    }
                }
            }
            pump(vIn, vOut, label: "video")
            if let aIn, let aOut { pump(aIn, aOut, label: "audio") }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw VideoBuilderError.writerFailed(writer.error?.localizedDescription ?? "mux") }
    }
}
#endif
