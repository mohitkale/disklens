@testable import DiskLensCore
import XCTest

final class VersionsTests: XCTestCase {
    func testOrdering() {
        XCTAssertTrue(Versions.less("30.0.2", "30.0.3"))
        XCTAssertTrue(Versions.less("9.0.0", "10.0.0"))
        XCTAssertTrue(Versions.less("36.0.0-rc3", "36.0.0"))
        XCTAssertFalse(Versions.less("36.1.0", "36.0.0"))
        XCTAssertTrue(Versions.less("26.1.10909125", "27.1.12297006"))
    }

    func testPartitionKeepsPinnedAndNewest() {
        let ndk = ["26.1.10909125", "27.1.12297006", "28.0.12674087", "29.0.14206865"]
        let result = Versions.partition(ndk, pinned: ["27.1.12297006"], keepNewest: 1)
        XCTAssertEqual(result.keep, ["27.1.12297006", "29.0.14206865"])
        XCTAssertEqual(result.remove, ["26.1.10909125", "28.0.12674087"])
    }

    func testPartitionDropsPrereleases() {
        let tools = ["30.0.2", "34.0.0-rc2", "35.0.0", "36.0.0", "36.0.0-rc3", "36.1.0"]
        let result = Versions.partition(tools, pinned: ["30.0.2"], keepNewest: 3)
        XCTAssertEqual(result.keep, ["30.0.2", "35.0.0", "36.0.0", "36.1.0"])
        XCTAssertEqual(result.remove, ["34.0.0-rc2", "36.0.0-rc3"])
    }

    func testPartitionWithOnlyPrereleasesKeepsNewest() {
        let result = Versions.partition(["1.0-rc1", "1.0-rc2"], pinned: [], keepNewest: 2)
        XCTAssertEqual(result.keep, ["1.0-rc2"])
    }
}

final class AndroidPinsTests: XCTestCase {
    func testParsesGradleAndVersionCatalog() {
        var pins = AndroidPins()
        pins.merge(text: """
        buildscript {
            ext {
                buildToolsVersion = "30.0.3"
                ndkVersion = "21.4.7075529"
            }
        }
        android { ndkVersion '22.1.7171670' }
        """, project: "cryptobot")
        pins.merge(text: """
        [versions]
        buildTools = "36.0.0"
        ndkVersion = "27.1.12297006"
        """, project: "expo-witchfinder")

        XCTAssertEqual(Set(pins.ndk.keys), ["21.4.7075529", "22.1.7171670", "27.1.12297006"])
        XCTAssertEqual(Set(pins.buildTools.keys), ["30.0.3", "36.0.0"])
        XCTAssertEqual(pins.ndk["27.1.12297006"], ["expo-witchfinder"])
    }

    func testIgnoresVariableReferences() {
        var pins = AndroidPins()
        pins.merge(text: "buildToolsVersion rootProject.ext.buildToolsVersion", project: "lib")
        XCTAssertTrue(pins.buildTools.isEmpty)
    }
}

final class ByteFormatTests: XCTestCase {
    func testParsesToolOutput() {
        XCTAssertEqual(ByteFormat.parse("5.117GB (22%)"), 5_117_000_000)
        XCTAssertEqual(ByteFormat.parse("173.1MB"), 173_100_000)
        XCTAssertEqual(ByteFormat.parse("0B"), 0)
        XCTAssertEqual(ByteFormat.parse("1.2 kB"), 1_200)
        XCTAssertNil(ByteFormat.parse("n/a"))
    }

    func testFormatsDecimalUnits() {
        XCTAssertEqual(ByteFormat.string(17_900_000_000), "17.9 GB")
        XCTAssertEqual(ByteFormat.string(175_600_000_000), "176 GB")
        XCTAssertEqual(ByteFormat.string(340_000_000), "340 MB")
    }
}

#if os(macOS)
final class TrashGuardTests: XCTestCase {
    let home = "/Users/test"

    func testRefusesTopLevelAndSensitiveFolders() {
        for path in ["/Users/test", "/Users/test/Documents", "/Users/test/Library", "/Users/test/Library/Caches",
                     "/Users/test/Library/Application Support", "/Users/test/.ssh/id_rsa", "/Users/test/Library/Keychains/login.keychain-db",
                     "/Applications", "/Applications/Utilities/Terminal.app", "/System/Applications/Mail.app",
                     "/Applications/Xcode.app/Contents", "/Library/Developer/CoreSimulator", "/Users/other/Library/Caches/x",
                     "/Users/test/Documents/../Library"] {
            XCTAssertFalse(Executor.isSafeToTrash(path, home: home), path)
        }
    }

    func testAllowsSpecificItems() {
        for path in ["/Users/test/Library/Caches/Cypress", "/Users/test/.npm/_cacache",
                     "/Users/test/Documents/app/node_modules", "/Users/test/Library/Android/sdk/ndk/26.1.10909125",
                     "/Applications/MetaTrader 5.app", "/Users/test/Applications/Tool.app"] {
            XCTAssertTrue(Executor.isSafeToTrash(path, home: home), path)
        }
    }
}
#endif

