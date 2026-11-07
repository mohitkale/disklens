#if os(macOS)
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum PrivacyScanner {
    /// Folders that usually hold photos, videos and documents people share.
    public static var defaultFolders: [String] {
        ["~/Desktop", "~/Documents", "~/Downloads", "~/Pictures", "~/Movies"].map { ($0 as NSString).expandingTildeInPath }
    }

    /// Reads what every photo, video, PDF and Office file under `folders` reveals. Read-only.
    /// Skips hidden folders, app bundles, photo libraries and node_modules.
    public static func scan(folders: [String], limit: Int = 60_000,
                            progress: @escaping @Sendable (Int, Int) -> Void) async -> [MetadataReport] {
        var paths: [String] = []
        for folder in folders {
            let url = URL(fileURLWithPath: folder)
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let item = walker.nextObject() as? URL {
                let name = item.lastPathComponent
                if name == "node_modules" || name.hasSuffix(".photoslibrary") || name.hasSuffix(".app") { walker.skipDescendants(); continue }
                if MetadataInspector.kind(for: item.path) != nil { paths.append(item.path) }
                if paths.count >= limit { break }
            }
        }
        paths = Array(Set(paths)).sorted()
        let total = paths.count
        progress(0, total)

        var reports: [MetadataReport] = []
        await withTaskGroup(of: MetadataReport?.self) { group in
            var iterator = paths.makeIterator()
            var done = 0
            for _ in 0..<8 { if let p = iterator.next() { group.addTask { await MetadataInspector.inspect(p) } } }
            while let result = await group.next() {
                done += 1
                if done % 50 == 0 || done == total { progress(done, total) }
                if let result, result.revealsAnything { reports.append(result) }
                if let p = iterator.next() { group.addTask { await MetadataInspector.inspect(p) } }
            }
        }
        return reports.sorted { $0.path < $1.path }
    }
}

public enum MetadataCleaner {
    public enum Level: String, Sendable, CaseIterable {
        /// GPS coordinates only.
        case location
        /// Location, device make/model, serial numbers, owner/author names and software. Keeps date and orientation.
        case identifying
    }

    public enum Mode: String, Sendable {
        /// Writes "name (clean).ext" next to the original.
        case saveCopy
        /// Replaces the file; the original goes to the Trash so it can be put back.
        case replaceOriginal
    }

    public struct Result: Sendable {
        public let path: String
        public let output: String?
        public let ok: Bool
        public let message: String
        /// True when the image had to be re-encoded (at maximum quality) instead of copied losslessly.
        public let reencoded: Bool
    }

    public static func clean(_ report: MetadataReport, level: Level, mode: Mode) async -> Result {
        let original = URL(fileURLWithPath: report.path)
        if mode == .replaceOriginal, !Executor.isSafeToTrash(report.path, home: NSHomeDirectory()) {
            return Result(path: report.path, output: nil, ok: false, message: "This file is outside the folders DiskLens may change.", reencoded: false)
        }
        let dir = original.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".disklens-clean-\(UUID().uuidString.prefix(8)).\(original.pathExtension)")

