#if os(macOS)
import Foundation

/// Docker Desktop's VM disk. Cleaned through the docker CLI so Docker stays consistent.
struct DockerRule: CleanupRule {
    let name = "Docker"
    var isQuick: Bool { true }
    static let bundleID = "com.docker.docker"

    struct DfRow: Decodable {
        let type: String
        let reclaimable: String
        let size: String
        enum CodingKeys: String, CodingKey { case type = "Type", reclaimable = "Reclaimable", size = "Size" }
    }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let disk = ctx.path("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        guard let docker = Tools.find("docker") else { return [] }
        let diskBytes = await DiskMeasure.size(of: disk) ?? 0
        let info = await Shell.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 10)
        let lastOpened = ctx.app(Self.bundleID)?.lastUsed

        guard info.ok else {
            guard diskBytes >= 1_000_000_000 else { return [] }
            return [Finding(
                id: "docker-not-running", title: "Docker disk image",
                detail: "Docker keeps every image, container, volume and build cache in one file. Docker Desktop isn't running, so DiskLens can't see inside it. Start it and scan again.",
                tier: .review, bytes: diskBytes, action: .launchApp(bundleID: Self.bundleID),
                revealPath: (disk as NSString).deletingLastPathComponent, symbol: "cube.transparent",
                facts: [Fact("Docker Desktop", "not running", .warning),
                        Fact("Last opened", lastOpened.map(RuleKit.relativeAge) ?? "unknown"),
                        Fact("Disk image", ByteFormat.string(diskBytes)),
                        Fact("Tip", "If you don't use Docker any more, uninstalling Docker Desktop frees all of it")])]
        }

        let df = await Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 60)
        let rows = df.out.split(separator: "\n").compactMap { try? JSONDecoder().decode(DfRow.self, from: Data($0.utf8)) }
        func reclaimable(_ type: String) -> Int64 {
            rows.first { $0.type == type }.flatMap { ByteFormat.parse($0.reclaimable) } ?? 0
        }
        func lines(_ args: [String]) async -> [[String]] {
            await Shell.run(docker, args, timeout: 30).out.split(separator: "\n").map { $0.components(separatedBy: "|") }
        }
        let note = "Docker hands the space back to macOS within a minute or two."
        let common = [Fact("Docker Desktop", "running, \(ByteFormat.string(diskBytes)) disk image"),
                      Fact("Undo", "Not through the Trash: images can be pulled or rebuilt", .warning)]
        var findings: [Finding] = []

        let cache = reclaimable("Build Cache")
        if cache >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "docker-build-cache", title: "Docker build cache",
                detail: "Layers Docker saved to speed up `docker build`.",
                tier: .safe, bytes: cache, action: .command(tool: docker, args: ["builder", "prune", "-a", "-f"]),
                afterNote: note, symbol: "cube.transparent",
                facts: [Fact("Used by", "only to speed up rebuilds", .good), Fact("Cost", "the next build is slower")] + common,
                quickClean: true))
        }

        let stopped = await lines(["ps", "-a", "--filter", "status=exited", "--filter", "status=created",
                                   "--format", "{{.Names}}|{{.Image}}|{{.Status}}|{{.Label \"com.docker.compose.project\"}}"])
        if !stopped.isEmpty {
            let items = stopped.map { f in
                FindingItem(path: f[0], bytes: 0, note: "\(f[safe: 1] ?? "") · \(f[safe: 2] ?? "")",
                            usedBy: (f[safe: 3]).flatMap { $0.isEmpty ? nil : $0 } ?? "no compose project")
            }
            findings.append(Finding(
                id: "docker-containers", title: "Stopped Docker containers",
                detail: "Containers that aren't running. Removing them deletes anything written inside them, but not their volumes.",
                tier: .review, bytes: reclaimable("Containers"), items: items,
                action: .command(tool: docker, args: ["container", "prune", "-f"]), afterNote: note, symbol: "shippingbox",
                facts: [Fact("Projects", Set(items.compactMap(\.usedBy)).sorted().joined(separator: ", "))] + common,
                risk: "Data written inside these containers (not in volumes) is lost."))
        }

        let images = reclaimable("Images")
        if images >= RuleKit.minimumFindingBytes {
            let list = await lines(["images", "--filter", "dangling=false", "--format", "{{.Repository}}:{{.Tag}}|{{.Size}}|{{.CreatedSince}}"])
            let items = list.prefix(30).map { f in
                FindingItem(path: f[0], bytes: ByteFormat.parse(f[safe: 1] ?? "") ?? 0, note: "created \(f[safe: 2] ?? "?")")
            }
            findings.append(Finding(
                id: "docker-images", title: "Unused Docker images",
                detail: "Images that no container uses. Docker keeps images that containers still need. Remove stopped containers first to free the images they hold.",
                tier: .review, bytes: images, items: items,
                action: .command(tool: docker, args: ["image", "prune", "-a", "-f"]), afterNote: note, symbol: "square.stack.3d.up",
                facts: [Fact("Get it back", "`docker pull` or `docker build` (needs internet)")] + common,
                risk: "Images you need again must be pulled or rebuilt."))
        }

        let volumes = reclaimable("Local Volumes")
        if volumes >= RuleKit.minimumFindingBytes {
            let list = await lines(["volume", "ls", "-f", "dangling=true", "--format", "{{.Name}}|{{.Label \"com.docker.compose.project\"}}"])
            let items = list.map { f in
                FindingItem(path: f[0], bytes: 0, note: f[0].count == 64 ? "anonymous volume" : "named volume",
                            usedBy: (f[safe: 1]).flatMap { $0.isEmpty ? nil : $0 } ?? "no compose project")
            }
            findings.append(Finding(
                id: "docker-volumes", title: "Unused Docker volumes",
                detail: "Volumes no container uses. Volumes hold databases, uploads or downloaded models.",
                tier: .review, bytes: volumes, items: items,
                action: .command(tool: docker, args: ["volume", "prune", "-a", "-f"]), afterNote: note, symbol: "externaldrive",
                facts: [Fact("Projects", Set(items.compactMap(\.usedBy)).sorted().joined(separator: ", ")),
                        Fact("Undo", "Impossible: volume data is gone for good", .warning)],
                risk: "Volume data (databases, uploads, models) can't be recovered."))
        }
        return findings
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Old version caches left by VS Code-based editors (Cursor, VS Code, Windsurf, Antigravity).
struct EditorLeftoversRule: CleanupRule {
    let name = "Editor leftovers"
    var isQuick: Bool { true }

