#if os(macOS)
import AppKit
import Foundation

/// An installed app with its size and the data it keeps in your Library.
public struct AppFootprint: Identifiable, Hashable, Sendable {
    public var id: String { app.path }
    public let app: InstalledApp
    public let appBytes: Int64
    public let leftovers: [FindingItem]
    public var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: Int64 { appBytes + leftoverBytes }

    public init(app: InstalledApp, appBytes: Int64, leftovers: [FindingItem]) {
        self.app = app
        self.appBytes = appBytes
        self.leftovers = leftovers
    }
}

public enum AppUninstaller {
    /// Library folders where apps keep data, and how an entry there is named.
    static let locations: [(folder: String, byName: Bool, kind: String)] = [
        ("~/Library/Application Support", true, "app data"),
        ("~/Library/Caches", true, "cache"),
        ("~/Library/Containers", false, "sandbox container"),
        ("~/Library/Preferences", false, "settings"),
        ("~/Library/Preferences/ByHost", false, "settings"),
        ("~/Library/Saved Application State", false, "saved window state"),
        ("~/Library/HTTPStorages", false, "web storage"),
        ("~/Library/WebKit", false, "web data"),
        ("~/Library/Logs", true, "logs"),
        ("~/Library/Cookies", false, "cookies"),
        ("~/Library/LaunchAgents", false, "background helper"),
        ("~/Library/Application Scripts", false, "scripts"),
    ]

    /// Apps you can uninstall: not Apple's, not in /System, not DiskLens itself.
    public static func removableApps(_ apps: [InstalledApp]) -> [InstalledApp] {
        apps.filter { app in
            guard let id = app.bundleID else { return false }
            return !id.hasPrefix("com.apple.") && id != Bundle.main.bundleIdentifier && !app.path.hasPrefix("/System")
        }
    }

    /// Everything an app keeps in your Library, matched by its bundle ID or its exact name.
    /// Names shared with another installed app are skipped, so nothing another app needs is touched.
    public static func leftovers(for app: InstalledApp, allApps: [InstalledApp], home: String = NSHomeDirectory()) async -> [FindingItem] {
        guard let id = app.bundleID else { return [] }
        let otherNames = Set(allApps.filter { $0.path != app.path }.map { $0.name.lowercased() })
        let otherIDs = allApps.filter { $0.path != app.path }.compactMap(\.bundleID)
        var paths: [(String, String)] = []
        for loc in locations {
            let folder = loc.folder.replacingOccurrences(of: "~", with: home)
            for entry in DiskMeasure.listDirectory(folder) {
                let name = (entry as NSString).lastPathComponent
                let lower = name.lowercased()
                let stem = ((lower as NSString).deletingPathExtension as NSString).deletingPathExtension
                let byID = lower == id.lowercased() || stem == id.lowercased()
                    || lower.hasPrefix(id.lowercased() + ".") && !otherIDs.contains { lower.hasPrefix($0.lowercased()) }
                let byName = loc.byName && lower == app.name.lowercased() && !otherNames.contains(lower)
                if byID || byName { paths.append((entry, loc.kind)) }
            }
        }
        // Group containers are named after the developer's team (e.g. "ABCDE12345.com.example.app").
        for entry in DiskMeasure.listDirectory(home + "/Library/Group Containers") {
            let lower = (entry as NSString).lastPathComponent.lowercased()
            if lower.hasSuffix("." + id.lowercased()) || lower == "group." + id.lowercased() { paths.append((entry, "shared container")) }
        }
        let sizes = await DiskMeasure.sizes(of: paths.map(\.0))
        return paths.map { path, kind in
            FindingItem(path: path, bytes: sizes[path] ?? 0, note: kind, lastUsed: RuleKit.modified(path), usedBy: app.name, quickSafe: false)
        }.sorted { $0.bytes > $1.bytes }
    }

