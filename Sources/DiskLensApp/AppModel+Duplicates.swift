import AppKit
import DiskLensCore
import Foundation
import Photos

enum DuplicatesTab: String, CaseIterable, Identifiable {
    case identical, similar
    var id: Self { self }
    var title: String { self == .identical ? "Identical Files" : "Similar & Blurry Photos" }
    var symbol: String { self == .identical ? "doc.on.doc" : "square.stack.3d.down.right" }
}

extension AppModel {
    static let duplicatesFindingID = "duplicate-files"

    var duplicateReclaimable: Int64 { duplicateGroups.reduce(0) { $0 + $1.reclaimable } }

    /// Space freed by the currently selected copies (clones free nothing).
    var duplicateSelectedBytes: Int64 {
        duplicateGroups.flatMap { g in g.files.filter { duplicateSelection.contains($0.path) && !g.clonePaths.contains($0.path) } }
            .reduce(0) { $0 + $1.bytes }
    }

    func scanDuplicates() async {
        guard !isFindingDuplicates, !DemoData.isEnabled else { return }
        isFindingDuplicates = true
        progress = "Listing files"
        let groups = await DuplicateFinder.scan(roots: duplicateRoots) { message in
            Task { @MainActor [weak self] in self?.progress = message }
        }
        duplicateGroups = groups
        selectSuggestedDuplicates()
        duplicatesScanned = .now
        isFindingDuplicates = false
        progress = ""
    }

    /// Every copy except the one DiskLens suggests keeping.
    func selectSuggestedDuplicates() {
        duplicateSelection = Set(duplicateGroups.flatMap { g in g.files.map(\.path).filter { $0 != g.keep } })
    }

    func isDuplicateSelected(_ path: String) -> Bool { duplicateSelection.contains(path) }

    /// At least one copy in every group always stays.
    func canToggleDuplicate(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        if duplicateSelection.contains(file.path) { return true }
        return group.files.filter { !duplicateSelection.contains($0.path) }.count > 1
    }

    func toggleDuplicate(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard canToggleDuplicate(file, in: group) else { return }
        if duplicateSelection.contains(file.path) { duplicateSelection.remove(file.path) } else { duplicateSelection.insert(file.path) }
    }

    func keepOnly(_ file: DuplicateFile, in group: DuplicateGroup) {
        for f in group.files { if f.path == file.path { duplicateSelection.remove(f.path) } else { duplicateSelection.insert(f.path) } }
    }

    /// Hands the selected copies to the standard review sheet (re-checked, then moved to the Trash).
    func reviewDuplicates() {
        let items = duplicateGroups.flatMap { g in
            g.files.filter { duplicateSelection.contains($0.path) }.map { f in
                FindingItem(path: f.path, bytes: g.clonePaths.contains(f.path) ? 0 : f.bytes,
                            note: "copy of \((g.keep as NSString).lastPathComponent)" + (g.clonePaths.contains(f.path) ? " · APFS clone, frees no space" : ""),
                            lastUsed: f.modified, usedBy: "you", quickSafe: false)
            }
        }
        guard !items.isEmpty else { return }
        let finding = Finding(
            id: Self.duplicatesFindingID, title: "Duplicate files (\(items.count))",
            detail: "Extra copies of files that are identical byte for byte. One copy of each always stays.",
            tier: .review, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .trash,
            symbol: "doc.on.doc",
            risk: "If an app or project expects a file at a specific path, it won't find the removed copy. Put it back from the Trash if needed.")
        selections[finding.id] = Set(items.map(\.path))
        review([finding])
    }

    /// Drops copies that were moved to the Trash, and groups with a single file left.
    func pruneDuplicates() {
        guard let entry = plan?.entries.first(where: { $0.finding.id == Self.duplicatesFindingID }),
              case let .done(result) = entry.status else { return }
        let gone = Set(result.trashed)
        duplicateGroups = duplicateGroups.compactMap { g in
            let files = g.files.filter { !gone.contains($0.path) }
            return files.count > 1 ? DuplicateFinder.regroup(g, keeping: files) : nil
        }
        duplicateSelection.subtract(gone)
        completed[Self.duplicatesFindingID] = nil
    }

    // MARK: Similar & blurry photos

    static let similarFindingID = "similar-photos"
    /// Checking every photo takes about 40 ms each; the newest ones matter most.
    static let similarPhotoLimit = 5_000

    var isScanningSimilar: Bool { similarProgress != nil }

    var similarSelectedItems: [MediaItem] {
        guard let r = similarResult else { return [] }
        return (r.groups.flatMap(\.items) + r.blurry).filter { similarSelection.contains($0.id) }
    }

