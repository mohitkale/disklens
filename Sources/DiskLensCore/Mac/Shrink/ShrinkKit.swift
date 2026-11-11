#if os(macOS)
import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Compress a video to a target size

public enum VideoCompressor {
    /// Common limits people hit.
    public static let presets: [(label: String, bytes: Int64)] = [
        ("Under 16 MB (WhatsApp)", 16_000_000), ("Under 25 MB (email)", 25_000_000),
        ("Under 50 MB", 50_000_000), ("Under 100 MB", 100_000_000),
    ]

    /// Re-encodes to H.264 (plays everywhere) at the bitrate that fits `targetBytes`, lowering the resolution
    /// when the bitrate gets too low for it. Tries again a little smaller if the first pass overshoots.
    public static func compress(_ path: String, targetBytes: Int64, removePrivateInfo: Bool = true, into folder: URL? = nil,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> ConvertResult {
        let src = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: src)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0.5,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform)
        else { return fail(path, "Not a readable video") }
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        let shown = natural.applying(transform)
        let size = CGSize(width: abs(shown.width), height: abs(shown.height))
        let original = Int64((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0)
        guard targetBytes < original else {
            return ConvertResult(source: path, output: nil, bytes: original, pixelSize: size, message: "It's already under that size.")
        }
        let audioBits = hasAudio ? 96_000.0 : 0
        var videoBits = Double(targetBytes) * 8 * 0.93 / duration - audioBits
        guard videoBits >= 200_000 else {
            let minimum = Int64((200_000 + audioBits) * duration / 8 / 0.93)
            return ConvertResult(source: path, output: nil, bytes: original, pixelSize: size,
                                 message: "This video is too long for that size. The smallest watchable version is about \(ByteFormat.string(minimum)).")
        }
        let dir = folder ?? src.deletingLastPathComponent()
        let out = MediaConverter.uniqueURL(dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + " (compressed).mp4"))
        for attempt in 0..<3 {
            let longest: CGFloat = videoBits >= 3_500_000 ? 1920 : videoBits >= 1_600_000 ? 1280 : videoBits >= 800_000 ? 960 : 640
            let scale = min(1, longest / max(size.width, size.height))
            let target = CGSize(width: (size.width * scale / 2).rounded() * 2, height: (size.height * scale / 2).rounded() * 2)
            try? FileManager.default.removeItem(at: out)
            do {
                try await transcode(asset, to: out, size: target, videoBits: videoBits, audio: hasAudio, duration: duration,
                                    removePrivateInfo: removePrivateInfo) { progress((Double(attempt) + $0) / 3) }
            } catch {
                try? FileManager.default.removeItem(at: out)
                return fail(path, error.localizedDescription)
            }
            let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int ?? 0)
            if bytes <= targetBytes {
                progress(1)
                // Verify it plays for as long as the original.
                let check = try? await AVURLAsset(url: out).load(.duration).seconds
                guard let check, abs(check - duration) < 1 else {
                    try? FileManager.default.removeItem(at: out)
                    return fail(path, "The result was shorter than the original, so it wasn't kept.")
                }
                return ConvertResult(source: path, output: out.path, bytes: bytes, pixelSize: target,
                                     message: "\(ByteFormat.string(original)) → \(ByteFormat.string(bytes)) at \(Int(target.width))×\(Int(target.height))")
            }
            videoBits *= 0.85 * Double(targetBytes) / Double(bytes)
        }
        try? FileManager.default.removeItem(at: out)
        return fail(path, "Couldn't get it under that size.")
    }

    static func transcode(_ asset: AVAsset, to out: URL, size: CGSize, videoBits: Double, audio: Bool, duration: Double,
                          removePrivateInfo: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        if !removePrivateInfo, let meta = try? await asset.load(.metadata) { writer.metadata = meta }

        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ShrinkError.unreadable }
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = composition
        reader.add(vOut)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(videoBits), AVVideoMaxKeyFrameIntervalDurationKey: 2,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var aOut: AVAssetReaderTrackOutput?
        var aIn: AVAssetWriterInput?
        if audio, let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                                             AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                                                             AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                                                             AVLinearPCMIsNonInterleaved: false])
            reader.add(o)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            aOut = o; aIn = i
        }
        guard reader.startReading(), writer.startWriting() else { throw ShrinkError.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Couldn't start") }
        writer.startSession(atSourceTime: .zero)

        let box = WriterBox(reader: reader, writer: writer)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(vOut, into: vIn, queue: "video", duration: duration, progress: progress) }
            if let aOut, let aIn { group.addTask { await pump(aOut, into: aIn, queue: "audio", duration: duration, progress: { _ in }) } }
        }
        _ = box
        if reader.status == .failed { writer.cancelWriting(); throw ShrinkError.failed(reader.error?.localizedDescription ?? "Couldn't read the video") }
        await writer.finishWriting()
        if writer.status != .completed { throw ShrinkError.failed(writer.error?.localizedDescription ?? "Couldn't write the video") }
    }

    private final class WriterBox: @unchecked Sendable {
        let reader: AVAssetReader, writer: AVAssetWriter
        init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue: String, duration: Double,
                             progress: @escaping @Sendable (Double) -> Void) async {
        let sendable = UncheckedPair(output: output, input: input)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: "disklens.compress.\(queue)")
            var finished = false
            sendable.input.requestMediaDataWhenReady(on: q) {
                while sendable.input.isReadyForMoreMediaData && !finished {
                    if let sample = sendable.output.copyNextSampleBuffer() {
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if t.isFinite { progress(min(1, t / duration)) }
                        if !sendable.input.append(sample) { finished = true }
                    } else {
                        finished = true
                    }
                }
                if finished {
                    sendable.input.markAsFinished()
                    done.resume()
                }
            }
        }
    }

    private struct UncheckedPair: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }

    static func fail(_ path: String, _ message: String) -> ConvertResult {
        ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: message)
    }
}

