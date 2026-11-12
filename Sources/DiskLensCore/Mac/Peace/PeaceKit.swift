#if os(macOS)
import CryptoKit
import DiskLensHealth
import Foundation

// MARK: - Disk health

public struct DiskHealth: Sendable {
    public enum Verdict: String, Sendable { case good = "Healthy", watch = "Keep an eye on it", replace = "Back up now" }

    /// macOS's own SMART verdict ("Verified" or "Failing"), from diskutil.
    public let smartStatus: String?
    public let model: String?
    public let percentUsed: Int?
    public let availableSpare: Int?
    public let spareThreshold: Int?
    public let temperatureC: Int?
    public let powerOnHours: Int?
    public let bytesWritten: Int64?
    public let bytesRead: Int64?
    public let unsafeShutdowns: Int?
    public let mediaErrors: Int?
    public let criticalWarning: Int?

    public init(smartStatus: String?, model: String?, percentUsed: Int?, availableSpare: Int?, spareThreshold: Int?, temperatureC: Int?,
                powerOnHours: Int?, bytesWritten: Int64?, bytesRead: Int64?, unsafeShutdowns: Int?, mediaErrors: Int?, criticalWarning: Int?) {
        self.smartStatus = smartStatus
        self.model = model
        self.percentUsed = percentUsed
        self.availableSpare = availableSpare
        self.spareThreshold = spareThreshold
        self.temperatureC = temperatureC
        self.powerOnHours = powerOnHours
        self.bytesWritten = bytesWritten
        self.bytesRead = bytesRead
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
        self.criticalWarning = criticalWarning
    }

    /// Healthy unless the drive itself reports trouble: SMART failing, a critical warning, media errors,
    /// spare blocks near their limit, or wear past its rated endurance.
    public var verdict: Verdict {
        if smartStatus?.lowercased().contains("fail") == true || (criticalWarning ?? 0) != 0 { return .replace }
        // Spare blocks: the drive sets a critical-warning bit itself when they run low (above). Its "threshold" field
        // isn't comparable across vendors (Apple SSDs report 99%), so only plain percentages are used here.
        if let spare = availableSpare, spare < 10 { return .replace }
        if (mediaErrors ?? 0) > 0 || (percentUsed ?? 0) >= 90 { return .watch }
        if let spare = availableSpare, spare < 50 { return .watch }
        return .good
    }

    /// Plain-language reasons behind the verdict.
    public var notes: [String] {
        var out: [String] = []
        if let p = percentUsed {
            out.append(p < 10 ? "\(p)% of its rated write endurance used: it's barely worn."
                       : p < 90 ? "\(p)% of its rated write endurance used."
                       : "\(p)% of its rated write endurance used. Drives often keep working past 100%, but keep your backups current.")
        }
        if let e = mediaErrors, e > 0 { out.append("\(e) media error\(e == 1 ? "" : "s") recorded: data couldn't be read back at least once.") }
        if (criticalWarning ?? 0) != 0 { out.append("The drive is reporting a critical warning.") }
        if let u = unsafeShutdowns, u > 0 { out.append("\(u) unexpected shutdown\(u == 1 ? "" : "s") (power loss or forced restarts). Normal in small numbers.") }
        return out
    }

    /// Reads the internal drive: SMART status from diskutil and the NVMe health log through IOKit. No admin rights needed.
    public static func read() async -> DiskHealth {
        let info = await Shell.run("/usr/sbin/diskutil", ["info", "disk0"], timeout: 15).out
        func field(_ name: String) -> String? {
            info.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") }
                .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        }
        var raw = [DLNVMeHealth](repeating: DLNVMeHealth(), count: 4)
        let n = Int(dl_read_nvme_health(&raw, 4))
        let h = n > 0 ? raw[0] : nil
        return DiskHealth(smartStatus: field("SMART Status"), model: field("Device / Media Name"),
                          percentUsed: h.map { Int($0.percentUsed) }, availableSpare: h.map { Int($0.availableSpare) },
                          spareThreshold: h.map { Int($0.spareThreshold) }, temperatureC: h.map { Int($0.temperatureC) },
                          powerOnHours: h.map { Int($0.powerOnHours) },
                          bytesWritten: h.map { Int64(clamping: $0.dataUnitsWritten &* 512_000) },
                          bytesRead: h.map { Int64(clamping: $0.dataUnitsRead &* 512_000) },
                          unsafeShutdowns: h.map { Int($0.unsafeShutdowns) }, mediaErrors: h.map { Int($0.mediaErrors) },
                          criticalWarning: h.map { Int($0.criticalWarning) })
    }
}

