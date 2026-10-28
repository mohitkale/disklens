import AppKit
import DiskLensCore
import Observation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview, cleanup, explore, history
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Clean Up"
        case .explore: "Explore"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cleanup: "sparkles"
        case .explore: "folder"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct FolderEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let isDirectory: Bool
    var name: String { (path as NSString).lastPathComponent }
}

/// One finding inside a cleanup the user is reviewing.
struct PlanEntry: Identifiable {
    enum Status {
        case checking, ready, blocked([String]), running, done(ExecutionResult)
    }

    var id: String { finding.id }
    let finding: Finding
    let items: [FindingItem]
    var included = true
    var status: Status = .checking

    var bytes: Int64 {
        finding.action == .trash && !finding.items.isEmpty ? items.reduce(0) { $0 + $1.bytes } : finding.bytes
    }

    var isReady: Bool { if case .ready = status { true } else { false } }
    var isBlocked: Bool { if case .blocked = status { true } else { false } }
}

/// A cleanup being reviewed, run, or summarised. Nothing runs until the user confirms.
struct CleanupPlan: Identifiable {
    enum Kind { case selection, quick }
    enum Phase: Equatable { case scanning, review, running, finished }

    let id = UUID()
    let kind: Kind
    var phase: Phase
    var entries: [PlanEntry] = []
    /// Helpful notes that aren't actions (restart for temp files).
    var advice: [Finding] = []
    var acknowledged = false
    var quickScanDuration: Double?

    var included: [PlanEntry] { entries.filter { $0.included && $0.isReady } }
    var includedBytes: Int64 { included.reduce(0) { $0 + $1.bytes } }
    var permanentCount: Int { included.filter { !$0.finding.isReversible }.count }
    var trashCount: Int { included.filter { $0.finding.isReversible }.count }
    var stillChecking: Bool { entries.contains { if case .checking = $0.status { true } else { false } } }
    /// Review-tier or irreversible actions need an explicit "I understand".
    var needsAcknowledgement: Bool { included.contains { !$0.finding.isReversible || $0.finding.tier == .review } }
    var canRun: Bool { !included.isEmpty && !stillChecking && (!needsAcknowledgement || acknowledged) }

    var results: [(Finding, ExecutionResult)] {
        entries.compactMap { if case let .done(r) = $0.status { ($0.finding, r) } else { nil } }
    }
}

struct Insight: Identifiable {
    enum Action { case finding(String), section(AppSection), fullDiskAccess, quickClean }
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var action: Action?
    var actionLabel: String?
}

@MainActor
@Observable
final class AppModel {
    var section: AppSection = .overview
    private(set) var snapshots: [Snapshot] = []
    private(set) var log: [LogEntry] = []
    private(set) var findings: [Finding] = []
    /// When the current findings were produced.
    private(set) var findingsDate: Date?
    var selections: [String: Set<String>] = [:]
    var selectedFindingIDs: Set<String> = []
    private(set) var completed: [String: ExecutionResult] = [:]
    private(set) var isScanning = false
    private(set) var isQuickScanning = false
    private(set) var progress = ""
    private(set) var hasFullDiskAccess = DiskMeasure.hasFullDiskAccess()
    var plan: CleanupPlan?
    /// Which tier Clean Up shows (nil = all).
    var cleanupFilter: Tier?
    /// Quick rules that found something in the last full scan.
    private(set) var profile: [String]?
    let volumeName = DiskMeasure.volumeName()
    var explorePath: [String] = []
    /// Scrolled to and highlighted when jumping from an insight.
    var focusedFindingID: String?
    private(set) var folderCache: [String: [FolderEntry]] = [:]

    private let store = HistoryStore()

    init() {
        if DemoData.isEnabled {
            snapshots = DemoData.snapshots
            log = DemoData.log
            findings = DemoData.findings
            findingsDate = snapshots.last?.date
            hasFullDiskAccess = true
            resetSelections()
            return
        }
        snapshots = store.loadSnapshots()
        log = store.loadLog()
        if let cached = store.loadFindings() {
            findings = cached.findings
            findingsDate = cached.date
            profile = cached.profile
            resetSelections()
        }
    }

    // MARK: Snapshots

    var latest: Snapshot? { snapshots.last }
    var previous: Snapshot? { snapshots.count >= 2 ? snapshots[snapshots.count - 2] : nil }
    var lastFullScan: Snapshot? { snapshots.last { !$0.categories.isEmpty } }
    var isBusy: Bool { isScanning || isQuickScanning }

