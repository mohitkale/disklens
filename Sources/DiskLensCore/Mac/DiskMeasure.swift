#if os(macOS)
import Foundation

public struct ContainerInfo: Sendable {
    public let capacity: Int64
    public let free: Int64
    public let dataUsed: Int64
    /// System, Preboot, Recovery, VM (swap) and other non-Data volumes in the container.
    public let systemUsed: Int64
}

public struct OpenFile: Sendable, Hashable {
    public let process: String
    public let path: String
}

/// One `lsof` listing of every file the user's processes have open, reused for a few seconds.
/// Far faster than walking each folder with `lsof +D`, and it also catches working directories.
actor OpenFileSnapshot {
    static let shared = OpenFileSnapshot()
    private var cached: (date: Date, files: [OpenFile])?
    private var inFlight: Task<[OpenFile]?, Never>?

    func current(timeout: TimeInterval) async -> [OpenFile]? {
        if let cached, Date().timeIntervalSince(cached.date) < 10 { return cached.files }
        if let inFlight { return await inFlight.value }
        let task = Task<[OpenFile]?, Never> {
            let r = await Shell.run("/usr/sbin/lsof", ["-n", "-P", "-w", "-F", "pRcn", "-u", String(getuid())],
                                    timeout: timeout, captureStderr: false)
            if r.timedOut { return nil }
            // Skip DiskLens's own helpers (du, find, lsof), which are reading these folders right now.
            let me = String(getpid())
            var files: [OpenFile] = []
            var command = "", parent = ""
            for line in r.out.split(separator: "\n") {
                guard let tag = line.first else { continue }
                let value = String(line.dropFirst())
                switch tag {
                case "p": parent = ""; command = ""
                case "R": parent = value
                case "c": command = value
                case "n" where value.hasPrefix("/") && parent != me: files.append(OpenFile(process: command, path: value))
                default: break
                }
            }
            return files
        }
        inFlight = task
        let files = await task.value
        inFlight = nil
        if let files { cached = (Date(), files) }
        return files
    }

    func invalidate() { cached = nil }
}

public enum DiskMeasure {
    public static let dataVolume = "/System/Volumes/Data"

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Allocated size on disk, like `du -sk`. Stays on one volume (-x) so mounted
    /// simulator images aren't double-counted. Unreadable folders are skipped.
    public static func size(of path: String, timeout: TimeInterval = 900) async -> Int64? {
        guard exists(path) else { return nil }
        let r = await Shell.run("/usr/bin/du", ["-skx", path], timeout: timeout, captureStderr: false)
        guard !r.timedOut, let line = r.out.split(separator: "\n").last,
              let kb = Int64(line.prefix { $0.isNumber }) else { return nil }
        return kb * 1024
    }

    public static func sizes(of paths: [String], concurrency: Int = 6) async -> [String: Int64] {
        var result: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64?).self) { group in
            var iterator = paths.makeIterator()
            for _ in 0..<concurrency {
                guard let p = iterator.next() else { break }
                group.addTask { (p, await size(of: p)) }
            }
            while let (p, bytes) = await group.next() {
                if let bytes { result[p] = bytes }
                if let next = iterator.next() { group.addTask { (next, await size(of: next)) } }
            }
        }
        return result
    }

    /// Immediate children of a folder with their sizes, largest first.
    public static func children(of path: String, minBytes: Int64 = 0) async -> [(path: String, bytes: Int64)] {
        guard exists(path) else { return [] }
        let r = await Shell.run("/usr/bin/du", ["-xkd1", path], timeout: 600, captureStderr: false)
        let root = (path as NSString).standardizingPath
        return r.out.split(separator: "\n").compactMap { line -> (String, Int64)? in
            guard let tab = line.firstIndex(of: "\t"), let kb = Int64(line[..<tab]) else { return nil }
            let child = String(line[line.index(after: tab)...])
            guard (child as NSString).standardizingPath != root else { return nil }
            return (child, kb * 1024)
        }
        .filter { $0.1 >= minBytes }
        .sorted { $0.1 > $1.1 }
    }

    /// Reads the APFS container that holds the startup Data volume.
    public static func containerInfo() async -> ContainerInfo? {
        let r = await Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 30)
        guard r.ok, let data = r.out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return nil }
        for c in containers {
            let volumes = c["Volumes"] as? [[String: Any]] ?? []
            let roles = volumes.flatMap { $0["Roles"] as? [String] ?? [] }
            guard roles.contains("Data"), roles.contains("System") else { continue }
            var data: Int64 = 0, other: Int64 = 0
            for v in volumes {
                let used = (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                if (v["Roles"] as? [String] ?? []).contains("Data") { data += used } else { other += used }
            }
            return ContainerInfo(capacity: (c["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0,
                                 free: (c["CapacityFree"] as? NSNumber)?.int64Value ?? 0,
                                 dataUsed: data, systemUsed: other)
        }
        return nil
    }

    /// The startup disk's name as Finder shows it (e.g. "Macintosh HD").
    public static func volumeName() -> String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Startup Disk"
    }

    /// Free space right now (cheap — used before/after a cleanup).
    public static func freeBytes() -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// Full Disk Access is needed to read Mail, iPhone backups, the Trash, etc.
    public static func hasFullDiskAccess() -> Bool {
        let probe = expand("~/Library/Application Support/com.apple.TCC/TCC.db")
        if let handle = FileHandle(forReadingAtPath: probe) {
            try? handle.close()
            return true
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: expand("~/.Trash"))) != nil
    }

    /// Files currently open under `path` (including processes whose working folder is inside it).
    /// Returns nil if lsof couldn't finish in time.
    public static func openFiles(under path: String, timeout: TimeInterval = 30) async -> [OpenFile]? {
        guard exists(path) else { return [] }
        guard let all = await OpenFileSnapshot.shared.current(timeout: timeout) else { return nil }
        let root = (path as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return all.filter { f in
            [root, resolved].contains { f.path == $0 || f.path.hasPrefix($0 + "/") }
        }
    }

    /// Days since the file or folder was last modified.
    public static func daysSinceModified(_ path: String) -> Int? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: .now).day
    }

    public static func listDirectory(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { $0 != ".DS_Store" }
            .map { (path as NSString).appendingPathComponent($0) }
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
#endif
