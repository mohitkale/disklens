#if os(macOS)
import AVFoundation
import Foundation
import ImageIO
import Photos

/// A photo or video from a folder or the Photos library.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case photo, video }
    public enum Origin: Hashable, Sendable {
        case file(String)
        /// A PHAsset local identifier.
        case photos(String)
    }

    public var id: String {
        switch origin {
        case let .file(path): path
        case let .photos(id): "photos:" + id
        }
    }
    public let origin: Origin
    public let kind: Kind
    public let date: Date
    public let coordinate: Coordinate?
    /// Seconds (videos only).
    public let duration: Double
    public let bytes: Int64

    public init(origin: Origin, kind: Kind, date: Date, coordinate: Coordinate? = nil, duration: Double = 0, bytes: Int64 = 0) {
        self.origin = origin
        self.kind = kind
        self.date = date
        self.coordinate = coordinate
        self.duration = duration
        self.bytes = bytes
    }

    public var filePath: String? { if case let .file(p) = origin { p } else { nil } }
    public var name: String {
        switch origin {
        case let .file(p): (p as NSString).lastPathComponent
        case .photos: kind == .photo ? "Photo" : "Video"
        }
    }
}

public enum MediaLibrary {
    static let photoTypes: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng", "webp", "avif"]
    static let videoTypes: Set<String> = ["mov", "mp4", "m4v"]

    /// Photos and videos in `folders` (and subfolders), with the date they were taken.
    public static func scanFolders(_ folders: [String], limit: Int = 20_000) async -> [MediaItem] {
        var paths: [String] = []
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL, paths.count < limit {
                let ext = url.pathExtension.lowercased()
                if photoTypes.contains(ext) || videoTypes.contains(ext) { paths.append(url.path) }
            }
        }
        var items: [MediaItem] = []
        await withTaskGroup(of: MediaItem?.self) { group in
            var it = paths.makeIterator()
            for _ in 0..<8 { if let p = it.next() { group.addTask { await item(at: p) } } }
            while let r = await group.next() {
                if let r { items.append(r) }
                if let p = it.next() { group.addTask { await item(at: p) } }
            }
        }
        return items.sorted { $0.date < $1.date }
    }

    public static func item(at path: String) async -> MediaItem? {
        let ext = (path as NSString).pathExtension.lowercased()
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let fileDate = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) ?? .now
        let bytes = Int64(attrs?[.size] as? Int ?? 0)
        if photoTypes.contains(ext) {
            let report = MetadataInspector.image(path, bytes: bytes)
            return MediaItem(origin: .file(path), kind: .photo, date: report?.captured ?? fileDate,
                             coordinate: report?.coordinate, bytes: bytes)
        }
        guard videoTypes.contains(ext) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let report = await MetadataInspector.video(path, bytes: bytes)
        return MediaItem(origin: .file(path), kind: .video, date: report?.captured ?? fileDate,
                         coordinate: report?.coordinate, duration: duration.isFinite ? duration : 0, bytes: bytes)
    }

    // MARK: Photos library (read-only; asks for permission the first time)

    public static func requestPhotosAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    public static var photosAccessGranted: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// Every photo and video in the library, oldest first. Only metadata is read here.
    public static func photosLibraryItems() -> [MediaItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: options)
        var items: [MediaItem] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            let c = asset.location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            items.append(MediaItem(origin: .photos(asset.localIdentifier), kind: asset.mediaType == .video ? .video : .photo,
                                   date: asset.creationDate ?? .distantPast, coordinate: c, duration: asset.duration))
        }
        return items
    }

    // MARK: Loading content

    /// A photo, oriented correctly, scaled so its longest side is at most `maxPixels`.
    public static func image(for item: MediaItem, maxPixels: Int) async -> CGImage? {
        switch item.origin {
        case let .file(path):
            return thumbnail(path, maxPixels: maxPixels)
        case let .photos(id):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            // Originals that only live in iCloud are skipped: DiskLens never goes online.
            options.isNetworkAccessAllowed = false
            options.resizeMode = .exact
            return await withCheckedContinuation { c in
                var resumed = false
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: maxPixels, height: maxPixels),
                                                      contentMode: .aspectFit, options: options) { image, info in
                    guard !resumed else { return }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    resumed = true
                    c.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                }
            }
        }
    }

    public static func thumbnail(_ path: String, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func asset(for item: MediaItem) async -> AVAsset? {
        switch item.origin {
        case let .file(path):
            return AVURLAsset(url: URL(fileURLWithPath: path))
        case let .photos(id):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            return await withCheckedContinuation { c in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in c.resume(returning: av) }
            }
        }
    }
}

/// Photos and videos taken close together in time (and usually place), e.g. a birthday or a trip day.
public struct MediaEvent: Identifiable, Hashable, Sendable {
    public var id: String { items.first?.id ?? UUID().uuidString }
    public var title: String
    public let items: [MediaItem]
    public var start: Date { items.first?.date ?? .distantPast }
    public var end: Date { items.last?.date ?? .distantPast }
    public var photoCount: Int { items.filter { $0.kind == .photo }.count }
    public var videoCount: Int { items.filter { $0.kind == .video }.count }
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public init(title: String, items: [MediaItem]) {
        self.title = title
        self.items = items
    }
}

public enum EventGrouper {
    /// Splits a timeline into events wherever there's a gap of more than `gapHours`,
    /// or a jump of more than `distanceKm` between consecutive located items. Small groups are dropped.
    public static func group(_ items: [MediaItem], gapHours: Double = 4, distanceKm: Double = 30, minimumItems: Int = 4) -> [MediaEvent] {
        let sorted = items.sorted { $0.date < $1.date }
        var events: [[MediaItem]] = []
        var current: [MediaItem] = []
        var lastLocated: Coordinate?
        for item in sorted {
            if let prev = current.last {
                let gap = item.date.timeIntervalSince(prev.date) / 3600
                var moved = false
                if let a = lastLocated, let b = item.coordinate { moved = distance(a, b) > distanceKm }
                if gap > gapHours || moved {
                    events.append(current)
                    current = []
                    lastLocated = nil
                }
            }
            current.append(item)
            if let c = item.coordinate { lastLocated = c }
        }
        if !current.isEmpty { events.append(current) }
        return events.filter { $0.count >= minimumItems }.map { MediaEvent(title: title(for: $0), items: $0) }.reversed()
    }

    /// "Sat 12 Mar 2025" or "12–14 Mar 2025" for multi-day events.
    public static func title(for items: [MediaItem]) -> String {
        guard let a = items.first?.date, let b = items.last?.date else { return "Event" }
        let cal = Calendar.current
        if cal.isDate(a, inSameDayAs: b) { return a.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()) }
        return "\(a.formatted(.dateTime.day().month(.abbreviated))) – \(b.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    /// Great-circle distance in kilometres.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180, dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
#endif
