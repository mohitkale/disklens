import AppKit
import DiskLensCore
import Foundation

/// Sample data for screenshots and demos (`DISKLENS_DEMO=1`), so nothing from a real Mac is shown.
/// `DISKLENS_DEMO=welcome` shows the first-run screen instead. Demo mode never scans, saves or cleans.
enum DemoData {
    static var mode: String? { ProcessInfo.processInfo.environment["DISKLENS_DEMO"] }
    static var isEnabled: Bool { mode != nil }
    static var isWelcome: Bool { mode == "welcome" }

    private static let home = NSHomeDirectory()
    private static let gb: Int64 = 1_000_000_000
    private static let mb: Int64 = 1_000_000
    private static func ago(days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }
    private static func p(_ path: String) -> String { home + "/" + path }

    static var snapshots: [Snapshot] {
        guard !isWelcome else { return [] }
        let cap: Int64 = 500 * gb
        func snap(_ daysAgo: Double, free: Int64, label: String?, docs: Int64, caches: Int64, xcode: Int64, docker: Int64) -> Snapshot {
            let cats = [
                CategoryUsage(name: "Documents", bytes: docs, paths: [p("Documents")]),
                CategoryUsage(name: "App data", bytes: 38 * gb, paths: [p("Library/Application Support"), p("Library/Containers")]),
                CategoryUsage(name: "Caches & temp", bytes: caches, paths: [p("Library/Caches"), p(".npm"), p(".cache")]),
                CategoryUsage(name: "Applications", bytes: 31 * gb, paths: ["/Applications"]),
                CategoryUsage(name: "Xcode & Simulators", bytes: xcode, paths: [p("Library/Developer"), "/Library/Developer/CoreSimulator"]),
                CategoryUsage(name: "Developer tools", bytes: 18 * gb, paths: [p(".nvm"), p(".gradle"), "/opt/homebrew"]),
                CategoryUsage(name: "Photos & media", bytes: 24 * gb, paths: [p("Pictures"), p("Movies"), p("Music")]),
                CategoryUsage(name: "Docker", bytes: docker, paths: [p("Library/Containers/com.docker.docker")]),
                CategoryUsage(name: "iCloud Drive", bytes: 9 * gb, paths: [p("Library/Mobile Documents")]),
                CategoryUsage(name: "Desktop & Downloads", bytes: 7 * gb, paths: [p("Desktop"), p("Downloads")]),
                CategoryUsage(name: "Other", bytes: 12 * gb, paths: ["/System/Volumes/Data"]),
            ].sorted { $0.bytes > $1.bytes }
            let measured = cats.reduce(0) { $0 + $1.bytes }
            return Snapshot(date: ago(days: daysAgo), label: label, capacity: cap, free: free, system: 23 * gb,
                            hidden: 0, measured: measured, trash: nil, categories: cats, duration: 104)
        }
        return [
            snap(21, free: 41 * gb, label: nil, docs: 72 * gb, caches: 44 * gb, xcode: 58 * gb, docker: 46 * gb),
            snap(14, free: 34 * gb, label: nil, docs: 74 * gb, caches: 47 * gb, xcode: 61 * gb, docker: 48 * gb),
            snap(7, free: 27 * gb, label: nil, docs: 76 * gb, caches: 50 * gb, xcode: 63 * gb, docker: 50 * gb),
            snap(3, free: 92 * gb, label: "After cleaning 6 items", docs: 64 * gb, caches: 21 * gb, xcode: 33 * gb, docker: 18 * gb),
            snap(0.02, free: 104 * gb, label: nil, docs: 62 * gb, caches: 19 * gb, xcode: 31 * gb, docker: 18 * gb),
        ]
    }

