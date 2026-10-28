#if os(macOS)
import Foundation

/// Third-party folders in ~/Library/Caches. Apple's caches and anything with open files are left alone.
struct AppCachesRule: CleanupRule {
    let name = "App caches"
    var isQuick: Bool { true }

    /// Handled by a dedicated rule or owned by the system.
    static let excluded: Set<String> = ["Homebrew", "CloudKit", "FamilyCircle", "GeoServices", "Metadata",
                                        "SiriTTS", "PassKit", "Microsoft Edge", "org.swift.swiftpm"]

    /// Removing these means running a command before the tool works again, so Quick Clean skips them.
    static let needsReinstall: [String: String] = [
        "Cypress": "Run `npx cypress install` before your next Cypress test run.",
        "ms-playwright": "Run `npx playwright install` before your next Playwright test run.",
        "ms-playwright-go": "Playwright for Go downloads its browsers again on the next run.",
    ]

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let caches = ctx.path("~/Library/Caches")
        let candidates = await DiskMeasure.children(of: caches, minBytes: 100_000_000).filter {
            let name = ($0.path as NSString).lastPathComponent
            return !name.hasPrefix("com.apple.") && !Self.excluded.contains(name)
        }

        var items: [FindingItem] = []
        var skipped: [String] = []
        await withTaskGroup(of: ([FindingItem], [String]).self) { group in
            for c in candidates {
                group.addTask { await Self.evaluate(folder: c.path, bytes: c.bytes, apps: ctx.apps) }
            }
            for await (i, s) in group {
                items += i
                skipped += s
            }
        }
        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        items.sort { $0.bytes > $1.bytes }

        let notes = items.compactMap { item in Self.needsReinstall.first { item.path.hasSuffix("/\($0.key)") }?.value }
        var facts = [Fact("Owners", "\(Set(items.compactMap(\.usedBy)).count) apps and tools"),
                     Fact("Rebuilt by", "each app, automatically, as it needs them", .good),
                     Fact("Apple caches", "never touched", .good)]
        if !skipped.isEmpty { facts.append(Fact("Skipped (open now)", skipped.sorted().joined(separator: "; "), .warning)) }
        return [Finding(
            id: "app-caches", title: "App caches",
            detail: "Temporary data apps keep to load faster. Apps rebuild it as needed.",
            tier: .safe, bytes: RuleKit.total(items), items: items, action: .trash,
            kept: skipped.isEmpty ? nil : "anything open right now",
            afterNote: notes.isEmpty ? nil : Array(Set(notes)).sorted().joined(separator: " "),
            revealPath: caches, symbol: "archivebox", facts: facts,
            risk: "Apps may open a little slower the first time while they rebuild their cache.",
            quickClean: true)]
    }

    /// A folder with open files is split one level down so the idle parts can still be cleaned.
    static func evaluate(folder: String, bytes: Int64, apps: [InstalledApp]) async -> ([FindingItem], [String]) {
        let name = (folder as NSString).lastPathComponent
        let owner = AppIndex.owner(ofFolder: name, apps: apps)
        let lastUsed = owner?.lastUsed ?? RuleKit.modified(folder)
        let quickSafe = needsReinstall[name] == nil
        guard let open = await DiskMeasure.openFiles(under: folder, timeout: 20) else {
            return ([FindingItem(path: folder, bytes: bytes, note: "couldn't check whether it's in use", selectedByDefault: false,
                                 lastUsed: lastUsed, usedBy: owner?.owner, quickSafe: false)], [])
        }
        if open.isEmpty {
            return ([FindingItem(path: folder, bytes: bytes, note: needsReinstall[name] != nil ? "needs a re-install command afterwards" : nil,
                                 lastUsed: lastUsed, usedBy: owner?.owner ?? name, quickSafe: quickSafe)], [])
        }

        var items: [FindingItem] = []
        var skipped: [String] = []
        for child in await DiskMeasure.children(of: folder, minBytes: 50_000_000) {
            let childName = (child.path as NSString).lastPathComponent
            let childOpen = open.filter { $0.path.hasPrefix(child.path + "/") || $0.path == child.path }
            if childOpen.isEmpty {
                let childOwner = AppIndex.owner(ofFolder: childName, apps: apps)
                items.append(FindingItem(path: child.path, bytes: child.bytes,
                                         note: "rest of \(name) is in use by \(RuleKit.processes(open))",
                                         lastUsed: RuleKit.modified(child.path),
                                         usedBy: childOwner?.owner ?? "\(owner?.owner ?? name) (\(childName))", quickSafe: quickSafe))
            } else {
                skipped.append("\(name)/\(childName) (\(RuleKit.processes(childOpen)))")
            }
        }
        if items.isEmpty && skipped.isEmpty { skipped.append("\(name) (\(RuleKit.processes(open)))") }
        return (items, skipped)
    }
}

