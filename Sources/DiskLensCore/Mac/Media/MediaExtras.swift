#if os(macOS)
import Accelerate
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Similar & blurry photos

public struct SimilarGroup: Identifiable, Hashable, Sendable {
    public var id: String { items.first?.id ?? "" }
    public let items: [MediaItem]
    /// The sharpest, largest photo: suggested to keep.
    public let keep: String
    public let sharpness: [String: Double]

    public init(items: [MediaItem], keep: String, sharpness: [String: Double]) {
        self.items = items
        self.keep = keep
        self.sharpness = sharpness
    }
}

public struct SimilarResult: Sendable {
    public let groups: [SimilarGroup]
    /// Photos much blurrier than the rest (and not already in a similar group).
    public let blurry: [MediaItem]
    public let sharpness: [String: Double]
    public let checked: Int

    public init(groups: [SimilarGroup], blurry: [MediaItem], sharpness: [String: Double], checked: Int) {
        self.groups = groups
        self.blurry = blurry
        self.sharpness = sharpness
        self.checked = checked
    }
}

public enum SimilarPhotos {
    /// Groups photos taken within `windowMinutes` of each other that look alike (bursts, retakes).
    /// 0.3 was measured on real photos: the same shot re-framed, brightened or softened scored 0.13–0.34,
    /// different photos of the same style 0.46 and up. The time window keeps unrelated look-alikes apart.
    public static func groups(_ items: [MediaItem], windowMinutes: Double = 3, threshold: Float = 0.3,
                              image: @Sendable (MediaItem) async -> CGImage?,
                              progress: @escaping @Sendable (Int, Int) -> Void) async -> [SimilarGroup] {
        await analyze(items, windowMinutes: windowMinutes, threshold: threshold, image: image, progress: progress).groups
    }

    /// Similar groups plus blurry photos, in one pass over the photos.
    public static func analyze(_ items: [MediaItem], windowMinutes: Double = 3, threshold: Float = 0.3,
                               image: @Sendable (MediaItem) async -> CGImage?,
                               progress: @escaping @Sendable (Int, Int) -> Void) async -> SimilarResult {
        let photos = items.filter { $0.kind == .photo }.sorted { $0.date < $1.date }
        var prints: [String: VNFeaturePrintObservation] = [:]
        var sharp: [String: Double] = [:]
        for (i, p) in photos.enumerated() {
            if Task.isCancelled { break }
            if i % 10 == 0 { progress(i, photos.count) }
            guard let cg = await image(p) else { continue }
            prints[p.id] = featurePrint(cg)
            sharp[p.id] = sharpness(cg)
        }
        progress(photos.count, photos.count)

        // Union-find over neighbours in time.
        var parent = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.id) })
        func find(_ x: String) -> String { var x = x; while parent[x]! != x { x = parent[x]! }; return x }
        for (i, a) in photos.enumerated() {
            guard let pa = prints[a.id] else { continue }
            for b in photos[(i + 1)...] {
                if b.date.timeIntervalSince(a.date) > windowMinutes * 60 { break }
                guard let pb = prints[b.id] else { continue }
                var d: Float = 0
                if (try? pa.computeDistance(&d, to: pb)) != nil, d < threshold { parent[find(b.id)] = find(a.id) }
            }
        }
        let grouped = Dictionary(grouping: photos.filter { prints[$0.id] != nil }) { find($0.id) }.values.filter { $0.count > 1 }
        let groups = grouped.map { g in
            let keep = g.max { (sharp[$0.id] ?? 0, $0.bytes) < (sharp[$1.id] ?? 0, $1.bytes) }!.id
            return SimilarGroup(items: g, keep: keep, sharpness: sharp.filter { k, _ in g.contains { $0.id == k } })
        }.sorted { $0.items.first!.date > $1.items.first!.date }
        let inGroups = Set(groups.flatMap { $0.items.map(\.id) })
        let blurIDs = blurry(sharp)
        let blurryItems = photos.filter { blurIDs.contains($0.id) && !inGroups.contains($0.id) }.sorted { $0.date > $1.date }
        return SimilarResult(groups: groups, blurry: blurryItems, sharpness: sharp, checked: prints.count)
    }

    static let printContext = CIContext(options: [.cacheIntermediates: false])

    /// Feature print of a small, slightly softened copy, so focus and noise differences between
    /// burst shots matter less than what's actually in the picture.
    public static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let ci = CIImage(cgImage: image)
        let scale = 360 / max(ci.extent.width, ci.extent.height)
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: small.extent)
        let input = printContext.createCGImage(soft, from: soft.extent) ?? image
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: input).perform([req])
        return req.results?.first
    }

    /// Variance of the Laplacian on a 512 px greyscale copy: low means blurry.
    public static func sharpness(_ image: CGImage) -> Double {
        let side = 512
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = max(8, Int(Double(image.width) * scale)), h = max(8, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue), let data = ctx.data else { return 0 }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        var sum = 0.0, sq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(px[y * w + x]) * 4
                let l = c - Double(px[y * w + x - 1]) - Double(px[y * w + x + 1]) - Double(px[(y - 1) * w + x]) - Double(px[(y + 1) * w + x])
                sum += l; sq += l * l; n += 1
            }
        }
        let mean = sum / n
        return sq / n - mean * mean
    }

    /// Photos far blurrier than the rest of the set: under a fifth of the median sharpness, and soft in absolute terms.
    /// (Sharp photos score in the thousands at this size; a badly focused or shaken one, a few hundred or less.)
    public static func blurry(_ scores: [String: Double], absolute: Double = 300) -> Set<String> {
        let sorted = scores.values.sorted()
        guard sorted.count >= 3 else { return [] }
        let median = sorted[sorted.count / 2]
        return Set(scores.filter { $0.value < absolute && $0.value < median * 0.2 }.map(\.key))
    }
}

