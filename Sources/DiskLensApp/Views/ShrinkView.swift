import AppKit
import DiskLensCore
import SwiftUI

/// Big videos, PDFs and photos that could be much smaller. DiskLens writes a checked smaller copy next to each;
/// the original is only moved to the Trash if you review and confirm that separately.
struct ShrinkView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.isScanningShrink { Card { ScanProgress(message: model.progress) } }
                if model.shrinkScanned != nil && model.shrinkCandidates.isEmpty && !model.isScanningShrink {
                    Card { Label("No big files that could be meaningfully smaller.", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.safe) }
                }
                if !model.shrinkCandidates.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(model.shrinkCandidates) { c in
                            ShrinkRow(candidate: c)
                            if c.id != model.shrinkCandidates.last?.id { Divider().padding(.leading, 52) }
                        }
                    }
                    .premiumCard(padding: 12)
                }
                howItWorks
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.brandStart, lineWidth: dropping ? 3 : 0).padding(8))
        .dropDestination(for: URL.self) { urls, _ in model.addShrinkFiles(urls.map(\.path)); return true } isTargeted: { dropping = $0 }
        .safeAreaInset(edge: .bottom) { if !readyOriginals.isEmpty { originalsBar } }
        .navigationTitle("Shrink")
    }

    private var readyOriginals: [String] {
        model.shrinkResults.filter { $0.value.ok && !model.shrinkTrashed.contains($0.key) && FileManager.default.fileExists(atPath: $0.key) }.map(\.key).sorted()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(symbol: "arrow.down.right.and.arrow.up.left", color: Theme.brandStart, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text("Make big files smaller").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Screen recordings, camera videos, scanned PDFs and uncompressed images are often several times bigger than they need to be. DiskLens saves a smaller copy next to each and checks it. Your original stays until you choose to move it to the Trash.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.shrinkScanned != nil {
                    HStack(spacing: 8) {
                        Chip(text: "\(model.shrinkCandidates.count) files", symbol: "doc.on.doc", tint: Theme.brandStart)
                        if model.shrinkEstimatedSaving > 0 {
                            Chip(text: "about \(ByteFormat.string(model.shrinkEstimatedSaving)) to save", symbol: "arrow.down.circle", tint: Theme.safe,
                                 help: "Estimated for videos and images. PDFs vary a lot: scans shrink by up to 95%, text barely at all.")
                        }
                        if model.shrinkDoneSaving > 0 {
                            Chip(text: "\(ByteFormat.string(model.shrinkDoneSaving)) saved in copies", symbol: "checkmark", tint: Theme.safe)
                        }
                        if let date = model.shrinkScanned { Chip(text: "Checked \(date.friendly)", symbol: "clock", tint: .secondary) }
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button { Task { await model.scanShrink() } } label: {
                    Label(model.shrinkScanned == nil ? "Find Big Files" : "Check Again", systemImage: "magnifyingglass")
                }
                .buttonStyle(GradientButtonStyle(large: true)).disabled(model.isScanningShrink)
                .help("Looks in Desktop, Documents, Downloads, Movies and Pictures. Read-only; about 10 seconds.")
                Button { model.chooseShrinkFiles() } label: { Label("Choose Files…", systemImage: "plus") }
                    .buttonStyle(.textLink).font(.callout)
                    .help("Make any PDF, video or photo smaller. You can also drop files on this page.")
            }
        }
        .premiumCard()
    }

    private var howItWorks: some View {
        Card {
            SectionHeader(title: "How each kind is made smaller", symbol: "info.circle")
            FactGrid(facts: [
                Fact("Videos", "re-encoded to HEVC at a bitrate that looks the same for their resolution, then checked to play for the full length", .good),
                Fact("PDFs", "images downsampled with text, links and pages kept; scanned PDFs re-encoded and made searchable. If it can't get 10% smaller, nothing is saved", .good),
                Fact("Photos", "PNG, TIFF and huge JPEGs saved as HEIC, which keeps the look at a fraction of the size", .good),
                Fact("Need a size limit?", "Media Studio → Convert fits videos and photos under a size, such as 16 MB for WhatsApp", .info),
            ])
        }
    }

    private var originalsBar: some View {
        let paths = readyOriginals
        let saved = paths.compactMap { model.shrinkResults[$0]?.saved }.reduce(0, +)
        return HStack(spacing: 14) {
            IconTile(symbol: "checkmark.circle", color: Theme.safe, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(paths.count) smaller cop\(paths.count == 1 ? "y" : "ies") ready · \(ByteFormat.string(saved)) to free").font(.headline).monospacedDigit()
                Text("Space is only freed when the original goes. Check a copy first if you like; originals go to the Trash.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.reviewShrinkOriginals(paths) } label: { Label("Review Originals…", systemImage: "list.bullet.clipboard") }
                .buttonStyle(GradientButtonStyle(large: true))
                .help("Review which originals move to the Trash. Nothing happens until you confirm.")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct ShrinkRow: View {
    @Environment(AppModel.self) private var model
    let candidate: ShrinkCandidate

    var body: some View {
        let c = candidate
        let outcome = model.shrinkResults[c.path]
        let busy = model.shrinking.contains(c.path)
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.path)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.headline).lineLimit(1).truncationMode(.middle).help(c.path)
                Text([c.detail, (c.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let outcome {
                    Label(outcome.message + (outcome.method.isEmpty ? "" : " · \(outcome.method)"),
                          systemImage: outcome.ok ? "checkmark.circle.fill" : "info.circle")
                        .font(.caption).foregroundStyle(outcome.ok ? Theme.safe : .secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(ByteFormat.string(c.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                if let est = c.estimate, outcome == nil {
                    Text("→ about \(ByteFormat.string(est))").font(.caption).foregroundStyle(Theme.safe).monospacedDigit()
                } else if let outcome, outcome.ok {
                    Text("→ \(ByteFormat.string(outcome.after))").font(.caption).foregroundStyle(Theme.safe).monospacedDigit()
                } else if c.kind == .pdf, outcome == nil {
                    Text("try to see").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, alignment: .trailing)
            if busy {
                ProgressView().controlSize(.small).frame(width: 120)
            } else if let outcome, outcome.ok, let copy = outcome.outputs.first {
                Button("Show Copy") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy)]) }
                    .buttonStyle(SoftButtonStyle(tint: .secondary)).frame(width: 120).help("See the smaller copy next to the original")
            } else {
                Button { Task { await model.shrink(c) } } label: { Text("Make Smaller") }
                    .buttonStyle(SoftButtonStyle(tint: Theme.brandStart)).frame(width: 120)
                    .disabled(outcome != nil || DemoData.isEnabled)
                    .help("Save a smaller copy next to the original and check it. The original isn't changed.")
            }
            PathActions(path: c.path)
        }
        .padding(.vertical, 8)
    }
}