    static var privacyReports: [MetadataReport] {
        guard !isWelcome else { return [] }
        let homeSpot = Coordinate(latitude: 37.3349, longitude: -122.0090)
        func photo(_ i: Int, _ c: Coordinate?, days: Double, device: String = "Apple iPhone 15 Pro", serial: Bool = false) -> MetadataReport {
            MetadataReport(path: p("Pictures/Exports/IMG_\(4100 + i).HEIC"), kind: .image, bytes: Int64(2_400_000 + i * 37_000),
                           coordinate: c.map { Coordinate(latitude: $0.latitude + Double(i % 5) * 0.0001, longitude: $0.longitude) },
                           device: device, serials: serial ? ["F2LXK8Q9H1"] : [], captured: ago(days: days))
        }
        var list = (0..<18).map { photo($0, homeSpot, days: Double($0 * 9 + 2)) }
        list += (0..<6).map { photo(20 + $0, Coordinate(latitude: 48.8584, longitude: 2.2945), days: 120) }
        list += (0..<4).map { photo(30 + $0, nil, days: 40, device: "Canon EOS R6", serial: true) }
        list.append(MetadataReport(path: p("Movies/beach-day.mov"), kind: .video, bytes: 184_000_000,
                                   coordinate: Coordinate(latitude: 36.9741, longitude: -122.0308), device: "Apple iPhone 15 Pro", captured: ago(days: 60)))
        list.append(MetadataReport(path: p("Documents/Resume-2026.pdf"), kind: .pdf, bytes: 240_000, people: ["Alex Morgan"], software: "Pages"))
        list.append(MetadataReport(path: p("Documents/Q3 Budget.xlsx"), kind: .office, bytes: 88_000, people: ["Alex Morgan", "Acme Inc"], software: "Microsoft Excel"))
        list.append(MetadataReport(path: p("Downloads/lease-signed.pdf"), kind: .pdf, bytes: 1_200_000, people: ["Alex Morgan"]))
        return list
    }