enum ShrinkError: LocalizedError {
    case unreadable, failed(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: "Not a readable file"
        case let .failed(m): m
        }
    }
}

// MARK: - Remove background

public enum BackgroundRemover {
    /// The main subject (people, pets, objects) cut out with Apple's on-device subject lifting.
    /// nil if no clear subject was found.
    public static func cutout(_ image: CGImage, background: CGColor? = nil) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let result = request.results?.first, !result.allInstances.isEmpty,
              let mask = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) else { return nil }
        let input = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: mask)
        let back = background.map { CIImage(color: CIColor(cgColor: $0)).cropped(to: input.extent) } ?? CIImage.empty().cropped(to: input.extent)
        let out = input.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: back, kCIInputMaskImageKey: maskImage])
        return context.createCGImage(out, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Saves "name (cut out).png" (transparent) or a JPEG on the chosen colour. Location and camera details aren't copied.
    public static func save(_ path: String, background: CGColor?, into folder: URL) -> ConvertResult {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = MediaConverter.orientedImage(source, maxPixels: 8_192) else {
            return ConvertResult(source: path, output: nil, bytes: 0, pixelSize: .zero, message: "Not a readable photo")
        }
        return save(image, name: (path as NSString).lastPathComponent, background: background, into: folder)
    }

    public static func save(_ image: CGImage, name: String, background: CGColor?, into folder: URL) -> ConvertResult {
        guard let cut = cutout(image, background: background) else {
            return ConvertResult(source: name, output: nil, bytes: 0, pixelSize: .zero, message: "No clear subject found in this photo")
        }
        let ext = background == nil ? "png" : "jpg"
        let out = MediaConverter.uniqueURL(folder.appendingPathComponent((name as NSString).deletingPathExtension + " (cut out).\(ext)"))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, (ext == "png" ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else {
            return ConvertResult(source: name, output: nil, bytes: 0, pixelSize: .zero, message: "Couldn't save")
        }
        CGImageDestinationAddImage(dest, cut, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return ConvertResult(source: name, output: nil, bytes: 0, pixelSize: .zero, message: "Couldn't save") }
        let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int ?? 0)
        return ConvertResult(source: name, output: out.path, bytes: bytes, pixelSize: CGSize(width: cut.width, height: cut.height), message: "")
    }
}

// MARK: - Biggest files that could be smaller

public struct ShrinkCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case video, pdf, image }
    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let bytes: Int64
    /// Rough size after shrinking, when it can be estimated without doing the work (videos, images).
    public let estimate: Int64?
    /// e.g. "4K · 12 min · 38 Mbps" or "PNG screenshot".
    public let detail: String
    public let modified: Date?
    public var name: String { (path as NSString).lastPathComponent }
    public var estimatedSaving: Int64? { estimate.map { max(0, bytes - $0) } }

    public init(path: String, kind: Kind, bytes: Int64, estimate: Int64?, detail: String, modified: Date?) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.estimate = estimate
        self.detail = detail
        self.modified = modified
    }
}

