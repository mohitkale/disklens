import DiskLensCore
import Foundation

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
}
