import AppKit
import DiskLensCore
import Foundation
import UniformTypeIdentifiers

/// The result of making one file smaller, splitting it, redacting it, and so on.
struct FileOutcome: Hashable {
    var ok: Bool
    var outputs: [String]
    var before: Int64
    var after: Int64
    var message: String
    var method = ""
    var saved: Int64 { ok ? max(0, before - after) : 0 }
}

enum PDFTool: String, CaseIterable, Identifiable {
    case compress, merge, split, searchable, redact
    var id: Self { self }
    var title: String {
        switch self {
        case .compress: "Compress"
        case .merge: "Merge"
        case .split: "Split"
        case .searchable: "Make Searchable"
        case .redact: "Redact"
        }
    }
    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .merge: "rectangle.stack.badge.plus"
        case .split: "scissors"
        case .searchable: "text.viewfinder"
        case .redact: "eye.slash"
        }
    }
}

enum CutoutBackground: String, CaseIterable, Identifiable {
    case transparent, white, black, color
    var id: Self { self }
    var label: String { rawValue.capitalized }
}

extension AppModel {
    static let shrinkOriginalsID = "shrink-originals"

    // MARK: Shrink: biggest files

    var shrinkEstimatedSaving: Int64 { shrinkCandidates.compactMap(\.estimatedSaving).reduce(0, +) }
    var shrinkDoneSaving: Int64 { shrinkResults.values.reduce(0) { $0 + $1.saved } }

    func scanShrink() async {
        guard !isScanningShrink, !DemoData.isEnabled else { return }
        isScanningShrink = true
        progress = "Looking for big files"
        shrinkCandidates = await ShrinkFinder.scan { message in Task { @MainActor [weak self] in self?.progress = message } }
        shrinkResults = shrinkResults.filter { k, _ in shrinkCandidates.contains { $0.path == k } }
        shrinkScanned = .now
        isScanningShrink = false
        progress = ""
    }

    /// Writes a smaller copy next to the original and checks it. The original isn't touched.
    func shrink(_ c: ShrinkCandidate) async {
        guard !DemoData.isEnabled, !shrinking.contains(c.path) else { return }
        shrinking.insert(c.path)
        defer { shrinking.remove(c.path) }
        let r = await ShrinkFinder.makeSmaller(c)
        shrinkResults[c.path] = FileOutcome(ok: r.ok, outputs: r.output.map { [$0] } ?? [], before: r.before, after: r.after,
                                            message: r.message, method: r.method)
        if r.ok {
            addLog(LogEntry(title: "Made a smaller copy of \(c.name)", bytes: 0, outcome: .freed,
                            detail: "\(ByteFormat.string(c.bytes)) → \(ByteFormat.string(r.after)). The original is unchanged."))
        }
    }

    /// The originals of files that now have a checked, smaller copy: reviewed, then moved to the Trash.
    func reviewShrinkOriginals(_ paths: [String]) {
        let items = paths.compactMap { path -> FindingItem? in
            guard let o = shrinkResults[path], o.ok, let copy = o.outputs.first, FileManager.default.fileExists(atPath: copy) else { return nil }
            return FindingItem(path: path, bytes: o.saved, note: "smaller copy: \((copy as NSString).lastPathComponent)",
                               lastUsed: RuleKitShim.modified(path), usedBy: "you", quickSafe: false)
        }
        guard !items.isEmpty else { return }
        let finding = Finding(
            id: Self.shrinkOriginalsID, title: "Originals of files you made smaller (\(items.count))",
            detail: "Each one has a checked smaller copy next to it. Moving the original to the Trash frees the difference.",
            tier: .review, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .trash, symbol: "arrow.down.right.and.arrow.up.left",
            risk: "The smaller copy is lower in file size, and for videos and photos slightly lower in quality. Keep the original if you might edit it again or need full quality. It stays in the Trash until you empty it.")
        selections[finding.id] = Set(items.map(\.path))
        review([finding])
    }

