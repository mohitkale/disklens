import AppKit
import DiskLensCore
import Foundation

enum AppsTab: String, CaseIterable, Identifiable {
    case uninstall, leftovers, startup, extensions
    var id: Self { self }
    var title: String {
        switch self {
        case .uninstall: "Uninstall"
        case .leftovers: "Leftovers"
        case .startup: "Startup Items"
        case .extensions: "Browser Extensions"
        }
    }
    var symbol: String {
        switch self {
        case .uninstall: "trash.square"
        case .leftovers: "archivebox"
        case .startup: "power"
        case .extensions: "puzzlepiece.extension"
        }
    }
}

extension AppModel {
    static let orphansFindingID = "app-leftovers"
    static let uninstallPrefix = "uninstall-"
    static let startupPrefix = "startup-"

    var isScanningApps: Bool { appsProgress != nil }

    var appsShown: [AppFootprint] {
        let q = appSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? appFootprints : appFootprints.filter { $0.app.name.lowercased().contains(q) || ($0.app.bundleID ?? "").lowercased().contains(q) }
    }

    var orphanSelectedBytes: Int64 { orphanItems.filter { orphanSelection.contains($0.path) }.reduce(0) { $0 + $1.bytes } }

    /// Measures every app and what it keeps in the Library, finds leftovers of removed apps,
    /// and lists startup items and browser extensions. Read-only.
    func scanApps() async {
        guard !isScanningApps, !DemoData.isEnabled else { return }
        appsProgress = (0, 0)
        let apps = AppIndex.installedApps()
        appFootprints = await AppUninstaller.footprints(apps: apps) { done, total in
            Task { @MainActor [weak self] in self?.appsProgress = (done, total) }
        }
        orphanItems = await AppUninstaller.orphanedLeftovers(apps: apps)
        orphanSelection = []
        startupItems = StartupInspector.items()
        browserExtensions = StartupInspector.browserExtensions()
        appsScanned = .now
        appsProgress = nil
    }

    /// The app plus everything it keeps in your Library, as one review the user confirms.
    func reviewUninstall(_ footprint: AppFootprint) {
        let app = footprint.app
        let bundle = FindingItem(path: app.path, bytes: footprint.appBytes, note: "the app itself",
                                 lastUsed: app.lastUsed, usedBy: app.name, quickSafe: false)
        // App Store apps are removed from Launchpad; DiskLens only clears their data.
        let items = (app.isManaged ? [] : [bundle]) + footprint.leftovers
        guard !items.isEmpty else { return }
        let finding = Finding(
            id: Self.uninstallPrefix + (app.bundleID ?? app.name), title: app.isManaged ? "Remove \(app.name)'s data" : "Uninstall \(app.name)",
            detail: "Moves \(app.name) and the data it keeps in your Library to the Trash. Untick anything you want to keep, such as settings for a future reinstall.",
            tier: .review, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .trash,
            quitApps: app.bundleID.map { [$0] } ?? [], symbol: "trash.square",
            risk: "Documents you saved with \(app.name) in your own folders are not touched. Removing its app data also removes its settings, history and sign-ins. Everything can be put back from the Trash until you empty it.")
        selections[finding.id] = Set(items.map(\.path))
        review([finding])
    }

    func reviewOrphans() {
        let items = orphanItems.filter { orphanSelection.contains($0.path) }
        guard !items.isEmpty else { return }
        let finding = Finding(
            id: Self.orphansFindingID, title: "Leftovers of removed apps (\(items.count))",
            detail: "Library folders named after apps that are no longer installed on this Mac.",
            tier: .review, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .trash, symbol: "archivebox",
            risk: "If you reinstall one of these apps later, it starts fresh without its old settings or data. Put the folder back from the Trash if you need it.")
        selections[finding.id] = Set(items.map(\.path))
        review([finding])
    }

    /// Only your own login items (in ~/Library/LaunchAgents) can be removed here.
    func canRemove(_ item: StartupItem) -> Bool { item.kind == .userAgent && !DemoData.isEnabled }

    func reviewRemoveStartup(_ item: StartupItem) {
        let entry = FindingItem(path: item.path, bytes: Int64((try? FileManager.default.attributesOfItem(atPath: item.path))?[.size] as? Int ?? 0),
                                note: item.program ?? item.label, lastUsed: item.modified, usedBy: item.owner ?? item.label, quickSafe: false)
        let finding = Finding(
            id: Self.startupPrefix + item.label, title: "Stop \(item.owner ?? item.label) starting at login",
            detail: "Moves its login item to the Trash. It stops after you log out or restart.",
            tier: .review, bytes: entry.bytes, items: [entry], action: .trash, symbol: "power",
            risk: item.owner.map { "\($0) may stop syncing, updating or showing notifications in the background. Opening \($0) may add it back." }
                ?? "Whatever this helper does in the background stops. Put it back from the Trash if something you use stops working.")
        selections[finding.id] = [item.path]
        review([finding])
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    /// Drops apps, leftovers and login items that were moved to the Trash.
    func pruneApps() {
        guard let plan else { return }
        var gone = Set<String>()
        for entry in plan.entries {
            let id = entry.finding.id
            guard id == Self.orphansFindingID || id.hasPrefix(Self.uninstallPrefix) || id.hasPrefix(Self.startupPrefix),
                  case let .done(result) = entry.status else { continue }
            gone.formUnion(result.trashed)
            completed[id] = nil
        }
        guard !gone.isEmpty else { return }
        appFootprints = appFootprints.compactMap { f in
            if gone.contains(f.app.path) { return nil }
            let left = f.leftovers.filter { !gone.contains($0.path) }
            return AppFootprint(app: f.app, appBytes: f.appBytes, leftovers: left)
        }
        orphanItems.removeAll { gone.contains($0.path) }
        orphanSelection.subtract(gone)
        startupItems.removeAll { gone.contains($0.path) }
    }
}