    /// VS Code-based editors: name, bundle ID, Application Support folder.
    static let editors: [(name: String, bundleID: String, support: String)] = [
        ("VS Code", "com.microsoft.VSCode", "~/Library/Application Support/Code"),
        ("VS Code Insiders", "com.microsoft.VSCodeInsiders", "~/Library/Application Support/Code - Insiders"),
        ("Cursor", "com.todesktop.230313mzl4w4u92", "~/Library/Application Support/Cursor"),
        ("Windsurf", "com.exafunction.windsurf", "~/Library/Application Support/Windsurf"),
        ("VSCodium", "com.vscodium", "~/Library/Application Support/VSCodium"),
        ("Antigravity", "com.google.antigravity", "~/Library/Application Support/Antigravity"),
        ("Trae", "com.trae.app", "~/Library/Application Support/Trae"),
    ]

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        var findings: [Finding] = []
        for editor in Self.editors {
            let support = ctx.path(editor.support)
            guard DiskMeasure.isDirectory(support), let app = ctx.app(editor.bundleID) else { continue }
            var items: [FindingItem] = []
            var kept: [String] = []

            // CachedData/<commit>: only the installed version's folder is used.
            let product = RuleKit.readJSON(app.path + "/Contents/Resources/app/product.json")
            if let commit = product?["commit"] as? String {
                for dir in DiskMeasure.listDirectory(support + "/CachedData") where DiskMeasure.isDirectory(dir) {
                    if (dir as NSString).lastPathComponent == commit { continue }
                    items.append(FindingItem(path: dir, bytes: await DiskMeasure.size(of: dir) ?? 0, note: "cache for an older version",
                                             lastUsed: RuleKit.modified(dir), usedBy: "older \(editor.name)"))
                }
                kept.append("the installed version's cache")
            }

            let backup = support + "/User/globalStorage/state.vscdb.backup"
            if let bytes = await DiskMeasure.size(of: backup), bytes > 50_000_000 {
                items.append(FindingItem(path: backup, bytes: bytes, note: "stale copy of the settings database",
                                         lastUsed: RuleKit.modified(backup), usedBy: "nothing (backup)"))
                kept.append("state.vscdb (your chats and settings)")
            }

            // Cursor's agent CLI keeps every downloaded version.
            if editor.name == "Cursor" {
                for local in [support + "/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local", ctx.path("~/.local")] {
                    let versions = local + "/share/cursor-agent/versions"
                    let all = DiskMeasure.listDirectory(versions).filter(DiskMeasure.isDirectory).map { ($0 as NSString).lastPathComponent }.sorted()
                    guard all.count > 1 else { continue }
                    let active = URL(fileURLWithPath: local + "/bin/cursor-agent").resolvingSymlinksInPath().path
                    let keep = Set([all.last!] + all.filter { active.contains("/versions/\($0)/") })
                    kept.append("cursor-agent " + keep.sorted().joined(separator: ", "))
                    for v in all where !keep.contains(v) {
                        let p = "\(versions)/\(v)"
                        items.append(FindingItem(path: p, bytes: await DiskMeasure.size(of: p) ?? 0, note: "old cursor-agent version",
                                                 lastUsed: RuleKit.modified(p), usedBy: "nothing (replaced)"))
                    }
                }
            }

            let total = RuleKit.total(items)
            guard total >= RuleKit.minimumFindingBytes else { continue }
            findings.append(Finding(
                id: "editor-\(editor.name)", title: "\(editor.name) leftovers",
                detail: "Caches for older \(editor.name) versions, a stale database backup and replaced agent versions. \(editor.name) never reads these again.",
                tier: .safe, bytes: total, items: items.sorted { $0.bytes > $1.bytes }, action: .trash,
                kept: kept.joined(separator: " · "),
                quitApps: app.bundleID.map { [$0] } ?? [],
                revealPath: support, symbol: "chevron.left.forwardslash.chevron.right",
                facts: [Fact("Installed version", app.version ?? "unknown"),
                        Fact("Last opened", app.lastUsed.map(RuleKit.relativeAge) ?? "unknown"),
                        Fact("Used by", "nothing: \(editor.name) only reads its current version's files", .good)],
                quickClean: true))
        }
        return findings
    }
}

