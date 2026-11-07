import AppKit
import AVFoundation
import DiskLensCore
import SwiftUI
import UniformTypeIdentifiers

/// Events → Video, Collage, and Convert & Resize. Everything is made on this Mac; originals are never changed
/// unless you explicitly free up space after making a video (and then they go to the Trash / Recently Deleted).
struct MediaView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Media Studio").font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("Turn events into videos, make collages, enhance photos, and convert or resize. All on this Mac.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Tool", selection: $model.mediaTool) {
                        ForEach(MediaTool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560).handCursor()
                    .help("Choose a tool")
                }
                switch model.mediaTool {
                case .events: EventsPanel()
                case .collage: CollagePanel()
                case .enhance: EnhancePanel()
                case .convert: ConvertPanel()
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackground())
        .navigationTitle("Media Studio")
    }
}

/// Thumbnail for a photo or video (first frame), loaded lazily.
struct MediaThumb: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var size: CGFloat = 92
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if item.kind == .video {
                Label(item.duration > 0 ? String(format: "%d:%02d", Int(item.duration) / 60, Int(item.duration) % 60) : "", systemImage: "play.fill")
                    .font(.caption2.weight(.semibold)).labelStyle(.titleAndIcon)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(4)
            }
        }
        .task(id: item.id) {
            if item.kind == .video, let path = item.filePath, !DemoData.isEnabled {
                let gen = AVAssetImageGeneratorBox(path: path)
                image = await gen.frame(maxPixels: Int(size * 2))
            } else {
                image = await model.thumbnail(item, maxPixels: Int(size * 2))
            }
        }
    }
}

private struct AVAssetImageGeneratorBox {
    let path: String
    func frame(maxPixels: Int) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        return try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }
}

// MARK: - Events → Video