        var reencoded = false
        do {
            switch report.kind {
            case .image: reencoded = try cleanImage(original, to: temp, level: level)
            case .video: try await cleanVideo(original, to: temp, level: level)
            case .pdf: try cleanPDF(original, to: temp)
            case .office: try await cleanOffice(original, to: temp)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return Result(path: report.path, output: nil, ok: false, message: error.localizedDescription, reencoded: false)
        }

        // Verify before touching the original.
        let check = await MetadataInspector.inspect(temp.path)
        let stillLeaks = check == nil || check!.coordinate != nil || (level == .identifying && check!.revealsIdentity)
        guard !stillLeaks else {
            try? FileManager.default.removeItem(at: temp)
            return Result(path: report.path, output: nil, ok: false, message: "The cleaned copy still contained the information, so nothing was changed.", reencoded: false)
        }
        copyDates(from: original, to: temp)

        do {
            switch mode {
            case .saveCopy:
                let target = uniqueCopyURL(for: original)
                try FileManager.default.moveItem(at: temp, to: target)
                return Result(path: report.path, output: target.path, ok: true, message: "Saved \(target.lastPathComponent)", reencoded: reencoded)
            case .replaceOriginal:
                try FileManager.default.trashItem(at: original, resultingItemURL: nil)
                try FileManager.default.moveItem(at: temp, to: original)
                return Result(path: report.path, output: original.path, ok: true, message: "Cleaned. The original is in the Trash.", reencoded: reencoded)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return Result(path: report.path, output: nil, ok: false, message: error.localizedDescription, reencoded: false)
        }
    }

    /// XMP paths of identifying tags removed by `.identifying` (GPS is excluded separately).
    static let identifyingTags = [
        "tiff:Make", "tiff:Model", "tiff:Software", "tiff:Artist", "tiff:HostComputer",
        "exif:BodySerialNumber", "exif:LensSerialNumber", "exif:CameraOwnerName",
        "exifEX:BodySerialNumber", "exifEX:LensSerialNumber", "exifEX:CameraOwnerName", "exifEX:LensMake", "exifEX:LensModel",
        "aux:SerialNumber", "aux:LensSerialNumber", "aux:OwnerName", "aux:Lens", "aux:LensID",
        "xmp:CreatorTool", "dc:creator", "photoshop:Credit", "Iptc4xmpCore:CreatorContactInfo",
    ]

    /// Returns true if the image had to be re-encoded.
    static func cleanImage(_ url: URL, to out: URL, level: Level) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let meta: CGMutableImageMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        if level == .identifying {
            for tag in identifyingTags { CGImageMetadataRemoveTagWithPath(meta, nil, tag as CFString) }
        }

        // Lossless path: copies the compressed image data and replaces only the metadata.
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
            let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false,
                                            kCGImageMetadataShouldExcludeGPS: true]
            if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil) { return false }
        }
        // Fallback (some formats, e.g. HEIC): re-encode at maximum quality with the filtered metadata.
        try? FileManager.default.removeItem(at: out)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        let gpsFree = meta
        for tag in ["GPSLatitude", "GPSLongitude", "GPSLatitudeRef", "GPSLongitudeRef", "GPSAltitude", "GPSAltitudeRef",
                    "GPSTimeStamp", "GPSDateStamp", "GPSSpeed", "GPSImgDirection", "GPSDestBearing", "GPSHPositioningError"] {
            CGImageMetadataRemoveTagWithPath(gpsFree, nil, "exif:\(tag)" as CFString)
        }
        CGImageDestinationAddImageAndMetadata(dest, image, gpsFree, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return true
    }

    static func cleanVideo(_ url: URL, to out: URL, level: Level) async throws {
        let asset = AVURLAsset(url: url)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let items = (try? await asset.load(.metadata)) ?? []
        let locationIDs: Set<AVMetadataIdentifier> = [.quickTimeMetadataLocationISO6709, .commonIdentifierLocation,
                                                      .quickTimeMetadataLocationName, .quickTimeMetadataLocationBody,
                                                      .quickTimeMetadataLocationNote, .quickTimeMetadataLocationRole,
                                                      .quickTimeMetadataLocationDate]
        let identityIDs: Set<AVMetadataIdentifier> = [.quickTimeMetadataMake, .quickTimeMetadataModel, .quickTimeMetadataSoftware,
                                                      .quickTimeMetadataAuthor, .commonIdentifierAuthor, .commonIdentifierCreator,
                                                      .quickTimeMetadataArtist, .commonIdentifierMake, .commonIdentifierModel,
                                                      .commonIdentifierSoftware]
        exporter.metadata = items.filter { item in
            guard let id = item.identifier else { return true }
            if locationIDs.contains(id) { return false }
            return level == .location || !identityIDs.contains(id)
        }
        exporter.metadataItemFilter = .forSharing()
        exporter.outputURL = out
        let ext = url.pathExtension.lowercased()
        exporter.outputFileType = ext == "mov" ? .mov : ext == "m4v" ? .m4v : ext == "3gp" ? .mobile3GPP : .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { c.resume() }
        }
        if exporter.status != .completed { throw exporter.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func cleanPDF(_ url: URL, to out: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        var attrs = doc.documentAttributes ?? [:]
        for key in [PDFDocumentAttribute.authorAttribute, .creatorAttribute, .producerAttribute, .keywordsAttribute] {
            attrs.removeValue(forKey: key)
        }
        doc.documentAttributes = attrs
        guard doc.write(to: out) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Office files are zip archives; the author, editor and company live in docProps/core.xml and app.xml.
    static func cleanOffice(_ url: URL, to out: URL) async throws {
        try FileManager.default.copyItem(at: url, to: out)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("disklens-office-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("docProps"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var changed: [String] = []
        for (entry, tags) in [("docProps/core.xml", ["dc:creator", "cp:lastModifiedBy"]), ("docProps/app.xml", ["Company", "Manager"])] {
            let xml = await Shell.run("/usr/bin/unzip", ["-p", url.path, entry], timeout: 15, captureStderr: false).out
            guard !xml.isEmpty else { continue }
            let cleaned = blank(tags, in: xml)
            if cleaned != xml {
                try cleaned.write(to: work.appendingPathComponent(entry), atomically: true, encoding: .utf8)
                changed.append(entry)
            }
        }
        guard !changed.isEmpty else { return }
        let r = await Shell.run("/usr/bin/zip", ["-q", out.path] + changed, timeout: 30, in: work)
        guard r.ok else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "zip: \(r.err)"]) }
    }

    /// Empties the text of each `<tag>…</tag>` (attributes kept).
    static func blank(_ tags: [String], in xml: String) -> String {
        var s = xml
        for tag in tags {
            let pattern = "(<\(NSRegularExpression.escapedPattern(for: tag))(\\s[^>]*)?>)[^<]*(</\(NSRegularExpression.escapedPattern(for: tag))>)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$3")
        }
        return s
    }

    static func uniqueCopyURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = dir.appendingPathComponent("\(base) (clean).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (clean \(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Keeps the original's dates so cleaned files sort the same way in Finder.
    static func copyDates(from src: URL, to dst: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: src.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
        if let c = attrs[.creationDate] { keep[.creationDate] = c }
        try? FileManager.default.setAttributes(keep, ofItemAtPath: dst.path)
    }
}
#endif
