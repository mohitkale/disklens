#if os(macOS)
import AVFoundation
import CoreImage
@testable import DiskLensCore
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class AppsTests: XCTestCase {
    func testFindsLeftoversByBundleIDAndExactNameOnly() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dl-home-\(UUID().uuidString.prefix(6))").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        for dir in ["Library/Application Support/Acme Notes", "Library/Application Support/Acme", "Library/Caches/com.acme.notes",
                    "Library/Containers/com.acme.notes", "Library/Saved Application State/com.acme.notes.savedState",
                    "Library/Group Containers/ABCDE12345.com.acme.notes", "Library/Caches/com.acme.notesbeta", "Library/Preferences"] {
            try fm.createDirectory(atPath: "\(home)/\(dir)", withIntermediateDirectories: true)
        }
        fm.createFile(atPath: "\(home)/Library/Preferences/com.acme.notes.plist", contents: Data("x".utf8))
        fm.createFile(atPath: "\(home)/Library/Preferences/com.acme.notes.helper.plist", contents: Data("x".utf8))
        let notes = InstalledApp(path: "/Applications/Acme Notes.app", name: "Acme Notes", bundleID: "com.acme.notes", version: "1", lastUsed: nil, isManaged: false)
        let other = InstalledApp(path: "/Applications/Acme.app", name: "Acme", bundleID: "com.acme.suite", version: "1", lastUsed: nil, isManaged: false)
        let found = await AppUninstaller.leftovers(for: notes, allApps: [notes, other], home: home).map { ($0.path as NSString).lastPathComponent }
        XCTAssertEqual(Set(found), ["Acme Notes", "com.acme.notes", "com.acme.notes.savedState", "ABCDE12345.com.acme.notes",
                                    "com.acme.notes.plist", "com.acme.notes.helper.plist"])
        XCTAssertFalse(found.contains("Acme"), "another app's folder is never matched")
        XCTAssertFalse(found.contains("com.acme.notesbeta"), "a different bundle ID is never matched")
        XCTAssertTrue(AppUninstaller.removableApps([notes, InstalledApp(path: "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari",
                                                                        version: nil, lastUsed: nil, isManaged: true)]).map(\.name) == ["Acme Notes"])
        XCTAssertTrue(AppUninstaller.looksLikeBundleID("com.example.app"))
        XCTAssertFalse(AppUninstaller.looksLikeBundleID("Google"))
        XCTAssertFalse(AppUninstaller.looksLikeBundleID("Caches"))
    }

    func testReadsStartupItems() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dl-la-\(UUID().uuidString.prefix(6))").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": "com.acme.updater", "ProgramArguments": ["/Applications/Acme.app/Contents/MacOS/updater", "--quiet"],
                                    "RunAtLoad": true]
        (plist as NSDictionary).write(toFile: home + "/Library/LaunchAgents/com.acme.updater.plist", atomically: true)
        let item = try XCTUnwrap(StartupInspector.items(home: home).first { $0.label == "com.acme.updater" })
        XCTAssertEqual(item.owner, "Acme")
        XCTAssertTrue(item.runsAtLoad)
        XCTAssertEqual(item.kind, .userAgent)
    }
}

final class SensitiveTests: XCTestCase {
    func testDetectsSensitiveTextWithoutFalseAlarms() {
        XCTAssertTrue(SensitiveScanner.luhn("4242424242424242"))
        XCTAssertFalse(SensitiveScanner.luhn("4242424242424241"))
        XCTAssertFalse(SensitiveScanner.luhn("0000000000000000"))
        let (card, samples) = SensitiveScanner.detect(in: ["Card 4242 4242 4242 4242", "Exp 12/29"])
        XCTAssertTrue(card.contains(.card))
        XCTAssertEqual(samples.first, "•••• 4242")
        XCTAssertTrue(SensitiveScanner.detect(in: ["Your verification code is 482913"]).0.contains(.code))
        XCTAssertTrue(SensitiveScanner.detect(in: ["Wi-Fi password: hunter2!"]).0.contains(.password))
        XCTAssertTrue(SensitiveScanner.detect(in: ["SSN 123-45-6789"]).0.contains(.id))
        let seed = ["Your secret recovery phrase", "abandon ability able about above absent absorb abstract absurd abuse access accident"]
        XCTAssertTrue(SensitiveScanner.detect(in: seed).0.contains(.seed))
        // Ordinary text: phone numbers, prices, dates and order numbers aren't flagged.
        let normal = SensitiveScanner.detect(in: ["Order #4823 placed 12/03/2026", "Total $1,249.00", "Call +1 415 555 0132", "Room 2041"]).0
        XCTAssertTrue(normal.isEmpty, "\(normal)")
    }
}