    /// Findings older than a day are worth refreshing before cleaning.
    var findingsAreStale: Bool { (findingsDate.map { Date().timeIntervalSince($0) } ?? .infinity) > 86_400 }

    /// No full scan yet on this Mac: the app recommends one first.
    var needsFirstScan: Bool { lastFullScan == nil }

    /// A full scan older than a week is worth repeating: things change.
    var fullScanIsOld: Bool { (lastFullScan.map { Date().timeIntervalSince($0.date) } ?? 0) > 7 * 86_400 }

    var cleanedSinceLastSnapshot: [LogEntry] {
        guard let last = snapshots.last else { return log }
        return log.filter { $0.date > last.date && $0.outcome != .failed }
    }

    // MARK: Full scan

    func scan() async {
        guard !isBusy, !DemoData.isEnabled else { return }
        isScanning = true
        progress = "Starting"
        hasFullDiskAccess = DiskMeasure.hasFullDiskAccess()
        let cleaned = cleanedSinceLastSnapshot
        let result = await Scanner.scan(codeRoots: RuleContext.defaultCodeRoots, runningBundleIDs: runningBundleIDs) { message in
            Task { @MainActor [weak self] in self?.progress = message }
        }

        let label = cleaned.isEmpty ? nil : "After cleaning \(cleaned.count) item\(cleaned.count == 1 ? "" : "s")"
        let s = result.snapshot
        let snapshot = Snapshot(date: s.date, label: label, capacity: s.capacity, free: s.free, system: s.system,
                                hidden: s.hidden, measured: s.measured, trash: s.trash, categories: s.categories,
                                duration: s.duration)
        // Repeated scans with nothing cleaned in between replace each other, so history stays readable.
        if let last = snapshots.last, cleaned.isEmpty, last.label == nil, !last.categories.isEmpty,
           s.date.timeIntervalSince(last.date) < 3600 {
            snapshots.removeLast()
        }
        snapshots.append(snapshot)
        store.saveSnapshots(snapshots)

        findings = result.findings
        findingsDate = s.date
        profile = result.profile
        store.saveFindings(.init(date: s.date, findings: result.findings, profile: result.profile))
        resetSelections()
        completed = [:]
        folderCache = [:]
        hasFullDiskAccess = result.hasFullDiskAccess
        isScanning = false
        progress = ""
    }

    private func resetSelections() {
        selections = Dictionary(uniqueKeysWithValues: findings.map { f in
            (f.id, Set(f.items.filter(\.selectedByDefault).map(\.path)))
        })
        selectedFindingIDs = []
    }

    func deleteSnapshot(_ snapshot: Snapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
        store.saveSnapshots(snapshots)
    }

    // MARK: Findings & selection

    func findings(in tier: Tier?) -> [Finding] {
        findings.filter { tier == nil || $0.tier == tier }
    }

    func selectedItems(_ f: Finding) -> [FindingItem] {
        let selected = selections[f.id] ?? []
        return f.items.filter { selected.contains($0.path) }
    }

    func bytes(_ f: Finding) -> Int64 { f.bytes(selected: selections[f.id] ?? []) }

    func isSelected(_ item: FindingItem, in f: Finding) -> Bool {
        selections[f.id]?.contains(item.path) ?? false
    }

    func setSelected(_ on: Bool, item: FindingItem, in f: Finding) {
        var set = selections[f.id] ?? []
        if on { set.insert(item.path) } else { set.remove(item.path) }
        selections[f.id] = set
        if set.isEmpty { selectedFindingIDs.remove(f.id) }
    }

    func setAll(_ on: Bool, in f: Finding) {
        selections[f.id] = on ? Set(f.items.map(\.path)) : []
        if !on { selectedFindingIDs.remove(f.id) }
    }

    /// Findings that can be ticked for a batch cleanup.
    func isSelectable(_ f: Finding) -> Bool {
        f.action.isExecutable && f.tier != .keep && completed[f.id] == nil
            && (f.action != .trash || f.items.isEmpty || !(selections[f.id] ?? []).isEmpty)
    }

    func toggleFinding(_ f: Finding) {
        if selectedFindingIDs.contains(f.id) { selectedFindingIDs.remove(f.id) } else if isSelectable(f) { selectedFindingIDs.insert(f.id) }
    }

