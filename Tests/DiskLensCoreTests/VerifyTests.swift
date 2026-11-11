#if os(macOS)
import AVFoundation
import CoreGraphics
@testable import DiskLensCore
import ImageIO
import Vision
import XCTest

/// Real-data verification, off by default. Set DISKLENS_VERIFY to a sandbox folder of *copies*:
/// every write goes into that folder, and the uninstall check uses a fake app it creates itself.
final class VerifyTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        let dir = ProcessInfo.processInfo.environment["DISKLENS_VERIFY"]
        try XCTSkipUnless(dir != nil, "Set DISKLENS_VERIFY to a sandbox folder")
        sandbox = URL(fileURLWithPath: dir!)
    }

    var copies: URL { sandbox.appendingPathComponent("copies") }
    func out(_ name: String) throws -> URL {
        let u = sandbox.appendingPathComponent("out/" + name)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func log(_ s: String) { print("VERIFY " + s) }

    func testEnhanceRealPhotos() throws {
        let folder = try out("enhance")
        for name in ["Trend 1.jpg", "t - 1.jpg"] {
            let src = copies.appendingPathComponent(name).path
            let r = PhotoEnhancer.enhanceFile(src, options: EnhanceOptions(), removePrivateInfo: true, into: folder)
            XCTAssertTrue(r.ok, r.message)
            let srcSize = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            log("enhance \(name): \(r.pixelSize.width)x\(r.pixelSize.height) (original \(srcSize?[kCGImagePropertyPixelWidth] ?? 0)x\(srcSize?[kCGImagePropertyPixelHeight] ?? 0)), \(r.bytes / 1000) KB")
            if let o = r.output { XCTAssertNil(try XCTUnwrap(MetadataInspectorProxy.report(o)).coordinate) }
        }
    }

    func testOfficeCleanOnCopy() async throws {
        let src = copies.appendingPathComponent("letter to college.docx").path
        let b = await MetadataInspector.inspect(src)
        let before = try XCTUnwrap(b)
        log("docx before: people \(before.people.count), app \(before.software ?? "-")")
        let result = await MetadataCleaner.clean(before, level: .identifying, mode: .saveCopy)
        XCTAssertTrue(result.ok, result.message)
        let output = try XCTUnwrap(result.output)
        let a = await MetadataInspector.inspect(output)
        let after = try XCTUnwrap(a)
        XCTAssertTrue(after.people.isEmpty)
        let zipTest = await Shell.run("/usr/bin/unzip", ["-tq", output])
        XCTAssertTrue(zipTest.ok, zipTest.out + zipTest.err)
        log("docx after: people \(after.people.count), zip intact: \(zipTest.ok), copy: \((output as NSString).lastPathComponent)")
        try FileManager.default.moveItem(atPath: output, toPath: try out("office").appendingPathComponent("clean.docx").path)
    }

    func testVideoWithTrimsAndBuiltInMusic() async throws {
        var items: [MediaItem] = []
        for name in ["Laya Demo.mov", "Trend 1.jpg", "portrait-demo (1).mp4", "t - 2.jpg"] {
            let item = await MediaLibrary.item(at: copies.appendingPathComponent(name).path)
            items.append(try XCTUnwrap(item))
        }
        var o = VideoOptions()
        o.title = "Verification"
        o.photoSeconds = 2
        o.musicPath = try MusicGenerator.track(.warm).path
        o.trims[items[0].id] = ClipTrim(start: 1, length: 2)
        o.trims[items[2].id] = ClipTrim(start: 0.5, length: 1.5)
        let url = try out("video").appendingPathComponent("verify.mp4")
        try? FileManager.default.removeItem(at: url)
        let result = try await VideoBuilder.build(items: items, options: o, output: url) { _ in }
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        log("video: \(String(format: "%.1f", result.duration)) s, video tracks \(video.count), audio tracks \(audio.count), skipped \(result.skipped)")
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        // Title card + 2 s + 2 s photos + 2 s + 1.5 s trimmed clips: well under the clips' full length.
        XCTAssertLessThan(result.duration, 14)
    }

    func testSimilarAndSensitiveReadOnly() async throws {
        let items = await MediaLibrary.scanFolders([copies.path])
        let r = await SimilarPhotos.analyze(items, image: { await MediaLibrary.image(for: $0, maxPixels: 512) }) { _, _ in }
        log("similar: \(r.checked) photos checked, \(r.groups.count) groups \(r.groups.map { $0.items.map(\.name) }), \(r.blurry.count) blurry")
        for name in ["Trend 1.jpg", "t - 1.jpg"] {
            let f = SensitiveScanner.inspect(copies.appendingPathComponent(name).path)
            log("sensitive \(name): \(f?.kinds.map(\.rawValue) ?? [])")
        }
    }

    /// Leftover matching across every real app, read-only: nothing claimed twice, nothing outside ~/Library.
    func testLeftoverMatchingIsConservative() async throws {
        let apps = AppIndex.installedApps()
        var owner: [String: String] = [:]
        var clashes: [String] = []
        var count = 0
        for app in AppUninstaller.removableApps(apps) {
            for item in await AppUninstaller.leftovers(for: app, allApps: apps) {
                count += 1
                XCTAssertTrue(item.path.hasPrefix(NSHomeDirectory() + "/Library/"), item.path)
                if let other = owner[item.path] { clashes.append("\(item.name): \(other) and \(app.name)") }
                owner[item.path] = app.name
            }
        }
        log("leftovers: \(count) items across apps, claimed by two apps: \(clashes.count) \(clashes.prefix(5))")
        XCTAssertTrue(clashes.isEmpty)
    }

    /// End-to-end uninstall of a fake app this test creates: detection, safety checks, then the Trash.
    func testUninstallFakeApp() async throws {
        let home = NSHomeDirectory()
        let id = "com.disklens.verify.fakeapp"
        let appURL = URL(fileURLWithPath: home + "/Applications/DiskLens Verify Fake.app")
        let fm = FileManager.default
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "DiskLens Verify Fake", "CFBundleShortVersionString": "1.0",
                                    "CFBundleExecutable": "fake", "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(to: appURL.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try Data("#!/bin/sh\n".utf8).write(to: appURL.appendingPathComponent("Contents/MacOS/fake"))
        let planted = [home + "/Library/Caches/" + id, home + "/Library/Application Support/DiskLens Verify Fake",
                       home + "/Library/Saved Application State/\(id).savedState"]
        for p in planted {
            try fm.createDirectory(atPath: p, withIntermediateDirectories: true)
            try Data(count: 50_000).write(to: URL(fileURLWithPath: p + "/data.bin"))
        }
        let prefs = home + "/Library/Preferences/\(id).plist"
        (["k": 1] as NSDictionary).write(toFile: prefs, atomically: true)
        defer { for p in planted + [prefs, appURL.path] { try? fm.removeItem(atPath: p) } }

        let app = AppIndex.app(at: appURL.path)
        let apps = AppIndex.installedApps()
        XCTAssertTrue(apps.contains { $0.bundleID == id }, "fake app not listed")
        let leftovers = await AppUninstaller.leftovers(for: app, allApps: apps)
        XCTAssertEqual(Set(leftovers.map(\.path)), Set(planted + [prefs]), "found \(leftovers.map(\.path))")

        let bundle = FindingItem(path: appURL.path, bytes: 10, note: "the app itself", usedBy: app.name, quickSafe: false)
        let items = [bundle] + leftovers
        let finding = Finding(id: "uninstall-" + id, title: "Uninstall", detail: "", tier: .review, bytes: 0, items: items, action: .trash,
                              quitApps: [id])
        let problems = await Executor.problems(for: finding, selected: items, runningApps: [:])
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        let result = await Executor.perform(finding, selected: items)
        log("uninstall fake app: \(result.trashed.count) of \(items.count) moved to the Trash, failures \(result.failures)")
        XCTAssertEqual(Set(result.trashed), Set(items.map(\.path)))
        for p in items.map(\.path) { XCTAssertFalse(fm.fileExists(atPath: p)) }
    }
}

