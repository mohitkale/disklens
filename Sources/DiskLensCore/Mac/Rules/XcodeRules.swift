#if os(macOS)
import Foundation

private let simulatorApp = "com.apple.iphonesimulator"
private let xcodeApp = "com.apple.dt.Xcode"

struct SimulatorDevice: Decodable {
    let udid: String
    let name: String
    let state: String?
    let isAvailable: Bool?
}

private struct DeviceList: Decodable { let devices: [String: [SimulatorDevice]] }

/// Simulator devices keyed by runtime identifier.
private func simulatorDevices() async -> [String: [SimulatorDevice]] {
    let r = await Shell.run(Tools.xcrun, ["simctl", "list", "devices", "-j"], timeout: 60)
    guard r.ok, let data = r.out.data(using: .utf8) else { return [:] }
    return (try? JSONDecoder().decode(DeviceList.self, from: data))?.devices ?? [:]
}

struct SimulatorRuntimesRule: CleanupRule {
    let name = "Simulator runtimes"

    struct Runtime: Decodable {
        let identifier: String
        let version: String?
        let build: String?
        let lastUsedAt: String?
        let sizeBytes: Int64?
        let state: String?
        let deletable: Bool?
        let runtimeIdentifier: String?
        let platformIdentifier: String?
    }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        guard FileManager.default.isExecutableFile(atPath: Tools.xcrun) else { return [] }
        let r = await Shell.run(Tools.xcrun, ["simctl", "runtime", "list", "-j"], timeout: 60)
        guard r.ok, let data = r.out.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Runtime].self, from: data) else { return [] }
        let runtimes = decoded.values.filter { $0.deletable != false && $0.state != "Deleting" }
        let devices = await simulatorDevices()

        // Simulator dyld caches live in dyld/<macOS build>/<runtime id>.<runtime build>.
        let dyldDirs = DiskMeasure.listDirectory("/Library/Developer/CoreSimulator/Caches/dyld")
            .flatMap { DiskMeasure.listDirectory($0) }

        var newest: [String: Runtime] = [:]
        for rt in runtimes {
            let p = platform(rt)
            if let current = newest[p], !Versions.less(current.version ?? "0", rt.version ?? "0") { continue }
            newest[p] = rt
        }
        let xcodeLastUsed = ctx.app(xcodeApp)?.lastUsed

        let iso = ISO8601DateFormatter()
        var findings: [Finding] = []
        for rt in runtimes {
            let p = platform(rt)
            let version = rt.version ?? "?"
            let cacheName = "\(rt.runtimeIdentifier ?? "-").\(rt.build ?? "-")"
            var cacheBytes: Int64 = 0
            if let cache = dyldDirs.first(where: { ($0 as NSString).lastPathComponent == cacheName }) {
                cacheBytes = await DiskMeasure.size(of: cache) ?? 0
            }
            let lastUsed = rt.lastUsedAt.flatMap { iso.date(from: $0) }
            let idleDays = RuleKit.days(since: lastUsed) ?? .max
            let isNewest = newest[p]?.identifier == rt.identifier
            let deviceNames = (devices[rt.runtimeIdentifier ?? ""] ?? []).map(\.name)
            let runtimeBytes = rt.sizeBytes ?? 0

            var facts = [
                Fact("Last used", lastUsed.map(RuleKit.relativeAge) ?? "never", idleDays > 90 ? .good : .warning),
                Fact("Simulators on it", deviceNames.isEmpty ? "none" : deviceNames.joined(separator: ", ")),
                Fact("Size", "\(ByteFormat.string(runtimeBytes)) runtime + \(ByteFormat.string(cacheBytes)) cache"),
                Fact("Get it back", "Xcode → Settings → Components (~\(ByteFormat.string(runtimeBytes)) download)"),
                Fact("Undo", "Not through the Trash: download it again", .warning),
            ]
            if let xcodeLastUsed { facts.insert(Fact("Xcode last opened", RuleKit.relativeAge(xcodeLastUsed)), at: 1) }

            findings.append(Finding(
                id: "sim-runtime-\(rt.identifier)",
                title: "\(p) \(version) simulator",
                detail: "The \(p) \(version) system that Xcode's simulators run on." + (isNewest ? " It's your newest \(p) simulator." : ""),
                tier: isNewest || idleDays < 90 ? .review : .safe,
                bytes: runtimeBytes + cacheBytes,
                action: .command(tool: Tools.xcrun, args: ["simctl", "runtime", "delete", rt.identifier]),
                quitApps: [simulatorApp],
                revealPath: "/Library/Developer/CoreSimulator",
                symbol: "iphone.gen3",
                facts: facts,
                risk: "Xcode can't run \(p) \(version) simulators" + (deviceNames.isEmpty ? "" : " (\(deviceNames.count) simulator(s) will disappear)") + " until you download it again."))
        }
        return findings.sorted { $0.bytes > $1.bytes }
    }

    private func platform(_ rt: Runtime) -> String {
        let id = (rt.runtimeIdentifier ?? "") + (rt.platformIdentifier ?? "")
        if id.contains("watch") { return "watchOS" }
        if id.contains("tvOS") || id.contains("appletv") { return "tvOS" }
        if id.contains("xrOS") || id.contains("xros") || id.contains("visionOS") { return "visionOS" }
        return "iOS"
    }
}