    public static func footprints(apps: [InstalledApp], progress: @escaping @Sendable (Int, Int) -> Void) async -> [AppFootprint] {
        let removable = removableApps(apps)
        var result: [AppFootprint] = []
        for (i, app) in removable.enumerated() {
            progress(i, removable.count)
            let bytes = await DiskMeasure.size(of: app.path) ?? 0
            let leftovers = await leftovers(for: app, allApps: apps)
            result.append(AppFootprint(app: app, appBytes: bytes, leftovers: leftovers))
        }
        progress(removable.count, removable.count)
        return result.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// Data in your Library named after an app that isn't installed any more.
    public static func orphanedLeftovers(apps: [InstalledApp], home: String = NSHomeDirectory()) async -> [FindingItem] {
        let installed = Set(apps.compactMap { $0.bundleID?.lowercased() })
        var candidates: [String] = []
        for folder in ["~/Library/Application Support", "~/Library/Containers", "~/Library/Caches", "~/Library/Saved Application State",
                       "~/Library/HTTPStorages", "~/Library/WebKit"] {
            for entry in DiskMeasure.listDirectory(folder.replacingOccurrences(of: "~", with: home)) {
                var id = (entry as NSString).lastPathComponent
                if id.hasSuffix(".savedState") { id = (id as NSString).deletingPathExtension }
                guard looksLikeBundleID(id), !id.lowercased().hasPrefix("com.apple."), !installed.contains(id.lowercased()) else { continue }
                // Still registered somewhere on disk (e.g. a helper, or an app outside /Applications): not an orphan.
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { continue }
                if installed.contains(where: { id.lowercased().hasPrefix($0 + ".") || $0.hasPrefix(id.lowercased() + ".") }) { continue }
                candidates.append(entry)
            }
        }
        let sizes = await DiskMeasure.sizes(of: candidates)
        return candidates.compactMap { path in
            guard let bytes = sizes[path], bytes >= 1_000_000 else { return nil }
            var id = (path as NSString).lastPathComponent
            if id.hasSuffix(".savedState") { id = (id as NSString).deletingPathExtension }
            let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return FindingItem(path: path, bytes: bytes, note: "\(folder) · no app with this ID is installed", selectedByDefault: false,
                               lastUsed: RuleKit.modified(path), usedBy: id, quickSafe: false)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// "com.example.app", "org.mozilla.firefox", not "Google" or "Caches".
    public static func looksLikeBundleID(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil
    }
}

/// Things that start with your Mac or run in the background, and browser extensions. Read-only.
public struct StartupItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case userAgent = "Starts when you log in", systemAgent = "Starts for every user", daemon = "Runs in the background (system)" }
    public var id: String { path }
    public let path: String
    public let label: String
    public let program: String?
    public let kind: Kind
    public let runsAtLoad: Bool
    public let keepAlive: Bool
    /// The app it belongs to, if its program is inside an app bundle.
    public let owner: String?
    public let modified: Date?

    public init(path: String, label: String, program: String?, kind: Kind, runsAtLoad: Bool, keepAlive: Bool, owner: String?, modified: Date?) {
        self.path = path
        self.label = label
        self.program = program
        self.kind = kind
        self.runsAtLoad = runsAtLoad
        self.keepAlive = keepAlive
        self.owner = owner
        self.modified = modified
    }
}

public struct BrowserExtension: Identifiable, Hashable, Sendable {
    public var id: String { browser + "/" + identifier }
    public let browser: String
    public let name: String
    public let identifier: String
    public let version: String?
    public let path: String
    public let permissions: [String]

    public init(browser: String, name: String, identifier: String, version: String?, path: String, permissions: [String]) {
        self.browser = browser
        self.name = name
        self.identifier = identifier
        self.version = version
        self.path = path
        self.permissions = permissions
    }
}

public enum StartupInspector {
    public static func items(home: String = NSHomeDirectory()) -> [StartupItem] {
        let folders: [(String, StartupItem.Kind)] = [(home + "/Library/LaunchAgents", .userAgent), ("/Library/LaunchAgents", .systemAgent),
                                                     ("/Library/LaunchDaemons", .daemon)]
        return folders.flatMap { folder, kind in
            DiskMeasure.listDirectory(folder).filter { $0.hasSuffix(".plist") }.compactMap { path -> StartupItem? in
                guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
                let label = dict["Label"] as? String ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
                let owner = program.flatMap { p -> String? in
                    guard let r = p.range(of: ".app/") else { return nil }
                    return ((String(p[..<r.lowerBound]) as NSString).lastPathComponent)
                }
                let keepAlive = (dict["KeepAlive"] as? Bool) ?? (dict["KeepAlive"] is [String: Any])
                return StartupItem(path: path, label: label, program: program, kind: kind, runsAtLoad: dict["RunAtLoad"] as? Bool ?? false,
                                   keepAlive: keepAlive, owner: owner, modified: RuleKit.modified(path))
            }
        }.sorted { ($0.owner ?? $0.label).lowercased() < ($1.owner ?? $1.label).lowercased() }
    }