    /// Select every cleanable finding in the given tiers (nil clears the selection).
    func selectTiers(_ tiers: Set<Tier>?) {
        guard let tiers else { selectedFindingIDs = []; return }
        selectedFindingIDs = Set(findings.filter { tiers.contains($0.tier) && isSelectable($0) }.map(\.id))
    }

    var selectedFindings: [Finding] { findings.filter { selectedFindingIDs.contains($0.id) } }

    /// Cleanable findings in the current Clean Up filter.
    var selectableInFilter: [Finding] { findings(in: cleanupFilter).filter(isSelectable) }

    enum SelectionState { case none, some, all }
    var filterSelection: SelectionState {
        let ids = Set(selectableInFilter.map(\.id))
        let picked = ids.intersection(selectedFindingIDs)
        return picked.isEmpty ? .none : picked == ids ? .all : .some
    }

    /// The "Select all" checkbox: selects or clears everything cleanable in the current filter.
    func toggleSelectAllInFilter() {
        let ids = Set(selectableInFilter.map(\.id))
        if filterSelection == .all { selectedFindingIDs.subtract(ids) } else { selectedFindingIDs.formUnion(ids) }
    }

    func showCleanup(_ tier: Tier?) {
        cleanupFilter = tier
        focusedFindingID = nil
        section = .cleanup
    }
    var selectedBytes: Int64 { selectedFindings.reduce(0) { $0 + bytes($1) } }

    /// Space still to be gained in a tier (finished findings excluded).
    func reclaimable(_ tier: Tier) -> Int64 {
        findings.filter { $0.tier == tier && completed[$0.id] == nil }.reduce(0) { $0 + bytes($1) }
    }

    /// What Quick Clean would take care of, from the last full scan.
    var quickCleanEstimate: Int64 {
        findings.filter { $0.quickClean && $0.action.isExecutable && completed[$0.id] == nil }.reduce(0) { total, f in
            total + (f.action == .trash ? f.items.filter(\.quickSafe).reduce(0) { $0 + $1.bytes } : f.bytes)
        }
    }

    private var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    var runningApps: [String: String] {
        Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { ($0, app.localizedName ?? $0) }
        }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Cleanup plans (review → confirm → run)

    func review(_ findings: [Finding]) {
        let entries = findings.map { PlanEntry(finding: $0, items: $0.action == .trash ? selectedItems($0) : $0.items) }
        plan = CleanupPlan(kind: .selection, phase: .review, entries: entries)
        Task { await preflightPlan() }
    }

    func reviewSelected() { review(selectedFindings) }

    /// Quick Scan, then show what Quick Clean would do. Nothing is cleaned until confirmed.
    func quickClean() async {
        guard !isBusy else { return }
        if DemoData.isEnabled {
            let quick = findings.filter { $0.quickClean && $0.action.isExecutable }
            plan = CleanupPlan(kind: .quick, phase: .review,
                               entries: quick.map { PlanEntry(finding: $0, items: $0.items.filter(\.quickSafe)) },
                               advice: findings.filter { $0.id == "temp" })
            await preflightPlan()
            return
        }
        isQuickScanning = true
        plan = CleanupPlan(kind: .quick, phase: .scanning)
        let result = await Scanner.quickScan(runningBundleIDs: runningBundleIDs, profile: profile) { message in
            Task { @MainActor [weak self] in self?.progress = message }
        }
        isQuickScanning = false
        progress = ""
        guard plan?.kind == .quick else { return }
        plan?.entries = result.findings.map { PlanEntry(finding: $0, items: $0.items) }
        plan?.advice = result.advice
        plan?.quickScanDuration = result.duration
        plan?.phase = .review
        await preflightPlan()
    }

    private func preflightPlan() async {
        guard let entries = plan?.entries else { return }
        // Demo data isn't on disk, so it skips the real checks (and never reveals what's running on this Mac).
        if DemoData.isEnabled {
            for i in entries.indices { plan?.entries[i].status = .ready }
            return
        }
        let apps = runningApps
        for entry in entries {
            let problems = await Executor.problems(for: entry.finding, selected: entry.items, runningApps: apps)
            guard let index = plan?.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            plan?.entries[index].status = problems.isEmpty ? .ready : .blocked(problems)
            if !problems.isEmpty { plan?.entries[index].included = false }
        }
    }

    func recheckPlan() {
        guard plan != nil else { return }
        for i in plan!.entries.indices {
            plan!.entries[i].status = .checking
            plan!.entries[i].included = true
        }
        Task { await preflightPlan() }
    }