private struct EventsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            source
            if model.isLoadingMedia {
                Card { ScanProgress(message: "Reading dates and places") }
            } else if !model.events.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    eventList.frame(width: 330)
                    if let event = model.selectedEvent { EventDetail(event: event) } else { Spacer() }
                }
            } else if model.mediaSourceLabel != nil {
                Card { Label("No events found. An event needs at least 4 photos or videos taken close together.", systemImage: "calendar.badge.exclamationmark") }
            }
        }
    }

    private var source: some View {
        @Bindable var model = model
        return Card {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol: "calendar.badge.clock", color: Theme.brandStart, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Group photos and videos into events").font(.headline)
                    Text(model.mediaSourceLabel.map { "From \($0) · \(model.mediaItems.count) items · \(model.events.count) events" }
                         ?? "Birthdays, trips, outings: grouped by date and place, ready to become one video.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { Task { await model.loadPhotosLibrary() } } label: { Label("Photos Library", systemImage: "photo.on.rectangle") }
                    .buttonStyle(GradientButtonStyle()).disabled(model.isLoadingMedia)
                    .help("Read dates and places from your Photos library (asks permission once). Items stored only in iCloud are skipped.")
                Button { model.loadMediaFolder() } label: { Label("Choose Folder…", systemImage: "folder") }
                    .buttonStyle(SoftButtonStyle()).disabled(model.isLoadingMedia)
                    .help("Use a folder of photos and videos instead")
            }
            if !model.mediaItems.isEmpty {
                HStack(spacing: 10) {
                    Text("Start a new event after a gap of").font(.callout).foregroundStyle(.secondary)
                    Picker("", selection: $model.eventGapHours) {
                        ForEach([1.0, 2, 4, 8, 12, 24], id: \.self) { Text("\(Int($0)) hour\($0 == 1 ? "" : "s")").tag($0) }
                    }
                    .labelsHidden().frame(width: 110).handCursor()
                    .onChange(of: model.eventGapHours) { _, _ in model.regroupEvents() }
                    .help("Shorter gaps make more, smaller events. Travel of more than 30 km also starts a new event.")
                }
            }
        }
    }

    private var eventList: some View {
        LazyVStack(spacing: 8) {
            ForEach(model.events) { event in
                Button { model.selectEvent(event) } label: {
                    HStack(spacing: 10) {
                        if let first = event.items.first { MediaThumb(item: first, size: 54) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.callout.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                            Text("\(event.photoCount) photos\(event.videoCount > 0 ? " · \(event.videoCount) videos" : "")"
                                 + (event.bytes > 0 ? " · \(ByteFormat.string(event.bytes))" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(model.selectedEventID == event.id ? Theme.brandStart.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).handCursor()
                .help("\(event.title): \(event.items.count) items")
            }
        }
        .premiumCard(padding: 10)
    }
}

private struct EventDetail: View {
    @Environment(AppModel.self) private var model
    let event: MediaEvent
    @State private var confirmFree = false
    @State private var understood = false

    var body: some View {
        @Bindable var model = model
        let included = model.includedItems(event)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Event name", text: Binding(get: { event.title }, set: { model.renameEvent(event.id, to: $0); model.videoOptions.title = $0 }))
                    .textFieldStyle(.plain).font(.title2.weight(.bold))
                    .help("Rename the event. The name becomes the video's title.")
                Spacer()
                Text("\(included.count) of \(event.items.count) included").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Shape").foregroundStyle(.secondary)
                    Picker("", selection: $model.videoOptions.shape) {
                        ForEach(VideoOptions.Shape.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(maxWidth: 280).handCursor().help("1080p video in this shape")
                }
                GridRow {
                    Text("Each photo").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $model.videoOptions.photoSeconds, in: 1.5...6, step: 0.5).frame(maxWidth: 200).handCursor()
                        Text(String(format: "%.1f s", model.videoOptions.photoSeconds)).monospacedDigit().foregroundStyle(.secondary)
                    }.help("How long each photo stays on screen")
                }
                GridRow {
                    Text("Clips").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $model.videoOptions.maxClipSeconds, in: 3...30, step: 1).frame(maxWidth: 200).handCursor()
                        Text("up to \(Int(model.videoOptions.maxClipSeconds)) s each").monospacedDigit().foregroundStyle(.secondary)
                        Toggle("Keep their sound", isOn: $model.videoOptions.keepClipAudio).toggleStyle(.checkbox).handCursor()
                    }.help("Longer clips are trimmed. Music is turned down while a clip plays its own sound.")
                }
                GridRow {
                    Text("Music").foregroundStyle(.secondary)
                    HStack {
                        if let label = model.musicLabel {
                            Label(label, systemImage: "music.note").lineLimit(1)
                            Button { model.clearMusic() } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(IconButtonStyle()).help("No music")
                        }
                        Menu(model.musicLabel == nil ? "Add Music" : "Change") {
                            Section("Built in (made on this Mac, free to use anywhere)") {
                                ForEach(MusicGenerator.Mood.allCases) { mood in
                                    Button(mood.label) { model.useBuiltInMusic(mood) }
                                }
                            }
                            Divider()
                            Button("Choose a File…") { model.chooseMusic() }
                        }
                        .menuStyle(.borderlessButton).fixedSize().handCursor()
                        .help("A built-in soft music bed, or an audio file you own. It loops and fades to fit the video.")
                        if model.videoOptions.musicPath != nil || model.musicMood != nil {
                            Slider(value: $model.videoOptions.musicVolume, in: 0.1...1).frame(maxWidth: 120).handCursor()
                                .help("Music volume")
                        }
                    }
                }
            }
            .font(.callout)

            footer(included)
            Divider()
            HStack {
                Text("Click to leave something out. Drag to change the order. Right-click a clip to trim it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.mediaOrder[event.id] != nil {
                    Button("Back to Time Order") { model.resetOrder(event) }.buttonStyle(.textLink).font(.caption)
                        .help("Order everything by when it was taken again")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(model.orderedItems(event).prefix(120)) { item in
                    EventItemTile(item: item, event: event)
                }
            }
            if event.items.count > 120 { Text("Showing the first 120 items; all included items are used.").font(.caption).foregroundStyle(.secondary) }

        }
        .premiumCard()
        .alert("Free up space?", isPresented: $confirmFree) {
            Button("Move to Trash", role: .destructive) { Task { await model.freeUpSpace(for: event) } }.disabled(!understood)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves the \(included.count) originals of “\(event.title)” to the Trash (files) or Recently Deleted (Photos), where you can restore them for 30 days or until you empty the Trash.\n\nThe video is a 1080p summary, not a full-quality backup. Keep originals in iCloud Photos or on a backup drive if you might want them later.")
        }
    }

    @ViewBuilder private func footer(_ included: [MediaItem]) -> some View {
        switch model.videoJob?.eventID == event.id ? model.videoJob?.phase : nil {
        case .building:
            HStack {
                ProgressView(value: model.videoJob?.progress ?? 0).frame(maxWidth: 360)
                Text("Making your video… \(Int((model.videoJob?.progress ?? 0) * 100))%").foregroundStyle(.secondary).monospacedDigit()
            }
        case .finished, .freeing, .freed:
            if let result = model.videoJob?.result {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Saved \(result.url.lastPathComponent) · \(String(format: "%d:%02d", Int(result.duration) / 60, Int(result.duration) % 60))"
                          + (result.skipped > 0 ? " · \(result.skipped) item(s) skipped (only in iCloud or unreadable)" : ""),
                          systemImage: "checkmark.circle.fill").foregroundStyle(Theme.safe).font(.callout.weight(.medium))
                    HStack {
                        Button { NSWorkspace.shared.open(result.url) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(GradientButtonStyle()).help("Open the video")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([result.url]) } label: { Label("Show in Finder", systemImage: "folder") }
                            .buttonStyle(SoftButtonStyle(tint: .secondary)).help("Upload it to YouTube, iCloud Drive or a drive from here")
                        Button { Task { await model.useEventForCollage(event) } } label: { Label("Make a Collage", systemImage: "square.grid.3x3.square") }
                            .buttonStyle(SoftButtonStyle(tint: .secondary)).help("Use this event's photos in a collage")
                        Spacer()
                        if case let .freed(n) = model.videoJob?.phase {
                            Label("\(n) originals moved to the Trash / Recently Deleted", systemImage: "trash").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Toggle("The video is enough. I keep originals elsewhere or don't need them", isOn: $understood)
                                .toggleStyle(.checkbox).font(.caption).handCursor()
                                .help("Required before freeing up space")
                            Button { confirmFree = true } label: { Label("Free Up \(ByteFormat.string(event.bytes))…", systemImage: "arrow.down.circle") }
                                .buttonStyle(SoftButtonStyle(tint: Theme.review)).disabled(!understood || event.bytes == 0 && included.allSatisfy { $0.filePath != nil })
                                .help("Move this event's originals to the Trash or Recently Deleted. You'll confirm once more.")
                        }
                    }
                }
            }
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
            createButton(included)
        case nil:
            createButton(included)
        }
    }

    private func createButton(_ included: [MediaItem]) -> some View {
        HStack {
            Label("About \(estimate(included)) long. Saved to ~/Movies/DiskLens. Originals aren't touched.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { Task { await model.buildVideo(for: event) } } label: { Label("Create Video", systemImage: "film") }
                .buttonStyle(GradientButtonStyle(large: true)).disabled(included.isEmpty)
                .help("Make one video from the included photos and clips")
        }
    }

    private func estimate(_ items: [MediaItem]) -> String {
        let o = model.videoOptions
        let seconds = 2.5 + items.reduce(0.0) { $0 + ($1.kind == .photo ? o.photoSeconds : min($1.duration, o.maxClipSeconds)) }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// One photo or clip in an event: click to include, drag to reorder, trim clips.
private struct EventItemTile: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    let event: MediaEvent
    @State private var trimming = false
    @State private var targeted = false

    var body: some View {
        let excluded = model.excludedMedia.contains(item.id)
        let trim = model.videoOptions.trims[item.id]
        Button {
            if excluded { model.excludedMedia.remove(item.id) } else { model.excludedMedia.insert(item.id) }
        } label: {
            MediaThumb(item: item)
                .opacity(excluded ? 0.35 : 1)
                .overlay(alignment: .topLeading) {
                    Image(systemName: excluded ? "circle" : "checkmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(excluded ? Color.white : Theme.brandStart)
                        .background(Circle().fill(.white).padding(2)).padding(5)
                }
                .overlay(alignment: .topTrailing) {
                    if item.kind == .video {
                        Button { trimming = true } label: {
                            Image(systemName: "scissors").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(5).background(Circle().fill(trim == nil ? Color.black.opacity(0.5) : Theme.brandStart))
                        }
                        .buttonStyle(.plain).padding(4).handCursor().help(trim == nil ? "Trim this clip" : "Trimmed. Click to change")
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.brandStart, lineWidth: targeted ? 3 : 0))
        }
        .buttonStyle(.plain).handCursor()
        .help(excluded ? "Left out. Click to include" : "Included. Click to leave it out; drag to move it")
        .draggable(item.id) { MediaThumb(item: item, size: 60) }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.moveMedia(id, before: item.id, in: event)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Move Earlier") { model.moveMedia(item, by: -1, in: event) }
            Button("Move Later") { model.moveMedia(item, by: 1, in: event) }
            if item.kind == .video {
                Divider()
                Button("Trim…") { trimming = true }
                if trim != nil { Button("Remove Trim") { model.videoOptions.trims[item.id] = nil } }
            }
        }
        .popover(isPresented: $trimming) { TrimEditor(item: item).environment(model) }
    }
}

private struct TrimEditor: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem

    var body: some View {
        let duration = max(item.duration, 1)
        let current = model.videoOptions.trims[item.id] ?? ClipTrim(start: 0, length: min(duration, model.videoOptions.maxClipSeconds))
        VStack(alignment: .leading, spacing: 12) {
            Text("Trim clip").font(.headline)
            Text(item.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Start").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { current.start }, set: { v in
                        model.videoOptions.trims[item.id] = ClipTrim(start: v, length: min(current.length, duration - v))
                    }), in: 0...max(0, duration - 0.5)).frame(width: 220)
                    Text(time(current.start)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                GridRow {
                    Text("Length").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { current.length }, set: { v in
                        model.videoOptions.trims[item.id] = ClipTrim(start: current.start, length: v)
                    }), in: 0.5...max(0.5, duration - current.start)).frame(width: 220)
                    Text(time(current.length)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            .font(.callout)
            HStack {
                Text("Plays \(time(current.start))–\(time(current.start + current.length)) of \(time(duration))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.videoOptions.trims[item.id] = nil }.buttonStyle(.textLink).font(.caption)
            }
        }
        .padding(16)
    }

    private func time(_ s: Double) -> String { String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
}

// MARK: - Enhance

private struct EnhancePanel: View {
    @Environment(AppModel.self) private var model
    @State private var split: CGFloat = 0.5

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Enhance photos", subtitle: "Apple's automatic exposure, colour and shadow fixes, plus gentle noise reduction and sharpening. Saves copies; originals are never changed.", symbol: "wand.and.stars")
                Divider()
                Toggle("Fix light and colour", isOn: $model.enhanceOptions.autoAdjust).toggleStyle(.checkbox).handCursor()
                    .help("Exposure, contrast, vibrance, shadows and highlights, like the Auto button in Photos")
                Toggle("Reduce noise", isOn: $model.enhanceOptions.reduceNoise).toggleStyle(.checkbox).handCursor()
                    .help("Smooths the grain in low-light photos")
                Toggle("Sharpen", isOn: $model.enhanceOptions.sharpen).toggleStyle(.checkbox).handCursor()
                    .help("Crisper detail without halos")
                HStack {
                    Text("Strength").foregroundStyle(.secondary)
                    Slider(value: $model.enhanceOptions.strength, in: 0.2...1).handCursor()
                    Text("\(Int(model.enhanceOptions.strength * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                }
                .help("Blend the result with the original")
                Toggle("Remove location and camera details", isOn: $model.enhanceRemovePrivate).toggleStyle(.checkbox).handCursor()
                    .help("The copies keep the date taken but not where or with what")
                Divider()
                HStack {
                    Button { model.addEnhancePhotos() } label: { Label("Add Photos…", systemImage: "plus") }
                        .buttonStyle(SoftButtonStyle(tint: .secondary))
                    if let event = model.selectedEvent {
                        Button("Use “\(event.title)”") { Task { await model.useEventForEnhance(event) } }
                            .buttonStyle(.textLink).font(.callout).lineLimit(1).help("Enhance this event's photos")
                    }
                }
                if !model.enhanceItems.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.enhanceItems) { item in
                                Button {
                                    model.enhancePreviewID = item.id
                                    Task { await model.refreshEnhancePreview() }
                                } label: {
                                    MediaThumb(item: item, size: 64)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.brandStart, lineWidth: model.enhanceSelected?.id == item.id ? 3 : 0))
                                }
                                .buttonStyle(.plain).handCursor().help("Preview \(item.name)")
                                .contextMenu { Button("Remove") { Task { await model.removeFromEnhance(item) } } }
                            }
                        }
                    }
                    Text("Saved to " + model.enhanceFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary)
                    if let p = model.enhanceProgress {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                        Text("Enhanced \(p.done) of \(p.total)…").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Button { Task { await model.saveEnhanced() } } label: {
                            Label("Save \(model.enhanceItems.count) Enhanced Cop\(model.enhanceItems.count == 1 ? "y" : "ies")", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(GradientButtonStyle(large: true)).disabled(DemoData.isEnabled)
                    }
                    let saved = model.enhanceResults.filter(\.ok)
                    if !saved.isEmpty {
                        HStack {
                            Label("\(saved.count) saved", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.safe)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(saved.compactMap(\.output).map { URL(fileURLWithPath: $0) }) }
                                .buttonStyle(.textLink)
                        }
                        .font(.callout)
                    }
                    ForEach(model.enhanceResults.filter { !$0.ok }, id: \.source) { r in
                        Label("\((r.source as NSString).lastPathComponent): \(r.message)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.review)
                    }
                }
            }
            .premiumCard()
            .frame(width: 380)
            .onChange(of: model.enhanceOptions) { Task { await model.refreshEnhancePreview() } }

            VStack(alignment: .leading, spacing: 8) {
                if let before = model.enhanceBefore, let after = model.enhanceAfter {
                    BeforeAfter(before: before, after: after, split: $split)
                    Text("Drag the line to compare. Left: original · right: enhanced.").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "wand.and.stars").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Add photos to see a before and after.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
            .frame(maxWidth: .infinity)
            .premiumCard()
        }
    }
}