// MARK: - Enhance

public struct EnhanceOptions: Sendable, Hashable {
    /// Apple's auto-adjust: exposure, contrast, colour, shadows, red-eye.
    public var autoAdjust = true
    public var reduceNoise = true
    public var sharpen = true
    /// 0…1, blends the result with the original.
    public var strength: Double = 1
    public init() {}
}

public enum PhotoEnhancer {
    static let context = CIContext(options: [.cacheIntermediates: false])

    public static func enhance(_ image: CGImage, options: EnhanceOptions) -> CGImage? {
        let original = CIImage(cgImage: image)
        var out = original
        if options.autoAdjust {
            for filter in out.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(out, forKey: kCIInputImageKey)
                out = filter.outputImage ?? out
            }
        }
        if options.reduceNoise {
            out = out.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.015, "inputSharpness": 0.5])
        }
        if options.sharpen {
            out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.45, kCIInputRadiusKey: 1.5])
        }
        if options.strength < 1 {
            out = out.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: original, kCIInputTimeKey: 1 - options.strength])
        }
        return context.createCGImage(out.cropped(to: original.extent), from: original.extent)
    }

    /// Saves an enhanced copy next to `folder`, keeping the date taken (location removed if asked).
    public static func enhanceFile(_ path: String, options: EnhanceOptions, removePrivateInfo: Bool, into folder: URL) -> ConvertResult {
        let src = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let image = MediaConverter.orientedImage(source, maxPixels: 16_384),
              let enhanced = enhance(image, options: options) else {
            return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: "Not a readable photo")
        }
        let ext = src.pathExtension.lowercased() == "heic" ? "heic" : "jpg"
        let out = MediaConverter.uniqueURL(folder.appendingPathComponent(src.deletingPathExtension().lastPathComponent + " (enhanced)." + ext))
        var convert = ImageConvertOptions()
        convert.format = ext == "heic" ? .heic : .jpeg
        convert.quality = 0.92
        convert.removePrivateInfo = removePrivateInfo
        guard let data = MediaConverter.encode(enhanced, source: source, options: convert, quality: 0.92) else {
            return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: "Couldn't save")
        }
        do { try data.write(to: out) } catch {
            return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: error.localizedDescription)
        }
        return ConvertResult(source: path, output: out.path, bytes: Int64(data.count),
                             pixelSize: CGSize(width: enhanced.width, height: enhanced.height), message: "")
    }
}

