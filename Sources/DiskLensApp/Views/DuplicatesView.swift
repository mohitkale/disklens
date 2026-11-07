import AppKit
import DiskLensCore
import SwiftUI

/// Identical files (byte for byte) across the home folder. One copy of each always stays.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Show", selection: $model.duplicatesTab) {
                    ForEach(DuplicatesTab.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460).handCursor()
                if model.duplicatesTab == .similar {
                    SimilarPhotosPanel()
                } else {
                    identical
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .safeAreaInset(edge: .bottom) {
            if model.duplicatesTab == .identical && !model.duplicateGroups.isEmpty { selectionBar }
            if model.duplicatesTab == .similar && model.similarResult != nil { similarBar }
        }
        .navigationTitle("Duplicates")
    }

    @ViewBuilder private var identical: some View {
                header
                if model.isFindingDuplicates {
                    Card { ScanProgress(message: model.progress) }
                } else if model.duplicatesScanned != nil && model.duplicateGroups.isEmpty {
                    Card {
                        Label("No duplicate files over 1 MB found.", systemImage: "checkmark.seal.fill")
                            .font(.headline).foregroundStyle(Theme.safe)
                    }
                }
                ForEach(model.duplicateGroups.prefix(300)) { DuplicateGroupCard(group: $0) }
                if model.duplicateGroups.count > 300 {
                    Text("Showing the 300 groups that free the most space.").font(.caption).foregroundStyle(.secondary)
                }
    }

    private var similarBar: some View {
        let items = model.similarSelectedItems
        let fromPhotos = items.contains { $0.filePath == nil }
        return HStack(spacing: 14) {
            IconTile(symbol: "square.stack.3d.down.right", color: items.isEmpty ? .secondary : Theme.brandStart, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(items.isEmpty ? "Nothing selected" : "\(items.count) photo\(items.count == 1 ? "" : "s") · \(ByteFormat.string(items.reduce(0) { $0 + $1.bytes }))")
                    .font(.headline).monospacedDigit()
                Text(fromPhotos ? "The sharpest photo of each set stays. Removed photos go to Recently Deleted in Photos for 30 days."
                                : "The sharpest photo of each set stays. Removed photos go to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Suggested") { model.selectSuggestedSimilar() }
                .buttonStyle(SoftButtonStyle(tint: .secondary)).help("Select every photo except the sharpest of each set")
            Button("Clear Selection") { model.similarSelection = [] }
                .buttonStyle(SoftButtonStyle(tint: .secondary)).disabled(items.isEmpty)
            Button { Task { await model.reviewSimilar() } } label: { Label("Review Selected…", systemImage: "list.bullet.clipboard") }
                .buttonStyle(GradientButtonStyle(large: true)).disabled(items.isEmpty || DemoData.isEnabled)
                .help("Confirm exactly what's removed before anything happens")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(symbol: "doc.on.doc.fill", color: Theme.brandStart, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text("Duplicate files").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Files over 1 MB that are identical byte for byte, compared by content, not by name. App data, hidden folders, photo libraries and project dependencies are skipped.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.duplicateGroups.isEmpty {
                    HStack(spacing: 8) {
                        Chip(text: "\(model.duplicateGroups.count) groups", symbol: "square.stack", tint: Theme.brandStart,
                             help: "Sets of identical files")
                        Chip(text: "\(ByteFormat.string(model.duplicateReclaimable)) can be freed", symbol: "arrow.down.circle", tint: Theme.safe,
                             help: "Space freed by keeping one copy of each")
                        let clones = model.duplicateGroups.reduce(0) { $0 + $1.clonePaths.count }
                        if clones > 0 {
                            Chip(text: "\(clones) clone\(clones == 1 ? "" : "s")", symbol: "link", tint: .secondary,
                                 help: "Copies made with Finder ▸ Duplicate share storage with the original, so removing them frees no space")
                        }
                        if let date = model.duplicatesScanned { Chip(text: "Checked \(date.friendly)", symbol: "clock", tint: .secondary) }
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button { Task { await model.scanDuplicates() } } label: {
                    Label(model.duplicatesScanned == nil ? "Find Duplicates" : "Check Again", systemImage: "magnifyingglass")
                }
                .buttonStyle(GradientButtonStyle(large: true)).disabled(model.isFindingDuplicates)
                .help("Compare files in your home folder. Read-only; takes under a minute on most Macs.")
                Button { chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder") }
                    .buttonStyle(.textLink).font(.callout).disabled(model.isFindingDuplicates)
                    .help("Look in a specific folder or drive instead of the whole home folder")
                if model.duplicateRoots != DuplicateFinder.defaultRoots {
                    Text("In: " + model.duplicateRoots.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .premiumCard()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Look Here"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.duplicateRoots = panel.urls.map(\.path)
        Task { await model.scanDuplicates() }
    }

    private var selectionBar: some View {
        let count = model.duplicateSelection.count
        return HStack(spacing: 14) {
            IconTile(symbol: "doc.on.doc", color: count == 0 ? .secondary : Theme.brandStart, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 0 ? "Nothing selected" : "\(count) extra cop\(count == 1 ? "y" : "ies") · \(ByteFormat.string(model.duplicateSelectedBytes))")
                    .font(.headline).monospacedDigit()
                Text("One copy of each file always stays. Removed copies go to the Trash.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Suggested") { model.selectSuggestedDuplicates() }
                .buttonStyle(SoftButtonStyle(tint: .secondary)).help("Select every copy except the one DiskLens suggests keeping")
            Button("Clear Selection") { model.duplicateSelection = [] }
                .buttonStyle(SoftButtonStyle(tint: .secondary)).disabled(count == 0).help("Untick everything")
            Button { model.reviewDuplicates() } label: { Label("Review Selected…", systemImage: "list.bullet.clipboard") }
                .buttonStyle(GradientButtonStyle(large: true)).disabled(count == 0)
                .help("Review exactly what moves to the Trash before anything happens")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct DuplicateGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: group.keep)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text((group.keep as NSString).lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(group.files.count) identical copies · \(ByteFormat.string(group.bytesPerFile)) each").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(ByteFormat.string(group.reclaimable)).font(.title3.weight(.bold)).monospacedDigit()
                    Text("can be freed").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(group.files) { file in
                let selected = model.isDuplicateSelected(file.path)
                let clone = group.clonePaths.contains(file.path)
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { selected }, set: { _ in model.toggleDuplicate(file, in: group) }))
                        .labelsHidden().toggleStyle(.checkbox).handCursor()
                        .disabled(!model.canToggleDuplicate(file, in: group))
                        .help(model.canToggleDuplicate(file, in: group) ? "Move this copy to the Trash" : "At least one copy has to stay")
                    VStack(alignment: .leading, spacing: 1) {
                        Text((file.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.head)
                        Text("\(file.name)\(file.modified.map { " · modified \($0.formatted(.relative(presentation: .named)))" } ?? "")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(file.path)
                    Spacer()
                    if file.path == group.keep && !selected {
                        Chip(text: "Suggested to keep", symbol: "star.fill", tint: Theme.safe,
                             help: "Looks like the original: not in Downloads or on the Desktop, no “copy” or “(1)” in its name, oldest")
                    } else if !selected {
                        Chip(text: "Keeping", symbol: "checkmark", tint: Theme.safe)
                    }
                    if clone {
                        Chip(text: "Clone", symbol: "link", tint: .secondary,
                             help: "Shares storage with another copy (APFS clone), so removing it frees no space")
                    }
                    Button("Keep Only This") { model.keepOnly(file, in: group) }
                        .buttonStyle(.textLink).font(.caption).help("Keep this copy and select all the others")
                    PathActions(path: file.path)
                }
                .padding(.vertical, 4)
                .opacity(selected ? 1 : 0.85)
            }
        }
        .premiumCard(padding: 16)
    }
}

// MARK: - Similar & blurry photos

private struct SimilarPhotosPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                IconTile(symbol: "square.stack.3d.down.right.fill", color: Theme.brandStart, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Similar & blurry photos").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Bursts and retakes taken within a few minutes that look almost the same, and photos that are out of focus. DiskLens compares what's in the pictures on this Mac and suggests keeping the sharpest one of each set.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let r = model.similarResult {
                        HStack(spacing: 8) {
                            Chip(text: "\(r.groups.count) sets of similar photos", symbol: "square.stack", tint: Theme.brandStart)
                            Chip(text: "\(r.blurry.count) blurry", symbol: "camera.metering.unknown", tint: Theme.review,
                                 help: "Much less sharp than your other photos")
                            Chip(text: "\(r.checked.formatted()) photos checked", symbol: "photo", tint: .secondary)
                            if let label = model.similarSourceLabel { Chip(text: label, symbol: "folder", tint: .secondary) }
                        }
                    } else if let label = model.similarSourceLabel {
                        Text(label).font(.callout).foregroundStyle(Theme.review)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button { Task { await model.scanSimilarInPhotos() } } label: { Label("Check Photos Library", systemImage: "photo.on.rectangle") }
                        .buttonStyle(GradientButtonStyle(large: true)).disabled(model.isScanningSimilar)
                        .help("Compare the newest 5,000 photos in your Photos library. Read-only; photos stored only in iCloud are skipped.")
                    Button { model.scanSimilarInFolder() } label: { Label("Choose Folder…", systemImage: "folder") }
                        .buttonStyle(.textLink).font(.callout).disabled(model.isScanningSimilar)
                        .help("Compare the photos in a folder instead")
                }
            }
            .premiumCard()

            if let p = model.similarProgress {
                Card {
                    HStack(spacing: 12) {
                        ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : nil).frame(maxWidth: 360)
                        Text(p.total > 0 ? "Compared \(p.done) of \(p.total) photos…" : "Listing photos…").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if let r = model.similarResult {
                if r.groups.isEmpty && r.blurry.isEmpty {
                    Card { Label("No similar or blurry photos found.", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.safe) }
                }
                ForEach(r.groups.prefix(200)) { SimilarGroupCard(group: $0) }
                if !r.blurry.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Blurry photos", subtitle: "Out of focus or shaken compared with the rest. Nothing is ticked for you.",
                                      symbol: "camera.metering.unknown")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                            ForEach(r.blurry.prefix(300)) { item in SimilarTile(item: item, group: nil, isKeep: false) }
                        }
                    }
                    .premiumCard(padding: 16)
                }
            }
        }
    }
}

private struct SimilarGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: SimilarGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(group.items.count) similar photos").font(.headline)
                Text(group.items.first!.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(group.items.filter { $0.id != group.keep }.reduce(0) { $0 + $1.bytes }) + " in the others")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(group.items) { item in SimilarTile(item: item, group: group, isKeep: item.id == group.keep) }
                }
            }
        }
        .premiumCard(padding: 16)
    }
}

private struct SimilarTile: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    let group: SimilarGroup?
    let isKeep: Bool

    var body: some View {
        let selected = model.similarSelection.contains(item.id)
        Button { model.toggleSimilar(item, in: group) } label: {
            ZStack(alignment: .topLeading) {
                MediaThumb(item: item, size: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.danger : (isKeep ? Theme.safe : .clear), lineWidth: 3))
                    .opacity(selected ? 0.6 : 1)
                Image(systemName: selected ? "trash.circle.fill" : (isKeep ? "star.circle.fill" : "circle"))
                    .font(.system(size: 20)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, selected ? Theme.danger : (isKeep ? Theme.safe : Color.black.opacity(0.35)))
                    .padding(6)
            }
        }
        .buttonStyle(.plain).handCursor()
        .help(selected ? "Will be removed. Click to keep it."
              : isKeep ? "Sharpest of this set: suggested to keep. Click to remove it instead."
              : "Click to remove this photo")
    }
}
