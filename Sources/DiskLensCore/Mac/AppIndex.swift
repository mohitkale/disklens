#if os(macOS)
import CoreServices
import Foundation

public struct InstalledApp: Sendable, Hashable {
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let lastUsed: Date?
    /// Installed from the Mac App Store (or by an admin): Finder/Launchpad should remove it, not DiskLens.
    public let isManaged: Bool
}

/// Local facts about apps and files from bundles and Spotlight metadata. No network.
public enum AppIndex {
    public static func installedApps() -> [InstalledApp] {
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        return roots.flatMap { root in
            DiskMeasure.listDirectory(root).filter { $0.hasSuffix(".app") }.map(app(at:))
        }
    }

    public static func app(at path: String) -> InstalledApp {
        let bundle = Bundle(path: path)
        let info = bundle?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let receipt = DiskMeasure.exists(path + "/Contents/_MASReceipt")
        let writable = FileManager.default.isWritableFile(atPath: path)
        return InstalledApp(path: path, name: name, bundleID: bundle?.bundleIdentifier,
                            version: info["CFBundleShortVersionString"] as? String,
                            lastUsed: lastUsed(path), isManaged: receipt || !writable)
    }

    /// When Spotlight last saw the item opened.
    public static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// The site a downloaded file came from, e.g. "github.com".
    public static func downloadSource(_ path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else { return nil }
        return sources.lazy.compactMap { URL(string: $0)?.host }.first
    }

    /// Who owns a cache or data folder, from its name.
    public static func owner(ofFolder name: String, apps: [InstalledApp]) -> (owner: String, lastUsed: Date?)? {
        if let app = apps.first(where: { $0.bundleID?.caseInsensitiveCompare(name) == .orderedSame }) {
            return (app.name, app.lastUsed)
        }
        if let ids = vendorApps[name] {
            let matches = apps.filter { app in ids.contains { app.bundleID == $0 } }
            if !matches.isEmpty {
                return (matches.map(\.name).joined(separator: ", "), matches.compactMap(\.lastUsed).max())
            }
        }
        if let tool = tools[name] { return (tool, nil) }
        // "AndroidStudio2024.2" → Android Studio, "Firefox" → Firefox.
        let folder = letters(name)
        if let app = apps.filter({ letters($0.name).count >= 4 && folder.hasPrefix(letters($0.name)) })
            .max(by: { $0.name.count < $1.name.count }) {
            return (app.name, app.lastUsed)
        }
        return nil
    }

    private static func letters(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) })
    }

    static let vendorApps: [String: [String]] = [
        "Google": ["com.google.Chrome", "com.google.android.studio"],
        "BraveSoftware": ["com.brave.Browser"],
        "Firefox": ["org.mozilla.firefox"],
        "Mozilla": ["org.mozilla.firefox"],
        "Comet": ["ai.perplexity.comet"],
        "Microsoft": ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.teams2"],
        "Slack": ["com.tinyspeck.slackmacgap"],
        "Spotify": ["com.spotify.client"],
        "zoom.us": ["us.zoom.xos"],
        "Codex": ["com.openai.codex"],
        "VisualStudio": ["com.microsoft.visual-studio"],
        "VisualStudioInstaller": ["com.microsoft.visual-studio"],
        "JetBrains": ["com.jetbrains.intellij", "com.google.android.studio"],
    ]

    static let tools: [String: String] = [
        "typescript": "TypeScript language service (VS Code, Cursor)",
        "Cypress": "Cypress test runner (npm)",
        "ms-playwright": "Playwright test browsers (npm)",
        "ms-playwright-go": "Playwright for Go",
        "pip": "Python pip",
        "puccinialin": "Rust toolchain used by Python builds",
        "Yarn": "Yarn package manager",
        "CocoaPods": "CocoaPods",
        "node-gyp": "node-gyp (native npm modules)",
        "copilot": "GitHub Copilot",
        "Homebrew": "Homebrew",
        "pnpm": "pnpm",
        "go-build": "Go compiler",
        "Cursor": "Cursor",
        "antigravity-updater": "Antigravity updater",
        "tradingview-desktop-updater": "TradingView updater",
        "com.apple.amp.itmstransporter": "Apple Transporter",
    ]
}
#endif