    /// Extensions in Chrome-family browsers (Chrome, Brave, Edge, Arc, Vivaldi, Opera) and Firefox.
    public static func browserExtensions(home: String = NSHomeDirectory()) -> [BrowserExtension] {
        let chromium: [(String, String)] = [("Google Chrome", "Google/Chrome"), ("Brave", "BraveSoftware/Brave-Browser"),
                                            ("Microsoft Edge", "Microsoft Edge"), ("Arc", "Arc/User Data"), ("Vivaldi", "Vivaldi"),
                                            ("Opera", "com.operasoftware.Opera"), ("Comet", "Comet")]
        var out: [BrowserExtension] = []
        for (browser, folder) in chromium {
            let root = home + "/Library/Application Support/" + folder
            let profiles = DiskMeasure.listDirectory(root).filter { p in
                let n = (p as NSString).lastPathComponent
                return n == "Default" || n.hasPrefix("Profile ")
            }
            for profile in profiles {
                for ext in DiskMeasure.listDirectory(profile + "/Extensions") {
                    let id = (ext as NSString).lastPathComponent
                    guard let version = DiskMeasure.listDirectory(ext).filter(DiskMeasure.isDirectory).sorted().last,
                          let manifest = RuleKit.readJSON(version + "/manifest.json") else { continue }
                    let name = localized(manifest["name"] as? String ?? id, in: version, defaultLocale: manifest["default_locale"] as? String)
                    if name.hasPrefix("__MSG_") || id == "Temp" { continue }
                    let perms = ((manifest["permissions"] as? [Any]) ?? []).compactMap { $0 as? String }
                        + ((manifest["host_permissions"] as? [String]) ?? [])
                    out.append(BrowserExtension(browser: browser, name: name, identifier: id, version: manifest["version"] as? String,
                                                path: ext, permissions: perms))
                }
            }
        }
        for profile in DiskMeasure.listDirectory(home + "/Library/Application Support/Firefox/Profiles") {
            guard let json = RuleKit.readJSON(profile + "/extensions.json"), let addons = json["addons"] as? [[String: Any]] else { continue }
            for a in addons where (a["location"] as? String) == "app-profile" {
                let name = ((a["defaultLocale"] as? [String: Any])?["name"] as? String) ?? (a["id"] as? String ?? "?")
                let perms = ((a["userPermissions"] as? [String: Any])?["origins"] as? [String]) ?? []
                out.append(BrowserExtension(browser: "Firefox", name: name, identifier: a["id"] as? String ?? name, version: a["version"] as? String,
                                            path: profile + "/extensions", permissions: perms))
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.sorted { ($0.browser, $0.name.lowercased()) < ($1.browser, $1.name.lowercased()) }
    }

    /// Extensions with access to every website can read what you type on any page.
    public static func readsAllSites(_ e: BrowserExtension) -> Bool {
        e.permissions.contains { $0 == "<all_urls>" || $0 == "*://*/*" || $0 == "http://*/*" || $0 == "https://*/*" }
    }

    static func localized(_ name: String, in folder: String, defaultLocale: String?) -> String {
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        for locale in [defaultLocale, "en", "en_US"].compactMap({ $0 }) {
            if let messages = RuleKit.readJSON(folder + "/_locales/\(locale)/messages.json") {
                for (k, v) in messages where k.lowercased() == key {
                    if let m = (v as? [String: Any])?["message"] as? String { return m }
                }
            }
        }
        return name
    }
}
#endif
