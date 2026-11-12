import AppKit
import DiskLensCore
import Foundation
import UserNotifications

extension AppModel {
    static let archiveOriginalsID = "archive-originals"

    var systemDataParts: [SystemDataPart] {
        guard let s = latest else { return [] }
        return SystemDataExplainer.breakdown(s, findings: findings)
    }

    func refreshHealth() async {
        guard !DemoData.isEnabled else { return }
        diskHealth = await DiskHealth.read()
        externalVolumes = Archiver.externalVolumes()
        if let chosen = archiveVolume, !externalVolumes.contains(chosen) { archiveVolume = nil }
        if archiveVolume == nil { archiveVolume = externalVolumes.first }
    }

    /// Opens Clean Up on the findings that reduce one part of System Data.
    func showFindings(_ ids: [String]) {
        cleanupFilter = nil
        section = .cleanup
        focusedFindingID = ids.first
    }

    // MARK: Archive

    var archiveBytes: Int64 { archiveItems.reduce(0) { $0 + (archiveSizes[$1] ?? 0) } }

    func addArchive(_ paths: [String]) {
        for p in paths where !archiveItems.contains(p) && p.hasPrefix(NSHomeDirectory() + "/") { archiveItems.append(p) }
        Task {
            let sizes = await DiskMeasure.sizes(of: archiveItems.filter { archiveSizes[$0] == nil })
            archiveSizes.merge(sizes) { $1 }
        }
    }

    func chooseArchiveItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "Choose files or folders to copy to the drive. Nothing is removed from your Mac until you review it afterwards."
        guard panel.runModal() == .OK else { return }
        addArchive(panel.urls.map(\.path))
    }

    /// Big files untouched for a year, from the last full scan.
    func addOldFilesToArchive() {
        guard let old = findings.first(where: { $0.id == "old-files" }) else { return }
        addArchive(old.items.map(\.path))
    }

    func chooseArchiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Archive Here"
        panel.message = "Choose a folder on another drive. DiskLens copies into a “DiskLens Archive” folder there."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveCustomFolder = url
    }

    var archiveTarget: URL? { archiveCustomFolder ?? archiveVolume.map { URL(fileURLWithPath: $0.path) } }

    func runArchive() async {
        guard let target = archiveTarget, !archiveItems.isEmpty, archiveProgress == nil, !DemoData.isEnabled else { return }
        archiveResult = nil
        archiveProgress = (0, "Starting")
        let items = archiveItems
        let result = await Archiver.archive(items, to: target) { p, message in
            Task { @MainActor [weak self] in self?.archiveProgress = (p, message) }
        }
        archiveResult = result
        archiveProgress = nil
        if !result.verified.isEmpty {
            addLog(LogEntry(title: "Archived \(result.verified.count) item\(result.verified.count == 1 ? "" : "s") to \(target.lastPathComponent)",
                            bytes: 0, outcome: .freed, detail: "Copied and verified (SHA-256) in \(result.destination?.path ?? target.path). Originals unchanged."))
        }
    }

    /// Verified originals, reviewed, then moved to the Trash.
    func reviewArchivedOriginals() {
        guard let result = archiveResult, let dest = result.destination else { return }
        let items = result.verified.filter { FileManager.default.fileExists(atPath: $0) }.map { path in
            FindingItem(path: path, bytes: archiveSizes[path] ?? 0, note: "verified copy in \(dest.path)", usedBy: "you", quickSafe: false)
        }
        guard !items.isEmpty else { return }
        let finding = Finding(
            id: Self.archiveOriginalsID, title: "Originals now archived (\(items.count))",
            detail: "Each one was copied to \(dest.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent) and checked file by file.",
            tier: .review, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .trash, symbol: "externaldrive.badge.checkmark",
            risk: "Keep the drive safe: once you empty the Trash, the archive is the only copy. A second backup (Time Machine or the cloud) is a good idea.")
        selections[finding.id] = Set(items.map(\.path))
        review([finding])
    }

    func pruneArchive() {
        guard let entry = plan?.entries.first(where: { $0.finding.id == Self.archiveOriginalsID }),
              case let .done(result) = entry.status else { return }
        let gone = Set(result.trashed)
        archiveItems.removeAll { gone.contains($0) }
        completed[Self.archiveOriginalsID] = nil
    }

    // MARK: Watched folders

    func loadWatched() {
        guard let data = UserDefaults.standard.data(forKey: "watchedFolders"),
              let list = try? JSONDecoder().decode([WatchedFolder].self, from: data) else { return }
        watchedFolders = list
    }

    func saveWatched() {
        guard !DemoData.isEnabled, let data = try? JSONEncoder().encode(watchedFolders) else { return }
        UserDefaults.standard.set(data, forKey: "watchedFolders")
    }

    func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        panel.message = "Choose a folder. DiskLens lets you know if it grows past the size you set."
        guard panel.runModal() == .OK, let url = panel.url, !watchedFolders.contains(where: { $0.path == url.path }) else { return }
        Task {
            let size = await DiskMeasure.size(of: url.path) ?? 0
            // Start the limit comfortably above today's size.
            let limit = max(1_000_000_000, Int64((Double(size) * 1.5 / 1e9).rounded(.up) * 1e9))
            watchedFolders.append(WatchedFolder(path: url.path, limitBytes: limit, lastBytes: size))
            saveWatched()
        }
    }

    func removeWatched(_ folder: WatchedFolder) {
        watchedFolders.removeAll { $0.path == folder.path }
        saveWatched()
    }

    func setLimit(_ folder: WatchedFolder, gb: Double) {
        guard let i = watchedFolders.firstIndex(of: folder) else { return }
        watchedFolders[i].limitBytes = Int64(gb * 1e9)
        watchedFolders[i].lastAlert = nil
        saveWatched()
    }

    /// Measures each watched folder (hourly from the monitor) and notifies once when one goes over its limit.
    func checkWatchedFolders() async {
        for folder in watchedFolders {
            guard let size = await DiskMeasure.size(of: folder.path, timeout: 300), let i = watchedFolders.firstIndex(where: { $0.path == folder.path }) else { continue }
            watchedFolders[i].lastBytes = size
            if Prefs.isBundled, folder.shouldAlert(size: size) {
                watchedFolders[i].lastAlert = Date()
                let content = UNMutableNotificationContent()
                content.title = "\((folder.path as NSString).lastPathComponent) is \(ByteFormat.string(size))"
                content.body = "It's over the \(ByteFormat.string(folder.limitBytes)) you set. Open DiskLens to see what grew."
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-" + folder.path, content: content, trigger: nil))
            }
        }
        saveWatched()
    }

    // MARK: Weekly digest

    /// Once a week (if turned on): free space, the change since last week, and what's safe to clean from the last scan.
    func sendDigestIfDue() async {
        let d = UserDefaults.standard
        guard Prefs.isBundled, d.bool(forKey: Prefs.weeklyDigest) else { return }
        let last = d.double(forKey: Prefs.lastDigest)
        let now = Date().timeIntervalSince1970
        guard now - last > 7 * 86_400 else { return }
        let free = DiskMeasure.freeBytes()
        let weekAgo = d.object(forKey: Prefs.lastDigestFree) as? Int64
        d.set(now, forKey: Prefs.lastDigest)
        d.set(free, forKey: Prefs.lastDigestFree)
        guard last > 0, let m = Digest.message(safeBytes: reclaimable(.safe), lastScan: lastFullScan?.date, free: free, freeWeekAgo: weekAgo) else { return }
        let content = UNMutableNotificationContent()
        content.title = m.title
        content.body = m.body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "weekly-digest", content: content, trigger: nil))
    }
}