/// The original on the left of the divider and the enhanced version on the right.
private struct BeforeAfter: View {
    let before: CGImage
    let after: CGImage
    @Binding var split: CGFloat

    var body: some View {
        let aspect = CGFloat(before.width) / CGFloat(max(before.height, 1))
        GeometryReader { geo in
            let x = geo.size.width * split
            ZStack(alignment: .leading) {
                Image(decorative: after, scale: 1).resizable().aspectRatio(contentMode: .fit)
                Image(decorative: before, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                Rectangle().fill(.white).frame(width: 2).shadow(radius: 2).offset(x: x - 1)
                Image(systemName: "arrow.left.and.right.circle.fill").font(.system(size: 26)).symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.brandStart, .white).offset(x: x - 13)
                Text("Before").font(.caption2.weight(.bold)).padding(5).background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
                    .padding(8).frame(maxHeight: .infinity, alignment: .top)
                Text("After").font(.caption2.weight(.bold)).padding(5).background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
                    .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(1, max(0, $0.location.x / geo.size.width)) })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Collage

private struct CollagePanel: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Photos", subtitle: "\(model.collageItems.count) chosen. Drop photos here, or add them.", symbol: "photo.stack")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(model.collageItems) { item in
                        MediaThumb(item: item, size: 72)
                            .overlay(alignment: .topTrailing) {
                                Button { Task { await model.removeFromCollage(item) } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6)) }
                                    .buttonStyle(IconButtonStyle()).help("Remove from the collage")
                            }
                    }
                }
                HStack {
                    Button { model.addCollagePhotos() } label: { Label("Add Photos…", systemImage: "plus") }
                        .buttonStyle(SoftButtonStyle()).help("Choose photos from your Mac")
                    if let event = model.selectedEvent {
                        Button { Task { await model.useEventForCollage(event) } } label: { Label("Use “\(event.title)”", systemImage: "calendar") }
                            .buttonStyle(SoftButtonStyle(tint: .secondary)).lineLimit(1).help("Use up to 12 photos from the selected event")
                    }
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Layout").foregroundStyle(.secondary)
                        Picker("", selection: $model.collageOptions.layout) {
                            ForEach(CollageOptions.Layout.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().handCursor()
                            .help("Grid crops photos into equal cells; Album rows keeps every photo's shape")
                    }
                    GridRow {
                        Text("Shape").foregroundStyle(.secondary)
                        Picker("", selection: $model.collageOptions.aspect) {
                            ForEach(CollageOptions.Aspect.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().handCursor()
                            .help("1:1 posts, 4:5 Instagram, 9:16 stories, 16:9 screens")
                    }
                    GridRow {
                        Text("Spacing").foregroundStyle(.secondary)
                        Slider(value: $model.collageOptions.spacing, in: 0...0.04).handCursor().help("Gap between photos")
                    }
                    GridRow {
                        Text("Corners").foregroundStyle(.secondary)
                        Slider(value: $model.collageOptions.cornerRadius, in: 0...0.04).handCursor().help("Rounded corners")
                    }
                    GridRow {
                        Text("Background").foregroundStyle(.secondary)
                        ColorPicker("", selection: Binding(get: { Color(cgColor: model.collageOptions.background) },
                                                           set: { model.collageOptions.background = NSColor($0).cgColor }), supportsOpacity: false)
                            .labelsHidden().handCursor().help("Colour behind and between photos")
                    }
                }
                .font(.callout)
                .onChange(of: model.collageOptions.layout) { _, _ in Task { await model.refreshCollagePreview() } }
                .onChange(of: model.collageOptions.aspect) { _, _ in Task { await model.refreshCollagePreview() } }
                .onChange(of: model.collageOptions.spacing) { _, _ in Task { await model.refreshCollagePreview() } }
                .onChange(of: model.collageOptions.cornerRadius) { _, _ in Task { await model.refreshCollagePreview() } }
                .onChange(of: model.collageOptions.background) { _, _ in Task { await model.refreshCollagePreview() } }
            }
            .frame(width: 380)
            .premiumCard()
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.brandStart, lineWidth: dropping ? 2 : 0))
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.addCollage(paths: urls.map(\.path)) }
                return true
            } isTargeted: { dropping = $0 }

            VStack(spacing: 14) {
                if let preview = model.collagePreview {
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .frame(maxHeight: 640)
                } else {
                    ContentUnavailableView("Add photos to see your collage", systemImage: "square.grid.3x3.square",
                                           description: Text("Drop photos on the left, or use an event's photos."))
                        .frame(minHeight: 420)
                }
                HStack {
                    Text("Saved at \(model.collageOptions.width) px wide, without location or camera details.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await model.saveCollage() } } label: { Label("Save Collage…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(GradientButtonStyle(large: true)).disabled(model.collageItems.isEmpty)
                        .help("Save as JPEG or PNG")
                }
            }
            .frame(maxWidth: .infinity)
            .premiumCard()
        }
    }
}

