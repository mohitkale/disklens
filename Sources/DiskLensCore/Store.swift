import Foundation

/// Persists scan snapshots and the cleanup log as JSON in Application Support.
public final class HistoryStore: @unchecked Sendable {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // DISKLENS_DATA_DIR lets tests and screenshots run against an empty history.
        let override = ProcessInfo.processInfo.environment["DISKLENS_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.directory = directory ?? override ?? base.appendingPathComponent("DiskLens", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private var snapshotsURL: URL { directory.appendingPathComponent("snapshots.json") }
    private var logURL: URL { directory.appendingPathComponent("cleanup-log.json") }
    private var findingsURL: URL { directory.appendingPathComponent("last-findings.json") }

    /// Findings from the most recent full scan, so the app has something to show at launch.
    public struct CachedFindings: Codable, Sendable {
        public let date: Date
        public let findings: [Finding]
        /// Quick rules that found something in this full scan (where Quick Scan looks).
        public let profile: [String]?
        public init(date: Date, findings: [Finding], profile: [String]? = nil) {
            self.date = date
            self.findings = findings
            self.profile = profile
        }
    }

    public func loadFindings() -> CachedFindings? {
        load(CachedFindings.self, from: findingsURL)
    }

    public func saveFindings(_ cached: CachedFindings) {
        save(cached, to: findingsURL)
    }

    public func loadSnapshots() -> [Snapshot] {
        load([Snapshot].self, from: snapshotsURL)?.sorted { $0.date < $1.date } ?? []
    }

    public func saveSnapshots(_ snapshots: [Snapshot]) {
        save(snapshots, to: snapshotsURL)
    }

    public func loadLog() -> [LogEntry] {
        load([LogEntry].self, from: logURL)?.sorted { $0.date > $1.date } ?? []
    }

    public func saveLog(_ log: [LogEntry]) {
        save(log, to: logURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
