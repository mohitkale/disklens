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
}
