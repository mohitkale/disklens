#if os(macOS)
import AVFoundation
import Foundation
import ImageIO
import PDFKit

/// What a file reveals about where it was made and who or what made it.
public struct MetadataReport: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case image, video, pdf, office }

    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let bytes: Int64
    public let coordinate: Coordinate?
    /// Camera or phone make and model, e.g. "Apple iPhone 15 Pro".
    public let device: String?
    /// Camera body or lens serial numbers.
    public let serials: [String]
    /// Owner, author or "last modified by" names.
    public let people: [String]
    public let software: String?
    public let captured: Date?
    /// Office documents can't be cleaned in place yet; they're reported only.
    public var canClean: Bool { kind != .office }

    public var name: String { (path as NSString).lastPathComponent }
    public var revealsLocation: Bool { coordinate != nil }
    public var revealsIdentity: Bool { device != nil || !serials.isEmpty || !people.isEmpty }
    public var revealsAnything: Bool { revealsLocation || revealsIdentity }

    public init(path: String, kind: Kind, bytes: Int64, coordinate: Coordinate? = nil, device: String? = nil,
                serials: [String] = [], people: [String] = [], software: String? = nil, captured: Date? = nil) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.coordinate = coordinate
        self.device = device
        self.serials = serials
        self.people = people
        self.software = software
        self.captured = captured
    }
}

public struct Coordinate: Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var formatted: String {
        String(format: "%.4f°%@, %.4f°%@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }

    /// Opens Apple Maps at this point only when the user asks (DiskLens itself never goes online).
    public var mapsURL: URL? { URL(string: "maps://?ll=\(latitude),\(longitude)&q=Photo%20location") }
}

public enum MetadataInspector {
    static let imageTypes: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "webp", "avif"]
    static let videoTypes: Set<String> = ["mov", "mp4", "m4v", "3gp"]
    static let officeTypes: Set<String> = ["docx", "xlsx", "pptx"]