// MARK: - "System Data", explained

/// What macOS's "System Data" bar is made of, built from DiskLens's own measurements.
public struct SystemDataPart: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let bytes: Int64
    public let explanation: String
    /// Findings in Clean Up that reduce this part.
    public let findingIDs: [String]
    public let canShrink: Bool
}

public enum SystemDataExplainer {
    /// Categories macOS counts as "System Data" (rather than Applications, Documents, Photos and so on).
    static let parts: [(category: String, explanation: String, findings: [String])] = [
        ("App data", "Settings, databases and files apps keep in your Library. Chat apps, browsers and editors are usually the biggest.", ["unused-apps"]),
        ("Caches & temp", "Files apps keep to load faster. Safe to clear; apps rebuild what they need.", ["app-caches", "npm-cache", "other-tool-caches", "package-caches", "pnpm-store", "go-modcache", "temp", "logs", "test-browsers"]),
        ("Xcode & Simulators", "Simulators, build products and device support files for app development.", ["xcode-derived-data", "xcode-device-support", "sim-devices-data", "sim-devices-unavailable", "xcode-archives", "sim-runtime-"]),
        ("Developer tools", "Package caches, SDKs and toolchains (Homebrew, Node, Gradle, Cargo, Python).", ["node-modules", "homebrew", "package-repos", "conda-", "editor-", "codex-staging"]),
        ("Docker", "The virtual disk where Docker keeps images, containers and volumes.", ["docker-build-cache", "docker-images", "docker-containers", "docker-volumes", "docker-not-running"]),
        ("Android SDK", "Android system images, NDKs and build tools.", ["android-sdk"]),
        ("Mail & Messages", "Downloaded mail, attachments and Messages history.", ["mail-downloads", "messages-attachments", "device-backups"]),
        ("iCloud Drive", "iCloud Drive files currently downloaded to this Mac.", ["icloud-downloads"]),
        ("Hidden (needs Full Disk Access)", "Folders macOS hides from apps without Full Disk Access, such as the Trash, iPhone backups and Mail.", []),
        ("macOS", "The system itself, recovery, and the space macOS sets aside for memory swap and updates.", ["tm-snapshots", "installers"]),
        ("Other", "Everything else DiskLens measured that doesn't fit the categories above.", ["large-files", "old-files"]),
    ]

    public static func breakdown(_ snapshot: Snapshot, findings: [Finding]) -> [SystemDataPart] {
        var byName = Dictionary(snapshot.categories.map { ($0.name, $0.bytes) }, uniquingKeysWith: +)
        byName["Hidden (needs Full Disk Access)"] = snapshot.hidden
        byName["macOS"] = snapshot.system
        return parts.compactMap { p in
            guard let bytes = byName[p.category], bytes >= 500_000_000 else { return nil }
            // Exact IDs, plus families such as "sim-runtime-17.5" for "sim-runtime-".
            let ids = findings.filter { f in p.findings.contains { $0.hasSuffix("-") ? f.id.hasPrefix($0) : f.id == $0 } }.map(\.id)
            var seen = Set<String>()
            let unique = ids.filter { seen.insert($0).inserted }
            return SystemDataPart(name: p.category, bytes: bytes, explanation: p.explanation, findingIDs: unique, canShrink: !unique.isEmpty)
        }.sorted { $0.bytes > $1.bytes }
    }
}

// MARK: - Archive to an external drive

public struct ExternalVolume: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let free: Int64
    public let capacity: Int64
    public let format: String?

    public init(path: String, name: String, free: Int64, capacity: Int64, format: String?) {
        self.path = path
        self.name = name
        self.free = free
        self.capacity = capacity
        self.format = format
    }
}

public struct ArchiveResult: Sendable {
    public let destination: URL?
    /// Originals whose copy was verified file by file (same files, sizes and SHA-256).
    public let verified: [String]
    public let failures: [String]
    public let bytes: Int64
}