public enum ShrinkFinder {
    public static var defaultFolders: [String] {
        ["~/Desktop", "~/Documents", "~/Downloads", "~/Movies", "~/Pictures"].map { ($0 as NSString).expandingTildeInPath }
    }

    static let videoTypes: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv"]
    static let skip: Set<String> = ["node_modules", "Pods", "DerivedData", "build", ".git"]

    /// Videos over 100 MB, PDFs over 10 MB and uncompressed or huge images over 8 MB. Read-only.
    public static func scan(folders: [String] = defaultFolders, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> [ShrinkCandidate] {
        var found: [(String, Int64, Date?)] = []
        for folder in folders {
            progress("Looking in " + (folder as NSString).lastPathComponent)
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
                                                              includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL {
                let name = url.lastPathComponent
                if skip.contains(name) || name.hasSuffix(".photoslibrary") || name.hasSuffix(".app") { walker.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                let min: Int64 = videoTypes.contains(ext) ? 100_000_000 : ext == "pdf" ? 10_000_000 : ["png", "tif", "tiff", "bmp", "jpg", "jpeg"].contains(ext) ? 8_000_000 : -1
                guard min > 0, let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = v.fileSize, Int64(size) >= min else { continue }
                found.append((url.path, Int64(size), v.contentModificationDate))
            }
        }
        progress("Estimating savings")
        var out: [ShrinkCandidate] = []
        for (path, bytes, date) in found {
            let ext = (path as NSString).pathExtension.lowercased()
            if videoTypes.contains(ext) {
                if let c = await videoCandidate(path, bytes: bytes, date: date) { out.append(c) }
            } else if ext == "pdf" {
                let info = PDFTools.info(path)
                let perPage = info.map { $0.pages > 0 ? $0.bytes / Int64($0.pages) : 0 } ?? 0
                out.append(ShrinkCandidate(path: path, kind: .pdf, bytes: bytes, estimate: nil,
                                           detail: info.map { "\($0.pages) pages · \(ByteFormat.string(perPage)) per page" + ($0.textCharacters < 40 * $0.pages ? " · scanned or pictures" : "") } ?? "PDF",
                                           modified: date))
            } else {
                let lossless = ["png", "tif", "tiff", "bmp"].contains(ext)
                out.append(ShrinkCandidate(path: path, kind: .image, bytes: bytes, estimate: Int64(Double(bytes) * (lossless ? 0.15 : 0.5)),
                                           detail: lossless ? "\(ext.uppercased()), uncompressed: HEIC keeps the look at a fraction of the size" : "Very large \(ext.uppercased())",
                                           modified: date))
            }
        }
        // Worth showing: anything that would save at least 30%, and every PDF (only trying tells).
        return out.filter { c in c.estimate.map { Double($0) <= Double(c.bytes) * 0.7 } ?? true }
            .sorted { ($0.estimatedSaving ?? $0.bytes / 3) > ($1.estimatedSaving ?? $1.bytes / 3) }
    }

    /// HEVC at a bitrate that looks the same for its resolution.
    static func videoCandidate(_ path: String, bytes: Int64, date: Date?) async -> ShrinkCandidate? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let duration = try? await asset.load(.duration).seconds, duration > 1,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return nil }
        let codec = (try? await track.load(.formatDescriptions))?.first.map { CMFormatDescriptionGetMediaSubType($0) }
        let longest = max(abs(size.width), abs(size.height))
        let target = estimateBitrate(longest: longest)
        let estimate = Int64((target + 128_000) * duration / 8)
        let mbps = Double(bytes) * 8 / duration / 1_000_000
        let res = longest >= 3000 ? "4K" : longest >= 1800 ? "1080p" : longest >= 1200 ? "720p" : "\(Int(longest))p"
        let isHEVC = codec == kCMVideoCodecType_HEVC
        let detail = "\(res) · \(Self.duration(duration)) · \(String(format: "%.0f", mbps)) Mbps" + (isHEVC ? " · already HEVC" : "")
        return ShrinkCandidate(path: path, kind: .video, bytes: bytes, estimate: isHEVC ? max(estimate, bytes * 8 / 10) : estimate,
                               detail: detail, modified: date)
    }