    func scanSimilarInPhotos() async {
        guard !isScanningSimilar, !DemoData.isEnabled else { return }
        similarProgress = (0, 0)
        guard await MediaLibrary.requestPhotosAccess() else {
            similarSourceLabel = "Photos access was not allowed. Turn it on in System Settings → Privacy & Security → Photos."
            similarProgress = nil
            return
        }
        let items = MediaLibrary.photosLibraryItems().filter { $0.kind == .photo }.sorted { $0.date > $1.date }
        similarSourceLabel = items.count > Self.similarPhotoLimit ? "Photos library · newest \(Self.similarPhotoLimit.formatted()) photos" : "Photos library"
        await analyzeSimilar(Array(items.prefix(Self.similarPhotoLimit)))
    }

    func scanSimilarInFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Check This Folder"
        panel.message = "Choose a folder of photos. DiskLens only reads it."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task {
            similarProgress = (0, 0)
            let items = await MediaLibrary.scanFolders(panel.urls.map(\.path))
            similarSourceLabel = panel.urls.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", ")
            await analyzeSimilar(items)
        }
    }

    private func analyzeSimilar(_ items: [MediaItem]) async {
        similarProgress = (0, items.count)
        let result = await SimilarPhotos.analyze(items, image: { await MediaLibrary.image(for: $0, maxPixels: 512) }) { done, total in
            Task { @MainActor [weak self] in self?.similarProgress = (done, total) }
        }
        similarResult = result
        selectSuggestedSimilar()
        similarScanned = .now
        similarProgress = nil
    }

    /// Every photo except the sharpest of each group. Blurry photos are left for the user to tick.
    func selectSuggestedSimilar() {
        similarSelection = Set((similarResult?.groups ?? []).flatMap { g in g.items.map(\.id).filter { $0 != g.keep } })
    }

    func toggleSimilar(_ item: MediaItem, in group: SimilarGroup?) {
        if similarSelection.contains(item.id) { similarSelection.remove(item.id); return }
        // At least one photo of each group stays.
        if let group, group.items.filter({ !similarSelection.contains($0.id) }).count <= 1 { return }
        similarSelection.insert(item.id)
    }

    /// Files go through the standard review sheet (Trash). Photos-library items go to Recently Deleted
    /// after DiskLens and then macOS ask for confirmation.
    func reviewSimilar() async {
        let chosen = similarSelectedItems
        guard !chosen.isEmpty else { return }
        let files = chosen.compactMap { item -> FindingItem? in
            guard let path = item.filePath else { return nil }
            return FindingItem(path: path, bytes: item.bytes, note: similarResult?.blurry.contains(item) == true ? "blurry" : "similar to a sharper shot",
                               lastUsed: item.date, usedBy: "you", quickSafe: false)
        }
        if !files.isEmpty {
            let finding = Finding(
                id: Self.similarFindingID, title: "Similar and blurry photos (\(files.count))",
                detail: "Near-identical shots and blurry photos. The sharpest photo of each set stays.",
                tier: .review, bytes: files.reduce(0) { $0 + $1.bytes }, items: files, action: .trash, symbol: "square.stack.3d.down.right",
                risk: "Similar isn't identical: check the shots you're removing. They can be put back from the Trash.")
            selections[finding.id] = Set(files.map(\.path))
            review([finding])
            return
        }
        let ids = chosen.compactMap { if case let .photos(id) = $0.origin { id } else { nil } }
        let alert = NSAlert()
        alert.messageText = "Delete \(ids.count) photo\(ids.count == 1 ? "" : "s") from your Photos library?"
        alert.informativeText = "They move to Recently Deleted in Photos, where you can recover them for 30 days. If you use iCloud Photos, they're removed from your other devices too."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        // macOS shows its own confirmation too.
        guard (try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }) != nil else { return }
        let bytes = chosen.reduce(0) { $0 + $1.bytes }
        removeSimilar(Set(chosen.map(\.id)))
        addLog(LogEntry(title: "Removed similar and blurry photos", bytes: bytes, outcome: .trashed,
                        detail: "\(ids.count) photo(s) moved to Recently Deleted in Photos"))
    }

    func removeSimilar(_ gone: Set<String>) {
        guard let r = similarResult else { return }
        let groups = r.groups.compactMap { g -> SimilarGroup? in
            let left = g.items.filter { !gone.contains($0.id) }
            guard left.count > 1 else { return nil }
            return SimilarGroup(items: left, keep: left.contains { $0.id == g.keep } ? g.keep : left[0].id, sharpness: g.sharpness)
        }
        similarResult = SimilarResult(groups: groups, blurry: r.blurry.filter { !gone.contains($0.id) }, sharpness: r.sharpness, checked: r.checked)
        similarSelection.subtract(gone)
    }

    func pruneSimilar() {
        guard let entry = plan?.entries.first(where: { $0.finding.id == Self.similarFindingID }),
              case let .done(result) = entry.status else { return }
        removeSimilar(Set(result.trashed))
        completed[Self.similarFindingID] = nil
    }
}