/// npm's download cache and npx package folders that no running tool is using.
struct NpmCacheRule: CleanupRule {
    let name = "npm cache"
    var isQuick: Bool { true }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let npm = ctx.path("~/.npm")
        guard DiskMeasure.exists(npm) else { return [] }
        var items: [FindingItem] = []
        if let bytes = await DiskMeasure.size(of: npm + "/_cacache"), bytes > 10_000_000 {
            items.append(FindingItem(path: npm + "/_cacache", bytes: bytes, note: "packages npm downloaded before",
                                     lastUsed: RuleKit.modified(npm + "/_cacache"), usedBy: "npm"))
        }

        let npx = npm + "/_npx"
        let open = await DiskMeasure.openFiles(under: npx, timeout: 30)
        let inUse = Set((open ?? []).compactMap { file -> String? in
            guard file.path.hasPrefix(npx + "/") else { return nil }
            return file.path.dropFirst(npx.count + 1).split(separator: "/").first.map(String.init)
        })
        var keptCount = 0
        if open != nil {
            for child in await DiskMeasure.children(of: npx, minBytes: 1_000_000) {
                let name = (child.path as NSString).lastPathComponent
                if inUse.contains(name) { keptCount += 1; continue }
                let used = RuleKit.modified(child.path)
                let recent = (RuleKit.days(since: used) ?? 99) < 1
                items.append(FindingItem(path: child.path, bytes: child.bytes, note: recent ? "used today, so Quick Clean skips it" : "not running now",
                                         lastUsed: used, usedBy: npxLabel(child.path), quickSafe: !recent))
            }
        }

        let yarn = ctx.path("~/.yarn/berry/cache")
        if let bytes = await DiskMeasure.size(of: yarn), bytes > 100_000_000 {
            items.append(FindingItem(path: yarn, bytes: bytes, note: "Yarn (Berry) download cache",
                                     lastUsed: RuleKit.modified(yarn), usedBy: "Yarn"))
        }

        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        return [Finding(
            id: "npm-cache", title: "npm and npx cache",
            detail: "Packages npm and npx downloaded before. They're fetched again the next time a project needs them.",
            tier: .safe, bytes: RuleKit.total(items), items: items.sorted { $0.bytes > $1.bytes }, action: .trash,
            kept: keptCount > 0 ? "\(keptCount) npx package(s) used by running tools" : nil,
            revealPath: npm, symbol: "shippingbox",
            facts: [Fact("Rebuilt by", "npm / npx, on the next install", .good),
                    Fact("Running tools", keptCount > 0 ? "\(keptCount) npx package(s) kept" : "none affected", .good),
                    Fact("Cost", "the next install downloads packages again")],
            quickClean: true)]
    }

    /// Names an npx cache folder after the package it holds.
    private func npxLabel(_ path: String) -> String {
        guard let pkg = RuleKit.readJSON(path + "/package.json"),
              let deps = pkg["dependencies"] as? [String: Any], !deps.isEmpty else { return "npx" }
        return "npx " + deps.keys.sorted().prefix(2).joined(separator: ", ")
    }
}

/// ~/.cache: test-browser downloads, leftover installer staging, and other tool caches.
struct ToolCachesRule: CleanupRule {
    let name = "Tool caches"
    var isQuick: Bool { true }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let cache = ctx.path("~/.cache")
        guard DiskMeasure.exists(cache) else { return [] }
        var findings: [Finding] = []