enum MetadataInspectorProxy {
    static func report(_ path: String) -> MetadataReport? { MetadataInspector.image(path, bytes: 0) }
}
#endif
#if os(macOS)
extension VerifyTests {
    func testSimilarBurstFromRealPhoto() async throws {
        // A real burst shares one moment; the edited copies here would otherwise carry today's date.
        let now = Date()
        let items = await MediaLibrary.scanFolders([sandbox.appendingPathComponent("burst").path]).enumerated().map { i, m in
            MediaItem(origin: m.origin, kind: m.kind, date: now.addingTimeInterval(Double(i)), bytes: m.bytes)
        }
        let r = await SimilarPhotos.analyze(items, image: { await MediaLibrary.image(for: $0, maxPixels: 512) }) { _, _ in }
        let groups = r.groups.map { g in g.items.map(\.name).sorted() + ["keep: " + (g.items.first { $0.id == g.keep }?.name ?? "?")] }
        log("burst: \(r.checked) checked, groups \(groups), blurry \(r.blurry.map(\.name)), sharpness \(r.sharpness.map { "\(String($0.key.suffix(12))) \(Int($0.value))" }.sorted())")
    }
}
#endif
#if os(macOS)
extension VerifyTests {
    func testSimilarProbe() async throws {
        let items = await MediaLibrary.scanFolders([sandbox.appendingPathComponent("burst").path]).sorted { $0.name < $1.name }
        var prints: [String: VNFeaturePrintObservation] = [:]
        for i in items { if let cg = await MediaLibrary.image(for: i, maxPixels: 512) { prints[i.name] = SimilarPhotos.featurePrint(cg) } }
        for i in items { log("probe \(i.name) date \(i.date)") }
        for a in items { for b in items where a.name < b.name {
            var d: Float = 0; try prints[a.name]!.computeDistance(&d, to: prints[b.name]!)
            log("probe \(a.name) ~ \(b.name): \(String(format: "%.3f", d))")
        } }
    }
}
#endif