public enum Archiver {
    /// Writable drives other than the startup disk (USB, Thunderbolt and SD cards; network shares excluded).
    public static func externalVolumes() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsLocalKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path != "/", let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsInternal != true,
                  v.volumeIsReadOnly != true, v.volumeIsLocal == true, v.volumeIsBrowsable != false else { return nil }
            return ExternalVolume(path: url.path, name: v.volumeName ?? url.lastPathComponent,
                                  free: v.volumeAvailableCapacityForImportantUsage ?? 0, capacity: Int64(v.volumeTotalCapacity ?? 0),
                                  format: v.volumeLocalizedFormatDescription)
        }
    }

    /// Copies each item into "<destination>/DiskLens Archive/<yyyy-MM-dd>/", then verifies every file of the copy
    /// against the original (names, sizes, SHA-256). Originals are never touched here; the app offers to move
    /// verified ones to the Trash afterwards, after a review.
    public static func archive(_ paths: [String], to destination: URL, date: Date = Date(),
                               progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async -> ArchiveResult {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let folder = destination.appendingPathComponent("DiskLens Archive").appendingPathComponent(f.string(from: date))
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return ArchiveResult(destination: nil, verified: [], failures: [error.localizedDescription], bytes: 0)
        }
        var verified: [String] = [], failures: [String] = []
        var bytes: Int64 = 0
        for (i, path) in paths.enumerated() {
            let name = (path as NSString).lastPathComponent
            progress(Double(i) / Double(paths.count), "Copying \(name)")
            let target = MediaConverter.uniqueURL(folder.appendingPathComponent(name))
            // ditto keeps permissions, dates, extended attributes and resource forks.
            let copy = await Shell.run("/usr/bin/ditto", [path, target.path], timeout: 6 * 3600)
            guard copy.ok else {
                failures.append("\(name): couldn't copy (\(copy.err.split(separator: "\n").first ?? "error"))")
                continue
            }
            progress((Double(i) + 0.6) / Double(paths.count), "Checking \(name)")
            if let problem = await Task.detached(operation: { compare(path, target.path) }).value {
                failures.append("\(name): \(problem). The copy was left on the drive; the original wasn't touched.")
                continue
            }
            verified.append(path)
            bytes += size(of: path)
        }
        progress(1, "Done")
        return ArchiveResult(destination: folder, verified: verified, failures: failures, bytes: bytes)
    }

    /// nil when every file under `a` exists in `b` with the same size and content.
    static func compare(_ a: String, _ b: String) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: a, isDirectory: &isDir) else { return "the original is gone" }
        let files: [String]
        if isDir.boolValue {
            guard let walker = fm.enumerator(atPath: a) else { return "couldn't list the original" }
            files = walker.compactMap { $0 as? String }.filter { rel in
                var d: ObjCBool = false
                return fm.fileExists(atPath: a + "/" + rel, isDirectory: &d) && !d.boolValue
            }
        } else {
            files = [""]
        }
        for rel in files {
            let src = rel.isEmpty ? a : a + "/" + rel, dst = rel.isEmpty ? b : b + "/" + rel
            guard fm.fileExists(atPath: dst) else { return "\(rel.isEmpty ? "the file" : rel) is missing from the copy" }
            guard size(of: src) == size(of: dst) else { return "\(rel.isEmpty ? "the copy" : rel) has a different size" }
            guard sha256(src) == sha256(dst) else { return "\(rel.isEmpty ? "the copy" : rel) has different content" }
        }
        return nil
    }

    static func size(of path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0) }
        var total: Int64 = 0
        for case let rel as String in FileManager.default.enumerator(atPath: path) ?? NSEnumerator() {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path + "/" + rel),
                  attrs[.type] as? FileAttributeType == .typeRegular else { continue }   // files only, not folder entries
            total += Int64(attrs[.size] as? Int ?? 0)
        }
        return total
    }

    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Large files you haven't opened in a year

struct OldFilesRule: CleanupRule {
    let name = "Old large files"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        guard let index = ctx.homeIndex else { return [] }
        let items = index.largeFiles.compactMap { path -> FindingItem? in
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]),
                  let size = v.totalFileAllocatedSize, size >= 300_000_000 else { return nil }
            let opened = AppIndex.lastUsed(path)
            let touched = [opened, v.contentModificationDate].compactMap { $0 }.max()
            guard let days = RuleKit.days(since: touched), days >= 365 else { return nil }
            let folder = ((path as NSString).deletingLastPathComponent).replacingOccurrences(of: ctx.home, with: "~")
            return FindingItem(path: path, bytes: Int64(size),
                               note: [v.localizedTypeDescription, "in \(folder)", opened == nil ? "never opened" : nil].compactMap { $0 }.joined(separator: " · "),
                               selectedByDefault: false, lastUsed: touched, usedBy: "you", quickSafe: false)
        }.sorted { $0.bytes > $1.bytes }
        guard RuleKit.total(items) >= RuleKit.minimumFindingBytes else { return [] }
        return [Finding(
            id: "old-files", title: "Big files you haven't opened in a year",
            detail: "Files over 300 MB in your home folder that haven't been opened or changed in at least a year. Good candidates for an external drive.",
            tier: .review, bytes: RuleKit.total(items), items: Array(items.prefix(100)), action: .trash, revealPath: ctx.home,
            symbol: "calendar.badge.clock",
            facts: [Fact("Files", "\(items.count)"), Fact("Preselected", "nothing: these are your files"),
                    Fact("Keep them?", "Archive to an external drive from History → Archive, with a verified copy before anything is removed")],
            risk: "These are your own files. If you might need them, archive them to an external drive instead of deleting.")]
    }
}

