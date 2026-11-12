#if os(macOS)
@testable import DiskLensCore
import XCTest

final class PeaceTests: XCTestCase {
    func testHealthVerdicts() {
        func h(_ used: Int?, spare: Int? = 100, errors: Int = 0, warning: Int = 0, smart: String = "Verified") -> DiskHealth {
            DiskHealth(smartStatus: smart, model: "SSD", percentUsed: used, availableSpare: spare, spareThreshold: 10, temperatureC: 35,
                       powerOnHours: 100, bytesWritten: 1, bytesRead: 1, unsafeShutdowns: 3, mediaErrors: errors, criticalWarning: warning)
        }
        XCTAssertEqual(h(2).verdict, .good)
        XCTAssertEqual(h(95).verdict, .watch)
        XCTAssertEqual(h(5, errors: 2).verdict, .watch)
        XCTAssertEqual(h(5, spare: 8).verdict, .replace)
        XCTAssertEqual(h(5, spare: 40).verdict, .watch)
        // Apple SSDs report a spare threshold of 99%: a full spare (100%) must still read as healthy.
        let apple = DiskHealth(smartStatus: "Verified", model: "APPLE SSD", percentUsed: 2, availableSpare: 100, spareThreshold: 99, temperatureC: 35,
                               powerOnHours: 1366, bytesWritten: 1, bytesRead: 1, unsafeShutdowns: 33, mediaErrors: 0, criticalWarning: 0)
        XCTAssertEqual(apple.verdict, .good)
        XCTAssertEqual(h(5, warning: 1).verdict, .replace)
        XCTAssertEqual(h(5, smart: "Failing").verdict, .replace)
        XCTAssertEqual(h(nil, spare: nil).verdict, .good, "no NVMe data: rely on SMART status")
        XCTAssertTrue(h(2).notes.first!.contains("barely worn"))
    }

    func testSystemDataBreakdownLinksCleanups() {
        let gb: Int64 = 1_000_000_000
        let snap = Snapshot(date: Date(), capacity: 500 * gb, free: 100 * gb, system: 20 * gb, hidden: 9 * gb, measured: 300 * gb, trash: nil,
                            categories: [CategoryUsage(name: "App data", bytes: 40 * gb, paths: []), CategoryUsage(name: "Caches & temp", bytes: 12 * gb, paths: []),
                                         CategoryUsage(name: "Xcode & Simulators", bytes: 30 * gb, paths: []), CategoryUsage(name: "Documents", bytes: 50 * gb, paths: []),
                                         CategoryUsage(name: "Docker", bytes: 100_000_000, paths: [])])
        let findings = [Finding(id: "app-caches", title: "", detail: "", tier: .safe, bytes: 1, action: .trash),
                        Finding(id: "sim-runtime-17.5", title: "", detail: "", tier: .review, bytes: 1, action: .advice)]
        let parts = SystemDataExplainer.breakdown(snap, findings: findings)
        XCTAssertEqual(parts.map(\.name), ["App data", "Xcode & Simulators", "macOS", "Caches & temp", "Hidden (needs Full Disk Access)"])
        XCTAssertFalse(parts.contains { $0.name == "Documents" }, "user folders aren't System Data")
        XCTAssertFalse(parts.contains { $0.name == "Docker" }, "tiny parts are left out")
        XCTAssertEqual(parts.first { $0.name == "Caches & temp" }?.findingIDs, ["app-caches"])
        XCTAssertEqual(parts.first { $0.name == "Xcode & Simulators" }?.findingIDs, ["sim-runtime-17.5"])
    }