extension PhotoEnhancer {
    /// For photos that aren't files (Photos library): saves an enhanced JPEG with no metadata at all.
    public static func enhanceImage(_ image: CGImage, name: String, options: EnhanceOptions, into folder: URL) -> ConvertResult {
        guard let enhanced = enhance(image, options: options) else {
            return ConvertResult(source: name, output: nil, bytes: 0, pixelSize: .zero, message: "Couldn't enhance")
        }
        let stem = (name as NSString).deletingPathExtension
        let out = MediaConverter.uniqueURL(folder.appendingPathComponent(stem + " (enhanced).jpg"))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return ConvertResult(source: name, output: nil, bytes: 0, pixelSize: .zero, message: "Couldn't save")
        }
        CGImageDestinationAddImage(dest, enhanced, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return ConvertResult(source: name, output: nil, bytes: 0, pixelSize: .zero, message: "Couldn't save")
        }
        let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int ?? 0)
        return ConvertResult(source: name, output: out.path, bytes: bytes, pixelSize: CGSize(width: enhanced.width, height: enhanced.height), message: "")
    }
}

// MARK: - Built-in music (generated on this Mac, royalty-free)

public enum MusicGenerator {
    public enum Mood: String, Sendable, CaseIterable, Identifiable {
        case calm, bright, warm
        public var id: Self { self }
        public var label: String {
            switch self {
            case .calm: "Calm (built-in)"
            case .bright: "Bright (built-in)"
            case .warm: "Warm (built-in)"
            }
        }
        /// Chord roots (MIDI notes) and seconds per chord.
        var progression: ([Int], Double) {
            switch self {
            case .calm: ([57, 53, 60, 55], 4)     // Am F C G
            case .bright: ([60, 67, 69, 65], 2.5) // C G Am F
            case .warm: ([62, 57, 59, 55], 3.5)   // D A Bm G
            }
        }
        var minorFirst: Bool { self == .calm }
    }

    /// A seamless 32-second pad loop, cached in ~/Library/Caches/DiskLens.
    public static func track(_ mood: Mood) throws -> URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/DiskLens/music")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(mood.rawValue)-v1.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try render(mood, to: url)
        return url
    }

    static func render(_ mood: Mood, to url: URL) throws {
        let rate = 44_100.0
        let (roots, perChord) = mood.progression
        let total = Int(rate * perChord * Double(roots.count) * 2)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
        let chordFrames = Int(rate * perChord)
        for i in 0..<total {
            let chord = (i / chordFrames) % roots.count
            let t = Double(i % chordFrames) / rate
            let root = Double(roots[chord])
            let minor = (chord == 0 && mood.minorFirst) || (mood == .warm && chord == 2) || (mood == .bright && chord == 2)
            let notes = [root - 12, root, root + (minor ? 3 : 4), root + 7, root + 12]
            // Soft attack and release per chord so chords blend without clicks.
            let env = min(1, t / 0.8) * min(1, (perChord - t) / 0.8)
            var l = 0.0, r = 0.0
            let time = Double(i) / rate
            for (k, n) in notes.enumerated() {
                let f = hz(n)
                let tone = sin(2 * .pi * f * time) + 0.25 * sin(2 * .pi * f * 2 * time) + 0.08 * sin(2 * .pi * f * 3 * time)
                let pan = Double(k) / Double(notes.count - 1)
                l += tone * (1 - pan * 0.5)
                r += tone * (0.5 + pan * 0.5)
            }
            let shimmer = 0.85 + 0.15 * sin(2 * .pi * 0.15 * time)
            left[i] = Float(l * env * shimmer * 0.06)
            right[i] = Float(r * env * shimmer * 0.06)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
#endif
