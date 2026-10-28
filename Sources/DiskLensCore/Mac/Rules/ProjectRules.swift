#if os(macOS)
import Foundation


/// node_modules folders in your projects. Re-created by `npm install`.
struct NodeModulesRule: CleanupRule {
    let name = "node_modules"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let index: HomeIndex
        if let existing = ctx.homeIndex { index = existing } else { index = await HomeIndex.build(home: ctx.home) }
        let folders = Array(Set(index.nodeModules))
        guard !folders.isEmpty else { return [] }
        let sizes = await DiskMeasure.sizes(of: folders)

        let items = folders.compactMap { folder -> FindingItem? in
            guard let bytes = sizes[folder], bytes > 1_000_000 else { return nil }
            let project = (folder as NSString).deletingLastPathComponent
            let active = Self.lastActive(project)
            let days = RuleKit.days(since: active)
            let recent = (days ?? 999) < 14
            let kind = Self.projectKind(project)
            let note = "\(kind.framework) · \(kind.manager)" + (recent ? " · worked on recently, not preselected" : "")
            return FindingItem(path: folder, bytes: bytes, note: note, selectedByDefault: !recent,
                               lastUsed: active, usedBy: (project as NSString).lastPathComponent)
        }.sorted { $0.bytes > $1.bytes }

        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        let stale = items.filter { (RuleKit.days(since: $0.lastUsed) ?? 0) >= 180 }
        let managers = Set(items.compactMap { $0.note?.split(separator: "·").dropFirst().first?.trimmingCharacters(in: .whitespaces) })
        return [Finding(
            id: "node-modules", title: "node_modules in \(items.count) projects",
            detail: "Installed JavaScript dependencies. Projects you worked on in the last 2 weeks aren't preselected.",
            tier: .safe, bytes: RuleKit.total(items), items: items, action: .trash,
            afterNote: "Run `npm install` (or `yarn` / `pnpm install`) when you next open one of these projects.",
            revealPath: ctx.home, symbol: "shippingbox.fill",
            facts: [Fact("Projects", "\(items.count) found across your home folder"),
                    Fact("Untouched 6+ months", "\(stale.count) projects · \(ByteFormat.string(RuleKit.total(stale)))", stale.isEmpty ? .info : .good),
                    Fact("Package managers", managers.sorted().joined(separator: ", ")),
                    Fact("Get it back", "`npm install` in the project (needs internet)")],
            risk: "A project won't run until you reinstall its dependencies. Projects that pin old packages may not reinstall cleanly.")]
    }

    /// Newest change among the project's manifest, lock files and git metadata.
    static func lastActive(_ project: String) -> Date? {
        let markers = ["package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", ".git/HEAD", ".git/index"]
        return markers.compactMap { RuleKit.modified("\(project)/\($0)") }.max()
    }

    static func projectKind(_ project: String) -> (framework: String, manager: String) {
        let pkg = RuleKit.readJSON(project + "/package.json")
        let deps = ((pkg?["dependencies"] as? [String: Any]) ?? [:]).merging((pkg?["devDependencies"] as? [String: Any]) ?? [:]) { a, _ in a }
        let framework: String = deps["expo"] != nil ? "Expo" : deps["react-native"] != nil ? "React Native"
            : deps["next"] != nil ? "Next.js" : deps["electron"] != nil ? "Electron" : deps["@remix-run/react"] != nil ? "Remix"
            : deps["vite"] != nil ? "Vite" : deps["react"] != nil ? "React" : deps["vue"] != nil ? "Vue" : "Node.js"
        let manager = DiskMeasure.exists(project + "/pnpm-lock.yaml") ? "pnpm" : DiskMeasure.exists(project + "/yarn.lock") ? "yarn"
            : DiskMeasure.exists(project + "/bun.lockb") ? "bun" : "npm"
        return (framework, manager)
    }
}

/// Android SDK pieces that no project pins and no emulator uses.
struct AndroidSdkRule: CleanupRule {
    let name = "Android SDK"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let sdk = ctx.path("~/Library/Android/sdk")
        guard DiskMeasure.isDirectory(sdk) else { return [] }
        let pins = await Self.projectPins(ctx)
        var items: [FindingItem] = []
        var kept: [String] = []

        func describe(_ version: String, _ projects: Set<String>?) -> String {
            guard let projects, !projects.isEmpty else { return version + " (newest)" }
            return "\(version) (used by \(projects.sorted().joined(separator: ", ")))"
        }

        // Legacy side-by-side NDK location.
        let bundle = sdk + "/ndk-bundle"
        if DiskMeasure.exists(bundle) {
            let rev = Self.revision(bundle) ?? "?"
            if pins.ndk[rev] == nil, let bytes = await DiskMeasure.size(of: bundle) {
                items.append(FindingItem(path: bundle, bytes: bytes, note: "deprecated ndk-bundle (NDK \(rev))", lastUsed: RuleKit.modified(bundle), usedBy: "no project"))
            } else {
                kept.append("ndk-bundle \(rev)")
            }
        }

        // NDKs: keep pinned ones and the newest.
        let ndkDirs = DiskMeasure.listDirectory(sdk + "/ndk").filter(DiskMeasure.isDirectory)
        let ndkVersions = ndkDirs.map { ($0 as NSString).lastPathComponent }
        let ndk = Versions.partition(ndkVersions, pinned: Set(pins.ndk.keys), keepNewest: 1)
        kept += ndk.keep.map { "NDK " + describe($0, pins.ndk[$0]) }
        for v in ndk.remove {
            let p = "\(sdk)/ndk/\(v)"
            let bytes = await DiskMeasure.size(of: p) ?? 0
            items.append(FindingItem(path: p, bytes: bytes, note: bytes < 1_000_000 ? "NDK \(v): empty folder" : "NDK \(v)", lastUsed: RuleKit.modified(p), usedBy: "no project"))
        }