struct HomebrewRule: CleanupRule {
    let name = "Homebrew"
    var isQuick: Bool { true }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        guard let brew = Tools.find("brew") else { return [] }
        let r = await Shell.run(brew, ["cleanup", "-n", "--prune=all"], timeout: 90)
        let lines = r.out.split(separator: "\n").map(String.init)
        let summary = lines.last { $0.contains("free approximately") }
        let amount = summary.flatMap { line -> Int64? in
            guard let range = line.range(of: #"approximately\s+([0-9.,]+\s*[KMGT]?B)"#, options: .regularExpression) else { return nil }
            return ByteFormat.parse(line[range].replacingOccurrences(of: "approximately", with: ""))
        } ?? 0
        guard amount >= RuleKit.minimumFindingBytes else { return [] }
        // "Would remove: /path (12 files, 34.8MB)"
        let items = lines.compactMap { line -> FindingItem? in
            guard line.hasPrefix("Would remove: ") else { return nil }
            let rest = line.dropFirst("Would remove: ".count)
            let path = rest.components(separatedBy: " (").first ?? String(rest)
            let size = rest.range(of: #"[0-9.,]+\s*[KMGT]?B\)"#, options: .regularExpression).flatMap { ByteFormat.parse(String(rest[$0]).replacingOccurrences(of: ")", with: "")) } ?? 0
            return FindingItem(path: path, bytes: size, note: "old version or download", usedBy: "Homebrew")
        }.sorted { $0.bytes > $1.bytes }
        return [Finding(
            id: "homebrew", title: "Homebrew downloads and old versions",
            detail: "Downloaded bottles and outdated versions Homebrew keeps after upgrades.",
            tier: .safe, bytes: amount, items: Array(items.prefix(40)),
            action: .command(tool: brew, args: ["cleanup", "-s", "--prune=all"]),
            revealPath: ctx.path("~/Library/Caches/Homebrew"), symbol: "mug",
            facts: [Fact("Installed packages", "not affected", .good),
                    Fact("Run by", "Homebrew's own cleanup command")],
            quickClean: true)]
    }
}

struct DownloadsRule: CleanupRule {
    let name = "Downloads"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let downloads = ctx.path("~/Downloads")
        let installers: Set<String> = ["dmg", "pkg", "iso", "xip", "zip"]
        let items = await DiskMeasure.children(of: downloads, minBytes: 200_000_000).map { child -> FindingItem in
            let ext = (child.path as NSString).pathExtension.lowercased()
            let kind = installers.contains(ext) ? "installer/archive" : (DiskMeasure.isDirectory(child.path) ? "folder" : "file")
            let opened = AppIndex.lastUsed(child.path)
            let source = AppIndex.downloadSource(child.path)
            return FindingItem(path: child.path, bytes: child.bytes,
                               note: [kind, opened == nil ? "never opened" : nil].compactMap { $0 }.joined(separator: " · "),
                               selectedByDefault: false, lastUsed: opened ?? RuleKit.modified(child.path),
                               usedBy: source.map { "from \($0)" }, quickSafe: false)
        }
        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        let installerCount = items.filter { $0.note?.hasPrefix("installer") == true }.count
        return [Finding(
            id: "downloads", title: "Large items in Downloads",
            detail: "Big files and folders in Downloads. Installers (.dmg, .pkg) are rarely needed after installing.",
            tier: .review, bytes: RuleKit.total(items), items: items, action: .trash, revealPath: downloads,
            symbol: "arrow.down.circle",
            facts: [Fact("Installers", "\(installerCount)"), Fact("Preselected", "nothing: your files, your call")],
            risk: "These are your own files. Only remove what you recognise.")]
    }
}