    static var duplicateGroups: [DuplicateGroup] {
        guard !isWelcome else { return [] }
        func f(_ path: String, _ bytes: Int64, _ days: Double) -> DuplicateFile {
            DuplicateFile(path: p(path), bytes: bytes, modified: ago(days: days), created: ago(days: days))
        }
        return [
            DuplicateFinder.group(hash: "a1", files: [f("Movies/Wedding/ceremony.mp4", 2_800 * mb, 400), f("Downloads/ceremony.mp4", 2_800 * mb, 30), f("Desktop/ceremony (1).mp4", 2_800 * mb, 12)]),
            DuplicateFinder.group(hash: "b2", files: [f("Documents/Installers/Xcode_16.xip", 3_100 * mb, 200), f("Downloads/Xcode_16.xip", 3_100 * mb, 199)]),
            DuplicateFinder.group(hash: "c3", files: [f("Documents/Taxes/2025-return.pdf", 14 * mb, 210), f("Downloads/2025-return.pdf", 14 * mb, 209), f("Desktop/2025-return copy.pdf", 14 * mb, 100)]),
            DuplicateFinder.group(hash: "d4", files: [f("Pictures/Trips/Iceland.zip", 920 * mb, 500), f("Downloads/Iceland.zip", 920 * mb, 480)]),
        ].sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Sample events (with generated swatches as "photos") for Media Studio screenshots.
    static var mediaItems: [MediaItem] {
        guard !isWelcome else { return [] }
        var items: [MediaItem] = []
        func add(_ name: String, count: Int, start: Double, videos: Int = 0) {
            for i in 0..<count {
                let video = i < videos
                items.append(MediaItem(origin: .file(p("Pictures/\(name)/\(i).\(video ? "mov" : "heic")")), kind: video ? .video : .photo,
                                       date: ago(days: start).addingTimeInterval(Double(i) * 420), duration: video ? Double(14 + i * 7) : 0,
                                       bytes: video ? 120_000_000 : 3_200_000))
            }
        }
        add("Birthday", count: 46, start: 12, videos: 4)
        add("Beach", count: 31, start: 40, videos: 3)
        add("Graduation", count: 58, start: 95, videos: 2)
        add("Hiking", count: 24, start: 150, videos: 1)
        add("Wedding", count: 88, start: 220, videos: 6)
        return items
    }

    /// A soft gradient "photo" for an item, so demo screenshots never show real images.
    static func swatch(for id: String, size: Int) -> CGImage? {
        var h: UInt64 = 1469598103934665603
        // Burst shots ("…burst-2#3.heic") share one look so similar-photo demos read as similar.
        let key = id.split(separator: "#").first.map(String.init) ?? id
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let hue = Double(h % 360) / 360, hue2 = Double((h >> 9) % 360) / 360
        let w = size, ht = size * 3 / 4
        guard let ctx = CGContext(data: nil, width: w, height: ht, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let a = NSColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1).cgColor
        let b = NSColor(hue: hue2, saturation: 0.55, brightness: 0.7, alpha: 1).cgColor
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [a, b] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: ht), options: [])
        ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
        ctx.fillEllipse(in: CGRect(x: w / 5, y: ht / 4, width: w / 3, height: w / 3))
        return ctx.makeImage()
    }

    static var log: [LogEntry] {
        guard !isWelcome else { return [] }
        return [
            LogEntry(date: ago(days: 3.1), title: "iOS 17.2 simulator", bytes: 9_400 * mb, outcome: .freed, detail: "xcrun simctl runtime delete …"),
            LogEntry(date: ago(days: 3.1), title: "Docker build cache", bytes: 28 * gb, outcome: .freed, detail: "docker builder prune -a -f"),
            LogEntry(date: ago(days: 3.2), title: "App caches", bytes: 14_300 * mb, outcome: .trashed, detail: "11 item(s) moved to the Trash"),
            LogEntry(date: ago(days: 3.2), title: "npm and npx cache", bytes: 8_200 * mb, outcome: .trashed, detail: "4 item(s) moved to the Trash"),
        ]
    }

    static var findings: [Finding] {
        guard !isWelcome else { return [] }
        let projects: [(String, String, Int64, Double, Bool)] = [
            ("acme-dashboard", "Next.js · npm", 1_840 * mb, 2, false), ("weather-app", "Expo · yarn", 1_120 * mb, 210, true),
            ("portfolio-site", "Vite · pnpm", 640 * mb, 400, true), ("chat-server", "Node.js · npm", 520 * mb, 95, true),
            ("todo-native", "React Native · npm", 980 * mb, 260, true), ("blog-starter", "Next.js · npm", 710 * mb, 540, true),
            ("landing-page", "React · yarn", 430 * mb, 330, true), ("design-system", "Vite · pnpm", 1_270 * mb, 6, false),
            ("api-gateway", "Node.js · npm", 360 * mb, 180, true), ("hackathon-2024", "Next.js · npm", 890 * mb, 620, true),
        ]
        let nodeItems = projects.map { name, kind, bytes, days, pre in
            FindingItem(path: p("Projects/\(name)/node_modules"), bytes: bytes,
                        note: kind + (pre ? "" : " · worked on recently, not preselected"),
                        selectedByDefault: pre, lastUsed: ago(days: days), usedBy: name)
        }
        let stale = nodeItems.filter { ($0.lastUsed.map { Date().timeIntervalSince($0) } ?? 0) > 180 * 86_400 }

        let cacheItems = [
            FindingItem(path: p("Library/Caches/Google"), bytes: 2_900 * mb, lastUsed: ago(days: 0.3), usedBy: "Google Chrome"),
            FindingItem(path: p("Library/Caches/com.spotify.client"), bytes: 1_600 * mb, lastUsed: ago(days: 1), usedBy: "Spotify"),
            FindingItem(path: p("Library/Caches/typescript"), bytes: 1_200 * mb, lastUsed: ago(days: 4), usedBy: "TypeScript language service (VS Code, Cursor)"),
            FindingItem(path: p("Library/Caches/com.tinyspeck.slackmacgap"), bytes: 780 * mb, lastUsed: ago(days: 0.5), usedBy: "Slack"),
            FindingItem(path: p("Library/Caches/Yarn"), bytes: 690 * mb, lastUsed: ago(days: 40), usedBy: "Yarn package manager"),
            FindingItem(path: p("Library/Caches/CocoaPods"), bytes: 410 * mb, lastUsed: ago(days: 70), usedBy: "CocoaPods"),
        ]
        let npmItems = [
            FindingItem(path: p(".npm/_cacache"), bytes: 3_100 * mb, note: "packages npm downloaded before", lastUsed: ago(days: 1), usedBy: "npm"),
            FindingItem(path: p(".npm/_npx/9f2c1a7e"), bytes: 210 * mb, note: "not running now", lastUsed: ago(days: 30), usedBy: "npx create-next-app"),
        ]
        let derived = [
            FindingItem(path: p("Library/Developer/Xcode/DerivedData/WeatherApp-abc123"), bytes: 2_300 * mb, lastUsed: ago(days: 12), usedBy: "WeatherApp"),
            FindingItem(path: p("Library/Developer/Xcode/DerivedData/TodoNative-def456"), bytes: 1_100 * mb, lastUsed: ago(days: 80), usedBy: "TodoNative"),
        ]
        let logs = [
            FindingItem(path: p("Library/Logs/DiagnosticReports"), bytes: 140 * mb, lastUsed: ago(days: 9), usedBy: "Crash reports"),
            FindingItem(path: p("Library/Logs/JetBrains"), bytes: 95 * mb, lastUsed: ago(days: 60), usedBy: "JetBrains IDEs"),
        ]
        let largeFiles = [
            FindingItem(path: p("Movies/conference-talk-4k.mov"), bytes: 18 * gb, note: "QuickTime movie · in ~/Movies", selectedByDefault: false, lastUsed: ago(days: 300), usedBy: "you", quickSafe: false),
            FindingItem(path: p("Downloads/ubuntu-24.04-desktop.iso"), bytes: 6 * gb, note: "Disk image · from releases.ubuntu.com", selectedByDefault: false, lastUsed: nil, usedBy: "never opened", quickSafe: false),
            FindingItem(path: p("Documents/backup-2023.zip"), bytes: 4_200 * mb, note: "ZIP archive · in ~/Documents", selectedByDefault: false, lastUsed: ago(days: 500), usedBy: "you", quickSafe: false),
        ]
        let apps = [
            FindingItem(path: "/Applications/Blender.app", bytes: 1_900 * mb, note: "v4.1 · leaves 300 MB of app data", selectedByDefault: false, lastUsed: ago(days: 240), usedBy: "Blender", quickSafe: false),
            FindingItem(path: "/Applications/Unity Hub.app", bytes: 700 * mb, note: "v3.8", selectedByDefault: false, lastUsed: ago(days: 400), usedBy: "Unity Hub", quickSafe: false),
        ]
        let brew = Tools.find("brew") ?? "/opt/homebrew/bin/brew"

        return [
            Finding(id: "node-modules", title: "node_modules in \(projects.count) projects",
                    detail: "Installed JavaScript dependencies. Projects you worked on in the last 2 weeks aren't preselected.",
                    tier: .safe, bytes: nodeItems.reduce(0) { $0 + $1.bytes }, items: nodeItems, action: .trash,
                    afterNote: "Run `npm install` (or `yarn` / `pnpm install`) when you next open one of these projects.",
                    revealPath: p("Projects"), symbol: "shippingbox.fill",
                    facts: [Fact("Projects", "\(projects.count) found across your home folder"),
                            Fact("Untouched 6+ months", "\(stale.count) projects · \(ByteFormat.string(stale.reduce(0) { $0 + $1.bytes }))", .good),
                            Fact("Package managers", "npm, pnpm, yarn"),
                            Fact("Get it back", "`npm install` in the project (needs internet)")],
                    risk: "A project won't run until you reinstall its dependencies."),
            Finding(id: "app-caches", title: "App caches", detail: "Temporary data apps keep to load faster. Apps rebuild it as needed.",
                    tier: .safe, bytes: cacheItems.reduce(0) { $0 + $1.bytes }, items: cacheItems, action: .trash,
                    kept: "anything open right now", revealPath: p("Library/Caches"), symbol: "archivebox",
                    facts: [Fact("Owners", "6 apps and tools"), Fact("Rebuilt by", "each app, automatically, as it needs them", .good),
                            Fact("Apple caches", "never touched", .good)],
                    risk: "Apps may open a little slower the first time while they rebuild their cache.", quickClean: true),
            Finding(id: "sim-runtime-demo-17", title: "iOS 17.5 simulator",
                    detail: "The iOS 17.5 system that Xcode's simulators run on.", tier: .safe, bytes: 9_800 * mb,
                    action: .command(tool: Tools.xcrun, args: ["simctl", "runtime", "delete", "DEMO-RUNTIME-ID"]),
                    quitApps: ["com.apple.iphonesimulator"], revealPath: "/Library/Developer/CoreSimulator", symbol: "iphone.gen3",
                    facts: [Fact("Last used", "8 months ago", .good), Fact("Xcode last opened", "2 days ago"),
                            Fact("Simulators on it", "iPhone 15, iPhone SE (3rd generation)"),
                            Fact("Size", "7.3 GB runtime + 2.5 GB cache"),
                            Fact("Get it back", "Xcode → Settings → Components (~7.3 GB download)"),
                            Fact("Undo", "Not through the Trash: download it again", .warning)],
                    risk: "Xcode can't run iOS 17.5 simulators until you download it again."),
            Finding(id: "npm-cache", title: "npm and npx cache", detail: "Packages npm and npx downloaded before. They're fetched again when needed.",
                    tier: .safe, bytes: npmItems.reduce(0) { $0 + $1.bytes }, items: npmItems, action: .trash,
                    kept: "2 npx package(s) used by running tools", revealPath: p(".npm"), symbol: "shippingbox",
                    facts: [Fact("Rebuilt by", "npm / npx, on the next install", .good)], quickClean: true),
            Finding(id: "temp", title: "Temporary files (restart to clear)",
                    detail: "macOS clears most of its temporary folder when you restart. Don't delete it by hand, since running apps use it.",
                    tier: .safe, bytes: 4_700 * mb, action: .advice, revealPath: NSTemporaryDirectory(), symbol: "arrow.clockwise.circle",
                    facts: [Fact("How", "Apple menu → Restart")]),
            Finding(id: "xcode-derived-data", title: "Xcode build data", detail: "Build products and indexes in DerivedData. Xcode rebuilds them on the next build.",
                    tier: .safe, bytes: derived.reduce(0) { $0 + $1.bytes }, items: derived, action: .trash,
                    quitApps: ["com.apple.dt.Xcode"], revealPath: p("Library/Developer/Xcode/DerivedData"), symbol: "hammer",
                    facts: [Fact("Rebuilt by", "Xcode, automatically", .good), Fact("Cost", "the first build afterwards is slower")], quickClean: true),
            Finding(id: "homebrew", title: "Homebrew downloads and old versions", detail: "Downloaded bottles and outdated versions Homebrew keeps after upgrades.",
                    tier: .safe, bytes: 1_400 * mb, action: .command(tool: brew, args: ["cleanup", "-s", "--prune=all"]),
                    symbol: "mug", facts: [Fact("Installed packages", "not affected", .good)], quickClean: true),
            Finding(id: "logs", title: "Old logs", detail: "Diagnostic logs written by apps and macOS. Nothing needs them to run.",
                    tier: .safe, bytes: logs.reduce(0) { $0 + $1.bytes }, items: logs, action: .trash, revealPath: p("Library/Logs"),
                    symbol: "doc.text.magnifyingglass", facts: [Fact("Used by", "only for troubleshooting", .good)], quickClean: true),
            Finding(id: "sim-runtime-demo-18", title: "iOS 18.4 simulator",
                    detail: "The iOS 18.4 system that Xcode's simulators run on. It's your newest iOS simulator.", tier: .review, bytes: 12_100 * mb,
                    action: .command(tool: Tools.xcrun, args: ["simctl", "runtime", "delete", "DEMO-RUNTIME-ID-2"]),
                    symbol: "iphone.gen3",
                    facts: [Fact("Last used", "5 months ago", .good), Fact("Simulators on it", "iPhone 16 Pro, iPad Air"),
                            Fact("Undo", "Not through the Trash: download it again", .warning)],
                    risk: "Xcode can't run iOS 18.4 simulators until you download it again."),
            Finding(id: "docker-not-running", title: "Docker disk image",
                    detail: "Docker keeps every image, container and volume in one file. Start Docker Desktop and scan again to see inside it.",
                    tier: .review, bytes: 18 * gb, action: .launchApp(bundleID: "com.docker.docker"), symbol: "cube.transparent",
                    facts: [Fact("Docker Desktop", "not running", .warning), Fact("Last opened", "3 weeks ago")]),
            Finding(id: "large-files", title: "Large files (over 1 GB)",
                    detail: "The biggest individual files in your home folder: videos, disk images, archives and so on.",
                    tier: .review, bytes: largeFiles.reduce(0) { $0 + $1.bytes }, items: largeFiles, action: .trash, symbol: "doc.zipper",
                    facts: [Fact("Files", "3"), Fact("Preselected", "nothing: these are your files")],
                    risk: "These are your own files. Move to an external drive if you're unsure."),
            Finding(id: "unused-apps", title: "Apps you haven't opened in 3+ months",
                    detail: "Apps Spotlight hasn't seen you open in at least 90 days. Moving an app to the Trash uninstalls it.",
                    tier: .review, bytes: apps.reduce(0) { $0 + $1.bytes }, items: apps, action: .trash, revealPath: "/Applications",
                    symbol: "square.grid.2x2", facts: [Fact("Not opened for", "90 days or more (from Spotlight)")],
                    risk: "You'll need to reinstall an app to use it again."),
            Finding(id: "keep-Photos library", title: "Photos library",
                    detail: "Use Photos → Settings → iCloud → Optimize Mac Storage instead of touching the library.",
                    tier: .keep, bytes: 21 * gb, action: .advice, symbol: "lock.fill",
                    facts: [Fact("Managed by", "Photos")]),
        ]
    }

    // MARK: Apps (fictional apps and paths)

    static var appFootprints: [AppFootprint] {
        guard !isWelcome else { return [] }
        func app(_ name: String, _ id: String, _ version: String, used: Double?, appGB: Double, managed: Bool = false,
                 data: [(String, String, Double)]) -> AppFootprint {
            let a = InstalledApp(path: "/Applications/\(name).app", name: name, bundleID: id, version: version,
                                 lastUsed: used.map { ago(days: $0) }, isManaged: managed)
            let items = data.map { folder, kind, g in
                FindingItem(path: p("Library/\(folder)/\(folder.hasPrefix("Containers") || folder.hasPrefix("Preferences") ? id : name)"),
                            bytes: Int64(g * 1e9), note: kind, lastUsed: used.map { ago(days: $0) }, usedBy: name, quickSafe: false)
            }
            return AppFootprint(app: a, appBytes: Int64(appGB * 1e9), leftovers: items)
        }
        return [
            app("StudioCut Pro", "com.example.studiocut", "11.2", used: 240, appGB: 6.8,
                data: [("Application Support", "app data", 9.4), ("Caches", "cache", 2.1), ("Preferences", "settings", 0.0004)]),
            app("PixelForge", "com.example.pixelforge", "4.0.3", used: 3, appGB: 2.4,
                data: [("Application Support", "app data", 3.2), ("Caches", "cache", 1.4), ("Saved Application State", "saved window state", 0.002)]),
            app("Chatterly", "com.example.chatterly", "2.18", used: 0.2, appGB: 0.6,
                data: [("Containers", "sandbox container", 4.1), ("Caches", "cache", 0.8)]),
            app("CodeHarbor", "com.example.codeharbor", "1.94", used: 1, appGB: 1.1,
                data: [("Application Support", "app data", 1.9), ("Caches", "cache", 0.9), ("Logs", "logs", 0.12)]),
            app("Notely", "com.example.notely", "8.1", used: 400, appGB: 0.3, managed: true,
                data: [("Containers", "sandbox container", 1.6)]),
            app("StreamBox", "com.example.streambox", "5.6", used: 120, appGB: 0.4,
                data: [("Caches", "cache", 1.2), ("HTTPStorages", "web storage", 0.05)]),
            app("Trackly", "com.example.trackly", "3.3", used: nil, appGB: 0.2, data: []),
        ]
    }

    static var orphanItems: [FindingItem] {
        guard !isWelcome else { return [] }
        return [
            ("Containers/com.example.oldgame", 3.8, 300), ("Application Support/com.example.videoconverter", 1.6, 520),
            ("Caches/com.example.photoeditor", 0.9, 410), ("Application Support/com.example.vpnclient", 0.31, 95),
        ].map { path, g, days in
            let id = (path as NSString).lastPathComponent
            let folder = (path as NSString).deletingLastPathComponent
            return FindingItem(path: p("Library/" + path), bytes: Int64(g * 1e9), note: "\(folder) · no app with this ID is installed",
                               selectedByDefault: false, lastUsed: ago(days: days), usedBy: id, quickSafe: false)
        }
    }

    static var startupItems: [StartupItem] {
        guard !isWelcome else { return [] }
        return [
            StartupItem(path: p("Library/LaunchAgents/com.example.chatterly.helper.plist"), label: "com.example.chatterly.helper",
                        program: "/Applications/Chatterly.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper",
                        kind: .userAgent, runsAtLoad: true, keepAlive: false, owner: "Chatterly", modified: ago(days: 30)),
            StartupItem(path: p("Library/LaunchAgents/com.example.updater.plist"), label: "com.example.updater",
                        program: "/Users/Shared/ExampleUpdater/updater", kind: .userAgent, runsAtLoad: true, keepAlive: true, owner: nil, modified: ago(days: 400)),
            StartupItem(path: "/Library/LaunchAgents/com.example.studiocut.agent.plist", label: "com.example.studiocut.agent",
                        program: "/Applications/StudioCut Pro.app/Contents/Resources/Agent", kind: .systemAgent, runsAtLoad: true, keepAlive: false,
                        owner: "StudioCut Pro", modified: ago(days: 240)),
            StartupItem(path: "/Library/LaunchDaemons/com.example.vpn.daemon.plist", label: "com.example.vpn.daemon",
                        program: "/Library/PrivilegedHelperTools/com.example.vpn.daemon", kind: .daemon, runsAtLoad: true, keepAlive: true,
                        owner: nil, modified: ago(days: 95)),
        ]
    }

    static var browserExtensions: [BrowserExtension] {
        guard !isWelcome else { return [] }
        let base = p("Library/Application Support/Google/Chrome/Default/Extensions/")
        return [
            BrowserExtension(browser: "Google Chrome", name: "Password Vault", identifier: "abcdefghijklmnopabcdefghijklmnop", version: "4.12",
                             path: base + "abcdefghijklmnopabcdefghijklmnop", permissions: ["<all_urls>", "storage"]),
            BrowserExtension(browser: "Google Chrome", name: "Coupon Finder", identifier: "bcdefghijklmnopabcdefghijklmnopa", version: "2.0.1",
                             path: base + "bcdefghijklmnopabcdefghijklmnopa", permissions: ["<all_urls>", "tabs", "cookies"]),
            BrowserExtension(browser: "Google Chrome", name: "Dark Reader Lite", identifier: "cdefghijklmnopabcdefghijklmnopab", version: "1.3",
                             path: base + "cdefghijklmnopabcdefghijklmnopab", permissions: ["storage", "activeTab"]),
            BrowserExtension(browser: "Firefox", name: "Tab Grouper", identifier: "tabgrouper@example.com", version: "0.9",
                             path: p("Library/Application Support/Firefox/Profiles/demo.default/extensions"), permissions: []),
        ]
    }

    static var sensitiveFindings: [SensitiveFinding] {
        guard !isWelcome else { return [] }
        return [
            SensitiveFinding(path: p("Desktop/Screenshot 2026-09-14 at 10.02.11.png"), bytes: 1_400_000, kinds: [.card],
                             samples: ["•••• 4242"], date: ago(days: 54)),
            SensitiveFinding(path: p("Downloads/IMG_0841.PNG"), bytes: 2_100_000, kinds: [.code], samples: ["one-time code"], date: ago(days: 20)),
            SensitiveFinding(path: p("Pictures/Screenshots/Screenshot 2026-07-02 at 21.40.55.png"), bytes: 900_000, kinds: [.seed],
                             samples: ["recovery phrase"], date: ago(days: 128)),
            SensitiveFinding(path: p("Desktop/Screenshot 2026-10-30 at 08.15.20.png"), bytes: 640_000, kinds: [.qr, .email], samples: [], date: ago(days: 8)),
        ]
    }

    static var similarResult: SimilarResult? {
        guard !isWelcome else { return nil }
        func burst(_ n: Int, shots: Int, days: Double) -> [MediaItem] {
            (0..<shots).map { i in
                MediaItem(origin: .file(p("Pictures/Beach/burst-\(n)#\(i).heic")), kind: .photo,
                          date: ago(days: days).addingTimeInterval(Double(i) * 2), duration: 0, bytes: 3_100_000 + Int64(i) * 40_000)
            }
        }
        let groups = [burst(1, shots: 5, days: 40), burst(2, shots: 3, days: 41), burst(3, shots: 4, days: 95)].map { items in
            SimilarGroup(items: items, keep: items[1].id, sharpness: [:])
        }
        let blurry = (0..<6).map { i in
            MediaItem(origin: .file(p("Pictures/Hiking/blurry-\(i).heic")), kind: .photo, date: ago(days: 150 + Double(i)), duration: 0, bytes: 2_800_000)
        }
        return SimilarResult(groups: groups, blurry: blurry, sharpness: [:], checked: 1_842)
    }

    // MARK: Shrink, PDF Tools, Cut Out (fictional paths; Apple's sample animal pictures for Cut Out)

    static var shrinkCandidates: [ShrinkCandidate] {
        guard !isWelcome else { return [] }
        return [
            ShrinkCandidate(path: p("Movies/Screen Recording 2026-10-02 at 14.10.33.mov"), kind: .video, bytes: 6_400 * mb, estimate: 980 * mb,
                            detail: "1080p · 48 min · 18 Mbps", modified: ago(days: 36)),
            ShrinkCandidate(path: p("Movies/Trip to the hills/GX010114.MP4"), kind: .video, bytes: 4_100 * mb, estimate: 1_250 * mb,
                            detail: "4K · 9 min · 60 Mbps", modified: ago(days: 120)),
            ShrinkCandidate(path: p("Downloads/Home loan agreement (scanned).pdf"), kind: .pdf, bytes: 212 * mb, estimate: nil,
                            detail: "64 pages · 3 MB per page · scanned or pictures", modified: ago(days: 300)),
            ShrinkCandidate(path: p("Desktop/Product demo final v3.mov"), kind: .video, bytes: 1_900 * mb, estimate: 410 * mb,
                            detail: "1080p · 12 min · 21 Mbps", modified: ago(days: 8)),
            ShrinkCandidate(path: p("Documents/Design/hero-banner-master.png"), kind: .image, bytes: 46 * mb, estimate: 7 * mb,
                            detail: "PNG, uncompressed: HEIC keeps the look at a fraction of the size", modified: ago(days: 60)),
            ShrinkCandidate(path: p("Documents/Annual report 2025.pdf"), kind: .pdf, bytes: 38 * mb, estimate: nil,
                            detail: "120 pages · 324 KB per page", modified: ago(days: 200)),
        ]
    }

    static var shrinkResults: [String: FileOutcome] {
        guard !isWelcome else { return [:] }
        return [
            p("Downloads/Home loan agreement (scanned).pdf"): FileOutcome(ok: true, outputs: [p("Downloads/Home loan agreement (scanned) (compressed).pdf")],
                                                                         before: 212 * mb, after: 9 * mb, message: "212 MB → 9 MB",
                                                                         method: "pages re-encoded, text recognised so it stays searchable"),
            p("Documents/Annual report 2025.pdf"): FileOutcome(ok: false, outputs: [], before: 38 * mb, after: 38 * mb,
                                                              message: "This PDF is mostly text and already compact, so it can't get meaningfully smaller."),
        ]
    }

    static var pdfFiles: [String] {
        guard !isWelcome else { return [] }
        return [p("Downloads/Home loan agreement (scanned).pdf"), p("Documents/Annual report 2025.pdf"), p("Downloads/Visa application form.pdf")]
    }

    static var pdfResults: [String: FileOutcome] {
        guard !isWelcome else { return [:] }
        var r = shrinkResults
        r[p("Downloads/Visa application form.pdf")] = FileOutcome(ok: true, outputs: [p("Downloads/Visa application form (compressed).pdf")],
                                                                before: 14 * mb, after: 2_600_000, message: "14 MB → 3 MB",
                                                                method: "images downsampled, text and links kept")
        return r
    }

    static var cutoutItems: [MediaItem] {
        guard !isWelcome else { return [] }
        let dir = "/Library/User Pictures/Animals"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().prefix(6).map {
            MediaItem(origin: .file(dir + "/" + $0), kind: .photo, date: ago(days: 2), bytes: 600_000)
        }
    }

    // MARK: Health (fictional drive and folders)

    static var diskHealth: DiskHealth? {
        guard !isWelcome else { return nil }
        return DiskHealth(smartStatus: "Verified", model: "APPLE SSD AP0512Z", percentUsed: 3, availableSpare: 100, spareThreshold: 99,
                          temperatureC: 36, powerOnHours: 2_140, bytesWritten: 61_000 * gb, bytesRead: 74_000 * gb,
                          unsafeShutdowns: 12, mediaErrors: 0, criticalWarning: 0)
    }

    static var externalVolumes: [ExternalVolume] {
        guard !isWelcome else { return [] }
        return [ExternalVolume(path: "/Volumes/Backup SSD", name: "Backup SSD", free: 640 * gb, capacity: 1_000 * gb, format: "APFS")]
    }

    static var archiveItems: [(String, Int64)] {
        guard !isWelcome else { return [] }
        return [(p("Movies/2023 Family trip raw footage"), 48 * gb), (p("Documents/Old projects/client-site-2022"), 6 * gb),
                (p("Downloads/Ubuntu-22.04-desktop.iso"), 4_700 * mb)]
    }

    static var watchedFolders: [WatchedFolder] {
        guard !isWelcome else { return [] }
        return [WatchedFolder(path: p("Downloads"), limitBytes: 20 * gb, lastBytes: 23_400 * mb),
                WatchedFolder(path: p("Movies/Screen Recordings"), limitBytes: 50 * gb, lastBytes: 12_100 * mb)]
    }
}
