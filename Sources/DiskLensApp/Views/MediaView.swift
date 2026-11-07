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
                        Text("Turn events into videos, make collages, and convert or resize photos and videos. All on this Mac.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Tool", selection: $model.mediaTool) {
                        ForEach(MediaTool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460).handCursor()
                    .help("Choose a tool")
                }
                switch model.mediaTool {
                case .events: EventsPanel()
                case .collage: CollagePanel()
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
                        if let music = model.videoOptions.musicPath {
                            Label((music as NSString).lastPathComponent, systemImage: "music.note").lineLimit(1)
                            Button { model.videoOptions.musicPath = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(IconButtonStyle()).help("No music")
                        }
                        Button(model.videoOptions.musicPath == nil ? "Choose Music…" : "Change…") { model.chooseMusic() }
                            .buttonStyle(SoftButtonStyle(tint: .secondary))
                            .help("An audio file you own. It loops and fades in and out to fit the video.")
                    }
                }
            }
            .font(.callout)

            footer(included)
            Divider()
            Text("Tap a photo or clip to leave it out.").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(event.items.prefix(120)) { item in
                    let excluded = model.excludedMedia.contains(item.id)
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
                    }
                    .buttonStyle(.plain).handCursor()
                    .help(excluded ? "Left out. Click to include" : "Included. Click to leave it out of the video")
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
