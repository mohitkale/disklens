#if os(macOS)
import Foundation

/// Where the space goes. Paths are measured once; `subtract` removes overlap with another category.
struct CategorySpec: Sendable {
    let name: String
    let paths: [String]
    var subtract: [String] = []

    static let all: [CategorySpec] = [
        CategorySpec(name: "Xcode & Simulators", paths: [
            "~/Library/Developer", "/Library/Developer/CoreSimulator",
            "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime",
            "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_watchOSSimulatorRuntime",
            "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_appleTVOSSimulatorRuntime",
            "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_xrOSSimulatorRuntime",
        ]),
        CategorySpec(name: "Caches & temp", paths: ["~/Library/Caches", "~/.cache", "~/.npm", "/private/var/folders"]),
        CategorySpec(name: "Docker", paths: ["~/Library/Containers/com.docker.docker"]),
        CategorySpec(name: "Documents", paths: ["~/Documents"]),
        CategorySpec(name: "Desktop & Downloads", paths: ["~/Desktop", "~/Downloads"]),
        CategorySpec(name: "Photos & media", paths: ["~/Pictures", "~/Movies", "~/Music"]),
        CategorySpec(name: "Applications", paths: ["/Applications"]),
        CategorySpec(name: "Android SDK", paths: ["~/Library/Android"]),
        CategorySpec(name: "App data", paths: ["~/Library/Application Support", "~/Library/Containers", "~/Library/Group Containers"],
                     subtract: ["~/Library/Containers/com.docker.docker", "~/Library/Containers/com.apple.mail"]),
        CategorySpec(name: "Mail & Messages", paths: ["~/Library/Mail", "~/Library/Messages", "~/Library/Containers/com.apple.mail"]),
        CategorySpec(name: "iCloud Drive", paths: ["~/Library/Mobile Documents"]),
        CategorySpec(name: "Developer tools", paths: [
            "~/.nvm", "~/.gradle", "~/.m2", "~/.cargo", "~/.rustup", "~/.vscode", "~/.cursor", "~/.expo", "~/.android",
            "~/.cocoapods", "~/.pub-cache", "~/.dotnet", "~/.nuget", "~/.local", "~/.codex", "~/.codeium", "~/.bun",
            "~/.yarn", "~/.gem", "~/.pyenv", "/usr/local", "/opt/homebrew", "/Library/Developer/CommandLineTools",
        ]),
    ]
}

public struct ScanResult: Sendable {
    public let snapshot: Snapshot
    public let findings: [Finding]
    public let hasFullDiskAccess: Bool
    /// Quick rules that found something on this Mac. Quick Scan looks there first.
    public let profile: [String]
}

public struct QuickScanResult: Sendable {
    public let date: Date
    public let duration: Double
    public let free: Int64
    /// Zero-risk findings, with items narrowed to those Quick Clean may touch.
    public let findings: [Finding]
    /// Informational findings shown alongside (restart for temp files, empty the Trash).
    public let advice: [Finding]
}

public enum Scanner {
    public static func scan(codeRoots: [String], runningBundleIDs: Set<String>,
                            progress: @escaping @Sendable (String) -> Void) async -> ScanResult {
        let started = Date()
        let hasFDA = DiskMeasure.hasFullDiskAccess()
        progress("Indexing apps")
        let apps = AppIndex.installedApps()
        let base = RuleContext(codeRoots: codeRoots, runningBundleIDs: runningBundleIDs, hasFullDiskAccess: hasFDA, apps: apps)
        progress("Reading the drive")
        let container = await DiskMeasure.containerInfo()

        // Everything is discovered fresh: nothing from earlier scans is reused.
        async let total = DiskMeasure.size(of: DiskMeasure.dataVolume, timeout: 1800)
        async let categorySizes = measureCategories(base, progress: progress)
        async let trash: Int64? = hasFDA ? DiskMeasure.size(of: base.path("~/.Trash")) : nil
        progress("Looking through your home folder")
        let index = await HomeIndex.build(home: base.home)
        let ctx = RuleContext(codeRoots: codeRoots, runningBundleIDs: runningBundleIDs, hasFullDiskAccess: hasFDA,
                              apps: apps, homeIndex: index)
        let (allFindings, active) = await evaluateRulesTracked(RuleCatalog.all, ctx, progress: progress)

        var categories = await categorySizes
        let trashBytes = await trash
        let categorized = categories.reduce(0) { $0 + $1.bytes }
        progress("Measuring the whole Data volume")
        let measured = await total ?? categorized
        let other = max(0, measured - categorized - (trashBytes ?? 0))
        categories.append(CategoryUsage(name: "Other", bytes: other, paths: [DiskMeasure.dataVolume]))
        if let trashBytes, trashBytes > 0 {
            categories.append(CategoryUsage(name: "Trash", bytes: trashBytes, paths: [ctx.path("~/.Trash")]))
        }

        let capacity = container?.capacity ?? 0
        let free = container?.free ?? DiskMeasure.freeBytes()
        let snapshot = Snapshot(
            date: .now, capacity: capacity, free: free, system: container?.systemUsed ?? 0,
            hidden: max(0, (container?.dataUsed ?? measured) - measured), measured: measured,
            trash: trashBytes, categories: categories.sorted { $0.bytes > $1.bytes },
            duration: Date().timeIntervalSince(started))

        let sorted = allFindings.sorted { a, b in a.tier != b.tier ? a.tier < b.tier : a.bytes > b.bytes }
        return ScanResult(snapshot: snapshot, findings: sorted, hasFullDiskAccess: hasFDA,
                          profile: RuleCatalog.all.filter { $0.isQuick && active.contains($0.name) }.map(\.name))
    }

