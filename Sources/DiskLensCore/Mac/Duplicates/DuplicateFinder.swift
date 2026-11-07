#if os(macOS)
import CryptoKit
import Foundation

public struct DuplicateFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let modified: Date?
    public let created: Date?
    /// APFS gives clones (e.g. Finder ▸ Duplicate) the same content identifier: they share storage.
    let contentID: Int64?
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, bytes: Int64, modified: Date?, created: Date?, contentID: Int64? = nil) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.created = created
        self.contentID = contentID
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let files: [DuplicateFile]
    /// The copy DiskLens suggests keeping.
    public let keep: String
    /// Space freed by removing every copy except `keep`. Clones of the kept file free nothing.
    public let reclaimable: Int64
    /// Copies that are APFS clones sharing storage with another copy.
    public let clonePaths: Set<String>

    public var bytesPerFile: Int64 { files.first?.bytes ?? 0 }
}

public enum DuplicateFinder {
    /// Home folder minus ~/Library, hidden folders, app bundles, photo libraries and dependency folders.
    public static var defaultRoots: [String] { [NSHomeDirectory()] }

    static let skipNames: Set<String> = ["node_modules", ".git", "Library", "build", ".build", "DerivedData", "Pods", ".Trash"]

    public static func scan(roots: [String], minimumBytes: Int64 = 1_000_000,
                            progress: @escaping @Sendable (String) -> Void) async -> [DuplicateGroup] {
        // 1. Group by size (cheap): only same-size files can be identical.
        progress("Listing files")
        var bySize: [Int64: [DuplicateFile]] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                                      .creationDateKey, .fileContentIdentifierKey]
        var seen = Set<String>()
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL {
                let name = url.lastPathComponent
                if skipNames.contains(name) && url.path != root || name.hasSuffix(".photoslibrary") { walker.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize, Int64(size) >= minimumBytes, seen.insert(url.path).inserted else { continue }
                bySize[Int64(size), default: []].append(DuplicateFile(
                    path: url.path, bytes: Int64(size), modified: v.contentModificationDate, created: v.creationDate,
                    contentID: v.fileContentIdentifier))
            }
        }
        let candidates = bySize.values.filter { $0.count > 1 }

        // 2. Same size → hash the first 64 KB; 3. still equal → full SHA-256.
        progress("Comparing \(candidates.reduce(0) { $0 + $1.count }) files")
        var groups: [DuplicateGroup] = []
        for sameSize in candidates {
            let byHead = Dictionary(grouping: sameSize) { hash($0.path, limit: 65_536) ?? UUID().uuidString }
            for headGroup in byHead.values where headGroup.count > 1 {
                let byFull = Dictionary(grouping: headGroup) { hash($0.path, limit: nil) ?? UUID().uuidString }
                for (digest, files) in byFull where files.count > 1 {
                    groups.append(makeGroup(hash: digest, files: files))
                }
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Recomputes a group after some copies were removed.
    /// Builds a group from files already known to be identical (e.g. sample data).
    public static func group(hash: String, files: [DuplicateFile]) -> DuplicateGroup { makeGroup(hash: hash, files: files) }

    public static func regroup(_ group: DuplicateGroup, keeping files: [DuplicateFile]) -> DuplicateGroup {
        makeGroup(hash: group.hash, files: files)
    }

    static func makeGroup(hash: String, files: [DuplicateFile]) -> DuplicateGroup {
        let keep = suggestKeep(files)
        let keepID = files.first { $0.path == keep }?.contentID
        var clones = Set<String>()
        // A clone of the kept file shares its storage: removing it frees nothing.
        for f in files where f.path != keep {
            if let id = f.contentID, id == keepID { clones.insert(f.path) }
        }
        // Among the other copies, clones of each other also share storage: count each storage once.
        var storages = Set<Int64>()
        var reclaim: Int64 = 0
        for f in files where f.path != keep && !clones.contains(f.path) {
            if let id = f.contentID {
                if storages.insert(id).inserted { reclaim += f.bytes } else { clones.insert(f.path) }
            } else {
                reclaim += f.bytes
            }
        }
        return DuplicateGroup(hash: hash, files: files.sorted { $0.path < $1.path }, keep: keep, reclaimable: reclaim, clonePaths: clones)
    }

    /// Keeps the copy that looks like the original: not in Downloads/Desktop, no "copy"/"(1)" in the name, oldest.
    public static func suggestKeep(_ files: [DuplicateFile]) -> String {
        func score(_ f: DuplicateFile) -> (Int, Int, Date) {
            let lower = f.path.lowercased()
            let home = NSHomeDirectory().lowercased()
            let transient = lower.hasPrefix(home + "/downloads/") || lower.hasPrefix(home + "/desktop/") ? 1 : 0
            let name = (f.name as NSString).deletingPathExtension.lowercased()
            let copyName = name.contains(" copy") || name.range(of: #"\(\d+\)$"#, options: .regularExpression) != nil
                || name.range(of: #"[ _-]\d$"#, options: .regularExpression) != nil ? 1 : 0
            return (transient, copyName, f.created ?? f.modified ?? .distantFuture)
        }
        return files.min { score($0) < score($1) }!.path
    }

    static func hash(_ path: String, limit: Int?) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? .max
        while remaining > 0 {
            let chunk = handle.readData(ofLength: min(1 << 20, remaining))
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
