import AppKit
import DiskLensCore
import SwiftUI

/// Finds photos, videos and documents that reveal where you were, which device you use or your name,
/// and removes that information. Originals go to the Trash, so every clean can be undone.
struct PrivacyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                scope
                if model.isScanningPrivacy { progressCard }
                if model.privacyScanned != nil || !model.privacyReports.isEmpty { results }
                SensitiveScreenshotsCard()
                photosNote
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .safeAreaInset(edge: .bottom) { if !model.privacyReports.isEmpty && model.sensitiveSelection.isEmpty { selectionBar } }
        .sheet(isPresented: Binding(get: { model.privacyJob != nil }, set: { if !$0 { model.privacyJob = nil } })) {
            PrivacyCleanSheet().environment(model).interactiveDismissDisabled(model.privacyJob?.phase == .running)
        }
        .navigationTitle("Privacy Shield")
    }

    // MARK: Sections

    private var intro: some View {
        HStack(alignment: .top, spacing: 16) {
            IconTile(symbol: "hand.raised.fill", color: Theme.brandStart, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text("What do your files reveal about you?").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Photos and videos can carry the exact place they were taken, your phone's model and serial numbers. Documents carry your name and company. Social apps usually strip this when you post, but **AirDrop, email, Messages, cloud links and file uploads send the original**, with everything in it.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label("Read-only until you choose to clean. Nothing leaves your Mac.", systemImage: "lock.shield.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(Theme.safe)
            }
        }
        .premiumCard()
    }

    private var scope: some View {
        Card {
            HStack {
                SectionHeader(title: "Folders to check", subtitle: "Photos, videos, PDFs and Office files inside these folders.", symbol: "folder")
                Spacer()
                if let date = model.privacyScanned {
                    Chip(text: "Checked \(date.friendly)", symbol: "clock", tint: .secondary, help: "When these folders were last checked")
                }
            }
            FlowChips(items: model.privacyFolders) { path in
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1)
                    Button { model.removePrivacyFolder(path) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(IconButtonStyle()).help("Don't check this folder")
                }
                .font(.callout)
                .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            HStack {
                Button { model.addPrivacyFolder() } label: { Label("Add Folder…", systemImage: "plus") }
                    .buttonStyle(SoftButtonStyle(tint: .secondary)).help("Choose more folders to check")
                Spacer()
                Button { Task { await model.scanPrivacy() } } label: {
                    Label(model.privacyScanned == nil ? "Check My Files" : "Check Again", systemImage: "magnifyingglass")
                }
                .buttonStyle(GradientButtonStyle(large: true))
                .disabled(model.isScanningPrivacy || model.privacyFolders.isEmpty)
                .help("Read the metadata of every photo, video and document in these folders. Read-only.")
            }
        }
    }

    private var progressCard: some View {
        let p = model.privacyProgress ?? (0, 0)
        return Card {
            HStack(spacing: 12) {
                ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : nil).frame(maxWidth: 360)
                Text(p.total > 0 ? "Checked \(p.done) of \(p.total) files…" : "Finding photos, videos and documents…")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder private var results: some View {
        let reports = model.privacyReports
        let located = reports.filter(\.revealsLocation).count
        let device = reports.filter { $0.device != nil || !$0.serials.isEmpty }.count
        let people = reports.filter { !$0.people.isEmpty }.count
        let serials = reports.filter { !$0.serials.isEmpty }.count
        Grid(horizontalSpacing: 14) {
            GridRow {
                StatTile(title: "Reveal a location", value: "\(located)", note: located == 0 ? "none of your files" : "exact GPS coordinates",
                         symbol: "location.fill", tint: located > 0 ? Theme.danger : Theme.safe,
                         help: "Show files with GPS coordinates") { model.privacyFilter = .location }
                StatTile(title: "Reveal your device", value: "\(device)", note: serials > 0 ? "\(serials) with serial numbers" : "camera or phone model",
                         symbol: "iphone", tint: Theme.review, help: "Show files that name the camera or phone (and serial numbers)") { model.privacyFilter = .device }
                StatTile(title: "Contain names", value: "\(people)", note: "owner, author or company", symbol: "person.text.rectangle",
                         tint: Theme.review, help: "Show files that contain a person's or company's name") { model.privacyFilter = .people }
                StatTile(title: "Files checked", value: "\(reports.count)", note: "reveal something", symbol: "doc.text.magnifyingglass",
                         tint: Theme.brandStart, help: "Show everything") { model.privacyFilter = .all }
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        if !model.privacyHotspots.isEmpty { hotspots }

        if reports.isEmpty {
            Card {
                Label("None of the checked files reveal a location, a device or a name.", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(Theme.safe)
            }
        } else {
            fileList
        }
    }

    private var hotspots: some View {
        Card {
            SectionHeader(title: "Places your files point to",
                          subtitle: "Spots where many files were taken. A spot visited on many different days is often a home or workplace.",
                          symbol: "mappin.and.ellipse")
            ForEach(Array(model.privacyHotspots.enumerated()), id: \.element.id) { index, spot in
                HStack(spacing: 12) {
                    IconTile(symbol: index == 0 && spot.days > 3 ? "house.fill" : "mappin", color: index == 0 ? Theme.danger : Theme.review, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(spot.files.count) files on \(spot.days) day\(spot.days == 1 ? "" : "s")"
                             + (index == 0 && spot.days > 3 ? ". Likely your home or work" : "")).font(.callout.weight(.semibold))
                        Text("Near \(spot.center.formatted)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button("Select These Files") { model.selectPrivacy(spot.files) }
                        .buttonStyle(SoftButtonStyle()).help("Tick the files taken here so you can remove their location")
                    if let url = spot.center.mapsURL {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Show in Maps", systemImage: "map") }
                            .buttonStyle(SoftButtonStyle(tint: .secondary))
                            .help("Opens Apple Maps at this spot. DiskLens itself never goes online.")
                    }
                }
            }
        }
    }

    private var fileList: some View {
        @Bindable var model = model
        let shown = model.privacyShown
        return Card {
            HStack(spacing: 14) {
                Picker("Show", selection: $model.privacyFilter) {
                    ForEach(PrivacyFilter.allCases) { f in
                        Text("\(f.title) · \(model.privacyReports.filter(f.matches).count)").tag(f)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 620).handCursor()
                .help("Show only files that reveal one kind of information")
                Spacer()
                Button { model.toggleAllPrivacy() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: model.privacySelectionState == .all ? "checkmark.square.fill"
                              : model.privacySelectionState == .some ? "minus.square.fill" : "square")
                            .font(.system(size: 16))
                            .foregroundStyle(model.privacySelectionState == .none ? Color.secondary : Theme.brandStart)
                        Text("Select all (\(model.privacyCleanable.count))").font(.callout.weight(.medium))
                    }
                }
                .buttonStyle(.plain).handCursor().disabled(model.privacyCleanable.isEmpty)
                .help("Select every file shown that DiskLens can clean")
            }
            Divider()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown.prefix(500)) { r in
                    PrivacyRow(report: r)
                    Divider()
                }
                if shown.count > 500 {
                    Text("Showing the first 500 of \(shown.count). Use the filters or Select all to work with the rest.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
        }
    }

    private var photosNote: some View {
        Card {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Photos library").font(.headline)
                    Text("DiskLens doesn't change the Photos library. In Photos, select photos → **Image → Location → Hide Location**. When sharing, click **Options** in the share sheet and turn off **Location**.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: { Image(systemName: "photo.on.rectangle").foregroundStyle(Theme.brandStart) }
        }
    }

    private var selectionBar: some View {
        let count = model.privacySelection.count
        return HStack(spacing: 14) {
            IconTile(symbol: "hand.raised.fill", color: count == 0 ? .secondary : Theme.brandStart, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 0 ? "Nothing selected" : "\(count) file\(count == 1 ? "" : "s") selected").font(.headline)
                Text(count == 0 ? "Tick files, a hotspot, or use Select all." : "You'll choose what to remove next. Originals can go to the Trash or stay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Clear Selection") { model.privacySelection = [] }
                .buttonStyle(SoftButtonStyle(tint: .secondary)).disabled(count == 0).help("Untick everything")
            Button { model.startPrivacyClean() } label: { Label("Remove Info…", systemImage: "eraser") }
                .buttonStyle(GradientButtonStyle(large: true)).disabled(count == 0)
                .help("Choose what to remove and review before anything changes")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct PrivacyRow: View {
    @Environment(AppModel.self) private var model
    let report: MetadataReport

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { model.privacySelection.contains(report.path) },
                                     set: { on in if on { model.privacySelection.insert(report.path) } else { model.privacySelection.remove(report.path) } }))
                .labelsHidden().toggleStyle(.checkbox).disabled(!report.canClean).handCursor()
                .help(report.kind == .office ? "Include this file: removes the author, last editor, company and manager from its properties"
                      : "Include this file")
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.name).lineLimit(1).truncationMode(.middle)
                FlowChips(items: reveals, spacing: 5) { item in
                    Chip(text: item.text, symbol: item.symbol, tint: item.tint, help: item.help)
                }
            }
            .help(report.path)
            Spacer()
            Text((report.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).frame(maxWidth: 260, alignment: .trailing)
            Text(ByteFormat.string(report.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            PathActions(path: report.path)
        }
        .padding(.vertical, 8)
    }

    private var icon: String {
        switch report.kind {
        case .image: "photo"
        case .video: "video"
        case .pdf: "doc.richtext"
        case .office: "doc.text"
        }
    }

    struct Reveal: Hashable { let text: String; let symbol: String; let tint: Color; let help: String }

    private var reveals: [Reveal] {
        var list: [Reveal] = []
        if let c = report.coordinate {
            list.append(Reveal(text: "Location", symbol: "location.fill", tint: Theme.danger, help: "Taken near \(c.formatted)"))
        }
        if let d = report.device { list.append(Reveal(text: d, symbol: "camera", tint: Theme.review, help: "The camera or phone that made this file")) }
        if !report.serials.isEmpty {
            list.append(Reveal(text: "Serial number", symbol: "number", tint: Theme.danger, help: "Serial numbers can link photos to one specific device: \(report.serials.joined(separator: ", "))"))
        }
        for p in report.people.prefix(2) {
            list.append(Reveal(text: p, symbol: "person.fill", tint: Theme.review, help: report.kind == .image ? "Owner or artist name" : "Author, editor or company name"))
        }
        if let date = report.captured, report.kind == .image || report.kind == .video {
            list.append(Reveal(text: date.formatted(date: .abbreviated, time: .shortened), symbol: "clock", tint: .secondary,
                               help: "When it was taken. Kept when cleaning, so your photos stay in order."))
        }
        return list
    }
}

/// Wrapping row of chips.
struct FlowChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    var spacing: CGFloat = 8
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: spacing) { ForEach(items, id: \.self) { content($0) } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Choose what to remove and where originals go, then run and summarise.
struct PrivacyCleanSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.privacyJob {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    IconTile(symbol: "hand.raised.fill", color: Theme.brandStart, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.phase == .finished ? "Done" : "Remove info from \(job.reports.count) file\(job.reports.count == 1 ? "" : "s")")
                            .font(.title2.weight(.bold))
                        Text(job.phase == .running ? "Cleaning \(job.done) of \(job.reports.count)…" : "Photos keep their quality, orientation and the date they were taken.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                Divider()
                Group {
                    switch job.phase {
                    case .confirm: options(job)
                    case .running: ProgressView(value: Double(job.done), total: Double(max(job.reports.count, 1))).padding(40)
                    case .finished: summary(job)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                footer(job)
            }
            .frame(width: 640, height: 520)
            .background(PageBackground())
        }
    }

    private func options(_ job: PrivacyJob) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What to remove").font(.headline)
                choice(selected: job.level == .location, title: "Location only",
                       detail: "GPS coordinates. Camera details and names stay.") { model.privacyJob?.level = .location }
                choice(selected: job.level == .identifying, title: "Location and everything that identifies you (recommended)",
                       detail: "GPS, phone or camera model, serial numbers, owner and author names, editing software.") { model.privacyJob?.level = .identifying }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What happens to the originals").font(.headline)
                choice(selected: job.mode == .replaceOriginal, title: "Replace them. Originals go to the Trash (recommended)",
                       detail: "Files are cleaned in place. Put an original back from the Trash any time until you empty it.") { model.privacyJob?.mode = .replaceOriginal }
                choice(selected: job.mode == .saveCopy, title: "Keep them and save clean copies",
                       detail: "Adds “name (clean)” next to each file. Uses extra space; share the clean copy.") { model.privacyJob?.mode = .saveCopy }
            }
            Label("Each file is checked after cleaning. If any information is still there, the original is left untouched.", systemImage: "checkmark.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func choice(selected: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.brandStart : .secondary).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(selected ? Theme.brandStart.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
    }

    private func summary(_ job: PrivacyJob) -> some View {
        let ok = job.results.filter(\.ok)
        let failed = job.results.filter { !$0.ok }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("\(ok.count) file\(ok.count == 1 ? "" : "s") cleaned" + (job.mode == .replaceOriginal ? ". Originals are in the Trash." : ". Clean copies saved next to the originals."),
                      systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Theme.safe)
                if ok.contains(where: \.reencoded) {
                    Label("\(ok.filter(\.reencoded).count) photo(s) were re-saved at maximum quality because their format can't be edited losslessly.",
                          systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(failed, id: \.path) { r in
                    Label("\((r.path as NSString).lastPathComponent): \(r.message)", systemImage: "xmark.octagon.fill")
                        .font(.callout).foregroundStyle(Theme.danger)
                }
            }
            .padding(20)
        }
    }

    private func footer(_ job: PrivacyJob) -> some View {
        HStack {
            Spacer()
            switch job.phase {
            case .confirm:
                Button("Cancel") { model.privacyJob = nil }.keyboardShortcut(.cancelAction).handCursor().help("Close without changing anything")
                Button { Task { await model.runPrivacyClean() } } label: { Label("Remove Info", systemImage: "eraser") }
                    .buttonStyle(GradientButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                    .help("Clean the selected files now")
            case .running:
                ProgressView().controlSize(.small)
            case .finished:
                if job.mode == .replaceOriginal {
                    Button { model.openTrash() } label: { Label("Open Trash", systemImage: "trash") }
                        .buttonStyle(SoftButtonStyle(tint: .secondary)).help("See the originals in the Trash")
                }
                Button("Done") { model.privacyJob = nil }.buttonStyle(GradientButtonStyle(large: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// Screenshots whose text shows a card number, one-time code, password, ID or recovery phrase.
/// The text is read on this Mac with Apple's Vision framework; nothing is uploaded.
private struct SensitiveScreenshotsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(alignment: .top) {
                SectionHeader(title: "Sensitive screenshots",
                              subtitle: "Screenshots of card numbers, one-time codes, passwords, IDs or crypto recovery phrases. Their text is read on this Mac; nothing is uploaded.",
                              symbol: "camera.viewfinder")
                Spacer()
                if let date = model.sensitiveScanned { Chip(text: "Checked \(date.friendly)", symbol: "clock", tint: .secondary) }
                Button { Task { await model.scanSensitive() } } label: {
                    Label(model.sensitiveScanned == nil ? "Check Screenshots" : "Check Again", systemImage: "text.viewfinder")
                }
                .buttonStyle(SoftButtonStyle(tint: Theme.brandStart))
                .disabled(model.isScanningSensitive || model.privacyFolders.isEmpty)
                .help("Read the text in every screenshot in the folders above. Read-only; about a second per screenshot.")
            }
            if let p = model.sensitiveProgress {
                HStack(spacing: 12) {
                    ProgressView(value: p.total > 0 ? Double(p.done) / Double(p.total) : nil).frame(maxWidth: 360)
                    Text(p.total > 0 ? "Read \(p.done) of \(p.total) screenshots…" : "Finding screenshots…").foregroundStyle(.secondary).monospacedDigit()
                }
            } else if model.sensitiveScanned != nil && model.sensitiveFindings.isEmpty {
                Label("No screenshots with sensitive text in \(model.sensitiveChecked) checked.", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(Theme.safe)
            }
            if !model.sensitiveFindings.isEmpty {
                Divider()
                ForEach(model.sensitiveFindings) { f in
                    SensitiveRow(finding: f)
                    Divider()
                }
                HStack {
                    Text(model.sensitiveSelection.isEmpty ? "Tick the screenshots you no longer need."
                         : "\(model.sensitiveSelection.count) selected · moved to the Trash after you review them")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Selection") { model.sensitiveSelection = [] }
                        .buttonStyle(SoftButtonStyle(tint: .secondary)).disabled(model.sensitiveSelection.isEmpty)
                    Button { model.reviewSensitive() } label: { Label("Review Selected…", systemImage: "list.bullet.clipboard") }
                        .buttonStyle(GradientButtonStyle()).disabled(model.sensitiveSelection.isEmpty)
                        .help("Review exactly what moves to the Trash. Empty the Trash afterwards so they're really gone.")
                }
            }
        }
    }
}

private struct SensitiveRow: View {
    @Environment(AppModel.self) private var model
    let finding: SensitiveFinding
    @State private var thumb: NSImage?

    var body: some View {
        let selected = model.sensitiveSelection.contains(finding.path)
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { selected }, set: { on in
                if on { model.sensitiveSelection.insert(finding.path) } else { model.sensitiveSelection.remove(finding.path) }
            }))
            .labelsHidden().toggleStyle(.checkbox).handCursor().help("Move this screenshot to the Trash")
            Group {
                if let thumb {
                    // Blurred on purpose: the point is that its contents are sensitive.
                    Image(nsImage: thumb).resizable().scaledToFill().blur(radius: 6)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 64, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            .help("Preview is blurred. Open it with Quick Look from Finder to see it.")
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.name).font(.headline).lineLimit(1).truncationMode(.middle).help(finding.path)
                HStack(spacing: 6) {
                    ForEach(finding.kinds, id: \.self) { k in
                        Chip(text: k.rawValue, symbol: k.symbol, tint: k.isHighRisk ? Theme.danger : Theme.review)
                    }
                    if !finding.samples.isEmpty {
                        Text(finding.samples.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            if let d = finding.date { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
            Text(ByteFormat.string(finding.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            PathActions(path: finding.path)
        }
        .padding(.vertical, 6)
        .task(id: finding.path) {
            guard !DemoData.isEnabled else { thumb = DemoData.swatch(for: finding.path, size: 160).map { NSImage(cgImage: $0, size: .zero) }; return }
            let path = finding.path
            let cg = await Task.detached { MediaLibrary.thumbnail(path, maxPixels: 160) }.value
            thumb = cg.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}