    func testArchiveVerifiesEveryFileAndCatchesBadCopies() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        let src = root.appendingPathComponent("home"), drive = root.appendingPathComponent("drive")
        try fm.createDirectory(at: src.appendingPathComponent("Old Project/assets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 7, count: 300_000).write(to: src.appendingPathComponent("Old Project/assets/video.bin"))
        try Data("notes".utf8).write(to: src.appendingPathComponent("Old Project/readme.txt"))
        try Data(repeating: 1, count: 1_000).write(to: src.appendingPathComponent("single.dat"))

        let paths = [src.appendingPathComponent("Old Project").path, src.appendingPathComponent("single.dat").path]
        let r = await Archiver.archive(paths, to: drive)
        XCTAssertEqual(r.verified, paths, "\(r.failures)")
        XCTAssertEqual(r.bytes, 301_005)
        let copied = try XCTUnwrap(r.destination).appendingPathComponent("Old Project/assets/video.bin")
        XCTAssertTrue(fm.fileExists(atPath: copied.path))
        XCTAssertTrue(fm.fileExists(atPath: paths[0]), "originals are never touched by archiving")

        // A copy that differs by one byte must be caught.
        var data = try Data(contentsOf: copied)
        data[1000] = 9
        try data.write(to: copied)
        XCTAssertNotNil(Archiver.compare(paths[0], try XCTUnwrap(r.destination).appendingPathComponent("Old Project").path))
        let dest = try XCTUnwrap(r.destination).appendingPathComponent("Old Project")
        try fm.removeItem(at: dest.appendingPathComponent("readme.txt"))
        let problem = try XCTUnwrap(Archiver.compare(paths[0], dest.path))
        XCTAssertTrue(problem.contains("missing") || problem.contains("different"), problem)
    }

    func testDigestAndWatchedFolders() {
        let now = Date()
        let gb: Int64 = 1_000_000_000
        let m = Digest.message(safeBytes: 12 * gb, lastScan: now.addingTimeInterval(-3 * 86_400), free: 80 * gb, freeWeekAgo: 95 * gb, now: now)
        XCTAssertEqual(m?.title, "DiskLens weekly: 80.0 GB free")
        XCTAssertTrue(m!.body.contains("dropped by 15.0 GB") && m!.body.contains("12.0 GB can be cleaned safely") && m!.body.contains("3 days ago"))
        XCTAssertNil(Digest.message(safeBytes: 0, lastScan: now, free: 80 * gb, freeWeekAgo: 80 * gb, now: now), "nothing to say, no notification")
        XCTAssertTrue(Digest.message(safeBytes: 0, lastScan: nil, free: 80 * gb, freeWeekAgo: nil, now: now)!.body.contains("last scan"))

        var w = WatchedFolder(path: "/tmp/x", limitBytes: 10 * gb)
        XCTAssertFalse(w.shouldAlert(size: 9 * gb))
        XCTAssertTrue(w.shouldAlert(size: 11 * gb))
        w.lastAlert = now.addingTimeInterval(-86_400)
        XCTAssertFalse(w.shouldAlert(size: 11 * gb, now: now), "at most once a week")
        w.lastAlert = now.addingTimeInterval(-8 * 86_400)
        XCTAssertTrue(w.shouldAlert(size: 11 * gb, now: now))
    }
}

/// Read-only checks on this Mac: DISKLENS_VERIFY15=1.
final class Verify15Tests: XCTestCase {
    override func setUpWithError() throws { try XCTSkipUnless(ProcessInfo.processInfo.environment["DISKLENS_VERIFY15"] != nil) }
    func log(_ s: String) { print("VERIFY15 " + s) }

    func testRealDiskHealthAndVolumes() async {
        let h = await DiskHealth.read()
        log("health: \(h.model ?? "?") SMART \(h.smartStatus ?? "?") used \(h.percentUsed ?? -1)% spare \(h.availableSpare ?? -1)% temp \(h.temperatureC ?? 0)C hours \(h.powerOnHours ?? 0) written \(ByteFormat.string(h.bytesWritten ?? 0)) verdict \(h.verdict.rawValue)")
        log("raw: spare threshold \(h.spareThreshold ?? -1), critical warning \(h.criticalWarning ?? -1), media errors \(h.mediaErrors ?? -1), unsafe \(h.unsafeShutdowns ?? -1)")
        XCTAssertNotNil(h.smartStatus)
        log("external drives: \(Archiver.externalVolumes().map { "\($0.name) \(ByteFormat.string($0.free)) free" })")
    }

    func testOldFilesOnThisMac() async {
        let t = Date()
        let index = await HomeIndex.build()
        let ctx = RuleContext(codeRoots: [], runningBundleIDs: [], hasFullDiskAccess: false, apps: [], homeIndex: index)
        let old = await OldFilesRule().evaluate(ctx)
        let large = await LargeFilesRule().evaluate(ctx)
        log("home index: \(index.largeFiles.count) files over 300 MB in \(String(format: "%.0fs", Date().timeIntervalSince(t))); old: \(old.first.map { "\($0.items.count) files, \(ByteFormat.string($0.bytes))" } ?? "none"); large (1 GB+): \(large.first.map { "\($0.items.count) files" } ?? "none")")
    }
}
#endif
#if os(macOS)
extension Verify15Tests {
    /// Archives sandbox copies to a mounted test disk image ("DL Test Drive"), as if it were a USB drive.
    func testArchiveToMountedTestDrive() async throws {
        let sandbox = try XCTUnwrap(ProcessInfo.processInfo.environment["DISKLENS_VERIFY14"])
        let drive = try XCTUnwrap(Archiver.externalVolumes().first { $0.name == "DL Test Drive" }, "test drive not detected as external")
        log("detected: \(drive.name) \(ByteFormat.string(drive.free)) free, \(drive.format ?? "?")")
        let sources = ["Laya Demo.mov", "Trend 1.jpg"].map { sandbox + "/copies/" + $0 } + [sandbox + "/out/pdf"]
        let before = sources.map { Archiver.sha256($0 + (FileManager.default.fileExists(atPath: $0 + "/") ? "" : "")) }
        let r = await Archiver.archive(sources, to: URL(fileURLWithPath: drive.path))
        log("archive: verified \(r.verified.count) of \(sources.count), \(ByteFormat.string(r.bytes)), failures \(r.failures), into \(r.destination?.path ?? "-")")
        XCTAssertEqual(r.verified.count, sources.count)
        XCTAssertEqual(sources.map { Archiver.sha256($0) }, before, "sources unchanged")
    }
}
#endif
