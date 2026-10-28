#if os(macOS)
import Foundation

public struct RuleContext: Sendable {
    public let home: String
    /// Folders searched for projects (node_modules, Gradle pins).
    public let codeRoots: [String]
    public let runningBundleIDs: Set<String>
    public let hasFullDiskAccess: Bool
    /// Installed apps with their last-opened dates (from Spotlight).
    public let apps: [InstalledApp]
    /// Projects and large files found in the home folder (full scans only).
    public let homeIndex: HomeIndex?

    public init(home: String = NSHomeDirectory(), codeRoots: [String], runningBundleIDs: Set<String>,
                hasFullDiskAccess: Bool, apps: [InstalledApp] = [], homeIndex: HomeIndex? = nil) {
        self.home = home
        self.codeRoots = codeRoots
        self.runningBundleIDs = runningBundleIDs
        self.hasFullDiskAccess = hasFullDiskAccess
        self.apps = apps
        self.homeIndex = homeIndex
    }

    /// An installed app by bundle ID, wherever it lives (e.g. Xcode-beta.app, ~/Applications).
    public func app(_ bundleID: String) -> InstalledApp? {
        apps.first { $0.bundleID == bundleID }
    }

    public func path(_ p: String) -> String {
        p.hasPrefix("~") ? home + p.dropFirst() : p
    }

    /// Projects are searched for across the whole home folder (minus ~/Library and hidden folders).
    public static let defaultCodeRoots = ["~"]
}

public protocol CleanupRule: Sendable {
    var name: String { get }
    /// Runs during Quick Scan (fast, and only produces zero-risk findings worth cleaning).
    var isQuick: Bool { get }
    func evaluate(_ ctx: RuleContext) async -> [Finding]
}

extension CleanupRule {
    public var isQuick: Bool { false }
}

enum RuleKit {
    static let minimumFindingBytes: Int64 = 50_000_000

    static func days(since date: Date?) -> Int? {
        date.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 }
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func relativeAge(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: .now)
    }

    static func ageNote(_ path: String) -> String? {
        guard let days = DiskMeasure.daysSinceModified(path) else { return nil }
        if days < 1 { return "modified today" }
        if days < 60 { return "modified \(days) days ago" }
        return "modified \(days / 30) months ago"
    }

    /// Items for each child folder of `path` at least `minBytes` in size.
    static func childItems(of path: String, minBytes: Int64, selected: Bool = true,
                           note: (String) -> String? = { ageNote($0) }) async -> [FindingItem] {
        await DiskMeasure.children(of: path, minBytes: minBytes).map {
            FindingItem(path: $0.path, bytes: $0.bytes, note: note($0.path), selectedByDefault: selected)
        }
    }

    static func total(_ items: [FindingItem]) -> Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }

    static func processes(_ files: [OpenFile]) -> String {
        Array(Set(files.map(\.process))).sorted().prefix(3).joined(separator: ", ")
    }

    static func bundleID(ofApp path: String) -> String? {
        Bundle(path: path)?.bundleIdentifier
    }

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// All rules, in the order findings are shown within a tier.
public enum RuleCatalog {
    public static let all: [CleanupRule] = [
        SimulatorRuntimesRule(), SimulatorDevicesRule(), XcodeDataRule(),
        DockerRule(), NodeModulesRule(), AppCachesRule(), NpmCacheRule(), ToolCachesRule(),
        AndroidSdkRule(), EditorLeftoversRule(), HomebrewRule(), DownloadsRule(),
        PackageCachesRule(), PackageToolCommandsRule(), InstallersRule(), MailDownloadsRule(), LargeFilesRule(),
        LogsRule(), UnusedAppsRule(), TrashAndTempRule(), DeviceBackupsRule(), AppManagedDataRule(),
    ]
}
#endif