    static func measureCategories(_ ctx: RuleContext, progress: @escaping @Sendable (String) -> Void) async -> [CategoryUsage] {
        let specs = CategorySpec.all
        let paths = Array(Set(specs.flatMap { ($0.paths + $0.subtract).map(ctx.path) }))
        progress("Measuring \(paths.count) folders")
        let sizes = await DiskMeasure.sizes(of: paths, concurrency: 6)
        return specs.compactMap { spec in
            let added = spec.paths.map(ctx.path).reduce(0) { $0 + (sizes[$1] ?? 0) }
            let removed = spec.subtract.map(ctx.path).reduce(0) { $0 + (sizes[$1] ?? 0) }
            let paths = spec.paths.map(ctx.path).filter { sizes[$0] != nil }.sorted { sizes[$0]! > sizes[$1]! }
            // Unreadable or empty (e.g. Mail without Full Disk Access): leave it out rather than show 0 B.
            guard added - removed > 0 else { return nil }
            return CategoryUsage(name: spec.name, bytes: max(0, added - removed), paths: paths,
                                 pathBytes: Dictionary(uniqueKeysWithValues: paths.map { ($0, sizes[$0]!) }))
        }
    }

    /// Fast pass over the zero-risk rules only: no whole-drive measurement, no project search.
    /// `profile` lists the quick rules that found something in the last full scan. With no profile, every quick rule runs.
    public static func quickScan(runningBundleIDs: Set<String>, profile: [String]? = nil,
                                 progress: @escaping @Sendable (String) -> Void) async -> QuickScanResult {
        let started = Date()
        progress("Indexing apps")
        let ctx = RuleContext(codeRoots: [], runningBundleIDs: runningBundleIDs,
                              hasFullDiskAccess: DiskMeasure.hasFullDiskAccess(), apps: AppIndex.installedApps())
        // Caches, logs and temp files change constantly, so they're always checked.
        let always: Set<String> = ["App caches", "Logs", "Trash and temp"]
        let rules = RuleCatalog.all.filter { $0.isQuick && (profile == nil || profile!.contains($0.name) || always.contains($0.name)) }
        let all = await evaluateRules(rules, ctx, progress: progress)
        let cleanable = all.compactMap { f -> Finding? in
            guard f.quickClean, f.action.isExecutable else { return nil }
            guard f.action == .trash else { return f }
            let items = f.items.filter(\.quickSafe)
            guard !items.isEmpty else { return nil }
            return Finding(id: f.id, title: f.title, detail: f.detail, tier: f.tier, bytes: items.reduce(0) { $0 + $1.bytes },
                           items: items, action: f.action, kept: f.kept, quitApps: f.quitApps, afterNote: nil,
                           revealPath: f.revealPath, symbol: f.symbol, facts: f.facts, risk: f.risk, quickClean: true)
        }
        let advice = all.filter { $0.tier == .safe && !$0.action.isExecutable }
        return QuickScanResult(date: started, duration: Date().timeIntervalSince(started), free: DiskMeasure.freeBytes(),
                               findings: cleanable.sorted { $0.bytes > $1.bytes }, advice: advice)
    }

    static func evaluateRules(_ catalog: [CleanupRule], _ ctx: RuleContext,
                              progress: @escaping @Sendable (String) -> Void) async -> [Finding] {
        await evaluateRulesTracked(catalog, ctx, progress: progress).0
    }

    /// Runs rules four at a time; also reports which rules produced findings.
    static func evaluateRulesTracked(_ catalog: [CleanupRule], _ ctx: RuleContext,
                                     progress: @escaping @Sendable (String) -> Void) async -> ([Finding], Set<String>) {
        var active = Set<String>()
        var findings: [Finding] = []
        await withTaskGroup(of: (String, [Finding]).self) { group in
            var rules = catalog.makeIterator()
            func next() -> Bool {
                guard let rule = rules.next() else { return false }
                group.addTask {
                    progress("Checking \(rule.name)")
                    return (rule.name, await rule.evaluate(ctx))
                }
                return true
            }
            for _ in 0..<4 { _ = next() }
            while let (name, result) = await group.next() {
                findings += result
                if !result.isEmpty { active.insert(name) }
                _ = next()
            }
        }
        return (findings, active)
    }
}
#endif