struct SimulatorDevicesRule: CleanupRule {
    let name = "Simulator devices"
    var isQuick: Bool { true }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        guard FileManager.default.isExecutableFile(atPath: Tools.xcrun) else { return [] }
        let devices = await simulatorDevices().values.flatMap { $0 }
        let root = ctx.path("~/Library/Developer/CoreSimulator/Devices")
        let sizes = await DiskMeasure.sizes(of: devices.map { "\(root)/\($0.udid)" })
        func size(_ d: SimulatorDevice) -> Int64 { sizes["\(root)/\(d.udid)"] ?? 0 }
        func lastBooted(_ d: SimulatorDevice) -> Date? { RuleKit.modified("\(root)/\(d.udid)/data") }

        var findings: [Finding] = []
        let orphaned = devices.filter { $0.isAvailable == false }
        if !orphaned.isEmpty {
            findings.append(Finding(
                id: "sim-devices-unavailable",
                title: "Orphaned simulators",
                detail: "Simulators whose iOS version is no longer installed. They can't start any more.",
                tier: .safe,
                bytes: orphaned.reduce(0) { $0 + size($1) },
                action: .command(tool: Tools.xcrun, args: ["simctl", "delete", "unavailable"]),
                quitApps: [simulatorApp],
                revealPath: root,
                symbol: "iphone.slash",
                facts: [Fact("Simulators", orphaned.map(\.name).joined(separator: ", ")),
                        Fact("Used by", "nothing: their iOS version was removed", .good)],
                quickClean: true))
        }

        let available = devices.filter { $0.isAvailable != false }
        let dataBytes = available.reduce(0) { $0 + size($1) }
        if dataBytes >= 300_000_000 {
            let booted = available.filter { $0.state == "Booted" }
            let recent = available.compactMap(lastBooted).max()
            findings.append(Finding(
                id: "sim-devices-data",
                title: "Simulator app data",
                detail: "Apps you installed in simulators, and their data. Erasing resets every simulator to a fresh state. The simulators themselves stay.",
                tier: .review,
                bytes: dataBytes,
                action: .command(tool: Tools.xcrun, args: ["simctl", "erase", "all"]),
                quitApps: [simulatorApp],
                revealPath: root,
                symbol: "iphone",
                facts: [Fact("Simulators", "\(available.count)" + (booted.isEmpty ? "" : ", \(booted.count) running")),
                        Fact("Last used", recent.map(RuleKit.relativeAge) ?? "unknown"),
                        Fact("Undo", "Not possible: apps must be reinstalled", .warning)],
                risk: "Apps and data inside every simulator are erased."))
        }
        return findings
    }
}

struct XcodeDataRule: CleanupRule {
    let name = "Xcode data"
    var isQuick: Bool { true }

    func evaluate(_ ctx: RuleContext) async -> [Finding] {
        let base = ctx.path("~/Library/Developer/Xcode")
        guard DiskMeasure.exists(base) else { return [] }
        var findings: [Finding] = []

        let derived = await DiskMeasure.children(of: base + "/DerivedData", minBytes: 1_000_000).map { child -> FindingItem in
            let name = (child.path as NSString).lastPathComponent
            let project = name.split(separator: "-").dropLast().joined(separator: "-")
            let modified = RuleKit.modified(child.path)
            return FindingItem(path: child.path, bytes: child.bytes, note: RuleKit.ageNote(child.path),
                               lastUsed: modified, usedBy: project.isEmpty ? "Xcode" : project)
        }
        if RuleKit.total(derived) >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "xcode-derived-data", title: "Xcode build data",
                detail: "Build products and indexes in DerivedData. Xcode rebuilds them on the next build.",
                tier: .safe, bytes: RuleKit.total(derived), items: derived, action: .trash,
                quitApps: [xcodeApp], revealPath: base + "/DerivedData", symbol: "hammer",
                facts: [Fact("Projects", "\(derived.count)"),
                        Fact("Rebuilt by", "Xcode, automatically", .good),
                        Fact("Cost", "the first build afterwards is slower")],
                quickClean: true))
        }

        var support: [FindingItem] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            support += await DiskMeasure.children(of: "\(base)/\(platform) DeviceSupport", minBytes: 1_000_000).map {
                FindingItem(path: $0.path, bytes: $0.bytes, note: "\(platform) symbols", lastUsed: RuleKit.modified($0.path), usedBy: "Xcode debugger")
            }
        }
        if RuleKit.total(support) >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "xcode-device-support", title: "Xcode device support files",
                detail: "Debug symbols Xcode copied from devices you connected.",
                tier: .safe, bytes: RuleKit.total(support), items: support, action: .trash,
                quitApps: [xcodeApp], revealPath: base, symbol: "cable.connector",
                facts: [Fact("Rebuilt by", "Xcode, the next time you connect that device"),
                        Fact("Cost", "connecting the device takes a few minutes longer once")]))
        }

        let archives = await DiskMeasure.children(of: base + "/Archives", minBytes: 1_000_000).map {
            FindingItem(path: $0.path, bytes: $0.bytes, note: "archives from \(($0.path as NSString).lastPathComponent)",
                        selectedByDefault: false, lastUsed: RuleKit.modified($0.path), usedBy: "Organizer", quickSafe: false)
        }
        if RuleKit.total(archives) >= RuleKit.minimumFindingBytes {
            findings.append(Finding(
                id: "xcode-archives", title: "Xcode archives",
                detail: "Builds made with Product → Archive. Pick only the ones you no longer need.",
                tier: .review, bytes: RuleKit.total(archives), items: archives, action: .trash,
                quitApps: [xcodeApp], revealPath: base + "/Archives", symbol: "archivebox",
                facts: [Fact("Contains", "dSYMs used to read crash reports from shipped builds", .warning)],
                risk: "Crash reports from builds you shipped can't be symbolicated without their archive."))
        }
        return findings
    }
}
#endif