        var browsers: [FindingItem] = []
        var browsersInUse: [String] = []
        for (name, tool) in [("puppeteer", "Puppeteer"), ("ms-playwright", "Playwright")] {
            let p = "\(cache)/\(name)"
            guard let bytes = await DiskMeasure.size(of: p), bytes > 10_000_000 else { continue }
            let open = await DiskMeasure.openFiles(under: p, timeout: 20)
            if let open, !open.isEmpty { browsersInUse.append("\(name) (\(RuleKit.processes(open)))"); continue }
            browsers.append(FindingItem(path: p, bytes: bytes, note: "browser builds", selectedByDefault: open != nil,
                                        lastUsed: RuleKit.modified(p), usedBy: tool, quickSafe: false))
        }
        if RuleKit.total(browsers) >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "test-browsers", title: "Browser downloads for test tools",
                detail: "Chrome and Firefox builds that Puppeteer and Playwright downloaded for automated tests.",
                tier: .safe, bytes: RuleKit.total(browsers), items: browsers, action: .trash,
                kept: browsersInUse.isEmpty ? nil : "anything running right now",
                afterNote: "Run `npx playwright install` if Playwright asks for its browsers.", revealPath: cache,
                symbol: "globe",
                facts: [Fact("Rebuilt by", "Puppeteer automatically, Playwright via `npx playwright install`"),
                        Fact("In use now", browsersInUse.isEmpty ? "no" : browsersInUse.joined(separator: "; "), browsersInUse.isEmpty ? .good : .warning)]))
        }

        let codex = "\(cache)/codex-runtimes"
        var staging: [FindingItem] = []
        for p in DiskMeasure.listDirectory(codex) where (p as NSString).lastPathComponent.hasPrefix("codex-runtime-install-") {
            guard let open = await DiskMeasure.openFiles(under: p, timeout: 15), open.isEmpty,
                  let bytes = await DiskMeasure.size(of: p) else { continue }
            staging.append(FindingItem(path: p, bytes: bytes, note: RuleKit.ageNote(p), lastUsed: RuleKit.modified(p), usedBy: "Codex installer"))
        }
        if RuleKit.total(staging) >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "codex-staging", title: "Codex leftover install folders",
                detail: "Staging folders left behind by interrupted Codex runtime installs.",
                tier: .safe, bytes: RuleKit.total(staging), items: staging, action: .trash,
                kept: "codex-primary-runtime (the active runtime)", revealPath: codex, symbol: "terminal",
                facts: [Fact("Used by", "nothing: installs that never finished", .good)],
                quickClean: true))
        }

        let handled: Set<String> = ["puppeteer", "ms-playwright", "codex-runtimes", "pip"]
        let others = await DiskMeasure.children(of: cache, minBytes: 500_000_000).filter {
            !handled.contains(($0.path as NSString).lastPathComponent)
        }.map { child -> FindingItem in
            let name = (child.path as NSString).lastPathComponent
            let note = name == "huggingface" ? "downloaded AI models, re-downloaded when a project needs them"
                                             : "may include history or settings. Check before removing"
            return FindingItem(path: child.path, bytes: child.bytes, note: note, selectedByDefault: false,
                               lastUsed: RuleKit.modified(child.path), usedBy: name, quickSafe: false)
        }
        if RuleKit.total(others) >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "other-tool-caches", title: "Other tool caches",
                detail: "Large folders in ~/.cache owned by individual tools. Usually re-creatable, but some keep history you may want.",
                tier: .review, bytes: RuleKit.total(others), items: others, action: .trash, revealPath: cache,
                symbol: "tray.full",
                facts: [Fact("Preselected", "nothing: pick what you recognise")],
                risk: "A tool may lose its history or need to download models again."))
        }
        return findings
    }
}

/// Diagnostic logs in ~/Library/Logs. Nothing reads them except you and crash reporters.
struct LogsRule: CleanupRule {
    let name = "Logs"
    var isQuick: Bool { true }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let logs = ctx.path("~/Library/Logs")
        let open = await DiskMeasure.openFiles(under: logs, timeout: 20) ?? []
        let items = await DiskMeasure.children(of: logs, minBytes: 5_000_000).compactMap { child -> FindingItem? in
            let name = (child.path as NSString).lastPathComponent
            if open.contains(where: { $0.path.hasPrefix(child.path + "/") || $0.path == child.path }) { return nil }
            let owner = AppIndex.owner(ofFolder: name, apps: ctx.apps)?.owner ?? name
            return FindingItem(path: child.path, bytes: child.bytes, note: RuleKit.ageNote(child.path),
                               lastUsed: RuleKit.modified(child.path), usedBy: owner)
        }
        guard RuleKit.total(items) >= 20_000_000 else { return [] }
        return [Finding(
            id: "logs", title: "Old logs",
            detail: "Diagnostic logs written by apps and macOS. Nothing needs them to run.",
            tier: .safe, bytes: RuleKit.total(items), items: items, action: .trash,
            kept: "logs being written right now", revealPath: logs, symbol: "doc.text.magnifyingglass",
            facts: [Fact("Used by", "only for troubleshooting", .good),
                    Fact("Rebuilt by", "apps, as they log new events")],
            quickClean: true)]
    }
}
#endif