final class OfficeCleanTests: XCTestCase {
    func testRemovesAuthorAndCompanyFromWordFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-office-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/docProps"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/word"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"<?xml version="1.0"?><cp:coreProperties xmlns:cp="x" xmlns:dc="y"><dc:creator>Jane Doe</dc:creator><cp:lastModifiedBy>John Roe</cp:lastModifiedBy><dc:title>Plan</dc:title></cp:coreProperties>"#
            .write(to: dir.appendingPathComponent("src/docProps/core.xml"), atomically: true, encoding: .utf8)
        try #"<?xml version="1.0"?><Properties><Application>Microsoft Word</Application><Company>Acme Inc</Company></Properties>"#
            .write(to: dir.appendingPathComponent("src/docProps/app.xml"), atomically: true, encoding: .utf8)
        try "<w:document/>".write(to: dir.appendingPathComponent("src/word/document.xml"), atomically: true, encoding: .utf8)
        let docx = dir.appendingPathComponent("Plan.docx")
        _ = await Shell.run("/usr/bin/zip", ["-qr", docx.path, "docProps", "word"], in: dir.appendingPathComponent("src"))

        let before = await MetadataInspector.inspect(docx.path)
        XCTAssertEqual(before?.people, ["Jane Doe", "John Roe", "Acme Inc"])
        let result = await MetadataCleaner.clean(try XCTUnwrap(before), level: .identifying, mode: .saveCopy)
        XCTAssertTrue(result.ok, result.message)
        let after = await MetadataInspector.inspect(try XCTUnwrap(result.output))
        XCTAssertEqual(after?.people, [])
        let title = await Shell.run("/usr/bin/unzip", ["-p", result.output!, "docProps/core.xml"]).out
        XCTAssertTrue(title.contains("<dc:title>Plan</dc:title>"), "other properties are kept")
        let body = await Shell.run("/usr/bin/unzip", ["-p", result.output!, "word/document.xml"]).out
        XCTAssertEqual(body, "<w:document/>", "document content is untouched")
    }
}

