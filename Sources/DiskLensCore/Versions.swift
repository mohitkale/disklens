import Foundation

/// Version-string helpers used to decide which SDK / tool versions to keep.
public enum Versions {
    /// True for "32.1.0-rc1", "36.0.0-rc3", "1.2-beta" and similar.
    public static func isPrerelease(_ v: String) -> Bool {
        let lower = v.lowercased()
        return ["rc", "beta", "alpha", "preview"].contains { lower.contains($0) }
    }

    static func numbers(_ v: String) -> [Int] {
        let head = v.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? v
        return head.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// Orders versions numerically; a prerelease sorts below the stable release with the same numbers.
    public static func less(_ a: String, _ b: String) -> Bool {
        let na = numbers(a), nb = numbers(b)
        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0
            let y = i < nb.count ? nb[i] : 0
            if x != y { return x < y }
        }
        return isPrerelease(a) && !isPrerelease(b)
    }

    /// Splits `versions` into kept and removable: pinned versions plus the `keepNewest`
    /// newest stable versions are kept. If nothing is stable, the newest version is kept.
    public static func partition(_ versions: [String], pinned: Set<String>, keepNewest: Int)
        -> (keep: [String], remove: [String]) {
        let stable = versions.filter { !isPrerelease($0) }.sorted(by: less)
        var keep = Set(stable.suffix(keepNewest))
        if keep.isEmpty, let newest = versions.sorted(by: less).last { keep.insert(newest) }
        keep.formUnion(versions.filter { pinned.contains($0) })
        let sorted = versions.sorted(by: less)
        return (sorted.filter { keep.contains($0) }, sorted.filter { !keep.contains($0) })
    }
}

/// Android NDK / build-tools versions that a project pins in its Gradle files.
public struct AndroidPins: Equatable, Sendable {
    public var ndk: [String: Set<String>] = [:]          // version -> projects
    public var buildTools: [String: Set<String>] = [:]   // version -> projects

    public init() {}

    public mutating func merge(text: String, project: String) {
        for v in Self.matches(in: text, key: "ndkVersion") { ndk[v, default: []].insert(project) }
        for v in Self.matches(in: text, key: "buildToolsVersion") { buildTools[v, default: []].insert(project) }
        // React Native's gradle/libs.versions.toml uses `buildTools = "36.0.0"`.
        for v in Self.matches(in: text, key: "buildTools") { buildTools[v, default: []].insert(project) }
    }

    static func matches(in text: String, key: String) -> [String] {
        let pattern = "\\b\(key)\\b\\s*[=:]?\\s*\\(?\\s*[\"']([0-9][0-9A-Za-z.\\-]*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