// MARK: - Convert & Resize

private struct ConvertPanel: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    private static let sides = [1080, 1600, 2048, 3840]
    private static let percents = [75, 50, 25]
    private static let sizes: [Int64] = [200_000, 500_000, 1_000_000, 2_000_000, 5_000_000]
    private static let crops: [(String, CGFloat?)] = [("Keep shape", nil), ("1:1", 1), ("4:5", 0.8), ("9:16", 9.0 / 16), ("16:9", 16.0 / 9)]

    var body: some View {
        @Bindable var model = model
        let hasImages = model.convertFiles.contains { !AppModel.isVideo($0) }
        let hasVideos = model.convertFiles.contains(where: AppModel.isVideo)
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Files", subtitle: model.convertFiles.isEmpty ? "Drop photos or videos here." : "\(model.convertFiles.count) file(s). Originals are never changed.",
                              symbol: "doc.on.doc")
                if model.convertFiles.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Drop photos or videos").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
                }
                ForEach(model.convertFiles, id: \.self) { path in
                    let result = model.convertResults.first { $0.source == path }
                    HStack(spacing: 10) {
                        Image(systemName: AppModel.isVideo(path) ? "video" : "photo").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            if let result {
                                Text(result.ok ? "→ \(ByteFormat.string(result.bytes))" + (result.pixelSize.width > 0 ? " · \(Int(result.pixelSize.width))×\(Int(result.pixelSize.height))" : "") + (result.message.isEmpty ? "" : " · \(result.message)")
                                     : result.message)
                                    .font(.caption).foregroundStyle(result.ok ? Theme.safe : Theme.danger)
                            } else if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 0 {
                                Text(ByteFormat.string(Int64(size))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let out = result?.output { PathActions(path: out) }
                        Button { model.convertFiles.removeAll { $0 == path } } label: { Image(systemName: "xmark") }
                            .buttonStyle(IconButtonStyle()).help("Remove from the list")
                    }
                    .help(path)
                }
                HStack {
                    Button { model.addConvertFiles() } label: { Label("Add Files…", systemImage: "plus") }
                        .buttonStyle(SoftButtonStyle()).help("Choose photos or videos")
                    if !model.convertFiles.isEmpty {
                        Button("Clear") { model.convertFiles = []; model.convertResults = [] }.buttonStyle(SoftButtonStyle(tint: .secondary)).help("Empty the list")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .premiumCard()
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.brandStart, lineWidth: dropping ? 2 : 0))
            .dropDestination(for: URL.self) { urls, _ in model.addConvert(paths: urls.map(\.path)); return true } isTargeted: { dropping = $0 }

            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Settings", symbol: "slider.horizontal.3")
                if hasImages || model.convertFiles.isEmpty {
                    Text("Photos").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Format").foregroundStyle(.secondary)
                            Picker("", selection: $model.imageOptions.format) {
                                ForEach(ImageConvertOptions.Format.allCases) { Text($0.label).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().handCursor()
                                .help("JPEG works everywhere; HEIC is about half the size; PNG and TIFF are lossless")
                        }
                        GridRow {
                            Text("Size").foregroundStyle(.secondary)
                            Picker("", selection: $model.imageOptions.resize) {
                                Text("Original").tag(ImageConvertOptions.Resize.original)
                                ForEach(Self.sides, id: \.self) { Text("Longest side \($0) px").tag(ImageConvertOptions.Resize.longestSide($0)) }
                                ForEach(Self.percents, id: \.self) { Text("\($0)%").tag(ImageConvertOptions.Resize.percent($0)) }
                            }.labelsHidden().handCursor().help("Make photos smaller in pixels")
                        }
                        GridRow {
                            Text("Crop").foregroundStyle(.secondary)
                            Picker("", selection: Binding(get: { Self.crops.firstIndex { $0.1 == model.imageOptions.cropRatio } ?? 0 },
                                                          set: { model.imageOptions.cropRatio = Self.crops[$0].1 })) {
                                ForEach(Self.crops.indices, id: \.self) { Text(Self.crops[$0].0).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().handCursor().help("Crop from the centre to this shape")
                        }
                        GridRow {
                            Text("Max file size").foregroundStyle(.secondary)
                            Picker("", selection: $model.imageOptions.maxBytes) {
                                Text("No limit").tag(Int64?.none)
                                ForEach(Self.sizes, id: \.self) { Text("Under \(ByteFormat.string($0))").tag(Int64?.some($0)) }
                            }.labelsHidden().handCursor()
                                .help("For forms and uploads with a size limit (JPEG/HEIC). Quality is lowered first, then the size.")
                        }
                    }
                    .font(.callout)
                }
                if hasVideos || model.convertFiles.isEmpty {
                    Text("Videos").font(.headline)
                    Picker("", selection: $model.videoPreset) {
                        ForEach(MediaConverter.VideoPreset.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().disabled(model.makeGIF).handCursor().help("Resolution and codec for converted videos")
                    Toggle("Make an animated GIF instead (first 6 seconds)", isOn: $model.makeGIF).toggleStyle(.checkbox).handCursor()
                }
                Toggle(isOn: $model.imageOptions.removePrivateInfo) {
                    Label("Remove location and camera details", systemImage: "hand.raised.fill")
                }
                .toggleStyle(.checkbox).handCursor()
                .help("Recommended before sharing. Keeps the date the photo was taken.")
                Divider()
                HStack {
                    Label(model.convertFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                        .font(.caption).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Change…") { model.chooseConvertFolder() }.buttonStyle(.textLink).font(.caption).help("Where converted files are saved")
                }
                if let p = model.convertProgress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Text("Converting \(p.done + 1) of \(p.total)…").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if !model.convertResults.isEmpty {
                        Button { NSWorkspace.shared.open(model.convertFolder) } label: { Label("Open Folder", systemImage: "folder") }
                            .buttonStyle(SoftButtonStyle(tint: .secondary)).help("See the converted files")
                    }
                    Spacer()
                    Button { Task { await model.convertAll() } } label: { Label("Convert \(model.convertFiles.count)", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(GradientButtonStyle(large: true)).disabled(model.convertFiles.isEmpty || model.convertProgress != nil)
                        .help("Save converted copies. Originals stay exactly as they are.")
                }
            }
            .frame(width: 420)
            .premiumCard()
        }
    }
}
