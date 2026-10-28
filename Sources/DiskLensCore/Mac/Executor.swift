#if os(macOS)
import Foundation

public struct ExecutionResult: Sendable {
    public let outcome: LogEntry.Outcome
    public let bytes: Int64
    public let trashed: [String]
    public let failures: [String]
    public let output: String
}

/// Runs a finding's cleanup, re-checking everything just before acting.
public enum Executor {
    /// Reasons the action can't run right now. Empty means it's clear to go.
    public static func problems(for finding: Finding, selected: [FindingItem],
                                runningApps: [String: String]) async -> [String] {
        await OpenFileSnapshot.shared.invalidate()
        var problems: [String] = []
        for id in finding.quitApps {
            if let name = runningApps[id] { problems.append("Quit \(name) first.") }
        }

        switch finding.action {
        case .trash:
            if selected.isEmpty { problems.append("Nothing is selected.") }
            let home = NSHomeDirectory()
            for item in selected {
                if isAppBundle(item.path) {
                    let app = AppIndex.app(at: item.path)
                    if let id = app.bundleID, let name = runningApps[id] { problems.append("Quit \(name) first.") }
                    if app.isManaged { problems.append("\(app.name) was installed by the App Store or an administrator. Remove it from Launchpad instead.") }
                    continue
                }
                guard isSafeToTrash(item.path, home: home) else {
                    problems.append("\(item.path) is outside the folders DiskLens is allowed to clean.")
                    continue
                }
                guard DiskMeasure.exists(item.path) else { continue }
                if let open = await DiskMeasure.openFiles(under: item.path, timeout: 20) {
                    if !open.isEmpty { problems.append("\(item.name) is in use by \(RuleKit.processes(open)).") }
                } else {
                    problems.append("Couldn't confirm \(item.name) isn't in use. Try again, or deselect it.")
                }
            }
        case let .command(tool, args):
            if !FileManager.default.isExecutableFile(atPath: tool) {
                problems.append("\((tool as NSString).lastPathComponent) isn't installed.")
            } else if (tool as NSString).lastPathComponent == "docker" {
                let info = await Shell.run(tool, ["info", "--format", "{{.ServerVersion}}"], timeout: 10)
                if !info.ok { problems.append("Docker Desktop isn't running. Start it first.") }
            }
            if args.first == "simctl", args.contains("erase") {
                let booted = await Shell.run(Tools.xcrun, ["simctl", "list", "devices", "booted"], timeout: 20)
                if booted.out.contains("(Booted)") { problems.append("Shut down running simulators first.") }
            }
        default:
            break
        }
        return problems
    }

    public static func perform(_ finding: Finding, selected: [FindingItem]) async -> ExecutionResult {
        switch finding.action {
        case .trash:
            var trashed: [String] = []
            var failures: [String] = []
            var bytes: Int64 = 0
            for item in selected where DiskMeasure.exists(item.path) {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    trashed.append(item.path)
                    bytes += item.bytes
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
            }
            return ExecutionResult(outcome: trashed.isEmpty ? .failed : .trashed, bytes: bytes,
                                   trashed: trashed, failures: failures, output: "")

        case let .command(tool, args):
            let before = DiskMeasure.freeBytes()
            let r = await Shell.run(tool, args, timeout: 1800)
            try? await Task.sleep(for: .seconds(3))
            let freed = max(0, DiskMeasure.freeBytes() - before)
            let output = (r.out + r.err).split(separator: "\n").suffix(12).joined(separator: "\n")
            return ExecutionResult(outcome: r.ok ? .freed : .failed, bytes: r.ok ? freed : 0,
                                   trashed: [], failures: r.ok ? [] : ["Exit code \(r.status)"], output: output)

        default:
            return ExecutionResult(outcome: .failed, bytes: 0, trashed: [], failures: ["Nothing to run."], output: "")
        }
    }

    /// A single app bundle directly inside /Applications or ~/Applications (never a system app).
    public static func isAppBundle(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = (path as NSString).standardizingPath
        let parent = (p as NSString).deletingLastPathComponent
        return p.hasSuffix(".app") && (parent == "/Applications" || parent == home + "/Applications")
    }

    /// Only folders inside your home folder, at least one level below the
    /// well-known top-level folders (or a single app bundle in Applications), can be moved to the Trash.
    public static func isSafeToTrash(_ path: String, home: String) -> Bool {
        if isAppBundle(path, home: home) { return true }
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(home + "/") else { return false }
        let protected = ["", "/Library", "/Library/Caches", "/Library/Application Support", "/Library/Containers",
                         "/Library/Group Containers", "/Library/Developer", "/Library/Android", "/Library/Android/sdk",
                         "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Movies", "/Music", "/Applications",
                         "/.cache", "/.npm", "/.Trash", "/.ssh", "/.gnupg", "/Library/Keychains", "/Library/Mail",
                         "/Library/Mobile Documents"].map { home + $0 }
        if protected.contains(p) { return false }
        if p.hasPrefix(home + "/Library/Keychains") || p.hasPrefix(home + "/.ssh") || p.hasPrefix(home + "/.gnupg") { return false }
        return p.split(separator: "/").count >= 4
    }
}
#endif
