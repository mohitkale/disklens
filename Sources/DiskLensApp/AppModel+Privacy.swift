import AppKit
import DiskLensCore
import Foundation

enum PrivacyFilter: String, CaseIterable, Identifiable {
    case all, location, device, people, documents
    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .location: "Location"
        case .device: "Device & serials"
        case .people: "Names"
        case .documents: "Documents"
        }
    }

    func matches(_ r: MetadataReport) -> Bool {
        switch self {
        case .all: true
        case .location: r.revealsLocation
        case .device: r.device != nil || !r.serials.isEmpty
        case .people: !r.people.isEmpty
        case .documents: r.kind == .pdf || r.kind == .office
        }
    }
}

/// A metadata clean the user is confirming, running or reviewing.
struct PrivacyJob {
    enum Phase { case confirm, running, finished }
    var phase: Phase = .confirm
    var reports: [MetadataReport]
    var level: MetadataCleaner.Level = .identifying
    /// Replacing is reversible because originals go to the Trash.
    var mode: MetadataCleaner.Mode = .replaceOriginal
    var done = 0
    var results: [MetadataCleaner.Result] = []
}

extension AppModel {
    var privacyShown: [MetadataReport] { privacyReports.filter(privacyFilter.matches) }
    var privacyCleanable: [MetadataReport] { privacyShown.filter(\.canClean) }
    var privacyHotspots: [Hotspot] { Hotspots.find(privacyReports) }
    var isScanningPrivacy: Bool { privacyProgress != nil }

    func scanPrivacy() async {
        guard !isScanningPrivacy, !DemoData.isEnabled else { return }
        privacyProgress = (0, 0)
        let reports = await PrivacyScanner.scan(folders: privacyFolders) { done, total in
            Task { @MainActor [weak self] in self?.privacyProgress = (done, total) }
        }
        privacyReports = reports
        privacySelection = []
        privacyScanned = .now
        privacyProgress = nil
    }

    func addPrivacyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders for Privacy Shield to check. It only reads them until you choose to clean."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !privacyFolders.contains(url.path) { privacyFolders.append(url.path) }
    }

    func removePrivacyFolder(_ path: String) {
        privacyFolders.removeAll { $0 == path }
    }

    enum SelectionState3 { case none, some, all }

    var privacySelectionState: SelectionState3 {
        let ids = Set(privacyCleanable.map(\.path))
        let picked = ids.intersection(privacySelection)
        return picked.isEmpty ? .none : picked == ids ? .all : .some
    }

    func toggleAllPrivacy() {
        let ids = Set(privacyCleanable.map(\.path))
        if privacySelectionState == .all { privacySelection.subtract(ids) } else { privacySelection.formUnion(ids) }
    }

    func selectPrivacy(_ paths: [String]) {
        privacyFilter = .all
        privacySelection = Set(paths)
    }

    func startPrivacyClean() {
        let chosen = privacyReports.filter { privacySelection.contains($0.path) && $0.canClean }
        guard !chosen.isEmpty else { return }
        privacyJob = PrivacyJob(reports: chosen,
                                level: chosen.contains(where: \.revealsIdentity) ? .identifying : .location)
    }

    func runPrivacyClean() async {
        guard var job = privacyJob, job.phase == .confirm, !DemoData.isEnabled else { return }
        job.phase = .running
        privacyJob = job
        for report in job.reports {
            let result = await MetadataCleaner.clean(report, level: job.level, mode: job.mode)
            privacyJob?.results.append(result)
            privacyJob?.done += 1
        }
        let cleaned = Set((privacyJob?.results ?? []).filter(\.ok).map(\.path))
        if job.mode == .replaceOriginal {
            // Re-read cleaned files so the list reflects what they reveal now.
            var updated: [MetadataReport] = []
            for r in privacyReports {
                if cleaned.contains(r.path), let fresh = await MetadataInspector.inspect(r.path) {
                    if fresh.revealsAnything { updated.append(fresh) }
                } else {
                    updated.append(r)
                }
            }
            privacyReports = updated
        }
        privacySelection.subtract(cleaned)
        let ok = privacyJob?.results.filter(\.ok).count ?? 0
        if ok > 0 {
            addLog(LogEntry(title: "Privacy Shield: \(job.level == .location ? "removed location" : "removed identifying info")",
                            bytes: 0, outcome: job.mode == .replaceOriginal ? .trashed : .freed,
                            detail: "\(ok) file(s) cleaned" + (job.mode == .replaceOriginal ? "; originals moved to the Trash" : "; clean copies saved next to the originals")))
        }
        privacyJob?.phase = .finished
    }
}
