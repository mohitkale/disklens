#if os(macOS)
@testable import DiskLensCore
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Shared helpers: a temp folder and photos with known metadata.
class PhotoFixture: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-privacy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func inspect(_ path: String) async throws -> MetadataReport {
        let report = await MetadataInspector.inspect(path)
        return try XCTUnwrap(report, "couldn't read \(path)")
    }

    /// A small photo with GPS, camera, serial number, owner name and a rotated orientation.
    func makePhoto(_ name: String, type: UTType = .jpeg) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 19.076, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 72.8777, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "SN12345", kCGImagePropertyExifCameraOwnerName: "Jane Doe",
                                             kCGImagePropertyExifDateTimeOriginal: "2025:03:12 18:30:00"],
        ]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func orientation(_ url: URL) -> Int? {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int
    }

}

final class PrivacyTests: PhotoFixture {
    func testInspectsWhatAPhotoReveals() async throws {
        let r = try await inspect(makePhoto("a.jpg").path)
        XCTAssertEqual(r.coordinate?.latitude ?? 0, 19.076, accuracy: 0.001)
        XCTAssertEqual(r.coordinate?.longitude ?? 0, 72.8777, accuracy: 0.001)
        XCTAssertEqual(r.device, "Apple iPhone 15 Pro")
        XCTAssertEqual(r.serials, ["SN12345"])
        XCTAssertEqual(r.people, ["Jane Doe"])
        XCTAssertNotNil(r.captured)
    }

    func testRemovesLocationOnlyAndKeepsTheRest() async throws {
        let photo = makePhoto("b.jpg")
        let report = try await inspect(photo.path)
        let result = await MetadataCleaner.clean(report, level: .location, mode: .saveCopy)
        XCTAssertTrue(result.ok, result.message)
        XCTAssertFalse(result.reencoded, "JPEG should be cleaned losslessly")
        let copy = try await inspect(XCTUnwrap(result.output))
        XCTAssertNil(copy.coordinate)
        XCTAssertEqual(copy.device, "Apple iPhone 15 Pro")
        XCTAssertEqual(orientation(URL(fileURLWithPath: result.output!)), 6, "orientation must survive or photos rotate")
        let untouched = try await inspect(photo.path)
        XCTAssertNotNil(untouched.coordinate, "save-copy leaves the original untouched")
    }

    func testRemovesAllIdentifyingInfo() async throws {
        for (name, type) in [("c.jpg", UTType.jpeg), ("d.heic", UTType.heic)] {
            let report = try await inspect(makePhoto(name, type: type).path)
            let result = await MetadataCleaner.clean(report, level: .identifying, mode: .saveCopy)
            XCTAssertTrue(result.ok, "\(name): \(result.message)")
            let copy = try await inspect(XCTUnwrap(result.output))
            XCTAssertNil(copy.coordinate, name)
            XCTAssertFalse(copy.revealsIdentity, "\(name) still reveals \(copy.device ?? "") \(copy.serials) \(copy.people)")
            XCTAssertEqual(orientation(URL(fileURLWithPath: result.output!)), 6, name)
            XCTAssertNotNil(copy.captured, "\(name): the capture date is kept")
        }
    }

    func testReplaceRefusesOutsideHomeFolder() async throws {
        let report = try await inspect(makePhoto("e.jpg").path)
        let result = await MetadataCleaner.clean(report, level: .location, mode: .replaceOriginal)
        XCTAssertFalse(result.ok)   // the temp folder is outside the home folder
        let after = try await inspect(report.path)
        XCTAssertNotNil(after.coordinate)
    }