    public static func estimateBitrate(longest: CGFloat) -> Double {
        longest >= 3000 ? 16_000_000 : longest >= 1800 ? 6_000_000 : longest >= 1200 ? 3_500_000 : 2_000_000
    }

    static func duration(_ s: Double) -> String {
        s >= 3600 ? String(format: "%d h %02d min", Int(s) / 3600, Int(s) % 3600 / 60)
            : s >= 60 ? "\(Int(s) / 60) min" : "\(Int(s)) s"
    }
}

// MARK: - Downloads tidy-up

/// Downloads you're done with: duplicates, archives already unpacked, installers, unfinished downloads.
struct DownloadsTidyRule: CleanupRule {
    let name = "Downloads tidy-up"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let downloads = ctx.path("~/Downloads")
        let items = DownloadsTidy.items(in: downloads, apps: ctx.apps)
        guard !items.isEmpty else { return [] }
        let total = RuleKit.total(items)
        guard total >= 20_000_000 else { return [] }
        let counts = Dictionary(grouping: items) { ($0.note ?? "").components(separatedBy: " · ").first ?? "" }.mapValues(\.count)
        return [Finding(
            id: "downloads-tidy", title: "Downloads you're done with",
            detail: "Exact duplicate downloads, archives you've already unpacked, installers for apps you've installed, and unfinished downloads.",
            tier: .safe, bytes: total, items: items, action: .trash, revealPath: downloads, symbol: "tray.and.arrow.down",
            facts: counts.sorted { $0.key < $1.key }.map { Fact($0.key.capitalized, "\($0.value)") }
                + [Fact("Kept", "the original of each duplicate, and the unpacked folder of each archive")],
            risk: "Installers can be downloaded again from where you got them. Everything goes to the Trash first.")]
    }
}

public enum DownloadsTidy {
    static let partial: Set<String> = ["crdownload", "part", "download", "partial", "opdownload"]
    static let archives: [String] = [".zip", ".tar.gz", ".tgz", ".tar", ".rar", ".7z"]