// MARK: - Messages attachments

/// Photos, videos and files kept by Messages. Deleting them in Finder would leave broken conversations,
/// so DiskLens shows the biggest and points to Apple's own Messages storage tools instead.
struct MessagesAttachmentsRule: CleanupRule {
    let name = "Messages attachments"

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let folder = ctx.path("~/Library/Messages/Attachments")
        guard ctx.hasFullDiskAccess, let total = await DiskMeasure.size(of: folder), total >= 500_000_000 else { return [] }
        let biggest = MessagesAttachments.biggest(in: folder, limit: 20)
        return [Finding(
            id: "messages-attachments", title: "Messages attachments",
            detail: "Photos, videos and files sent and received in Messages. Remove them in Messages so conversations stay intact: System Settings → General → Storage → Messages lists them by size, or set Messages → Settings → Keep messages to 1 year.",
            tier: .review, bytes: total, items: biggest, action: .open(path: "x-apple.systempreferences:com.apple.settings.Storage"),
            revealPath: folder, symbol: "message",
            facts: [Fact("Biggest", biggest.first.map { "\(ByteFormat.string($0.bytes)) · \($0.name)" } ?? "-"),
                    Fact("Why not here", "deleting the files directly leaves gaps in your conversations"),
                    Fact("iCloud", "with Messages in iCloud, removing an attachment removes it on your other devices too")],
            risk: nil)]
    }
}

public enum MessagesAttachments {
    public static func biggest(in folder: String, limit: Int) -> [FindingItem] {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var files: [(String, Int64, Date?)] = []
        while let url = walker.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let s = v.fileSize, s >= 10_000_000 else { continue }
            files.append((url.path, Int64(s), v.contentModificationDate))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map {
            FindingItem(path: $0.0, bytes: $0.1, note: "remove in Messages", selectedByDefault: false, lastUsed: $0.2, usedBy: "Messages", quickSafe: false)
        }
    }
}

// MARK: - Watched folders and the weekly digest (pure helpers; the app schedules them)

public struct WatchedFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var limitBytes: Int64
    public var lastBytes: Int64?
    public var lastAlert: Date?

    public init(path: String, limitBytes: Int64, lastBytes: Int64? = nil, lastAlert: Date? = nil) {
        self.path = path
        self.limitBytes = limitBytes
        self.lastBytes = lastBytes
        self.lastAlert = lastAlert
    }

    /// Alert once when it goes over the limit, then again only after a week if it's still over.
    public func shouldAlert(size: Int64, now: Date = Date()) -> Bool {
        guard size > limitBytes else { return false }
        guard let last = lastAlert else { return true }
        return now.timeIntervalSince(last) > 7 * 86_400
    }
}

public enum Digest {
    /// One line for the weekly notification, or nil when there's nothing worth saying.
    public static func message(safeBytes: Int64, lastScan: Date?, free: Int64, freeWeekAgo: Int64?, now: Date = Date()) -> (title: String, body: String)? {
        let days = lastScan.map { Int(now.timeIntervalSince($0) / 86_400) }
        var body: [String] = []
        if let before = freeWeekAgo {
            let change = free - before
            if abs(change) >= 1_000_000_000 {
                body.append(change < 0 ? "Free space dropped by \(ByteFormat.string(-change)) this week." : "You gained \(ByteFormat.string(change)) of free space this week.")
            }
        }
        if safeBytes >= 1_000_000_000 {
            body.append("\(ByteFormat.string(safeBytes)) can be cleaned safely" + (days.map { $0 > 0 ? " (from your scan \($0) day\($0 == 1 ? "" : "s") ago)." : "." } ?? "."))
        } else if days == nil || days! >= 14 {
            body.append("It's been a while since your last scan. A full scan takes about two minutes.")
        }
        guard !body.isEmpty else { return nil }
        return ("DiskLens weekly: \(ByteFormat.string(free)) free", body.joined(separator: " "))
    }
}
#endif
