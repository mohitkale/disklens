#if os(macOS)
@testable import DiskLensCore
import ImageIO
import XCTest

final class ShrinkTests: XCTestCase {
    func testDownloadsTidyFindsOnlyWhatsSafe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ name: String, _ content: String, daysOld: Double = 30) throws {
            let url = dir.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
        }
        try write("Report.pdf", "same")
        try write("Report (1).pdf", "same")          // exact duplicate → found
        try write("Notes.txt", "v1")
        try write("Notes (1).txt", "v2 different")   // same name pattern, different content → kept
        try write("photos.zip", "zip")
        try fm.createDirectory(at: dir.appendingPathComponent("photos"), withIntermediateDirectories: true)  // unpacked → found
        try write("lonely.zip", "zip")               // not unpacked → kept
        try write("big.crdownload", "partial", daysOld: 3)   // unfinished → found
        try write("fresh.crdownload", "partial", daysOld: 0) // still downloading → kept
        try write("Slack-4.41.dmg", "dmg")           // installer for an installed app → found, preselected
        try write("Other-1.0.dmg", "dmg")            // installer, app unknown → found, not preselected
        try write("new.dmg", "dmg", daysOld: 2)      // too new → kept
        let slack = InstalledApp(path: "/Applications/Slack.app", name: "Slack", bundleID: "com.tinyspeck.slackmacgap", version: "4", lastUsed: nil, isManaged: false)
        let items = DownloadsTidy.items(in: dir.path, apps: [slack])
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["Report (1).pdf", "photos.zip", "big.crdownload", "Slack-4.41.dmg", "Other-1.0.dmg"])
        XCTAssertTrue(byName["Slack-4.41.dmg"]!.selectedByDefault)
        XCTAssertFalse(byName["Other-1.0.dmg"]!.selectedByDefault)
        XCTAssertEqual(DownloadsTidy.duplicateOriginal(of: "a copy.png"), "a.png")
        XCTAssertEqual(DownloadsTidy.duplicateOriginal(of: "a-2.png"), "a.png")
        XCTAssertNil(DownloadsTidy.duplicateOriginal(of: "2024-report.png"))
    }

    func testSnapshotParsingLeavesMacOSSnapshotsAlone() {
        let out = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-11-10-101500.local
        com.apple.TimeMachine.2026-11-09-091500.local
        com.apple.os.update-ECF5104E367CC369B8BD7A90CC030DE52A096EC09BA72FF71581DD3982BBA0A2
        com.apple.os.update-MSUPrepareUpdate
        """
        let p = LocalSnapshots.parse(out)
        XCTAssertEqual(p.timeMachine, ["2026-11-09-091500", "2026-11-10-101500"])
        XCTAssertEqual(p.system.count, 2)
        XCTAssertTrue(LocalSnapshots.parse("Snapshots for volume group containing disk /:\ncom.apple.os.update-X").timeMachine.isEmpty)
    }

    func testICloudGuard() {
        let home = NSHomeDirectory()
        XCTAssertTrue(ICloudFiles.isInICloudDrive(home + "/Library/Mobile Documents/com~apple~CloudDocs/a.mov"))
        XCTAssertFalse(ICloudFiles.isInICloudDrive(home + "/Documents/a.mov"))
        XCTAssertFalse(ICloudFiles.isInICloudDrive(home + "/Library/Mobile Documents/../Documents/a.mov"))
        XCTAssertTrue(CleanupAction.removeDownload.usesItems && CleanupAction.removeDownload.isExecutable)
    }

    /// Apple's own sample account pictures (animals): a clear subject, no personal photos.
    func testRemoveBackgroundOnSampleAnimal() throws {
        let dir = "/Library/User Pictures/Animals"
        let file = try XCTUnwrap((try? FileManager.default.contentsOfDirectory(atPath: dir))?.sorted().first, "no sample pictures")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: dir + "/" + file) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        guard let cut = BackgroundRemover.cutout(image) else { throw XCTSkip("No subject found in \(file) on this Mac") }
        XCTAssertEqual(cut.width, image.width)
        XCTAssertTrue([.premultipliedLast, .last, .premultipliedFirst, .first].contains(cut.alphaInfo))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let r = BackgroundRemover.save(dir + "/" + file, background: nil, into: out)
        XCTAssertTrue(r.ok, r.message)
        if let keep = ProcessInfo.processInfo.environment["DISKLENS_VERIFY14"], let o = r.output {
            try? FileManager.default.copyItem(atPath: o, toPath: keep + "/out/cutout.png")
            try? FileManager.default.copyItem(atPath: dir + "/" + file, toPath: keep + "/out/cutout-source." + (file as NSString).pathExtension)
        }
    }
}

extension Verify14Tests {
    func testCompressRealVideoToTarget() async throws {
        let out = sandbox.appendingPathComponent("out/video")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, target) in [("Laya Demo.mov", Int64(1_500_000)), ("portrait-demo (1).mp4", Int64(1_000_000))] {
            let t = Date()
            let r = await VideoCompressor.compress(sandbox.appendingPathComponent("copies/" + name).path, targetBytes: target, into: out)
            log("video \(name) → under \(ByteFormat.string(target)): ok \(r.ok), \(r.message), \(String(format: "%.0fs", Date().timeIntervalSince(t)))")
            XCTAssertTrue(r.ok, r.message)
            XCTAssertLessThanOrEqual(r.bytes, target)
        }
        let tooSmall = await VideoCompressor.compress(sandbox.appendingPathComponent("copies/Laya Demo.mov").path, targetBytes: 20_000, into: out)
        log("video impossible target: \(tooSmall.message)")
        XCTAssertFalse(tooSmall.ok)
    }

    func testBiggestFilesScanReadOnly() async {
        let t = Date()
        let found = await ShrinkFinder.scan()
        var kinds: [String: Int] = [:]
        for c in found { kinds[c.kind.rawValue, default: 0] += 1 }
        let saving = found.compactMap(\.estimatedSaving).reduce(0, +)
        log("biggest files: \(found.count) candidates \(kinds), estimated saving \(ByteFormat.string(saving)) (excl. PDFs), \(String(format: "%.0fs", Date().timeIntervalSince(t)))")
        let tidy = DownloadsTidy.items(in: NSHomeDirectory() + "/Downloads", apps: AppIndex.installedApps())
        var notes: [String: Int] = [:]
        for i in tidy { notes[(i.note ?? "").components(separatedBy: " · ").first ?? "", default: 0] += 1 }
        log("downloads tidy: \(tidy.count) items \(notes), \(ByteFormat.string(tidy.reduce(0) { $0 + $1.bytes })), preselected \(tidy.filter(\.selectedByDefault).count)")
    }
}
#endif
#if os(macOS)
extension Verify14Tests {
    /// "Make Smaller" on copies of a real video, PDF and a PNG made from a real photo: copies only, originals checked by hash outside.
    func testMakeSmallerOnCopies() async throws {
        let work = sandbox.appendingPathComponent("out/makesmaller")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fm = FileManager.default
        for name in ["Laya Demo.mov", "land-6a7c5f013c889200010f912e.pdf", "161361290_20241220T010904.pdf"] {
            try fm.copyItem(at: sandbox.appendingPathComponent("copies/" + name), to: work.appendingPathComponent(name))
        }
        // A big PNG from a real photo copy (lossless: the classic "could be much smaller" case).
        var png = ImageConvertOptions(); png.format = .png; png.removePrivateInfo = false
        _ = MediaConverter.convertImage(sandbox.appendingPathComponent("copies/Trend 1.jpg").path, options: png, into: work)
        for name in try fm.contentsOfDirectory(atPath: work.path).sorted() {
            let path = work.appendingPathComponent(name).path
            let bytes = Int64((try fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
            let ext = (name as NSString).pathExtension.lowercased()
            let kind: ShrinkCandidate.Kind = ext == "pdf" ? .pdf : ext == "png" ? .image : .video
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            let r = await ShrinkFinder.makeSmaller(ShrinkCandidate(path: path, kind: kind, bytes: bytes, estimate: nil, detail: "", modified: nil))
            log("make smaller \(name.prefix(14)): ok \(r.ok) | \(r.message) | \(r.method) | \(r.output.map { ($0 as NSString).lastPathComponent } ?? "-")")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "original must be unchanged")
            if r.ok { XCTAssertLessThanOrEqual(Double(r.after), Double(bytes) * 0.8) }
        }
    }
}
#endif
