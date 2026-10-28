#if os(macOS)
import Foundation

/// Download caches of common package managers and build tools. Each only appears if it exists.
struct PackageCachesRule: CleanupRule {
    let name = "Package caches"

    private struct Source {
        let path: String
        let tool: String
        let note: String
        let safe: Bool
    }

    private static let sources: [Source] = [
        Source(path: "~/.gradle/caches", tool: "Gradle", note: "downloaded dependencies and build cache", safe: true),
        Source(path: "~/.cargo/registry", tool: "Cargo (Rust)", note: "downloaded crates", safe: true),
        Source(path: "~/.bun/install/cache", tool: "Bun", note: "downloaded packages", safe: true),
        Source(path: "~/.android/cache", tool: "Android tools", note: "SDK manager cache", safe: true),
        Source(path: "~/.cache/pip", tool: "pip", note: "downloaded wheels", safe: true),
        Source(path: "~/.deno", tool: "Deno", note: "module cache", safe: true),
        Source(path: "~/.m2/repository", tool: "Maven", note: "local repository: builds re-download what they need", safe: false),
        Source(path: "~/.nuget/packages", tool: "NuGet (.NET)", note: "package folder: builds re-download what they need", safe: false),
        Source(path: "~/.pub-cache", tool: "Dart / Flutter", note: "package cache, plus globally activated tools", safe: false),
        Source(path: "~/.cocoapods/repos", tool: "CocoaPods", note: "spec repositories (CocoaPods uses the CDN now)", safe: false),
        Source(path: "~/.swiftpm/cache", tool: "Swift Package Manager", note: "package cache", safe: true),
        Source(path: "~/Library/Caches/org.swift.swiftpm", tool: "Swift Package Manager", note: "package cache", safe: true),
    ]

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        var safe: [FindingItem] = [], review: [FindingItem] = []
        for s in Self.sources {
            let p = ctx.path(s.path)
            guard let bytes = await DiskMeasure.size(of: p), bytes >= 50_000_000 else { continue }
            if let open = await DiskMeasure.openFiles(under: p), !open.isEmpty { continue }
            let item = FindingItem(path: p, bytes: bytes, note: s.note, selectedByDefault: s.safe,
                                   lastUsed: RuleKit.modified(p), usedBy: s.tool, quickSafe: false)
            if s.safe { safe.append(item) } else { review.append(item) }
        }
        // Old Gradle distributions: keep the two most recently used.
        let dists = DiskMeasure.listDirectory(ctx.path("~/.gradle/wrapper/dists")).filter(DiskMeasure.isDirectory)
            .sorted { (RuleKit.modified($0) ?? .distantPast) > (RuleKit.modified($1) ?? .distantPast) }
        for old in dists.dropFirst(2) {
            if let bytes = await DiskMeasure.size(of: old), bytes > 10_000_000 {
                safe.append(FindingItem(path: old, bytes: bytes, note: "older Gradle version (2 newest kept)",
                                        lastUsed: RuleKit.modified(old), usedBy: "Gradle wrapper", quickSafe: false))
            }
        }

        var findings: [Finding] = []
        if RuleKit.total(safe) >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "package-caches", title: "Package manager caches",
                detail: "Downloads kept by build tools and package managers. They fetch what they need again on the next build.",
                tier: .safe, bytes: RuleKit.total(safe), items: safe.sorted { $0.bytes > $1.bytes }, action: .trash,
                quitApps: ["com.google.android.studio"], revealPath: ctx.home, symbol: "shippingbox.circle",
                facts: [Fact("Tools", Set(safe.compactMap(\.usedBy)).sorted().joined(separator: ", ")),
                        Fact("Rebuilt by", "each tool, on the next build or install"),
                        Fact("Cost", "the next build downloads again (needs internet)")],
                risk: "The next build of each project is slower and needs internet."))
        }
        if RuleKit.total(review) >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "package-repos", title: "Package repositories",
                detail: "Local package stores that builds read from directly. Usually re-downloadable, but offline builds would fail.",
                tier: .review, bytes: RuleKit.total(review), items: review.sorted { $0.bytes > $1.bytes }, action: .trash,
                revealPath: ctx.home, symbol: "books.vertical",
                facts: [Fact("Tools", Set(review.compactMap(\.usedBy)).sorted().joined(separator: ", ")),
                        Fact("Preselected", "nothing")],
                risk: "Builds need internet to fetch packages again. Globally installed tools (e.g. `dart pub global`) may need reinstalling."))
        }
        return findings
    }
}