    func pruneShrink() {
        guard let entry = plan?.entries.first(where: { $0.finding.id == Self.shrinkOriginalsID }),
              case let .done(result) = entry.status else { return }
        let gone = Set(result.trashed)
        shrinkCandidates.removeAll { gone.contains($0.path) }
        for g in gone { if var o = shrinkResults[g] { o.message += " · original in the Trash"; shrinkResults[g] = o } }
        shrinkTrashed.formUnion(gone)
        completed[Self.shrinkOriginalsID] = nil
    }

    /// Any files the user drops or picks: PDFs, videos (to a size limit) and photos.
    func addShrinkFiles(_ paths: [String]) {
        Task {
            for path in paths where !shrinkCandidates.contains(where: { $0.path == path }) {
                let ext = (path as NSString).pathExtension.lowercased()
                let bytes = Int64((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0)
                let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                let kind: ShrinkCandidate.Kind? = ext == "pdf" ? .pdf : AppModel.isVideo(path) ? .video : AppModel.isMedia(path) ? .image : nil
                guard let kind else { continue }
                shrinkCandidates.insert(ShrinkCandidate(path: path, kind: kind, bytes: bytes, estimate: nil, detail: "added by you", modified: date), at: 0)
            }
        }
    }

    func chooseShrinkFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .movie, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs, videos or photos to make smaller. DiskLens saves a smaller copy next to each; the originals stay."
        guard panel.runModal() == .OK else { return }
        addShrinkFiles(panel.urls.map(\.path))
    }

    // MARK: PDF Tools

    func addPDFs(_ paths: [String]) {
        for p in paths where p.lowercased().hasSuffix(".pdf") && !pdfFiles.contains(p) { pdfFiles.append(p) }
        if pdfTool == .redact, let first = pdfFiles.first { redactSuggestions = PDFTools.suggestedTerms(first) }
    }

