import Foundation

/// How confident we are that a cleanup can't break anything.
public enum Tier: String, Codable, CaseIterable, Sendable, Comparable {
    case safe, review, keep

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review first"
        case .keep: "Leave alone"
        }
    }

    public var symbol: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .review: "exclamationmark.triangle.fill"
        case .keep: "xmark.octagon.fill"
        }
    }

    private var order: Int { switch self { case .safe: 0; case .review: 1; case .keep: 2 } }
    public static func < (a: Tier, b: Tier) -> Bool { a.order < b.order }
}

/// A labelled fact shown with a finding, e.g. "Last used: 5 months ago".
public struct Fact: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case info, good, warning }
    public let label: String
    public let value: String
    public let kind: Kind

    public init(_ label: String, _ value: String, _ kind: Kind = .info) {
        self.label = label
        self.value = value
        self.kind = kind
    }
}

/// One file or folder a finding would act on.
public struct FindingItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let note: String?
    public let selectedByDefault: Bool
    /// When the item (or the project/app it belongs to) was last used or changed.
    public let lastUsed: Date?
    /// The app, project or tool that depends on this item.
    public let usedBy: String?
    /// Part of Quick Clean: removing it can't affect any app (no manual re-install needed).
    public let quickSafe: Bool

    public init(path: String, bytes: Int64, note: String? = nil, selectedByDefault: Bool = true,
                lastUsed: Date? = nil, usedBy: String? = nil, quickSafe: Bool = true) {
        self.path = path
        self.bytes = bytes
        self.note = note
        self.selectedByDefault = selectedByDefault
        self.lastUsed = lastUsed
        self.usedBy = usedBy
        self.quickSafe = quickSafe
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public enum CleanupAction: Codable, Hashable, Sendable {
    /// Move the selected items to the Trash (reversible until the Trash is emptied).
    case trash
    /// Run a vendor tool that owns the data (xcrun simctl, docker, brew).
    case command(tool: String, args: [String])
    /// Open an app (e.g. start Docker Desktop so it can be analysed).
    case launchApp(bundleID: String)
    /// Open a file or folder in Finder (e.g. the Trash).
    case open(path: String)
    /// Nothing to run — the detail text says what to do.
    case advice

    public var isExecutable: Bool {
        switch self {
        case .trash, .command: true
        default: false
        }
    }

    public var commandLine: String? {
        guard case let .command(tool, args) = self else { return nil }
        return ([(tool as NSString).lastPathComponent] + args).joined(separator: " ")
    }
}

public struct Finding: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let tier: Tier
    /// Estimated space reclaimed. For `.trash` findings the UI recomputes it from the selected items.
    public let bytes: Int64
    public let items: [FindingItem]
    public let action: CleanupAction
    /// What was deliberately left in place, and why.
    public let kept: String?
    /// Bundle IDs of apps that must be quit first.
    public let quitApps: [String]
    /// Something the user should know after cleaning (e.g. a re-install command).
    public let afterNote: String?
    public let revealPath: String?
    /// SF Symbol shown with the finding.
    public let symbol: String
    /// Dependencies and context: last used, used by, how to get it back.
    public let facts: [Fact]
    /// What could go wrong, shown in the confirmation.
    public let risk: String?
    /// Included in Quick Clean.
    public let quickClean: Bool

    public init(id: String, title: String, detail: String, tier: Tier, bytes: Int64,
                items: [FindingItem] = [], action: CleanupAction, kept: String? = nil,
                quitApps: [String] = [], afterNote: String? = nil, revealPath: String? = nil,
                symbol: String = "folder", facts: [Fact] = [], risk: String? = nil, quickClean: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tier = tier
        self.bytes = bytes
        self.items = items
        self.action = action
        self.kept = kept
        self.quitApps = quitApps
        self.afterNote = afterNote
        self.revealPath = revealPath ?? items.first.map { ($0.path as NSString).deletingLastPathComponent }
        self.symbol = symbol
        self.facts = facts
        self.risk = risk
        self.quickClean = quickClean
    }

    /// Trash moves can be undone until the Trash is emptied; tool commands can't.
    public var isReversible: Bool { action == .trash }

    public func bytes(selected: Set<String>) -> Int64 {
        guard action == .trash, !items.isEmpty else { return bytes }
        return items.filter { selected.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }
}

public struct CategoryUsage: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let bytes: Int64
    public let paths: [String]
    /// Size of each path, when measured individually.
    public let pathBytes: [String: Int64]?

    public init(name: String, bytes: Int64, paths: [String], pathBytes: [String: Int64]? = nil) {
        self.name = name
        self.bytes = bytes
        self.paths = paths
        self.pathBytes = pathBytes
    }
}