final class MediaExtrasTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-extras-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A detailed test image: checkerboard plus shapes, optionally shifted or blurred.
    func pattern(seed: Int, shift: CGFloat = 0, blur: Double = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<16 { for y in 0..<12 where (x + y + seed) % 2 == 0 {
            ctx.setFillColor(CGColor(red: CGFloat((x * 37 + seed * 11) % 255) / 255, green: CGFloat((y * 53 + seed * 7) % 255) / 255, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(x * 40) + shift, y: CGFloat(y * 40), width: 40, height: 40))
        } }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 100 + seed * 30, y: 100, width: 160, height: 160))
        let img = ctx.makeImage()!
        guard blur > 0 else { return img }
        let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: CIImage(cgImage: img).extent)
        return CIContext().createCGImage(ci, from: ci.extent)!
    }

    /// A different composition: sky gradient, horizon, sun.
    func scene() -> CGImage {
        let ctx = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 1, green: 0.55, blue: 0.2, alpha: 1),
                                                                               CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 160), end: CGPoint(x: 0, y: 480), options: [])
        ctx.setFillColor(CGColor(red: 0.1, green: 0.35, blue: 0.15, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.7, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 420, y: 260, width: 110, height: 110))
        return ctx.makeImage()!
    }

    func testSharpnessAndSimilarGroups() async {
        let sharp = SimilarPhotos.sharpness(pattern(seed: 1)), soft = SimilarPhotos.sharpness(pattern(seed: 1, blur: 6))
        XCTAssertGreaterThan(sharp, soft * 3, "blur lowers the sharpness score")
        let base = Date()
        // a/b/c: the same shot (b slightly moved, c slightly soft); d: a completely different scene.
        let images: [String: CGImage] = ["a": pattern(seed: 1), "b": pattern(seed: 1, shift: 3), "c": pattern(seed: 1, blur: 1.2), "d": scene()]
        let items = ["a", "b", "c", "d"].enumerated().map { i, id in
            MediaItem(origin: .file(id), kind: .photo, date: base.addingTimeInterval(Double(i) * 20))
        }
        let groups = await SimilarPhotos.groups(items, image: { images[$0.filePath!] }, progress: { _, _ in })
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].items.compactMap(\.filePath)), ["a", "b", "c"], "the different photo stays out")
        XCTAssertNotEqual(groups[0].keep, "c", "the blurry copy is never the one suggested to keep")
        XCTAssertTrue(SimilarPhotos.blurry(["x": 500, "y": 480, "z": 20]).contains("z"))
    }

    func testEnhanceKeepsSizeAndChangesPixels() throws {
        let dull = CIImage(cgImage: pattern(seed: 2)).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.5, kCIInputBrightnessKey: -0.2])
        let input = CIContext().createCGImage(dull, from: dull.extent)!
        let out = try XCTUnwrap(PhotoEnhancer.enhance(input, options: EnhanceOptions()))
        XCTAssertEqual(out.width, input.width)
        XCTAssertEqual(out.height, input.height)
        XCTAssertNotEqual(out.dataProvider?.data as Data?, input.dataProvider?.data as Data?)
    }

    func testBuiltInMusicIsAFullLoop() async throws {
        let url = dir.appendingPathComponent("calm.caf")
        try MusicGenerator.render(.calm, to: url)
        let seconds = CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
        XCTAssertEqual(seconds, 32, accuracy: 0.1)
    }

    func testTrimsClips() async throws {
        // A 4.5 s source (title + 1 photo), then a video that uses 1.5 s from its middle.
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let photo = dir.appendingPathComponent("p.jpg")
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        var o = VideoOptions(); o.title = "Source"; o.photoSeconds = 2
        let src = try await VideoBuilder.build(items: [await MediaLibrary.item(at: photo.path)!], options: o,
                                               output: dir.appendingPathComponent("src.mp4")) { _ in }
        let clip = await MediaLibrary.item(at: src.url.path)!
        var t = VideoOptions(); t.trims[clip.id] = ClipTrim(start: 1.5, length: 1.5)
        let trimmed = try await VideoBuilder.build(items: [clip], options: t, output: dir.appendingPathComponent("trim.mp4")) { _ in }
        XCTAssertEqual(trimmed.duration, 1.5, accuracy: 0.1)
    }
}

final class ScreenshotDetectionTests: XCTestCase {
    /// Finds screenshots by name and by the "Screenshot" EXIF comment, and skips code projects.
    func testFindsScreenshotsByNameAndHeader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        func write(_ name: String, comment: String?) {
            let url = dir.appendingPathComponent(name)
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            let props: [CFString: Any] = comment.map { [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: $0]] } ?? [:]
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        write("Screenshot 2026-01-01 at 10.00.00.png", comment: nil)
        write("IMG_0001.png", comment: "Screenshot")
        write("holiday.png", comment: nil)
        write("node_modules/Screenshot inside dependency.png", comment: nil)
        let found = SensitiveScanner.screenshots(in: [dir.path]).map { ($0 as NSString).lastPathComponent }.sorted()
        XCTAssertEqual(found, ["IMG_0001.png", "Screenshot 2026-01-01 at 10.00.00.png"])
    }
}

final class MusicEnvelopeTests: XCTestCase {
    /// Overlapping volume ramps crash AVFoundation: clips inside the fades and back-to-back clips must still give a clean curve.
    func testEnvelopeHasIncreasingTimesAndDucks() {
        let env = VideoBuilder.musicEnvelope(duration: 10, volume: 0.7, clips: [(0.5, 1.5), (2.0, 1.0), (8.5, 1.2), (3.1, 0.2)])
        XCTAssertEqual(env.first?.time, 0)
        XCTAssertEqual(env.first?.volume, 0)
        XCTAssertEqual(env.last?.time, 10)
        XCTAssertEqual(env.last?.volume, 0)
        for (a, b) in zip(env, env.dropFirst()) { XCTAssertLessThan(a.time, b.time) }
        XCTAssertTrue(env.allSatisfy { $0.volume >= 0 && $0.volume <= 0.7 })
        let mid = env.first { $0.time == 2.5 } ?? env.min { abs($0.time - 2.5) < abs($1.time - 2.5) }!
        XCTAssertLessThan(mid.volume, 0.7 * 0.3)
        XCTAssertTrue(VideoBuilder.musicEnvelope(duration: 0, volume: 1, clips: []).isEmpty)
    }
}
#endif