    public static func items(in folder: String, apps: [InstalledApp], now: Date = Date()) -> [FindingItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        let visible = names.filter { !$0.hasPrefix(".") }
        let lowerNames = Set(visible.map { $0.lowercased() })
        let appNames = apps.map { ($0.name.lowercased(), $0.lastUsed) }
        var out: [FindingItem] = []
        func size(_ p: String) -> Int64 { Int64((try? fm.attributesOfItem(atPath: p))?[.size] as? Int ?? 0) }
        func modified(_ p: String) -> Date? { (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date }

        for name in visible {
            let path = folder + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let lower = name.lowercased()
            let ext = (lower as NSString).pathExtension
            let age = modified(path).map { now.timeIntervalSince($0) / 86_400 } ?? 0

            // Unfinished downloads more than a day old.
            if partial.contains(ext), age > 1 {
                out.append(FindingItem(path: path, bytes: size(path), note: "unfinished download", lastUsed: modified(path), usedBy: "browser"))
                continue
            }
            // "file (1).pdf", "file-2.pdf", "file copy.pdf" identical to "file.pdf".
            if let original = duplicateOriginal(of: name), lowerNames.contains(original.lowercased()) {
                let originalPath = folder + "/" + (visible.first { $0.lowercased() == original.lowercased() } ?? original)
                if size(originalPath) == size(path), sameContent(originalPath, path) {
                    out.append(FindingItem(path: path, bytes: size(path), note: "duplicate · same as \(original)", lastUsed: modified(path), usedBy: "you"))
                    continue
                }
            }
            // Archives whose unpacked folder sits next to them.
            if let suffix = archives.first(where: { lower.hasSuffix($0) }), age > 2 {
                let stem = String(name.dropLast(suffix.count))
                var stemIsDir: ObjCBool = false
                if fm.fileExists(atPath: folder + "/" + stem, isDirectory: &stemIsDir), stemIsDir.boolValue {
                    out.append(FindingItem(path: path, bytes: size(path), note: "archive · already unpacked to “\(stem)”", lastUsed: modified(path), usedBy: "you"))
                    continue
                }
            }
            // Installers older than two weeks; preselected only when the app is clearly installed.
            if ["dmg", "pkg", "mpkg"].contains(ext), age > 14 {
                let stem = (lower as NSString).deletingPathExtension
                let installed = appNames.first { app, _ in app.count >= 3 && stem.replacingOccurrences(of: "-", with: " ").contains(app) }
                out.append(FindingItem(path: path, bytes: size(path),
                                       note: "installer" + (installed != nil ? " · the app is installed" : " · \(Int(age)) days old"),
                                       selectedByDefault: installed != nil, lastUsed: modified(path), usedBy: installed?.0.capitalized ?? "you"))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// "Report (1).pdf" → "Report.pdf", "Report-2.pdf" → "Report.pdf", "Report copy.pdf" → "Report.pdf".
    public static func duplicateOriginal(of name: String) -> String? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for pattern in [#"^(.+?) \(\d{1,2}\)$"#, #"^(.+?)-\d$"#, #"^(.+?) copy( \d+)?$"#] {
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
               let r = Range(m.range(at: 1), in: stem) {
                return ext.isEmpty ? String(stem[r]) : String(stem[r]) + "." + ext
            }
        }
        return nil
    }

    static func sameContent(_ a: String, _ b: String) -> Bool {
        guard let ha = hash(a), let hb = hash(b) else { return false }
        return ha == hb
    }

    static func hash(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - iCloud Drive: keep in iCloud, remove the download

/// Big iCloud Drive files you haven't opened in a while. "Remove Download" keeps them in iCloud
/// (still listed in Finder) and frees the space on this Mac; opening one downloads it again.
struct ICloudDownloadsRule: CleanupRule {
    let name = "iCloud Drive downloads"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let root = ctx.path("~/Library/Mobile Documents/com~apple~CloudDocs")
        let items = ICloudFiles.removableDownloads(under: root)
        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        return [Finding(
            id: "icloud-downloads", title: "iCloud Drive files you can keep online only",
            detail: "Large iCloud Drive files you haven't opened in 2+ months. Removing the download frees the space on this Mac; the file stays in iCloud and in Finder, and downloads again when you open it.",
            tier: .safe, bytes: RuleKit.total(items), items: items, action: .removeDownload, revealPath: root,
            symbol: "icloud.and.arrow.down",
            facts: [Fact("Deleted", "nothing: files stay in iCloud and on your other devices"),
                    Fact("Offline", "they need an internet connection to open again")])]
    }
}

public enum ICloudFiles {
    public static func removableDownloads(under root: String, minBytes: Int64 = 50_000_000, idleDays: Double = 60) -> [FindingItem] {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey,
                                         .contentAccessDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: Array(keys),
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [FindingItem] = []
        while let url = walker.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, v.isUbiquitousItem == true,
                  v.ubiquitousItemDownloadingStatus == .current, let size = v.fileSize, Int64(size) >= minBytes else { continue }
            let used = [v.contentAccessDate, v.contentModificationDate].compactMap { $0 }.max()
            guard let used, Date().timeIntervalSince(used) > idleDays * 86_400 else { continue }
            out.append(FindingItem(path: url.path, bytes: Int64(size), note: "stays in iCloud", lastUsed: used, usedBy: "iCloud Drive"))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Only files inside iCloud Drive can have their download removed.
    public static func isInICloudDrive(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        (path as NSString).standardizingPath.hasPrefix(home + "/Library/Mobile Documents/")
    }
}

// MARK: - Time Machine local snapshots

/// Local Time Machine snapshots (taken hourly when the backup disk isn't connected). macOS's own update
/// snapshots are listed for information only and never touched.
struct LocalSnapshotsRule: CleanupRule {
    let name = "Time Machine local snapshots"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let listing = await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 20).out
        let parsed = LocalSnapshots.parse(listing)
        guard !parsed.timeMachine.isEmpty else { return [] }
        let dates = parsed.timeMachine
        let oldest = dates.first.flatMap(LocalSnapshots.date).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "?"
        return dates.count == 0 ? [] : [Finding(
            id: "tm-snapshots", title: "Time Machine local snapshots (\(dates.count))",
            detail: "Copies of changed files that Time Machine keeps on this Mac while your backup disk isn't connected. They count as \"System Data\". macOS removes them on its own when space runs low or after 24 hours, but deleting them frees the space now.",
            tier: .review, bytes: 0, action: .command(tool: "/usr/bin/tmutil", args: ["deletelocalsnapshots", "/"]),
            symbol: "clock.arrow.2.circlepath",
            facts: [Fact("Snapshots", "\(dates.count), oldest from \(oldest)"),
                    Fact("Size", "macOS doesn't report it; the space shows up as free afterwards"),
                    Fact("Your backups", "on the backup disk aren't affected")]
                + (parsed.system.isEmpty ? [] : [Fact("Left alone", "\(parsed.system.count) macOS update snapshot(s), managed by macOS")]),
            risk: "You can't restore a file to a time covered only by these local snapshots. Backups on your Time Machine disk are unaffected.")]
    }
}

public enum LocalSnapshots {
    /// Splits `tmutil listlocalsnapshots /` output into Time Machine snapshot dates and other (macOS) snapshots.
    public static func parse(_ output: String) -> (timeMachine: [String], system: [String]) {
        var tm: [String] = [], system: [String] = []
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("com.apple.TimeMachine."), let r = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) {
                tm.append(String(line[r]))
            } else if line.hasPrefix("com.apple.") {
                system.append(line)
            }
        }
        return (tm.sorted(), system)
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: s)
    }
}
#endif