    func testParsesVideoLocationAndOfficeProperties() {
        let c = MetadataInspector.parseISO6709("+19.0760+072.8777+010.000/")
        XCTAssertEqual(c?.latitude ?? 0, 19.076, accuracy: 0.0001)
        XCTAssertEqual(c?.longitude ?? 0, 72.8777, accuracy: 0.0001)
        XCTAssertEqual(MetadataInspector.parseISO6709("-33.8688+151.2093/")?.latitude ?? 0, -33.8688, accuracy: 0.0001)
        XCTAssertNil(MetadataInspector.parseISO6709("nowhere"))
        let core = "<cp:coreProperties><dc:creator>Jane Doe</dc:creator><cp:lastModifiedBy>John Roe</cp:lastModifiedBy></cp:coreProperties>"
        XCTAssertEqual(MetadataInspector.officePeople(core: core, app: "<Properties><Company>Acme Inc</Company></Properties>"),
                       ["Jane Doe", "John Roe", "Acme Inc"])
    }

    func testFindsHotspotsByRepeatVisits() {
        func r(_ i: Int, _ lat: Double, _ lon: Double, day: Int) -> MetadataReport {
            MetadataReport(path: "/p/\(i)", kind: .image, bytes: 1, coordinate: Coordinate(latitude: lat, longitude: lon),
                           captured: Date(timeIntervalSince1970: Double(day) * 86_400))
        }
        let home = (0..<6).map { r($0, 19.0761 + Double($0) * 0.00001, 72.8777, day: $0) }      // 6 days
        let trip = (6..<12).map { r($0, 48.8584, 2.2945, day: 100) }                           // one day
        let spots = Hotspots.find(home + trip + [r(99, 0.5, 0.5, day: 1)])
        XCTAssertEqual(spots.count, 2)
        XCTAssertEqual(spots.first?.days, 6, "repeat visits rank first (likely home)")
        XCTAssertEqual(spots.first?.files.count, 6)
    }
}

final class DuplicateTests: XCTestCase {
    func testFindsDuplicatesAndClones() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data((0..<2_000_000).map { UInt8($0 % 251) })
        try payload.write(to: dir.appendingPathComponent("report.pdf"))
        try payload.write(to: dir.appendingPathComponent("sub/report copy.pdf"))
        var other = payload; other[1_999_999] ^= 0xFF                       // same size, differs at the end
        try other.write(to: dir.appendingPathComponent("different.pdf"))
        let clone = Process()                                                  // APFS clone: shares storage
        clone.executableURL = URL(fileURLWithPath: "/bin/cp")
        clone.arguments = ["-c", dir.appendingPathComponent("report.pdf").path, dir.appendingPathComponent("report (1).pdf").path]
        try clone.run(); clone.waitUntilExit()

        let groups = await DuplicateFinder.scan(roots: [dir.path]) { _ in }
        XCTAssertEqual(groups.count, 1)
        let g = try XCTUnwrap(groups.first)
        XCTAssertEqual(g.files.count, 3)
        XCTAssertEqual((g.keep as NSString).lastPathComponent, "report.pdf", "keeps the copy without 'copy'/'(1)' in its name")
        XCTAssertTrue(g.clonePaths.contains { $0.hasSuffix("report (1).pdf") }, "detects the APFS clone")
        XCTAssertEqual(g.reclaimable, 2_000_000, "only the real copy frees space")
    }
}
#endif

#if os(macOS)
/// Replaces a throwaway photo in the home folder; its original goes to the real Trash. Opt-in: DISKLENS_LIVE_TEST=1
final class LivePrivacyTests: PhotoFixture {
    override func setUp() {
        dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/DiskLensSelfTest-privacy-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if FileManager.default.fileExists(atPath: dir.path) { try? FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
    }

    func testReplaceMovesOriginalToTrash() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISKLENS_LIVE_TEST"] == "1")
        let photo = makePhoto("live.jpg")
        let report = try await inspect(photo.path)
        let result = await MetadataCleaner.clean(report, level: .identifying, mode: .replaceOriginal)
        XCTAssertTrue(result.ok, result.message)
        let cleaned = try await inspect(photo.path)
        XCTAssertNil(cleaned.coordinate)
        XCTAssertFalse(cleaned.revealsIdentity)
        XCTAssertEqual(orientation(photo), 6)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["live.jpg"], "no temp files left behind")
    }
}
#endif