/// Apps not opened in months, with the data they leave behind.
struct UnusedAppsRule: CleanupRule {
    let name = "Unused apps"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let support = ctx.path("~/Library/Application Support")
        var items: [FindingItem] = []
        var managed: [String] = []
        for app in ctx.apps {
            guard let last = app.lastUsed, let days = RuleKit.days(since: last), days >= 90 else { continue }
            if let id = app.bundleID, ctx.runningBundleIDs.contains(id) { continue }
            guard let bytes = await DiskMeasure.size(of: app.path), bytes >= 150_000_000 else { continue }
            if app.isManaged { managed.append(app.name); continue }
            var dataBytes: Int64 = 0
            for candidate in [app.bundleID, app.name].compactMap({ $0 }) {
                if let b = await DiskMeasure.size(of: "\(support)/\(candidate)") { dataBytes += b }
            }
            let note = "v\(app.version ?? "?")" + (dataBytes > 50_000_000 ? " · leaves \(ByteFormat.string(dataBytes)) of app data" : "")
            items.append(FindingItem(path: app.path, bytes: bytes, note: note, selectedByDefault: false,
                                     lastUsed: last, usedBy: app.name, quickSafe: false))
        }
        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        items.sort { $0.bytes > $1.bytes }
        var facts = [Fact("Not opened for", "90 days or more (from Spotlight)"),
                     Fact("Their data", "stays in your Library, so a reinstall picks up where you left off"),
                     Fact("Preselected", "nothing")]
        if !managed.isEmpty { facts.append(Fact("App Store apps", "remove from Launchpad: " + managed.prefix(5).joined(separator: ", "))) }
        return [Finding(
            id: "unused-apps", title: "Apps you haven't opened in 3+ months",
            detail: "Apps Spotlight hasn't seen you open in at least 90 days. Moving an app to the Trash uninstalls it.",
            tier: .review, bytes: RuleKit.total(items), items: items, action: .trash, revealPath: "/Applications",
            symbol: "square.grid.2x2", facts: facts,
            risk: "You'll need to reinstall an app (and its licence) to use it again.")]
    }
}

/// The Trash and macOS temp files, which DiskLens points you to but doesn't empty itself.
struct TrashAndTempRule: CleanupRule {
    let name = "Trash and temp"
    var isQuick: Bool { true }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        var findings: [Finding] = []
        let trash = ctx.path("~/.Trash")
        if ctx.hasFullDiskAccess, let bytes = await DiskMeasure.size(of: trash), bytes >= 100_000_000 {
            findings.append(Finding(
                id: "trash", title: "Empty the Trash",
                detail: "Everything in the Trash still takes up space. Open it, check it, then choose Finder → Empty Trash.",
                tier: .safe, bytes: bytes, action: .open(path: trash), revealPath: trash, symbol: "trash",
                facts: [Fact("Emptied by", "you, in Finder: DiskLens never empties it")]))
        }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            let temp = String(cString: buffer)
            if let bytes = await DiskMeasure.size(of: temp), bytes >= 2_000_000_000 {
                findings.append(Finding(
                    id: "temp", title: "Temporary files (restart to clear)",
                    detail: "macOS clears most of its temporary folder when you restart. Don't delete it by hand, since running apps use it.",
                    tier: .safe, bytes: bytes, action: .advice, revealPath: temp, symbol: "arrow.clockwise.circle",
                    facts: [Fact("How", "Apple menu → Restart"), Fact("Used by", "apps that are running now", .warning)]))
            }
        }
        return findings
    }
}

