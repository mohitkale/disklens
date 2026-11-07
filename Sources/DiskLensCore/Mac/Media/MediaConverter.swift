#if os(macOS)
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageConvertOptions: Sendable {
    public enum Format: String, Sendable, CaseIterable, Identifiable {
        case jpeg, heic, png, tiff
        public var id: Self { self }
        public var label: String { rawValue.uppercased() }
        public var ext: String { self == .jpeg ? "jpg" : rawValue }
        var type: UTType { switch self { case .jpeg: .jpeg; case .heic: .heic; case .png: .png; case .tiff: .tiff } }
        public var isLossy: Bool { self == .jpeg || self == .heic }
    }

    public enum Resize: Sendable, Hashable {
        case original
        /// Longest side in pixels.
        case longestSide(Int)
        case percent(Int)
    }

    public var format: Format = .jpeg
    public var resize: Resize = .original
    /// Crop to this width/height ratio (nil keeps the shape).
    public var cropRatio: CGFloat?
    /// For JPEG/HEIC: shrink until the file is at most this size.
    public var maxBytes: Int64?
    public var quality: Double = 0.88
    /// Removes location, device and owner details from the output (on by default).
    public var removePrivateInfo = true

    public init() {}
}

public struct ConvertResult: Sendable {
    public let source: String
    public let output: String?
    public let bytes: Int64
    public let pixelSize: CGSize
    public let message: String
    public var ok: Bool { output != nil }

    public init(source: String, output: String?, bytes: Int64, pixelSize: CGSize, message: String) {
        self.source = source
        self.output = output
        self.bytes = bytes
        self.pixelSize = pixelSize
        self.message = message
    }
}

public enum MediaConverter {
    // MARK: Images

    public static func convertImage(_ path: String, options: ImageConvertOptions, into folder: URL) -> ConvertResult {
        let src = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: "Not a readable image")
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(w, h)
        var target: Int = {
            switch options.resize {
            case .original: longest
            case let .longestSide(px): min(px, longest)
            case let .percent(p): max(16, longest * p / 100)
            }
        }()
        let out = uniqueURL(folder.appendingPathComponent(src.deletingPathExtension().lastPathComponent + "." + options.format.ext))
        var quality = options.quality
        for _ in 0..<12 {
            guard var image = orientedImage(source, maxPixels: target) else { break }
            if let ratio = options.cropRatio { image = crop(image, to: ratio) }
            let data = encode(image, source: source, options: options, quality: quality)
            guard let data else { break }
            if let max = options.maxBytes, options.format.isLossy, Int64(data.count) > max {
                // First lower the quality (down to 0.5), then shrink the dimensions.
                if quality > 0.55 { quality -= 0.1; continue }
                target = Int(Double(target) * 0.85)
                if target < 200 { break }
                continue
            }
            do { try data.write(to: out) } catch {
                return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: error.localizedDescription)
            }
            let note = options.maxBytes.map { Int64(data.count) <= $0 ? "under \(ByteFormat.string($0))" : "" } ?? ""
            return ConvertResult(source: path, output: out.path, bytes: Int64(data.count),
                                 pixelSize: CGSize(width: image.width, height: image.height), message: note)
        }
        return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero,
                             message: options.maxBytes != nil ? "Couldn't reach that file size without making it tiny" : "Couldn't convert")
    }

    static func orientedImage(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    public static func crop(_ image: CGImage, to ratio: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = w / h > ratio
            ? CGRect(x: ((w - h * ratio) / 2).rounded(), y: 0, width: (h * ratio).rounded(), height: h)
            : CGRect(x: 0, y: ((h - w / ratio) / 2).rounded(), width: w, height: (w / ratio).rounded())
        return image.cropping(to: rect) ?? image
    }

    static func encode(_ image: CGImage, source: CGImageSource, options: ImageConvertOptions, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, options.format.type.identifier as CFString, 1, nil) else { return nil }
        // The thumbnail is already rotated upright, so orientation is reset. Keep the capture date and colour info;
        // drop location/device/owner when asked.
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: 1]
        if !options.removePrivateInfo, let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary] {
                if let v = original[key] { props[key] = v }
            }
        } else if let exif = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyExifDictionary] as? [CFString: Any],
                  let taken = exif[kCGImagePropertyExifDateTimeOriginal] {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: taken]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: Videos

    public enum VideoPreset: String, Sendable, CaseIterable, Identifiable {
        case hevc4K, hevc1080, h264_1080, h264_720, h264_540
        public var id: Self { self }
        public var label: String {
            switch self {
            case .hevc4K: "4K · HEVC (smallest at high quality)"
            case .hevc1080: "1080p · HEVC (recommended)"
            case .h264_1080: "1080p · H.264 (plays everywhere)"
            case .h264_720: "720p · H.264"
            case .h264_540: "540p · H.264 (small, for messaging)"
            }
        }
        var avPreset: String {
            switch self {
            case .hevc4K: AVAssetExportPresetHEVC3840x2160
            case .hevc1080: AVAssetExportPresetHEVC1920x1080
            case .h264_1080: AVAssetExportPreset1920x1080
            case .h264_720: AVAssetExportPreset1280x720
            case .h264_540: AVAssetExportPreset960x540
            }
        }
    }

    public static func convertVideo(_ path: String, preset: VideoPreset, removePrivateInfo: Bool, into folder: URL,
                                    progress: @escaping @Sendable (Double) -> Void) async -> ConvertResult {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset.avPreset) else {
            return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: "This format isn't supported")
        }
        let out = uniqueURL(folder.appendingPathComponent(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".mp4"))
        exporter.outputURL = out
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        if removePrivateInfo { exporter.metadataItemFilter = .forSharing() }
        let timer = Task {
            while !Task.isCancelled {
                progress(Double(exporter.progress))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in exporter.exportAsynchronously { c.resume() } }
        timer.cancel()
        guard exporter.status == .completed else {
            return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: exporter.error?.localizedDescription ?? "Export failed")
        }
        let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int ?? 0)
        return ConvertResult(source: path, output: out.path, bytes: bytes, pixelSize: .zero, message: "")
    }

    /// An animated GIF from the first `seconds` of a video.
    public static func videoToGIF(_ path: String, seconds: Double = 6, width: Int = 640, fps: Double = 12, into folder: URL) async -> ConvertResult {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let length = min(seconds, duration)
        guard length > 0 else { return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: "Not a readable video") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width * 4)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        let count = max(1, Int(length * fps))
        let out = uniqueURL(folder.appendingPathComponent(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".gif"))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: "Couldn't create the GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var size = CGSize.zero
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            guard let frame = try? await generator.image(at: t).image else { continue }
            size = CGSize(width: frame.width, height: frame.height)
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: "Couldn't write the GIF") }
        let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int ?? 0)
        return ConvertResult(source: path, output: out.path, bytes: bytes, pixelSize: size, message: "")
    }

    /// "photo.jpg", then "photo 2.jpg", "photo 3.jpg"… so nothing is ever overwritten.
    public static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
            n += 1
        }
        return candidate
    }
}
#endif