/// Caches that should be cleaned with the tool's own command (Go, pnpm, conda).
struct PackageToolCommandsRule: CleanupRule {
    let name = "Package tools"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        var findings: [Finding] = []
        if let go = Tools.find("go"), let bytes = await DiskMeasure.size(of: ctx.path("~/go/pkg/mod")), bytes >= 200_000_000 {
            findings.append(Finding(
                id: "go-modcache", title: "Go module cache",
                detail: "Every Go module version downloaded by your builds.",
                tier: .safe, bytes: bytes, action: .command(tool: go, args: ["clean", "-modcache"]),
                revealPath: ctx.path("~/go/pkg"), symbol: "chevron.left.forwardslash.chevron.right",
                facts: [Fact("Rebuilt by", "`go build` / `go mod download`"), Fact("Run by", "Go's own clean command")],
                risk: "The next Go build downloads its modules again."))
        }
        if let pnpm = Tools.find("pnpm") {
            let store = ctx.path("~/Library/pnpm/store")
            if let bytes = await DiskMeasure.size(of: store), bytes >= 200_000_000 {
                findings.append(Finding(
                    id: "pnpm-store", title: "pnpm store (unused packages)",
                    detail: "pnpm keeps every package version in one store. Pruning removes versions no project references.",
                    tier: .safe, bytes: bytes / 3, action: .command(tool: pnpm, args: ["store", "prune"]),
                    revealPath: store, symbol: "shippingbox",
                    facts: [Fact("Store size", ByteFormat.string(bytes)), Fact("Estimate", "pruning usually frees a third or more"),
                            Fact("Run by", "`pnpm store prune`")]))
            }
        }
        for base in ["~/miniconda3", "~/anaconda3", "~/miniforge3", "~/mambaforge", "/opt/homebrew/Caskroom/miniconda/base", "/usr/local/Caskroom/miniconda/base"] {
            let root = ctx.path(base)
            let conda = root + "/bin/conda"
            guard FileManager.default.isExecutableFile(atPath: conda),
                  let bytes = await DiskMeasure.size(of: root + "/pkgs"), bytes >= 300_000_000 else { continue }
            findings.append(Finding(
                id: "conda-\(base)", title: "Conda package cache",
                detail: "Downloaded package archives and unused packages in \((root as NSString).lastPathComponent). Environments are not affected.",
                tier: .safe, bytes: bytes, action: .command(tool: conda, args: ["clean", "--all", "--yes"]),
                revealPath: root + "/pkgs", symbol: "flask",
                facts: [Fact("Run by", "`conda clean --all`"), Fact("Environments", "not affected", .good)]))
        }
        return findings
    }
}