    func runPlan() async {
        guard var current = plan, current.canRun else { return }
        current.phase = .running
        plan = current
        for entry in current.included {
            guard let index = plan?.entries.firstIndex(where: { $0.id == entry.id }) else { continue }
            plan?.entries[index].status = .running
            let result = await Executor.perform(entry.finding, selected: entry.items)
            plan?.entries[index].status = .done(result)
            completed[entry.finding.id] = result
            selectedFindingIDs.remove(entry.finding.id)

            var detail = entry.finding.action.commandLine ?? "\(result.trashed.count) item(s) moved to the Trash"
            if !result.failures.isEmpty { detail += ". Problems: " + result.failures.joined(separator: "; ") }
            log.insert(LogEntry(title: entry.finding.title, bytes: result.bytes, outcome: result.outcome, detail: detail), at: 0)
        }
        store.saveLog(log)
        plan?.phase = .finished
    }

    func dismissPlan() { plan = nil }

    // MARK: Insights (computed locally from scans and findings)

    var insights: [Insight] {
        var list: [Insight] = []
        if let first = snapshots.first, let last = snapshots.last, first.id != last.id {
            let delta = last.free - first.free
            if abs(delta) > 1_000_000_000 {
                list.append(Insight(id: "trend", symbol: delta > 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill",
                                    tint: delta > 0 ? Theme.safe : Theme.review,
                                    title: "\(delta > 0 ? "+" : "−")\(ByteFormat.string(abs(delta))) free space since \(first.date.formatted(.dateTime.day().month()))",
                                    detail: "From \(ByteFormat.string(first.free)) to \(ByteFormat.string(last.free)) free across \(snapshots.count) scans.",
                                    action: .section(.history), actionLabel: "History"))
            }
            if let days = daysUntilFull {
                list.append(Insight(id: "forecast", symbol: "hourglass", tint: Theme.review,
                                    title: "At this rate the drive fills in about \(days) days",
                                    detail: "Based on how free space changed over your recent scans."))
            }
        }
        if let biggest = findings.filter({ $0.tier == .safe && $0.action.isExecutable && completed[$0.id] == nil }).max(by: { bytes($0) < bytes($1) }) {
            list.append(Insight(id: "biggest", symbol: biggest.symbol, tint: Theme.safe,
                                title: "Biggest safe win: \(biggest.title)",
                                detail: "\(ByteFormat.string(bytes(biggest))) you can clean without breaking anything.",
                                action: .finding(biggest.id), actionLabel: "Review"))
        }
        if let nm = findings.first(where: { $0.id == "node-modules" }) {
            let stale = nm.items.filter { (Self.days($0.lastUsed) ?? 0) >= 180 }
            if !stale.isEmpty {
                let oldest = stale.compactMap(\.lastUsed).min().map { $0.formatted(.relative(presentation: .named)) } ?? "long ago"
                list.append(Insight(id: "stale-projects", symbol: "moon.zzz.fill", tint: CategoryStyle.of("Developer tools").color,
                                    title: "\(stale.count) projects untouched for 6+ months",
                                    detail: "Their node_modules use \(ByteFormat.string(stale.reduce(0) { $0 + $1.bytes })). The oldest was last touched \(oldest).",
                                    action: .finding(nm.id), actionLabel: "See projects"))
            }
        }
        if let sim = findings.filter({ $0.id.hasPrefix("sim-runtime-") }).max(by: { $0.bytes < $1.bytes }),
           let used = sim.facts.first(where: { $0.label == "Last used" }) {
            list.append(Insight(id: "sim", symbol: "iphone.gen3", tint: CategoryStyle.of("Xcode & Simulators").color,
                                title: "\(sim.title) last used \(used.value)",
                                detail: "It takes \(ByteFormat.string(sim.bytes)). If you test on a real device, you may not need it.",
                                action: .finding(sim.id), actionLabel: "Details"))
        }
        if let apps = findings.first(where: { $0.id == "unused-apps" }) {
            list.append(Insight(id: "apps", symbol: "square.grid.2x2.fill", tint: CategoryStyle.of("Applications").color,
                                title: "\(apps.items.count) app\(apps.items.count == 1 ? "" : "s") not opened in 3+ months",
                                detail: "\(apps.items.prefix(3).map { $0.usedBy ?? $0.name }.joined(separator: ", ")): \(ByteFormat.string(apps.items.reduce(0) { $0 + $1.bytes })).",
                                action: .finding(apps.id), actionLabel: "See apps"))
        }
        if let docker = findings.first(where: { $0.id == "docker-not-running" }) {
            list.append(Insight(id: "docker", symbol: "shippingbox.fill", tint: CategoryStyle.of("Docker").color,
                                title: "Docker's \(ByteFormat.string(docker.bytes)) disk can't be inspected",
                                detail: "Docker Desktop isn't running. Start it and scan again to see unused images and caches.",
                                action: .finding(docker.id), actionLabel: "Details"))
        }
        if !hasFullDiskAccess, let hidden = latest?.hidden, hidden > 5_000_000_000 {
            list.append(Insight(id: "fda", symbol: "lock.fill", tint: .secondary,
                                title: "\(ByteFormat.string(hidden)) can't be measured yet",
                                detail: "macOS hides the Trash, iPhone backups and Mail until you grant Full Disk Access.",
                                action: .fullDiskAccess, actionLabel: "Grant access"))
        }
        if let temp = findings.first(where: { $0.id == "temp" }) {
            list.append(Insight(id: "temp", symbol: "arrow.clockwise.circle.fill", tint: Theme.brandStart,
                                title: "A restart frees about \(ByteFormat.string(temp.bytes))",
                                detail: "macOS clears its temporary files on restart."))
        }
        return list
    }