        // Build tools: keep pinned ones and the 3 newest stable releases.
        let btVersions = DiskMeasure.listDirectory(sdk + "/build-tools").filter(DiskMeasure.isDirectory).map { ($0 as NSString).lastPathComponent }
        let bt = Versions.partition(btVersions, pinned: Set(pins.buildTools.keys), keepNewest: 3)
        if !bt.keep.isEmpty {
            kept.append("build-tools " + bt.keep.map { v in
                pins.buildTools[v].map { "\(v) (used by \($0.sorted().joined(separator: ", ")))" } ?? v
            }.joined(separator: ", "))
        }
        for v in bt.remove {
            let p = "\(sdk)/build-tools/\(v)"
            let bytes = await DiskMeasure.size(of: p) ?? 0
            items.append(FindingItem(path: p, bytes: bytes, note: "build-tools \(v)" + (Versions.isPrerelease(v) ? " (pre-release)" : " (older, not pinned)"), lastUsed: RuleKit.modified(p), usedBy: "no project"))
        }

        // System images not referenced by any emulator (AVD).
        let used = Self.imagesUsedByEmulators(ctx)
        for api in DiskMeasure.listDirectory(sdk + "/system-images").filter(DiskMeasure.isDirectory) {
            let name = (api as NSString).lastPathComponent
            if used.contains(where: { $0.hasPrefix("system-images/\(name)/") }) {
                kept.append("system image \(name) (used by an emulator)")
                continue
            }
            let bytes = await DiskMeasure.size(of: api) ?? 0
            items.append(FindingItem(path: api, bytes: bytes, note: "emulator image \(name)", lastUsed: RuleKit.modified(api), usedBy: "no emulator"))
        }

        for leftover in [".downloadIntermediates", ".temp"] {
            let p = "\(sdk)/\(leftover)"
            if let bytes = await DiskMeasure.size(of: p), bytes > 1_000_000 {
                items.append(FindingItem(path: p, bytes: bytes, note: "interrupted SDK Manager downloads", lastUsed: RuleKit.modified(p), usedBy: "nothing"))
            }
        }

        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        let studio = "com.google.android.studio"
        return [Finding(
            id: "android-sdk", title: "Android SDK leftovers",
            detail: "SDK components that none of your projects pin and no emulator uses. If a project needs one later, Gradle or the Android Studio SDK Manager downloads it again.",
            tier: .safe, bytes: RuleKit.total(items), items: items.sorted { $0.bytes > $1.bytes }, action: .trash,
            kept: kept.isEmpty ? nil : kept.joined(separator: " · "),
            quitApps: [studio], revealPath: sdk, symbol: "cpu",
            facts: [Fact("Projects checked", "\(Set(pins.ndk.values.flatMap { $0 } + pins.buildTools.values.flatMap { $0 }).count) Android projects with version pins"),
                    Fact("Emulators", used.isEmpty ? "none set up" : "\(used.count) set up"),
                    Fact("Android Studio last opened", ctx.app("com.google.android.studio")?.lastUsed.map(RuleKit.relativeAge) ?? "not installed"),
                    Fact("Get it back", "Gradle or SDK Manager downloads it when a project asks")],
            risk: "A project that needs one of these versions downloads it again on its next build (needs internet).")]
    }

    static func revision(_ ndkPath: String) -> String? {
        guard let text = try? String(contentsOfFile: ndkPath + "/source.properties", encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.contains("Pkg.Revision") }?
            .split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
    }

    /// NDK and build-tools versions pinned by Gradle files (and React Native's version catalog).
    static func projectPins(_ ctx: RuleContext) async -> AndroidPins {
        var pins = AndroidPins()
        let index: HomeIndex
        if let existing = ctx.homeIndex { index = existing } else { index = await HomeIndex.build(home: ctx.home) }
        var files = index.gradleFiles
        // React Native projects pin their NDK in node_modules/react-native's version catalog.
        for gradle in index.gradleFiles {
            guard let range = gradle.range(of: "/android/") else { continue }
            let catalog = gradle[..<range.lowerBound] + "/node_modules/react-native/gradle/libs.versions.toml"
            if DiskMeasure.exists(String(catalog)) { files.append(String(catalog)) }
        }
        for file in Set(files) {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            pins.merge(text: text, project: projectName(for: file, root: ctx.home))
        }
        return pins
    }

    static func projectName(for file: String, root: String) -> String {
        var path = file
        if let range = path.range(of: "/node_modules/") { path = String(path[..<range.lowerBound]) }
        else if let range = path.range(of: "/android/") { path = String(path[..<range.lowerBound]) }
        else { path = (path as NSString).deletingLastPathComponent }
        return (path as NSString).lastPathComponent
    }

    static func imagesUsedByEmulators(_ ctx: RuleContext) -> [String] {
        DiskMeasure.listDirectory(ctx.path("~/.android/avd")).filter { $0.hasSuffix(".avd") }.compactMap { avd in
            guard let text = try? String(contentsOfFile: avd + "/config.ini", encoding: .utf8) else { return nil }
            return text.split(separator: "\n").first { $0.hasPrefix("image.sysdir.1") }?
                .split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
        }
    }
}
#endif
