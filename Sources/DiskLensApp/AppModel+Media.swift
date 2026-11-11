import AppKit
import DiskLensCore
import Foundation
import Photos

enum MediaTool: String, CaseIterable, Identifiable {
    case events, collage, enhance, cutout, convert
    var id: Self { self }
    var title: String {
        switch self {
        case .events: "Events → Video"
        case .collage: "Collage"
        case .enhance: "Enhance"
        case .cutout: "Cut Out"
        case .convert: "Convert & Resize"
        }
    }
    var symbol: String {
        switch self {
        case .events: "film"
        case .collage: "square.grid.3x3.square"
        case .enhance: "wand.and.stars"
        case .cutout: "person.crop.rectangle"
        case .convert: "arrow.triangle.2.circlepath"
        }
    }
}

/// Building an event video, and the optional "free up space" step afterwards.
struct VideoJob {
    enum Phase: Equatable { case building, finished, failed(String), freeing, freed(Int) }
    var eventID: String
    var phase: Phase = .building
    var progress: Double = 0
    var result: VideoBuildResult?
}

extension AppModel {
    var selectedEvent: MediaEvent? { events.first { $0.id == selectedEventID } }

    func includedItems(_ event: MediaEvent) -> [MediaItem] { orderedItems(event).filter { !excludedMedia.contains($0.id) } }

    /// The event's items in the order the user arranged them (by time until they drag something).
    func orderedItems(_ event: MediaEvent) -> [MediaItem] {
        guard let order = mediaOrder[event.id] else { return event.items }
        let byID = Dictionary(uniqueKeysWithValues: event.items.map { ($0.id, $0) })
        let placed = order.compactMap { byID[$0] }
        let placedIDs = Set(order)
        return placed + event.items.filter { !placedIDs.contains($0.id) }
    }

    func moveMedia(_ id: String, before target: String, in event: MediaEvent) {
        guard id != target else { return }
        var ids = orderedItems(event).map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        let to = ids.firstIndex(of: target) ?? ids.count
        ids.insert(id, at: to)
        mediaOrder[event.id] = ids
    }

    func moveMedia(_ item: MediaItem, by offset: Int, in event: MediaEvent) {
        var ids = orderedItems(event).map(\.id)
        guard let from = ids.firstIndex(of: item.id) else { return }
        let to = max(0, min(ids.count - 1, from + offset))
        ids.remove(at: from)
        ids.insert(item.id, at: to)
        mediaOrder[event.id] = ids
    }

    func resetOrder(_ event: MediaEvent) { mediaOrder[event.id] = nil }

    // MARK: Music

    var musicLabel: String? {
        if let mood = musicMood { return mood.label }
        return videoOptions.musicPath.map { ($0 as NSString).lastPathComponent }
    }

    /// Built-in music is generated on this Mac the first time it's used (about a second), then cached.
    func useBuiltInMusic(_ mood: MusicGenerator.Mood) {
        if DemoData.isEnabled { musicMood = mood; return }
        Task.detached {
            let url = try? MusicGenerator.track(mood)
            await MainActor.run { [weak self] in
                guard let self, let url else { return }
                self.videoOptions.musicPath = url.path
                self.musicMood = mood
            }
        }
    }

    func clearMusic() {
        videoOptions.musicPath = nil
        musicMood = nil
    }

    // MARK: Sources