#if os(macOS)
// MARK: - Make one file smaller (a checked copy next to it)

public struct ShrinkOutcome: Sendable, Hashable {
    public let ok: Bool
    public let output: String?
    public let before: Int64
    public let after: Int64
    public let message: String
    public let method: String
    public var saved: Int64 { ok ? max(0, before - after) : 0 }
}

extension ShrinkFinder {
    /// Saves "name (smaller).ext" (or "(compressed)" for PDFs) next to the original, checks it, and keeps it only
    /// if it saves at least 20%. The original is never changed.
    public static func makeSmaller(_ c: ShrinkCandidate) async -> ShrinkOutcome {
        let src = URL(fileURLWithPath: c.path)
        let folder = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        var out: String?, after: Int64 = c.bytes, message = "", method = ""
        switch c.kind {
        case .pdf:
            let r = await PDFTools.compress(c.path, level: .medium, into: folder)
            out = r.output; after = r.bytes; message = r.message; method = r.method
        case .video:
            let asset = AVURLAsset(url: src)
            var longest: CGFloat = 0
            if let t = try? await asset.loadTracks(withMediaType: .video).first, let s = try? await t.load(.naturalSize) {
                longest = max(abs(s.width), abs(s.height))
            }
            let r = await MediaConverter.convertVideo(c.path, preset: longest >= 3000 ? .hevc4K : .hevc1080, removePrivateInfo: false,
                                                      into: folder) { _ in }
            message = r.message
            if r.ok, let o = r.output {
                let dest = MediaConverter.uniqueURL(folder.appendingPathComponent(stem + " (smaller).mp4"))
                out = (try? FileManager.default.moveItem(atPath: o, toPath: dest.path)) != nil ? dest.path : o
                after = r.bytes
                method = "re-encoded as HEVC"
                // Verify it plays for as long as the original.
                let a = try? await asset.load(.duration).seconds
                let b = try? await AVURLAsset(url: URL(fileURLWithPath: out!)).load(.duration).seconds
                if let a, let b, abs(a - b) > 1 {
                    try? FileManager.default.removeItem(atPath: out!)
                    return ShrinkOutcome(ok: false, output: nil, before: c.bytes, after: c.bytes,
                                         message: "The copy came out shorter than the original, so it wasn't kept.", method: "")
                }
            }
        case .image:
            var o = ImageConvertOptions()
            o.format = .heic
            o.quality = 0.85
            o.removePrivateInfo = false
            let r = MediaConverter.convertImage(c.path, options: o, into: folder)
            message = r.message
            if r.ok, let output = r.output {
                let dest = MediaConverter.uniqueURL(folder.appendingPathComponent(stem + " (smaller).heic"))
                out = (try? FileManager.default.moveItem(atPath: output, toPath: dest.path)) != nil ? dest.path : output
                after = r.bytes
                method = "saved as HEIC"
            }
        }
        guard let out else { return ShrinkOutcome(ok: false, output: nil, before: c.bytes, after: c.bytes, message: message, method: "") }
        if Double(after) > Double(c.bytes) * 0.8 {
            try? FileManager.default.removeItem(atPath: out)
            return ShrinkOutcome(ok: false, output: nil, before: c.bytes, after: c.bytes,
                                 message: "Already efficient: a smaller copy would save less than 20%, so it wasn't kept.", method: "")
        }
        return ShrinkOutcome(ok: true, output: out, before: c.bytes, after: after,
                             message: "\(ByteFormat.string(c.bytes)) → \(ByteFormat.string(after))", method: method)
    }
}
#endif
