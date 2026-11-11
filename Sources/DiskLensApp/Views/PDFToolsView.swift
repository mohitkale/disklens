import AppKit
import DiskLensCore
import SwiftUI

/// Compress, merge, split, make searchable and redact PDFs. Nothing is uploaded; new files are saved next to the originals.
struct PDFToolsView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    private static let targets: [Int64] = [1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PDF Tools").font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("Everything happens on this Mac: your PDFs are never uploaded. New files are saved next to the originals.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Tool", selection: $model.pdfTool) {
                        ForEach(PDFTool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560).handCursor()
                    .onChange(of: model.pdfTool) { _, tool in
                        model.pdfResults = [:]
                        if tool == .redact, model.pdfFiles.count > 1 { model.pdfFiles = Array(model.pdfFiles.prefix(1)) }
                        if tool == .redact, let f = model.pdfFiles.first { model.redactSuggestions = PDFTools.suggestedTerms(f) }
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    files
                    options.frame(width: 420)
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .navigationTitle("PDF Tools")
    }

    private var files: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: model.pdfTool == .merge ? "PDFs, in order" : model.pdfTool == .redact ? "PDF" : "PDFs",
                          subtitle: model.pdfFiles.isEmpty ? "Drop PDFs here or choose them." : model.pdfTool == .merge ? "Drag to change the order." : nil,
                          symbol: "doc.richtext")
            if model.pdfFiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Drop PDFs").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
            }
            ForEach(Array(model.pdfFiles.enumerated()), id: \.element) { index, path in
                PDFFileRow(path: path, index: index)
            }
            HStack {
                Button { model.choosePDFs() } label: { Label(model.pdfTool == .redact ? "Choose PDF…" : "Add PDFs…", systemImage: "plus") }
                    .buttonStyle(SoftButtonStyle())
                if !model.pdfFiles.isEmpty {
                    Button("Clear") { model.pdfFiles = []; model.pdfResults = [:]; model.redactSuggestions = [] }
                        .buttonStyle(SoftButtonStyle(tint: .secondary))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .premiumCard()
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.brandStart, lineWidth: dropping ? 2 : 0))
        .dropDestination(for: URL.self) { urls, _ in
            if model.pdfTool == .redact { model.pdfFiles = [] }
            model.addPDFs(model.pdfTool == .redact ? Array(urls.map(\.path).prefix(1)) : urls.map(\.path))
            return true
        } isTargeted: { dropping = $0 }
    }

    @ViewBuilder private var options: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: model.pdfTool.title, symbol: model.pdfTool.symbol)
            switch model.pdfTool {
            case .compress:
                Picker("", selection: $model.pdfLevel) {
                    ForEach(PDFTools.Level.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().handCursor()
                Text(model.pdfLevel.detail).font(.caption).foregroundStyle(.secondary)
                Picker("Size limit", selection: $model.pdfTarget) {
                    Text("No limit").tag(Int64?.none)
                    ForEach(Self.targets, id: \.self) { Text("Under \(ByteFormat.string($0))").tag(Int64?.some($0)) }
                }.handCursor().help("Tries each level, from best quality down, until the PDF fits")
                note("Text, links and pages are kept. Scanned PDFs are re-encoded and their text recognised, so they stay searchable. Mostly-text PDFs are already compact: DiskLens says so instead of making them worse.")
            case .merge:
                note("Combines the PDFs in this order into “Merged.pdf”, next to the first one.")
            case .split:
                TextField("Pages, e.g. 1-3, 5, 8-10 (empty: one file per page)", text: $model.pdfSplitRanges)
                    .textFieldStyle(.roundedBorder)
                note("Each range becomes its own PDF, saved next to the original.")
            case .searchable:
                note("Recognises the text in scanned pages so you can search, select and copy it. Pages that already have text stay exactly as they are.")
            case .redact:
                Text("Words or numbers to remove, one per line or separated by commas").font(.callout)
                TextEditor(text: $model.redactTerms)
                    .font(.callout).frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                if !model.redactSuggestions.isEmpty {
                    Text("Found in this PDF:").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(model.redactSuggestions, id: \.self) { term in
                            Button { addTerm(term) } label: { Label(term, systemImage: "plus").font(.caption) }
                                .buttonStyle(SoftButtonStyle(tint: .secondary)).help("Add to the words to remove")
                        }
                    }
                }
                note("Each page with a match becomes an image of the page with black boxes painted in, so the text underneath is really gone, not just covered. The rest of the page stays searchable. Author and title are cleared, and the result is searched again to check.")
            }
            Divider()
            if let p = model.pdfProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                Text("Working on \(min(p.done + 1, p.total)) of \(p.total)…").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button { Task { await model.runPDFTool() } } label: { Label(actionTitle, systemImage: model.pdfTool.symbol) }
                    .buttonStyle(GradientButtonStyle(large: true))
                    .disabled(model.pdfFiles.isEmpty || model.pdfProgress != nil || DemoData.isEnabled
                              || (model.pdfTool == .merge && model.pdfFiles.count < 2)
                              || (model.pdfTool == .redact && model.redactTermList.isEmpty))
                    .help("Saves new files next to the originals. The originals aren't changed.")
            }
        }
        .premiumCard()
    }

    private var actionTitle: String {
        switch model.pdfTool {
        case .compress: "Compress \(model.pdfFiles.count)"
        case .merge: "Merge \(model.pdfFiles.count)"
        case .split: "Split"
        case .searchable: "Make Searchable"
        case .redact: "Redact"
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func addTerm(_ term: String) {
        let existing = model.redactTermList
        guard !existing.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        model.redactTerms = (existing + [term]).joined(separator: "\n")
    }
}

private struct PDFFileRow: View {
    @Environment(AppModel.self) private var model
    let path: String
    let index: Int
    @State private var targeted = false

    var body: some View {
        let result = model.pdfResults[path]
        let info = PDFTools.info(path)
        HStack(spacing: 10) {
            if model.pdfTool == .merge { Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 16) }
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let result {
                    Text(result.message + (result.method.isEmpty ? "" : " · \(result.method)"))
                        .font(.caption).foregroundStyle(result.ok ? Theme.safe : .secondary).lineLimit(2)
                } else if let info {
                    Text("\(info.pages) page\(info.pages == 1 ? "" : "s") · \(ByteFormat.string(info.bytes))" + (info.textCharacters < 40 * info.pages ? " · scanned or pictures" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let out = result?.outputs, !out.isEmpty {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(out.map { URL(fileURLWithPath: $0) }) }
                    .buttonStyle(.textLink).font(.caption).help("Show the new file\(out.count == 1 ? "" : "s") in Finder")
            }
            Button { model.pdfFiles.removeAll { $0 == path }; model.pdfResults[path] = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle()).help("Remove from the list")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Theme.brandStart.opacity(0.1) : .clear))
        .help(path)
        .draggable(path)
        .dropDestination(for: String.self) { items, _ in
            guard let moving = items.first, moving != path, let from = model.pdfFiles.firstIndex(of: moving) else { return false }
            model.pdfFiles.remove(at: from)
            model.pdfFiles.insert(moving, at: model.pdfFiles.firstIndex(of: path) ?? model.pdfFiles.count)
            return true
        } isTargeted: { targeted = $0 }
    }
}