    func choosePDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = pdfTool != .redact
        panel.message = "Choose PDFs. DiskLens saves new files next to them; the originals stay exactly as they are."
        guard panel.runModal() == .OK else { return }
        if pdfTool == .redact { pdfFiles = [] }
        addPDFs(panel.urls.map(\.path))
    }

    var redactTermList: [String] {
        redactTerms.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func runPDFTool() async {
        guard !pdfFiles.isEmpty, pdfProgress == nil, !DemoData.isEnabled else { return }
        pdfResults = [:]
        let files = pdfFiles
        pdfProgress = (0, files.count)
        switch pdfTool {
        case .merge:
            let first = URL(fileURLWithPath: files[0])
            do {
                let url = try PDFTools.merge(files, to: first.deletingLastPathComponent().appendingPathComponent("Merged.pdf"))
                let pages = PDFTools.info(url.path)?.pages ?? 0
                pdfResults[files[0]] = FileOutcome(ok: true, outputs: [url.path], before: 0, after: fileSize(url.path),
                                                   message: "\(files.count) PDFs → \(url.lastPathComponent), \(pages) pages")
            } catch {
                pdfResults[files[0]] = FileOutcome(ok: false, outputs: [], before: 0, after: 0, message: error.localizedDescription)
            }
        case .split:
            let ranges = pdfSplitRanges.trimmingCharacters(in: .whitespaces).isEmpty ? nil : PDFTools.parseRanges(pdfSplitRanges)
            if ranges == nil && !pdfSplitRanges.trimmingCharacters(in: .whitespaces).isEmpty {
                pdfResults[files[0]] = FileOutcome(ok: false, outputs: [], before: 0, after: 0, message: "Use page ranges like 1-3, 5, 8-10")
                break
            }
            for (i, f) in files.enumerated() {
                do {
                    let parts = try PDFTools.split(f, ranges: ranges)
                    pdfResults[f] = FileOutcome(ok: true, outputs: parts.map(\.path), before: fileSize(f), after: 0,
                                                message: "\(parts.count) file\(parts.count == 1 ? "" : "s") saved next to it")
                } catch {
                    pdfResults[f] = FileOutcome(ok: false, outputs: [], before: 0, after: 0, message: error.localizedDescription)
                }
                pdfProgress = (i + 1, files.count)
            }
        case .compress, .searchable:
            for (i, f) in files.enumerated() {
                let r = pdfTool == .compress ? await PDFTools.compress(f, level: pdfLevel, targetBytes: pdfTarget)
                                            : await PDFTools.makeSearchable(f)
                pdfResults[f] = FileOutcome(ok: r.ok, outputs: r.output.map { [$0] } ?? [], before: r.originalBytes, after: r.bytes,
                                            message: r.message, method: r.method)
                pdfProgress = (i + 1, files.count)
            }
        case .redact:
            let f = files[0]
            let r = await PDFTools.redact(f, terms: redactTermList)
            pdfResults[f] = FileOutcome(ok: r.output != nil, outputs: r.output.map { [$0] } ?? [], before: fileSize(f),
                                        after: r.output.map(fileSize) ?? 0, message: r.message, method: r.verified ? "checked: the words can't be found in the result" : "")
        }
        pdfProgress = nil
        let ok = pdfResults.values.filter(\.ok).count
        if ok > 0 {
            addLog(LogEntry(title: "PDF \(pdfTool.title.lowercased()): \(ok) file\(ok == 1 ? "" : "s")", bytes: 0, outcome: .freed,
                            detail: "Saved next to the originals, which are unchanged"))
        }
    }

    private func fileSize(_ p: String) -> Int64 { Int64((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int ?? 0) }

    // MARK: Cut Out (remove background)

    var cutoutSelected: MediaItem? { cutoutItems.first { $0.id == cutoutPreviewID } ?? cutoutItems.first }

    var cutoutColor: CGColor? {
        switch cutoutBackground {
        case .transparent: nil
        case .white: CGColor(gray: 1, alpha: 1)
        case .black: CGColor(gray: 0, alpha: 1)
        case .color: cutoutCustomColor
        }
    }

    func addCutoutPhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos of people, pets or objects. The originals are never changed."
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls where !cutoutItems.contains(where: { $0.filePath == url.path }) {
                if let item = await MediaLibrary.item(at: url.path), item.kind == .photo { cutoutItems.append(item) }
            }
            if cutoutPreviewID == nil { cutoutPreviewID = cutoutItems.first?.id }
            await refreshCutoutPreview()
        }
    }

    func useEventForCutout(_ event: MediaEvent) async {
        cutoutItems = Array(includedItems(event).filter { $0.kind == .photo }.prefix(30))
        cutoutPreviewID = cutoutItems.first?.id
        mediaTool = .cutout
        await refreshCutoutPreview()
    }

    func refreshCutoutPreview() async {
        guard let item = cutoutSelected else { cutoutPreview = nil; return }
        let image = await thumbnail(item, maxPixels: 1200)
        let color = cutoutColor
        cutoutPreview = await Task.detached { image.flatMap { BackgroundRemover.cutout($0, background: color) } }.value
        cutoutNoSubject = image != nil && cutoutPreview == nil
    }

    func saveCutouts() async {
        guard !DemoData.isEnabled, !cutoutItems.isEmpty else { return }
        try? FileManager.default.createDirectory(at: cutoutFolder, withIntermediateDirectories: true)
        cutoutResults = []
        cutoutProgress = (0, cutoutItems.count)
        let folder = cutoutFolder, color = cutoutColor
        for (i, item) in cutoutItems.enumerated() {
            let r: ConvertResult
            if let path = item.filePath {
                r = await Task.detached { BackgroundRemover.save(path, background: color, into: folder) }.value
            } else if let image = await MediaLibrary.image(for: item, maxPixels: 8_192) {
                let name = item.name
                r = await Task.detached { BackgroundRemover.save(image, name: name, background: color, into: folder) }.value
            } else {
                r = ConvertResult(source: item.name, output: nil, bytes: 0, pixelSize: .zero, message: "Only in iCloud: download it in Photos first")
            }
            cutoutResults.append(r)
            cutoutProgress = (i + 1, cutoutItems.count)
        }
        cutoutProgress = nil
        let ok = cutoutResults.filter(\.ok).count
        addLog(LogEntry(title: "Cut out \(ok) photo\(ok == 1 ? "" : "s")", bytes: 0, outcome: .freed,
                        detail: "Saved to \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"))
    }
}

/// File dates without reaching into DiskLensCore internals.
enum RuleKitShim {
    static func modified(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
}