struct DeviceBackupsRule: CleanupRule {
    let name = "iPhone backups"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        guard ctx.hasFullDiskAccess else { return [] }
        let root = ctx.path("~/Library/Application Support/MobileSync/Backup")
        let items = await DiskMeasure.children(of: root, minBytes: 100_000_000).map { child -> FindingItem in
            let info = NSDictionary(contentsOfFile: child.path + "/Info.plist")
            let device = info?["Device Name"] as? String ?? "Unknown device"
            let product = info?["Product Type"] as? String
            let date = info?["Last Backup Date"] as? Date
            return FindingItem(path: child.path, bytes: child.bytes, note: product ?? "backup", selectedByDefault: false,
                               lastUsed: date, usedBy: device, quickSafe: false)
        }
        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        return [Finding(
            id: "device-backups", title: "iPhone and iPad backups",
            detail: "Local backups made by Finder. Keep the newest backup of any device you still use, unless it's backed up to iCloud.",
            tier: .review, bytes: RuleKit.total(items), items: items, action: .trash, revealPath: root,
            symbol: "iphone.and.arrow.forward",
            facts: [Fact("Devices", Set(items.compactMap(\.usedBy)).sorted().joined(separator: ", ")),
                    Fact("Also manageable in", "Finder → device → Manage Backups")],
            risk: "A removed backup can't restore that device any more.")]
    }
}

/// Large data that apps manage themselves, listed so it's clear why it stays.
struct AppManagedDataRule: CleanupRule {
    let name = "App-managed data"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        // Data that apps manage themselves on many Macs. Each only shows up if it exists and is over 1 GB.
        let known: [(path: String, title: String, why: String, app: String?)] = [
            ("~/Pictures/Photos Library.photoslibrary", "Photos library", "Use Photos → Settings → iCloud → Optimize Mac Storage instead of touching the library.", "/System/Applications/Photos.app"),
            ("~/Library/Mail", "Mail", "Remove large attachments from inside Mail, or remove an account you no longer use.", "/System/Applications/Mail.app"),
            ("~/Library/Messages", "Messages attachments", "Use System Settings → General → Storage → Messages to review large attachments.", "/System/Applications/Messages.app"),
            ("~/Music/Music/Media.localized", "Music library", "Remove downloads from inside the Music app.", "/System/Applications/Music.app"),
            ("~/Library/Mobile Documents", "iCloud Drive (local copies)", "Turn on System Settings → Apple Account → iCloud → Optimize Mac Storage to keep only recent files on this Mac.", nil),
            ("~/Library/Application Support/Claude/vm_bundles", "Claude desktop VM", "The disk image for Claude's sandboxed VM. Claude manages it, and deleting it by hand only triggers a re-download.", "/Applications/Claude.app"),
            ("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb", "Cursor chat database", "Holds Cursor's chat history and settings. Clear old chats inside Cursor to shrink it.", "/Applications/Cursor.app"),
            ("~/Library/Application Support/Code/User/globalStorage/state.vscdb", "VS Code state database", "Holds VS Code's extension state and history.", "/Applications/Visual Studio Code.app"),
            ("~/Library/Containers/com.utmapp.UTM", "UTM virtual machines", "Remove virtual machines from inside UTM.", "/Applications/UTM.app"),
            ("~/Parallels", "Parallels virtual machines", "Remove virtual machines from Parallels Control Center.", "/Applications/Parallels Desktop.app"),
            ("~/Virtual Machines.localized", "VMware virtual machines", "Remove virtual machines from inside VMware Fusion.", "/Applications/VMware Fusion.app"),
        ]
        var findings: [Finding] = []
        for entry in known {
            let p = ctx.path(entry.path)
            guard let bytes = await DiskMeasure.size(of: p), bytes >= 1_000_000_000 else { continue }
            var facts = [Fact("Managed by", entry.app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "its app"),
                         Fact("Last changed", RuleKit.modified(p).map(RuleKit.relativeAge) ?? "unknown")]
            if let app = entry.app, let opened = AppIndex.lastUsed(app) { facts.append(Fact("App last opened", RuleKit.relativeAge(opened))) }
            findings.append(Finding(id: "keep-\(entry.title)", title: entry.title, detail: entry.why,
                                    tier: .keep, bytes: bytes, action: .advice,
                                    revealPath: (p as NSString).deletingLastPathComponent, symbol: "lock.fill", facts: facts))
        }
        return findings
    }
}
#endif