    public static func kind(for path: String) -> MetadataReport.Kind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageTypes.contains(ext) { return .image }
        if videoTypes.contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        if officeTypes.contains(ext) { return .office }
        return nil
    }

    public static func inspect(_ path: String) async -> MetadataReport? {
        guard let kind = kind(for: path) else { return nil }
        let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0)
        switch kind {
        case .image: return image(path, bytes: bytes)
        case .video: return await video(path, bytes: bytes)
        case .pdf: return pdf(path, bytes: bytes)
        case .office: return await office(path, bytes: bytes)
        }
    }

    // MARK: Images (reads the header only)

    static func image(_ path: String, bytes: Int64) -> MetadataReport? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        var coordinate: Coordinate?
        if let gps, let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           lat != 0 || lon != 0 {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W"
            coordinate = Coordinate(latitude: south ? -lat : lat, longitude: west ? -lon : lon)
        }
        let device = joinDevice(tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String)
        let serials = [exif[kCGImagePropertyExifBodySerialNumber], exif[kCGImagePropertyExifLensSerialNumber],
                       aux[kCGImagePropertyExifAuxSerialNumber], aux[kCGImagePropertyExifAuxLensSerialNumber]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let people = [exif[kCGImagePropertyExifCameraOwnerName], tiff[kCGImagePropertyTIFFArtist]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let captured = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDate)
        return MetadataReport(path: path, kind: .image, bytes: bytes, coordinate: coordinate, device: device,
                              serials: Array(Set(serials)).sorted(), people: Array(Set(people)).sorted(),
                              software: tiff[kCGImagePropertyTIFFSoftware] as? String, captured: captured)
    }

    // MARK: Videos

    static func video(_ path: String, bytes: Int64) async -> MetadataReport? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let items = try? await asset.load(.metadata) else { return nil }
        func string(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = items.first(where: { $0.identifier == id }) else { return nil }
            return try? await item.load(.stringValue)
        }
        var location: String? = await string(.quickTimeMetadataLocationISO6709)
        if location == nil { location = await string(.commonIdentifierLocation) }
        let make = await string(.quickTimeMetadataMake)
        let model = await string(.quickTimeMetadataModel)
        let software = await string(.quickTimeMetadataSoftware)
        let author = await string(.quickTimeMetadataAuthor)
        let created = await string(.quickTimeMetadataCreationDate)
        return MetadataReport(path: path, kind: .video, bytes: bytes,
                              coordinate: location.flatMap(parseISO6709), device: joinDevice(make, model),
                              people: author.map { [$0] } ?? [], software: software,
                              captured: created.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    // MARK: PDFs

    static func pdf(_ path: String, bytes: Int64) -> MetadataReport? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        let attrs = doc.documentAttributes ?? [:]
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespaces)
        return MetadataReport(path: path, kind: .pdf, bytes: bytes,
                              people: [author].compactMap { $0 }.filter { !$0.isEmpty },
                              software: [attrs[PDFDocumentAttribute.creatorAttribute] as? String,
                                         attrs[PDFDocumentAttribute.producerAttribute] as? String].compactMap { $0 }.first,
                              captured: attrs[PDFDocumentAttribute.creationDateAttribute] as? Date)
    }

    // MARK: Office (docx/xlsx/pptx are zip files with XML properties)

    static func office(_ path: String, bytes: Int64) async -> MetadataReport? {
        let core = await Shell.run("/usr/bin/unzip", ["-p", path, "docProps/core.xml"], timeout: 10, captureStderr: false).out
        let app = await Shell.run("/usr/bin/unzip", ["-p", path, "docProps/app.xml"], timeout: 10, captureStderr: false).out
        let people = officePeople(core: core, app: app)
        return MetadataReport(path: path, kind: .office, bytes: bytes, people: people,
                              software: xmlValue("Application", in: app))
    }

    /// Author, last editor and company from Office document properties.
    public static func officePeople(core: String, app: String) -> [String] {
        let values = [xmlValue("dc:creator", in: core), xmlValue("cp:lastModifiedBy", in: core), xmlValue("Company", in: app)]
        var seen = Set<String>()
        return values.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func xmlValue(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        let value = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: Helpers

    /// "+19.0760+072.8777+010.000/" → 19.0760, 72.8777
    public static func parseISO6709(_ s: String) -> Coordinate? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let latRange = Range(m.range(at: 1), in: s), let lonRange = Range(m.range(at: 2), in: s),
              let lat = Double(s[latRange]), let lon = Double(s[lonRange]) else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    static func joinDevice(_ make: String?, _ model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if make.isEmpty && model.isEmpty { return nil }
        if model.lowercased().hasPrefix(make.lowercased()) { return model }
        return [make, model].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func exifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }
}

/// A place where many files were made, e.g. home or work.
public struct Hotspot: Identifiable, Hashable, Sendable {
    public var id: String { "\(center.latitude),\(center.longitude)" }
    public let center: Coordinate
    public let files: [String]
    /// Distinct days with files at this spot: repeat visits suggest home or work.
    public let days: Int
}

public enum Hotspots {
    /// Groups coordinates into ~100 m cells and returns the busiest ones.
    public static func find(_ reports: [MetadataReport], minimumFiles: Int = 3, limit: Int = 8) -> [Hotspot] {
        var cells: [String: [MetadataReport]] = [:]
        for r in reports {
            guard let c = r.coordinate else { continue }
            let key = String(format: "%.3f,%.3f", c.latitude, c.longitude)
            cells[key, default: []].append(r)
        }
        let cal = Calendar.current
        return cells.values.filter { $0.count >= minimumFiles }.map { group in
            let lat = group.compactMap(\.coordinate?.latitude).reduce(0, +) / Double(group.count)
            let lon = group.compactMap(\.coordinate?.longitude).reduce(0, +) / Double(group.count)
            let days = Set(group.compactMap { $0.captured.map { cal.startOfDay(for: $0) } }).count
            return Hotspot(center: Coordinate(latitude: lat, longitude: lon), files: group.map(\.path), days: max(days, 1))
        }
        .sorted { ($0.days, $0.files.count) > ($1.days, $1.files.count) }
        .prefix(limit).map { $0 }
    }
}
#endif