    func loadMediaFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder of photos and videos. DiskLens only reads it."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task {
            isLoadingMedia = true
            mediaItems = await MediaLibrary.scanFolders(panel.urls.map(\.path))
            mediaSourceLabel = panel.urls.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.joined(separator: ", ")
            regroupEvents()
            isLoadingMedia = false
        }
    }

    func loadPhotosLibrary() async {
        isLoadingMedia = true
        defer { isLoadingMedia = false }
        guard await MediaLibrary.requestPhotosAccess() else {
            mediaSourceLabel = "Photos access was not allowed. Turn it on in System Settings → Privacy & Security → Photos."
            mediaItems = []
            events = []
            return
        }
        mediaItems = MediaLibrary.photosLibraryItems()
        mediaSourceLabel = "Photos library"
        regroupEvents()
    }

    func regroupEvents() {
        events = EventGrouper.group(mediaItems, gapHours: eventGapHours)
        if selectedEvent == nil { selectedEventID = events.first?.id }
        videoJob = nil
    }

    func selectEvent(_ event: MediaEvent) {
        selectedEventID = event.id
        videoOptions.title = event.title
        videoOptions.subtitle = "\(event.photoCount) photos" + (event.videoCount > 0 ? " · \(event.videoCount) videos" : "")
        if videoJob?.eventID != event.id { videoJob = nil }
    }

    func renameEvent(_ id: String, to title: String) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].title = title
    }

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a song or audio file you own (MP3, M4A, WAV, AIFF). Apple Music downloads are copy-protected and can't be used."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        videoOptions.musicPath = url.path
        musicMood = nil
    }

    // MARK: Build

    func buildVideo(for event: MediaEvent) async {
        guard !DemoData.isEnabled else { return }
        let items = includedItems(event)
        guard !items.isEmpty else { return }
        videoJob = VideoJob(eventID: event.id)
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Movies/DiskLens")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeTitle = (videoOptions.title?.isEmpty == false ? videoOptions.title! : event.title)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let output = MediaConverter.uniqueURL(folder.appendingPathComponent(safeTitle + ".mp4"))
        do {
            let result = try await VideoBuilder.build(items: items, options: videoOptions, output: output) { p in
                Task { @MainActor [weak self] in self?.videoJob?.progress = p }
            }
            videoJob?.result = result
            videoJob?.phase = .finished
            addLog(LogEntry(title: "Created video “\(safeTitle)”", bytes: 0, outcome: .freed,
                            detail: "\(items.count) items → \(String(format: "%.0f", result.duration)) s video in ~/Movies/DiskLens"))
        } catch {
            videoJob?.phase = .failed(error.localizedDescription)
        }
    }

    /// Moves the event's originals to the Trash (files) or Recently Deleted (Photos library). Both can be undone.
    func freeUpSpace(for event: MediaEvent) async {
        let items = includedItems(event)
        videoJob?.phase = .freeing
        var removed = 0
        var removedIDs = Set<String>()
        let photoIDs = items.compactMap { if case let .photos(id) = $0.origin { id } else { nil } }
        for path in items.compactMap(\.filePath) where Executor.isSafeToTrash(path, home: NSHomeDirectory()) {
            if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil {
                removed += 1
                removedIDs.insert(path)
            }
        }
        if !photoIDs.isEmpty {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: photoIDs, options: nil)
            // macOS asks for confirmation itself, and the items go to Recently Deleted for 30 days.
            let ok = (try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }) != nil
            if ok {
                removed += assets.count
                removedIDs.formUnion(photoIDs.map { "photos:" + $0 })
            }
        }
        mediaItems.removeAll { removedIDs.contains($0.id) }
        addLog(LogEntry(title: "Freed space after making a video of “\(event.title)”", bytes: event.bytes,
                        outcome: .trashed, detail: "\(removed) original(s) moved to the Trash / Recently Deleted"))
        videoJob?.phase = .freed(removed)
    }

    // MARK: Collage

    func addCollagePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos for the collage"
        guard panel.runModal() == .OK else { return }
        Task { await addCollage(paths: panel.urls.map(\.path)) }
    }

    func addCollage(paths: [String]) async {
        for p in paths where !collageItems.contains(where: { $0.filePath == p }) {
            if let item = await MediaLibrary.item(at: p), item.kind == .photo { collageItems.append(item) }
        }
        await refreshCollagePreview()
    }

    func useEventForCollage(_ event: MediaEvent) async {
        collageItems = Array(includedItems(event).filter { $0.kind == .photo }.prefix(12))
        mediaTool = .collage
        await refreshCollagePreview()
    }

    func removeFromCollage(_ item: MediaItem) async {
        collageItems.removeAll { $0.id == item.id }
        await refreshCollagePreview()
    }

    func refreshCollagePreview() async {
        var images: [CGImage] = []
        for item in collageItems { if let cg = await thumbnail(item, maxPixels: 700) { images.append(cg) } }
        var preview = collageOptions
        preview.width = 1100
        collagePreview = images.isEmpty ? nil : CollageBuilder.render(images, options: preview)
    }

    func saveCollage() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = "Collage.jpg"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var images: [CGImage] = []
        for item in collageItems { if let cg = await thumbnail(item, maxPixels: max(collageOptions.width, 2400)) { images.append(cg) } }
        guard let image = CollageBuilder.render(images, options: collageOptions) else { return }
        do {
            try CollageBuilder.save(image, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    /// Real thumbnails, or generated swatches in demo mode (so screenshots never show real photos).
    func thumbnail(_ item: MediaItem, maxPixels: Int) async -> CGImage? {
        // Demo: Apple's sample account pictures are real images (not personal); everything else is a swatch.
        if DemoData.isEnabled, item.filePath?.hasPrefix("/Library/User Pictures/") != true { return DemoData.swatch(for: item.id, size: min(maxPixels, 600)) }
        return await MediaLibrary.image(for: item, maxPixels: maxPixels)
    }

    // MARK: Convert

    func addConvertFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos or videos to convert. The originals are never changed."
        guard panel.runModal() == .OK else { return }
        addConvert(paths: panel.urls.map(\.path))
    }

    func addConvert(paths: [String]) {
        for p in paths where !convertFiles.contains(p) && Self.isMedia(p) { convertFiles.append(p) }
    }

    static func isMedia(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp", "gif", "bmp", "dng", "avif", "mov", "mp4", "m4v"].contains(ext)
    }

    static func isVideo(_ path: String) -> Bool {
        ["mov", "mp4", "m4v"].contains((path as NSString).pathExtension.lowercased())
    }

    func chooseConvertFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        convertFolder = url
    }

    func convertAll() async {
        guard !convertFiles.isEmpty, !DemoData.isEnabled else { return }
        try? FileManager.default.createDirectory(at: convertFolder, withIntermediateDirectories: true)
        convertResults = []
        convertProgress = (0, convertFiles.count)
        for path in convertFiles {
            let result: ConvertResult
            if Self.isVideo(path) {
                if !makeGIF, let target = videoTargetBytes {
                    result = await VideoCompressor.compress(path, targetBytes: target, removePrivateInfo: imageOptions.removePrivateInfo, into: convertFolder)
                } else {
                result = makeGIF ? await MediaConverter.videoToGIF(path, into: convertFolder)
                    : await MediaConverter.convertVideo(path, preset: videoPreset, removePrivateInfo: imageOptions.removePrivateInfo,
                                                        into: convertFolder) { _ in }
                }
            } else {
                let options = imageOptions
                let folder = convertFolder
                result = await Task.detached { MediaConverter.convertImage(path, options: options, into: folder) }.value
            }
            convertResults.append(result)
            convertProgress = (convertResults.count, convertFiles.count)
        }
        convertProgress = nil
        let ok = convertResults.filter(\.ok).count
        addLog(LogEntry(title: "Converted \(ok) file\(ok == 1 ? "" : "s")", bytes: 0, outcome: .freed,
                        detail: "Saved to \(convertFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")); originals unchanged"))
    }

    // MARK: Enhance

    var enhanceSelected: MediaItem? { enhanceItems.first { $0.id == enhancePreviewID } ?? enhanceItems.first }

    func addEnhancePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos to enhance. The originals are never changed."
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls where !enhanceItems.contains(where: { $0.filePath == url.path }) {
                if let item = await MediaLibrary.item(at: url.path), item.kind == .photo { enhanceItems.append(item) }
            }
            if enhancePreviewID == nil { enhancePreviewID = enhanceItems.first?.id }
            await refreshEnhancePreview()
        }
    }

    func useEventForEnhance(_ event: MediaEvent) async {
        enhanceItems = Array(includedItems(event).filter { $0.kind == .photo }.prefix(60))
        enhancePreviewID = enhanceItems.first?.id
        mediaTool = .enhance
        await refreshEnhancePreview()
    }

    func removeFromEnhance(_ item: MediaItem) async {
        enhanceItems.removeAll { $0.id == item.id }
        if enhancePreviewID == item.id { enhancePreviewID = enhanceItems.first?.id }
        await refreshEnhancePreview()
    }

    /// Before and after of the selected photo at preview size.
    func refreshEnhancePreview() async {
        guard let item = enhanceSelected else { enhanceBefore = nil; enhanceAfter = nil; return }
        let before = await thumbnail(item, maxPixels: 1400)
        let options = enhanceOptions
        enhanceBefore = before
        enhanceAfter = await Task.detached { before.flatMap { PhotoEnhancer.enhance($0, options: options) } }.value
    }

    func saveEnhanced() async {
        guard !DemoData.isEnabled, !enhanceItems.isEmpty else { return }
        try? FileManager.default.createDirectory(at: enhanceFolder, withIntermediateDirectories: true)
        enhanceResults = []
        enhanceProgress = (0, enhanceItems.count)
        let options = enhanceOptions, folder = enhanceFolder, strip = enhanceRemovePrivate
        for (i, item) in enhanceItems.enumerated() {
            let result: ConvertResult
            if let path = item.filePath {
                result = await Task.detached { PhotoEnhancer.enhanceFile(path, options: options, removePrivateInfo: strip, into: folder) }.value
            } else if let image = await MediaLibrary.image(for: item, maxPixels: 8_192) {
                let name = item.name
                result = await Task.detached { PhotoEnhancer.enhanceImage(image, name: name, options: options, into: folder) }.value
            } else {
                result = ConvertResult(source: item.name, output: nil, bytes: 0, pixelSize: .zero, message: "Only in iCloud: download it in Photos first")
            }
            enhanceResults.append(result)
            enhanceProgress = (i + 1, enhanceItems.count)
        }
        enhanceProgress = nil
        let ok = enhanceResults.filter(\.ok).count
        addLog(LogEntry(title: "Enhanced \(ok) photo\(ok == 1 ? "" : "s")", bytes: 0, outcome: .freed,
                        detail: "Saved to \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Originals unchanged."))
    }
}