final class FindingTests: XCTestCase {
    func testSelectedBytes() {
        let items = [FindingItem(path: "/a", bytes: 100), FindingItem(path: "/b", bytes: 50)]
        let f = Finding(id: "x", title: "x", detail: "", tier: .safe, bytes: 150, items: items, action: .trash)
        XCTAssertEqual(f.bytes(selected: ["/b"]), 50)
        XCTAssertEqual(f.bytes(selected: []), 0)
        let cmd = Finding(id: "y", title: "y", detail: "", tier: .safe, bytes: 999, action: .command(tool: "/usr/bin/true", args: []))
        XCTAssertEqual(cmd.bytes(selected: []), 999)
    }

    func testHistoryRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: dir)
        let snap = Snapshot(date: Date(timeIntervalSince1970: 1_000), capacity: 500, free: 100, system: 20, hidden: 30,
                            measured: 350, trash: nil, categories: [CategoryUsage(name: "Docs", bytes: 10, paths: ["/d"])])
        store.saveSnapshots([snap])
        XCTAssertEqual(store.loadSnapshots(), [snap])
        try? FileManager.default.removeItem(at: dir)
    }
}

#if os(macOS)
/// Moves a throwaway folder to the real Trash. Opt-in: DISKLENS_LIVE_TEST=1 swift test
final class LiveTrashTests: XCTestCase {
    func testTrashesOnlyWhatWasSelected() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISKLENS_LIVE_TEST"] == "1")
        let root = NSHomeDirectory() + "/Library/Caches/DiskLensSelfTest-\(UUID().uuidString.prefix(8))"
        let keep = root + "/keep", drop = root + "/drop"
        for dir in [keep, drop] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(count: 1_000_000).write(to: URL(fileURLWithPath: dir + "/blob"))
        }
        let items = [FindingItem(path: drop, bytes: 1_000_000), FindingItem(path: keep, bytes: 1_000_000, selectedByDefault: false)]
        let finding = Finding(id: "t", title: "t", detail: "", tier: .safe, bytes: 2_000_000, items: items, action: .trash)
        let selected = [items[0]]

        let problems = await Executor.problems(for: finding, selected: selected, runningApps: [:])
        XCTAssertEqual(problems, [])
        let result = await Executor.perform(finding, selected: selected)
        XCTAssertEqual(result.outcome, .trashed)
        XCTAssertEqual(result.trashed, [drop])
        XCTAssertFalse(FileManager.default.fileExists(atPath: drop))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep + "/blob"))
        try FileManager.default.trashItem(at: URL(fileURLWithPath: root), resultingItemURL: nil)
    }

    func testRefusesWhileFileIsOpen() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISKLENS_LIVE_TEST"] == "1")
        let dir = NSHomeDirectory() + "/Library/Caches/DiskLensSelfTest-open-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/locked", contents: Data("x".utf8))
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: dir + "/locked"))
        let item = FindingItem(path: dir, bytes: 1)
        let finding = Finding(id: "o", title: "o", detail: "", tier: .safe, bytes: 1, items: [item], action: .trash)
        let problems = await Executor.problems(for: finding, selected: [item], runningApps: [:])
        XCTAssertTrue(problems.contains { $0.contains("in use") }, "\(problems)")
        try handle.close()
        try FileManager.default.trashItem(at: URL(fileURLWithPath: dir), resultingItemURL: nil)
    }
}
#endif

#if os(macOS)
final class AppIndexTests: XCTestCase {
    let apps = [
        InstalledApp(path: "/Applications/Android Studio.app", name: "Android Studio", bundleID: "com.google.android.studio", version: "2024.2", lastUsed: nil, isManaged: false),
        InstalledApp(path: "/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome", version: "1", lastUsed: nil, isManaged: false),
        InstalledApp(path: "/Applications/Firefox.app", name: "Firefox", bundleID: "org.mozilla.firefox", version: "1", lastUsed: nil, isManaged: false),
    ]

    func testMatchesCacheFoldersToOwners() {
        XCTAssertEqual(AppIndex.owner(ofFolder: "AndroidStudio2024.2", apps: apps)?.owner, "Android Studio")
        XCTAssertEqual(AppIndex.owner(ofFolder: "com.google.Chrome", apps: apps)?.owner, "Google Chrome")
        XCTAssertEqual(AppIndex.owner(ofFolder: "Firefox", apps: apps)?.owner, "Firefox")
        XCTAssertEqual(AppIndex.owner(ofFolder: "pip", apps: apps)?.owner, "Python pip")
        XCTAssertNil(AppIndex.owner(ofFolder: "SomethingUnknown", apps: apps))
    }

    func testAppBundleGuard() {
        XCTAssertTrue(Executor.isAppBundle("/Applications/Foo.app", home: "/Users/t"))
        XCTAssertTrue(Executor.isAppBundle("/Users/t/Applications/Foo.app", home: "/Users/t"))
        XCTAssertFalse(Executor.isAppBundle("/Applications/Utilities/Foo.app", home: "/Users/t"))
        XCTAssertFalse(Executor.isAppBundle("/System/Applications/Mail.app", home: "/Users/t"))
        XCTAssertFalse(Executor.isAppBundle("/Applications/Foo.app/Contents", home: "/Users/t"))
    }
}
#endif