/// iPhone/iPad firmware downloads and macOS installers: always re-downloadable.
struct InstallersRule: CleanupRule {
    let name = "Installers"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        var items: [FindingItem] = []
        for dir in ["~/Library/iTunes/iPhone Software Updates", "~/Library/iTunes/iPad Software Updates", "~/Library/iTunes/iPod Software Updates"] {
            for file in DiskMeasure.listDirectory(ctx.path(dir)) where file.hasSuffix(".ipsw") {
                if let bytes = await DiskMeasure.size(of: file) {
                    items.append(FindingItem(path: file, bytes: bytes, note: "firmware download", lastUsed: RuleKit.modified(file), usedBy: "Finder device restore"))
                }
            }
        }
        for app in ctx.apps where (app.path as NSString).lastPathComponent.hasPrefix("Install macOS") {
            guard !app.isManaged, let bytes = await DiskMeasure.size(of: app.path) else { continue }
            items.append(FindingItem(path: app.path, bytes: bytes, note: "macOS installer \(app.version ?? "")",
                                     lastUsed: app.lastUsed ?? RuleKit.modified(app.path), usedBy: "macOS upgrade", quickSafe: false))
        }
        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        return [Finding(
            id: "installers", title: "Firmware files and macOS installers",
            detail: "iPhone/iPad firmware that Finder downloaded for updates or restores, and full macOS installers. Both can be downloaded again.",
            tier: .safe, bytes: RuleKit.total(items), items: items, action: .trash, revealPath: ctx.path("~/Library/iTunes"),
            symbol: "arrow.down.app",
            facts: [Fact("Get it back", "Finder or Software Update downloads them again when needed")])]
    }
}

/// Attachments Mail saved when you opened them (needs Full Disk Access).
struct MailDownloadsRule: CleanupRule {
    let name = "Mail downloads"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        guard ctx.hasFullDiskAccess else { return [] }
        let dir = ctx.path("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        guard let bytes = await DiskMeasure.size(of: dir), bytes >= RuleKit.minimumFindingBytes else { return [] }
        let items = await RuleKit.childItems(of: dir, minBytes: 1_000_000)
        return [Finding(
            id: "mail-downloads", title: "Mail attachment downloads",
            detail: "Copies of attachments Mail saved when you opened or previewed them. The originals stay in your messages.",
            tier: .safe, bytes: bytes, items: items, action: .trash, quitApps: ["com.apple.mail"], revealPath: dir,
            symbol: "paperclip",
            facts: [Fact("Originals", "stay in Mail", .good), Fact("Rebuilt by", "Mail, when you open an attachment again")],
            quickClean: true)]
    }
}

/// Individual files over 1 GB in your home folder, so nothing big goes unnoticed.
struct LargeFilesRule: CleanupRule {
    let name = "Large files"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        guard let index = ctx.homeIndex, !index.largeFiles.isEmpty else { return [] }
        let items = index.largeFiles.compactMap { path -> FindingItem? in
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .localizedTypeDescriptionKey, .contentModificationDateKey]),
                  let size = values.totalFileAllocatedSize else { return nil }
            let opened = AppIndex.lastUsed(path)
            let source = AppIndex.downloadSource(path)
            let folder = ((path as NSString).deletingLastPathComponent).replacingOccurrences(of: ctx.home, with: "~")
            return FindingItem(path: path, bytes: Int64(size),
                               note: [values.localizedTypeDescription, "in \(folder)", source.map { "from \($0)" }].compactMap { $0 }.joined(separator: " · "),
                               selectedByDefault: false, lastUsed: opened ?? values.contentModificationDate,
                               usedBy: opened == nil ? "never opened" : "you", quickSafe: false)
        }.sorted { $0.bytes > $1.bytes }
        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        let stale = items.filter { (RuleKit.days(since: $0.lastUsed) ?? 0) > 180 }
        return [Finding(
            id: "large-files", title: "Large files (over 1 GB)",
            detail: "The biggest individual files in your home folder: videos, disk images, archives, virtual machines and so on.",
            tier: .review, bytes: RuleKit.total(items), items: Array(items.prefix(50)), action: .trash, revealPath: ctx.home,
            symbol: "doc.zipper",
            facts: [Fact("Files", "\(items.count)"),
                    Fact("Not opened in 6+ months", "\(stale.count) · \(ByteFormat.string(RuleKit.total(stale)))"),
                    Fact("Preselected", "nothing: these are your files")],
            risk: "These are your own files. Move to an external drive if you're unsure.")]
    }
}
#endif