    /// Days until the drive is full, from the free-space trend of scans in the last 30 days (nil if it isn't shrinking).
    var daysUntilFull: Int? {
        let recent = snapshots.filter { $0.date > Date().addingTimeInterval(-30 * 86_400) }
        guard let a = recent.first, let b = recent.last, b.date.timeIntervalSince(a.date) > 2 * 86_400,
              log.filter({ $0.date > a.date }).isEmpty else { return nil }
        let perDay = Double(a.free - b.free) / (b.date.timeIntervalSince(a.date) / 86_400)
        guard perDay > 100_000_000 else { return nil }
        return Int(Double(b.free) / perDay)
    }

    static func days(_ date: Date?) -> Int? {
        date.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 }
    }

    func perform(_ insight: Insight) {
        switch insight.action {
        case let .finding(id):
            cleanupFilter = nil
            section = .cleanup
            focusedFindingID = id
        case let .section(s): section = s
        case .fullDiskAccess: openFullDiskAccessSettings()
        case .quickClean: Task { await quickClean() }
        case nil: break
        }
    }

    // MARK: Finder & system

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if DiskMeasure.isDirectory(path) && !path.hasSuffix(".app") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func revealInParent(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshAccess() {
        guard !DemoData.isEnabled else { return }
        hasFullDiskAccess = DiskMeasure.hasFullDiskAccess()
    }

    // MARK: Explore

    func entries(for path: String) async -> [FolderEntry] {
        if let cached = folderCache[path] { return cached }
        let children = await DiskMeasure.children(of: path).map {
            FolderEntry(path: $0.path, bytes: $0.bytes, isDirectory: DiskMeasure.isDirectory($0.path))
        }
        folderCache[path] = children
        return children
    }

    /// Finds files and folders whose name contains `query` anywhere under `path`, using the local Spotlight index.
    func search(_ query: String, in path: String) async -> [FolderEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let r = await Shell.run("/usr/bin/mdfind", ["-onlyin", path, "-name", q], timeout: 30, captureStderr: false)
        let paths = Array(r.out.split(separator: "\n").map(String.init).prefix(300))
        let dirs = paths.filter(DiskMeasure.isDirectory)
        let dirSizes = await DiskMeasure.sizes(of: Array(dirs.prefix(60)), concurrency: 6)
        return paths.map { p in
            let isDir = DiskMeasure.isDirectory(p)
            let bytes = isDir ? (dirSizes[p] ?? 0)
                : Int64((try? URL(fileURLWithPath: p).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            return FolderEntry(path: p, bytes: bytes, isDirectory: isDir)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Opens a category in Explore: straight into its folder, or the category list if it spans several.
    func explore(_ category: CategoryUsage) {
        explorePath = category.paths.count == 1 ? category.paths : []
        section = .explore
    }
}

extension Date {
    /// "Today 4:45 PM", "Yesterday 9:10 AM", "3 Oct, 2:00 PM".
    var friendly: String {
        let cal = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(self) { return "Today \(time)" }
        if cal.isDateInYesterday(self) { return "Yesterday \(time)" }
        return formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

extension Double {
    /// "1 min 38 s", "17 s".
    var durationText: String {
        let s = Int(rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }
}
