#if os(macOS)
import AVFoundation
@testable import DiskLensCore
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class MediaTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dl-media-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { if ProcessInfo.processInfo.environment["DISKLENS_KEEP_TEMP"] == nil { try? FileManager.default.removeItem(at: dir) } }

    func makeImage(_ name: String, w: Int, h: Int, type: UTType = .jpeg, gps: Bool = false, hue: CGFloat = 0.3) -> String {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<12 {   // stripes, so files compress like a photo, not a flat colour
            ctx.setFillColor(CGColor(red: hue, green: CGFloat(i) / 12, blue: 1 - hue, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h * i / 12, width: w, height: h / 12 + 1))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if gps { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 12.97, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 77.59, kCGImagePropertyGPSLongitudeRef: "E"] }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func pixelSize(_ path: String) -> CGSize {
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return CGSize(width: p[kCGImagePropertyPixelWidth] as! Int, height: p[kCGImagePropertyPixelHeight] as! Int)
    }

    // MARK: Events

    func testGroupsEventsByTimeGapsAndPlace() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let home = Coordinate(latitude: 19.07, longitude: 72.87), goa = Coordinate(latitude: 15.49, longitude: 73.82)
        func item(_ minutes: Double, _ c: Coordinate?) -> MediaItem {
            MediaItem(origin: .file("/p/\(minutes)"), kind: .photo, date: base.addingTimeInterval(minutes * 60), coordinate: c)
        }
        let birthday = (0..<6).map { item(Double($0) * 10, home) }               // one evening
        let trip = (0..<5).map { item(2000 + Double($0) * 15, goa) }             // next day, far away
        let sameDayElsewhere = (0..<4).map { item(2080 + Double($0) * 5, home) } // an hour later, but 450 km back
        let stray = [item(9000, nil)]                                            // single photo: dropped
        let events = EventGrouper.group(birthday + trip + sameDayElsewhere + stray)
        XCTAssertEqual(events.map(\.items.count), [4, 5, 6], "newest first; the place jump splits the second day")
        XCTAssertFalse(events[0].title.isEmpty)
    }

    // MARK: Collage

    func testCollageLayoutsStayInsideAndDontOverlap() {
        let canvas = CGSize(width: 3000, height: 3000)
        let sizes = [CGSize(width: 4000, height: 3000), CGSize(width: 3000, height: 4000), CGSize(width: 4000, height: 3000),
                     CGSize(width: 3000, height: 3000), CGSize(width: 1920, height: 1080)]
        for layout in CollageOptions.Layout.allCases {
            var o = CollageOptions(); o.layout = layout
            let rects = CollageBuilder.frames(for: sizes, options: o, canvas: canvas)
            XCTAssertEqual(rects.count, sizes.count)
            for (i, a) in rects.enumerated() {
                XCTAssertTrue(CGRect(origin: .zero, size: canvas).insetBy(dx: -0.5, dy: -0.5).contains(a), "\(layout) rect \(i) outside")
                for b in rects[(i + 1)...] { XCTAssertFalse(a.insetBy(dx: 1, dy: 1).intersects(b), "\(layout) overlap") }
            }
            if layout == .rows {   // album rows keep every photo's shape
                for (r, s) in zip(rects, sizes) { XCTAssertEqual(r.width / r.height, s.width / s.height, accuracy: 0.01) }
            }
        }
        let images = (0..<4).map { CollageBuilder.self; _ = $0; return MediaLibrary.thumbnail(makeImage("c\($0).jpg", w: 800, h: 600), maxPixels: 800)! }
        var o = CollageOptions(); o.aspect = .story; o.width = 1080
        let collage = CollageBuilder.render(images, options: o)
        XCTAssertEqual(collage?.width, 1080)
        XCTAssertEqual(collage?.height, 1920)
    }

    // MARK: Convert

    func testConvertsResizesCropsAndStripsLocation() async throws {
        let heic = makeImage("big.heic", w: 4000, h: 3000, type: .heic, gps: true)
        var o = ImageConvertOptions(); o.format = .jpeg; o.resize = .longestSide(1200)
        let r = MediaConverter.convertImage(heic, options: o, into: dir)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(pixelSize(r.output!), CGSize(width: 1200, height: 900))
        let report = await MetadataInspector.inspect(r.output!)
        XCTAssertNil(report?.coordinate, "location removed by default")

        o.cropRatio = 1; o.resize = .percent(50)
        let square = MediaConverter.convertImage(heic, options: o, into: dir)
        XCTAssertEqual(pixelSize(square.output!), CGSize(width: 1500, height: 1500))

        var small = ImageConvertOptions(); small.maxBytes = 150_000
        let tiny = MediaConverter.convertImage(heic, options: small, into: dir)
        XCTAssertTrue(tiny.ok, tiny.message)
        XCTAssertLessThanOrEqual(tiny.bytes, 150_000)

        var keep = ImageConvertOptions(); keep.removePrivateInfo = false; keep.format = .png
        let withGPS = MediaConverter.convertImage(heic, options: keep, into: dir)
        let kept = await MetadataInspector.inspect(withGPS.output!)
        XCTAssertNotNil(kept?.coordinate, "keeps location only when asked")
        XCTAssertNotEqual(r.output, MediaConverter.convertImage(heic, options: o, into: dir).output, "never overwrites")
    }

    // MARK: Video

    func makeTone(seconds: Double) throws -> String {
        let url = dir.appendingPathComponent("tone.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![ch][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 44_100) } }
        try file.write(from: buffer)
        return url.path
    }

    func testBuildsAnEventVideoThenAGif() async throws {
        let photos = [makeImage("p1.jpg", w: 1600, h: 900, hue: 0.1), makeImage("p2.jpg", w: 900, h: 1600, hue: 0.5),
                      makeImage("p3.jpg", w: 1200, h: 1200, hue: 0.9)]
        var items: [MediaItem] = []
        for p in photos { if let i = await MediaLibrary.item(at: p) { items.append(i) } }
        var o = VideoOptions()
        o.title = "Test Event"; o.subtitle = "3 photos"; o.photoSeconds = 1.5; o.musicPath = try makeTone(seconds: 3)
        let first = try await VideoBuilder.build(items: items, options: o, output: dir.appendingPathComponent("event.mp4")) { _ in }
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.duration, 2.5 + 3 * 1.5, accuracy: 0.1)
        let asset = AVURLAsset(url: first.url)
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(vTracks.count, 1)
        XCTAssertEqual(aTracks.count, 1, "music is mixed in")
        let size = try await vTracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))

        // The finished video works as a clip in a portrait video, and as a GIF source.
        guard let clip = await MediaLibrary.item(at: first.url.path) else { return XCTFail("clip not readable") }
        var p = VideoOptions(); p.shape = .portrait; p.maxClipSeconds = 3
        let second = try await VideoBuilder.build(items: [items[0], clip], options: p, output: dir.appendingPathComponent("reel.mov")) { _ in }
        XCTAssertEqual(second.duration, 3 + 3, accuracy: 0.2)
        let reelSize = try await AVURLAsset(url: second.url).loadTracks(withMediaType: .video)[0].load(.naturalSize)
        XCTAssertEqual(reelSize, CGSize(width: 1080, height: 1920))

        let gif = await MediaConverter.videoToGIF(first.url.path, seconds: 2, width: 320, into: dir)
        XCTAssertTrue(gif.ok, gif.message)
        let frames = CGImageSourceGetCount(CGImageSourceCreateWithURL(URL(fileURLWithPath: gif.output!) as CFURL, nil)!)
        XCTAssertGreaterThan(frames, 15)
    }
}
#endif
