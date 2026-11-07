import AppKit
import DiskLensCore
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--scan") {
            Task {
                if CommandLine.arguments.contains("--privacy") { await Headless.privacy() }
                else if CommandLine.arguments.contains("--duplicates") { await Headless.duplicates() }
                else if CommandLine.arguments.contains("--quick") { await Headless.quick() } else {
                    await Headless.scan(json: CommandLine.arguments.contains("--json"))
                }
                exit(0)
            }
            dispatchMain()
        } else {
            DiskLensApp.main()
        }
    }
}

/// `DiskLens --scan [--json]`: runs a full read-only scan and prints it. Never cleans or saves anything.
enum Headless {
    static func scan(json: Bool) async {
        let started = Date()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let result = await Scanner.scan(codeRoots: RuleContext.defaultCodeRoots, runningBundleIDs: running) { message in
            if !json { FileHandle.standardError.write(Data("… \(message)\n".utf8)) }
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            struct Output: Encodable { let snapshot: Snapshot; let findings: [Finding] }
            if let data = try? encoder.encode(Output(snapshot: result.snapshot, findings: result.findings)) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        let s = result.snapshot
        print("Capacity \(ByteFormat.string(s.capacity)) · free \(ByteFormat.string(s.free)) · system \(ByteFormat.string(s.system)) · hidden \(ByteFormat.string(s.hidden)) · Full Disk Access: \(result.hasFullDiskAccess)")
        for c in s.categories { print(String(format: "  %-22@ %@", c.name as NSString, ByteFormat.string(c.bytes) as NSString)) }
        print("\nFindings:")
        for f in result.findings {
            let selected = Set(f.items.filter(\.selectedByDefault).map(\.path))
            print("[\(f.tier.label)] \(f.title) — \(ByteFormat.string(f.bytes(selected: selected)))\(f.action.commandLine.map { "  (\($0))" } ?? "")")
            if let kept = f.kept { print("    kept: \(kept)") }
            for fact in f.facts { print("    · \(fact.label): \(fact.value)") }
            for item in f.items.prefix(6) { printItem(item) }
            if f.items.count > 8 { print("    … \(f.items.count - 8) more") }
        }
        print(String(format: "\nScan took %.0fs", Date().timeIntervalSince(started)))
    }

    static func printItem(_ item: FindingItem) {
        let used = item.lastUsed.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""
        print("    \(item.selectedByDefault ? "☑" : "☐") \(ByteFormat.string(item.bytes))  \(item.name) [\(item.usedBy ?? "-")\(used)]\(item.note.map { " — \($0)" } ?? "")")
    }

    static func quick() async {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let r = await Scanner.quickScan(runningBundleIDs: running) { _ in }
        let total = r.findings.reduce(0) { $0 + $1.bytes }
        print(String(format: "Quick scan: %@ in %d findings, %.0fs", ByteFormat.string(total), r.findings.count, r.duration))
        for f in r.findings {
            print("• \(f.title) — \(ByteFormat.string(f.bytes))\(f.action.commandLine.map { "  (\($0))" } ?? "")")
            for item in f.items.prefix(4) { printItem(item) }
        }
        for a in r.advice { print("ℹ︎ \(a.title) — \(ByteFormat.string(a.bytes))") }
    }

    /// Counts only: never prints file names, people or coordinates.
    static func privacy() async {
        let started = Date()
        let reports = await PrivacyScanner.scan(folders: PrivacyScanner.defaultFolders) { _, _ in }
        let located = reports.filter(\.revealsLocation)
        let spots = Hotspots.find(reports)
        print("Privacy scan: \(reports.count) files reveal something, \(located.count) reveal location, "
              + "\(reports.filter { $0.device != nil }.count) device, \(reports.filter { !$0.serials.isEmpty }.count) serial numbers, "
              + "\(reports.filter { !$0.people.isEmpty }.count) names. Hotspots: \(spots.count) (busiest: \(spots.first.map { "\($0.files.count) files on \($0.days) days" } ?? "none")).")
        for kind in [MetadataReport.Kind.image, .video, .pdf, .office] {
            print("  \(kind.rawValue): \(reports.filter { $0.kind == kind }.count)")
        }
        print(String(format: "Took %.0fs", Date().timeIntervalSince(started)))
    }

    static func duplicates() async {
        let started = Date()
        let groups = await DuplicateFinder.scan(roots: DuplicateFinder.defaultRoots) { _ in }
        let reclaim = groups.reduce(0) { $0 + $1.reclaimable }
        let clones = groups.reduce(0) { $0 + $1.clonePaths.count }
        print("Duplicates: \(groups.count) groups, \(groups.reduce(0) { $0 + $1.files.count }) files, \(ByteFormat.string(reclaim)) reclaimable, \(clones) APFS clones (free nothing).")
        print(String(format: "Took %.0fs", Date().timeIntervalSince(started)))
    }
}
