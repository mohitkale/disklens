import AppKit
import DiskLensCore
import SwiftUI

/// Peace of mind: the drive's own health report, what "System Data" is, archiving to another drive, and watched folders.
struct HealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DriveHealthCard()
                SystemDataCard()
                ArchiveCard()
                WatchedFoldersCard()
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .task { await model.refreshHealth() }
        .navigationTitle("Health")
    }
}

// MARK: - Drive health

private struct DriveHealthCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let h = model.diskHealth
        let tint: Color = switch h?.verdict { case .replace: Theme.danger; case .watch: Theme.review; default: Theme.safe }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                IconTile(symbol: h?.verdict == .good || h == nil ? "checkmark.shield.fill" : "exclamationmark.triangle.fill", color: tint, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(h.map { "Drive health: \($0.verdict.rawValue)" } ?? "Drive health").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Read from the drive's own health report, the same one disk utilities use. Read-only.")
                        .foregroundStyle(.secondary)
                    if let notes = h?.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(notes, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                        }
                    }
                }
                Spacer()
                if let used = h?.percentUsed {
                    let left = Double(max(0, 100 - used)) / 100
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 10)
                        Circle().trim(from: 0, to: max(0.01, left)).stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(max(0, 100 - used))%").font(.title2.weight(.bold)).monospacedDigit()
                            Text("life left").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 96, height: 96)
                    .help("Rated write endurance left. Drives often keep working past their rating.")
                }
            }
            if let h {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        fact("Model", h.model ?? "Unknown")
                        fact("macOS check (SMART)", h.smartStatus ?? "Not available")
                        fact("Spare capacity", h.availableSpare.map { "\($0)%" } ?? "-")
                    }
                    GridRow {
                        fact("Temperature", h.temperatureC.map { "\($0) °C" } ?? "-")
                        fact("Powered on", h.powerOnHours.map { "\($0.formatted()) hours" } ?? "-")
                        fact("Written in its lifetime", h.bytesWritten.map(lifetime) ?? "-")
                    }
                    GridRow {
                        fact("Read in its lifetime", h.bytesRead.map(lifetime) ?? "-")
                        fact("Unexpected shutdowns", h.unsafeShutdowns.map { "\($0)" } ?? "-")
                        fact("Media errors", h.mediaErrors.map { "\($0)" } ?? "-")
                    }
                }
                if h.percentUsed == nil {
                    Text("This drive doesn't share a detailed health report (only macOS's SMART check is shown).").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ScanProgress(message: "Reading the drive's health report")
            }
        }
        .premiumCard()
    }

    /// Lifetime totals run into terabytes.
    private func lifetime(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000_000 ? String(format: "%.1f TB", Double(bytes) / 1e12) : ByteFormat.string(bytes)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - System Data, explained

private struct SystemDataCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let parts = model.systemDataParts
        let total = parts.reduce(0) { $0 + $1.bytes }
        Card {
            SectionHeader(title: "What “System Data” really is",
                          subtitle: "System Settings lumps all of this together. Here it is, piece by piece, from your last full scan.",
                          symbol: "square.stack.3d.up")
            if parts.isEmpty {
                Text(model.lastFullScan == nil ? "Run a full scan to see this." : "Nothing large outside your own files.").foregroundStyle(.secondary)
            }
            ForEach(parts) { part in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(part.name).font(.headline)
                            Spacer()
                            Text(ByteFormat.string(part.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        GeometryReader { geo in
                            Capsule().fill(.quaternary).overlay(alignment: .leading) {
                                Capsule().fill(part.canShrink ? Theme.brandStart : Color.secondary.opacity(0.5))
                                    .frame(width: geo.size.width * CGFloat(Double(part.bytes) / Double(max(total, 1))))
                            }
                        }
                        .frame(height: 6)
                        Text(part.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if part.canShrink {
                        Button("See Cleanups") { model.showFindings(part.findingIDs) }
                            .buttonStyle(SoftButtonStyle(tint: Theme.brandStart)).frame(width: 120)
                            .help("Open Clean Up at what reduces this part")
                    } else {
                        Text(part.name.hasPrefix("Hidden") ? "Grant Full Disk Access" : "Nothing to clean")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 120)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Archive to an external drive

private struct ArchiveCard: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    var body: some View {
        @Bindable var model = model
        Card {
            HStack(alignment: .top) {
                SectionHeader(title: "Archive to an external drive",
                              subtitle: "Copies files you rarely need to another drive and checks every file of the copy. Only then can you move the originals to the Trash, after a review.",
                              symbol: "externaldrive.badge.plus")
                Spacer()
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To archive").font(.callout.weight(.semibold))
                    if model.archiveItems.isEmpty {
                        Text("Drop files or folders here").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
                    }
                    ForEach(model.archiveItems, id: \.self) { path in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).help(path)
                            Spacer()
                            if let verified = model.archiveResult?.verified, verified.contains(path) {
                                Chip(text: "Copied and checked", symbol: "checkmark", tint: Theme.safe)
                            }
                            Text(model.archiveSizes[path].map(ByteFormat.string) ?? "…").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button { model.archiveItems.removeAll { $0 == path } } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
                        }
                    }
                    HStack {
                        Button { model.chooseArchiveItems() } label: { Label("Add…", systemImage: "plus") }.buttonStyle(SoftButtonStyle(tint: .secondary))
                        if let old = model.findings.first(where: { $0.id == "old-files" }) {
                            Button("Add \(old.items.count) files untouched for a year") { model.addOldFilesToArchive() }
                                .buttonStyle(.textLink).font(.callout)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.brandStart, lineWidth: dropping ? 2 : 0))
                .dropDestination(for: URL.self) { urls, _ in model.addArchive(urls.map(\.path)); return true } isTargeted: { dropping = $0 }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Drive").font(.callout.weight(.semibold))
                    if model.externalVolumes.isEmpty && model.archiveCustomFolder == nil {
                        Label("Connect a USB or Thunderbolt drive", systemImage: "cable.connector").foregroundStyle(.secondary)
                    }
                    ForEach(model.externalVolumes) { v in
                        Button { model.archiveVolume = v; model.archiveCustomFolder = nil } label: {
                            HStack {
                                Image(systemName: model.archiveVolume == v && model.archiveCustomFolder == nil ? "largecircle.fill.circle" : "circle")
                                Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(v.name)
                                    Text("\(ByteFormat.string(v.free)) free" + (v.format.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain).handCursor()
                    }
                    if let folder = model.archiveCustomFolder {
                        Label(folder.path, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    HStack {
                        Button("Other Folder…") { model.chooseArchiveFolder() }.buttonStyle(.textLink).font(.caption)
                        Button("Refresh") { Task { await model.refreshHealth() } }.buttonStyle(.textLink).font(.caption)
                    }
                    Divider()
                    if let p = model.archiveProgress {
                        ProgressView(value: p.fraction)
                        Text(p.message + "…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        let tooBig = model.archiveVolume.map { model.archiveCustomFolder == nil && model.archiveBytes > $0.free } ?? false
                        Button { Task { await model.runArchive() } } label: { Label("Copy and Check", systemImage: "externaldrive.badge.checkmark") }
                            .buttonStyle(GradientButtonStyle(large: true))
                            .disabled(model.archiveItems.isEmpty || model.archiveTarget == nil || tooBig || DemoData.isEnabled)
                            .help("Copies everything to the drive, then compares every file (size and SHA-256). Nothing is removed from your Mac.")
                        if tooBig { Text("Not enough free space on that drive.").font(.caption).foregroundStyle(Theme.danger) }
                    }
                    if let r = model.archiveResult {
                        if !r.verified.isEmpty {
                            Label("\(r.verified.count) copied and checked", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.safe).font(.callout)
                            Button { model.reviewArchivedOriginals() } label: { Label("Review Originals…", systemImage: "list.bullet.clipboard") }
                                .buttonStyle(SoftButtonStyle(tint: Theme.review))
                                .help("Move the originals to the Trash, after a review, to free the space on this Mac")
                        }
                        ForEach(r.failures, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.review) }
                    }
                }
                .frame(width: 330, alignment: .leading)
            }
        }
    }
}

// MARK: - Watched folders

private struct WatchedFoldersCard: View {
    @Environment(AppModel.self) private var model
    private static let limits: [Double] = [1, 2, 5, 10, 20, 50, 100, 200]

    var body: some View {
        Card {
            HStack(alignment: .top) {
                SectionHeader(title: "Watched folders",
                              subtitle: "Get a notification when a folder grows past the size you set, such as Downloads or a project. Checked hourly while DiskLens is open.",
                              symbol: "eye")
                Spacer()
                Button { model.addWatchedFolder() } label: { Label("Watch a Folder…", systemImage: "plus") }
                    .buttonStyle(SoftButtonStyle()).disabled(DemoData.isEnabled)
            }
            if model.watchedFolders.isEmpty {
                Text("No folders watched yet.").foregroundStyle(.secondary)
            }
            ForEach(model.watchedFolders) { folder in
                let over = (folder.lastBytes ?? 0) > folder.limitBytes
                HStack(spacing: 12) {
                    Image(systemName: over ? "exclamationmark.circle.fill" : "folder.fill").foregroundStyle(over ? Theme.review : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((folder.path as NSString).lastPathComponent).font(.headline)
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(folder.lastBytes.map { "now \(ByteFormat.string($0))" } ?? "measuring…").font(.callout).monospacedDigit()
                        .foregroundStyle(over ? Theme.review : .secondary)
                    Picker("Limit", selection: Binding(get: { Double(folder.limitBytes) / 1e9 }, set: { model.setLimit(folder, gb: $0) })) {
                        ForEach(Self.limits, id: \.self) { Text("\(Int($0)) GB").tag($0) }
                        if !Self.limits.contains(Double(folder.limitBytes) / 1e9) {
                            Text(ByteFormat.string(folder.limitBytes)).tag(Double(folder.limitBytes) / 1e9)
                        }
                    }
                    .frame(width: 150).handCursor()
                    Button { model.removeWatched(folder) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle()).help("Stop watching")
                }
            }
        }
    }
}