/// A point-in-time picture of the disk, kept for before/after comparisons.
public struct Snapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let label: String?
    public let capacity: Int64
    public let free: Int64
    /// macOS system volumes (System, Preboot, Recovery, VM/swap).
    public let system: Int64
    /// On the Data volume but unreadable without Full Disk Access.
    public let hidden: Int64
    /// Everything `du` could measure on the Data volume.
    public let measured: Int64
    public let trash: Int64?
    public let categories: [CategoryUsage]
    /// How long the scan took, in seconds.
    public let duration: Double?

    public init(date: Date, label: String? = nil, capacity: Int64, free: Int64, system: Int64,
                hidden: Int64, measured: Int64, trash: Int64?, categories: [CategoryUsage], duration: Double? = nil) {
        self.date = date
        self.label = label
        self.capacity = capacity
        self.free = free
        self.system = system
        self.hidden = hidden
        self.measured = measured
        self.trash = trash
        self.categories = categories
        self.duration = duration
    }

    public var used: Int64 { capacity - free }
    public var usedFraction: Double { capacity > 0 ? Double(used) / Double(capacity) : 0 }

    public func category(named name: String) -> CategoryUsage? {
        categories.first { $0.name == name }
    }
}

public struct LogEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable { case freed, trashed, failed }

    public var id: UUID
    public let date: Date
    public let title: String
    public let bytes: Int64
    public let outcome: Outcome
    public let detail: String

    public init(date: Date = .now, title: String, bytes: Int64, outcome: Outcome, detail: String) {
        self.id = UUID()
        self.date = date
        self.title = title
        self.bytes = bytes
        self.outcome = outcome
        self.detail = detail
    }
}

public enum ByteFormat {
    /// Decimal units, matching Finder and System Settings (1 GB = 1,000,000,000 bytes).
    public static func string(_ bytes: Int64) -> String {
        let b = Double(bytes)
        switch abs(b) {
        case 100e9...: return String(format: "%.0f GB", b / 1e9)
        case 1e9...: return String(format: "%.1f GB", b / 1e9)
        case 1e6...: return String(format: "%.0f MB", b / 1e6)
        case 1e3...: return String(format: "%.0f KB", b / 1e3)
        default: return "\(bytes) B"
        }
    }

    public static func gb(_ bytes: Int64) -> Double { Double(bytes) / 1e9 }

    /// Parses sizes printed by tools like docker and brew ("5.117GB", "173.1MB", "0B", "1.2 kB").
    public static func parse(_ text: String) -> Int64? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let range = s.range(of: #"^[0-9]*\.?[0-9]+\s*[a-zA-Z]*"#, options: .regularExpression) else { return nil }
        let token = String(s[range])
        let number = token.prefix { "0123456789.".contains($0) }
        let unit = token.dropFirst(number.count).trimmingCharacters(in: .whitespaces).uppercased()
        guard let value = Double(number) else { return nil }
        let multipliers: [String: Double] = [
            "": 1, "B": 1, "KB": 1e3, "K": 1e3, "MB": 1e6, "M": 1e6, "GB": 1e9, "G": 1e9, "TB": 1e12, "T": 1e12,
            "KIB": 1024, "MIB": 1_048_576, "GIB": 1_073_741_824,
        ]
        guard let m = multipliers[unit] else { return nil }
        return Int64(value * m)
    }
}
