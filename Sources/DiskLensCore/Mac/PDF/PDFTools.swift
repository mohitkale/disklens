#if os(macOS)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Quartz
import Vision

/// What a PDF is made of, to pick the right way to shrink it.
public struct PDFInfo: Sendable {
    public let pages: Int
    public let bytes: Int64
    /// Characters of text PDFKit can extract (including invisible recognised text in scans).
    public let textCharacters: Int
}

public struct PDFResult: Sendable {
    public let source: String
    public let output: String?
    public let originalBytes: Int64
    public let bytes: Int64
    /// How it was done, in plain words ("images downsampled", "pages re-encoded, text recognised").
    public let method: String
    public let message: String
    public var ok: Bool { output != nil }
    public var savedFraction: Double { originalBytes > 0 && ok ? 1 - Double(bytes) / Double(originalBytes) : 0 }

    public init(source: String, output: String?, originalBytes: Int64, bytes: Int64, method: String, message: String) {
        self.source = source
        self.output = output
        self.originalBytes = originalBytes
        self.bytes = bytes
        self.method = method
        self.message = message
    }
}

public enum PDFTools {
    /// Image resolution and JPEG quality for each level.
    public enum Level: String, CaseIterable, Identifiable, Sendable {
        case high, medium, small
        public var id: Self { self }
        public var label: String {
            switch self {
            case .high: "High quality"
            case .medium: "Balanced"
            case .small: "Smallest"
            }
        }
        public var detail: String {
            switch self {
            case .high: "150 dpi images: sharp on screen and in print"
            case .medium: "110 dpi images: sharp on screen"
            case .small: "80 dpi images: readable, for email and uploads"
            }
        }
        var dpi: Double { switch self { case .high: 150; case .medium: 110; case .small: 80 } }
        var quality: Double { switch self { case .high: 0.72; case .medium: 0.6; case .small: 0.48 } }
    }

    public static func info(_ path: String) -> PDFInfo? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        return PDFInfo(pages: doc.pageCount, bytes: fileSize(path), textCharacters: doc.string?.count ?? 0)
    }

    // MARK: Compress

    /// Writes a smaller copy, or explains why it can't be smaller. The copy is kept only if it has every page,
    /// keeps its text (or, for scans, gets it back through text recognition) and is at least 10% smaller.
    /// With `targetBytes`, levels are tried from best quality down until one fits.
    public static func compress(_ path: String, level: Level, targetBytes: Int64? = nil, into folder: URL? = nil,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> PDFResult {
        let src = URL(fileURLWithPath: path)
        guard let doc = PDFDocument(url: src), doc.pageCount > 0 else {
            return fail(path, "Not a readable PDF")
        }
        if doc.isEncrypted && doc.isLocked { return fail(path, "This PDF is password-protected. Unlock it first.") }
        let original = fileSize(path)
        let text = doc.string?.count ?? 0
        let levels: [Level] = targetBytes == nil ? [level] : Level.allCases.drop { $0 != level }.map { $0 }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("disklens-pdf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var best: (url: URL, bytes: Int64, method: String)?
        var scanned = false
        for (i, lv) in levels.enumerated() {
            let base = Double(i) / Double(levels.count), span = 1 / Double(levels.count)
            // 1. Images downsampled, everything else (text, links, outline) kept.
            let vector = work.appendingPathComponent("v-\(lv.rawValue).pdf")
            if writeFiltered(doc, to: vector, dpi: lv.dpi, quality: lv.quality), let out = PDFDocument(url: vector),
               out.pageCount == doc.pageCount {
                let kept = out.string?.count ?? 0
                if kept >= Int(Double(text) * 0.95) {
                    consider(vector, "images downsampled, text and links kept")
                } else if text > 0 && kept < text / 2 {
                    scanned = true   // the text was an invisible layer over scanned pages
                }
            }
            progress(base + span * 0.3)
            // 2. Scanned or picture-only pages: re-encode each page and recognise its text again.
            if scanned || text < 40 * doc.pageCount {
                let raster = work.appendingPathComponent("r-\(lv.rawValue).pdf")
                if await rasterize(doc, to: raster, dpi: lv.dpi, quality: lv.quality, recognizeText: true,
                                   progress: { progress(base + span * (0.3 + 0.7 * $0)) }),
                   let out = PDFDocument(url: raster), out.pageCount == doc.pageCount {
                    let recognised = out.string?.count ?? 0
                    if text == 0 || recognised >= text / 2 {
                        consider(raster, "pages re-encoded, text recognised so it stays searchable")
                    }
                }
            }
            progress(base + span)
            if let target = targetBytes, let b = best, b.bytes <= target { break }
        }

        func consider(_ url: URL, _ method: String) {
            let b = fileSize(url.path)
            if best == nil || b < best!.bytes { best = (url, b, method) }
        }

        guard let best, Double(best.bytes) <= Double(original) * 0.9 else {
            let why = text > 300 * doc.pageCount
                ? "This PDF is mostly text and already compact, so it can't get meaningfully smaller."
                : "Couldn't make this PDF meaningfully smaller without losing quality."
            return PDFResult(source: path, output: nil, originalBytes: original, bytes: original, method: "", message: why)
        }
        let dest = MediaConverter.uniqueURL((folder ?? src.deletingLastPathComponent())
            .appendingPathComponent(src.deletingPathExtension().lastPathComponent + " (compressed).pdf"))
        do { try FileManager.default.moveItem(at: best.url, to: dest) } catch { return fail(path, error.localizedDescription) }
        var message = "\(ByteFormat.string(original)) → \(ByteFormat.string(best.bytes))"
        if let target = targetBytes, best.bytes > target {
            message += ". The smallest it can get without becoming unreadable is above your target."
        }
        return PDFResult(source: path, output: dest.path, originalBytes: original, bytes: best.bytes, method: best.method, message: message)
    }

    /// Re-saves through a Quartz filter that downsamples and JPEG-compresses images only.
    static func writeFiltered(_ doc: PDFDocument, to url: URL, dpi: Double, quality: Double) -> Bool {
        let settings: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true], "FilterType": 1, "Name": "DiskLens",
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": quality, "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": Int(dpi), "ImageScaleInterpolate": true,
                                       "ImageSizeMax": Int(dpi * 17), "ImageSizeMin": 0]]]]]
        let filterURL = url.deletingPathExtension().appendingPathExtension("qfilter")
        guard (settings as NSDictionary).write(to: filterURL, atomically: true), let filter = QuartzFilter(url: filterURL) else { return false }
        return doc.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
    }

    // MARK: Pages as images (with a searchable text layer)

    /// Renders every page to a JPEG at `dpi` and, if asked, lays invisible recognised text over it so the
    /// PDF stays searchable and copyable.
    static func rasterize(_ doc: PDFDocument, to url: URL, dpi: Double, quality: Double, recognizeText: Bool,
                          redact: [Int: [CGRect]] = [:], pages only: Set<Int>? = nil,
                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Bool {
        var box = CGRect.zero
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { return false }
            var media = page.bounds(for: .mediaBox)
            ctx.beginPage(mediaBox: &media)
            if let image = render(page, dpi: dpi, blackout: redact[i] ?? []), let jpeg = jpeg(image, quality: quality) {
                ctx.draw(jpeg, in: media)
                if recognizeText { drawInvisibleText(recognize(image), in: media, ctx: ctx) }
            }
            ctx.endPage()
            progress(Double(i + 1) / Double(doc.pageCount))
            await Task.yield()
        }
        ctx.closePDF()
        return true
    }

    /// A page drawn as PDFKit shows it (annotations included), with optional black boxes painted in.
    public static func render(_ page: PDFPage, dpi: Double, blackout: [CGRect] = []) -> CGImage? {
        let media = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let w = Int((rotated ? media.height : media.width) * dpi / 72), h = Int((rotated ? media.width : media.height) * dpi / 72)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: dpi / 72, y: dpi / 72)
        page.draw(with: .mediaBox, to: ctx)
        if !blackout.isEmpty {
            // PDFKit draws the page with its own transform; boxes are in page space, so map them the same way.
            ctx.concatenate(page.transform(for: .mediaBox))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for r in blackout { ctx.fill(r.insetBy(dx: -1.5, dy: -1.5)) }
        }
        return ctx.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func recognize(_ image: CGImage) -> [VNRecognizedTextObservation] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return req.results ?? []
    }

    /// Invisible text placed over each recognised line, stretched to its width, so search and selection line up.
    static func drawInvisibleText(_ lines: [VNRecognizedTextObservation], in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            guard let text = line.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let b = line.boundingBox
            let box = CGRect(x: rect.minX + b.minX * rect.width, y: rect.minY + b.minY * rect.height,
                             width: b.width * rect.width, height: b.height * rect.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, box.height * 0.85), nil)
            let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard natural > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: box.minX, y: box.minY + box.height * 0.15)
            ctx.scaleBy(x: box.width / natural, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: Make searchable

    /// Adds recognised text to pages that have none (scans), keeping pages that already have text exactly as they are.
    public static func makeSearchable(_ path: String, into folder: URL? = nil,
                                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> PDFResult {
        let src = URL(fileURLWithPath: path)
        guard let doc = PDFDocument(url: src), doc.pageCount > 0 else { return fail(path, "Not a readable PDF") }
        if doc.isLocked { return fail(path, "This PDF is password-protected. Unlock it first.") }
        let needs = (0..<doc.pageCount).filter { (doc.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) < 20 }
        guard !needs.isEmpty else {
            return PDFResult(source: path, output: nil, originalBytes: fileSize(path), bytes: fileSize(path), method: "",
                             message: "Every page already has text you can search and copy.")
        }
        var recognised = 0
        for (n, i) in needs.enumerated() {
            guard let page = doc.page(at: i), let replacement = await searchablePage(page) else { continue }
            doc.removePage(at: i)
            doc.insert(replacement, at: i)
            recognised += 1
            progress(Double(n + 1) / Double(needs.count))
        }
        let dest = MediaConverter.uniqueURL((folder ?? src.deletingLastPathComponent())
            .appendingPathComponent(src.deletingPathExtension().lastPathComponent + " (searchable).pdf"))
        guard doc.write(to: dest) else { return fail(path, "Couldn't save the searchable copy") }
        return PDFResult(source: path, output: dest.path, originalBytes: fileSize(path), bytes: fileSize(dest.path),
                         method: "text recognised on \(recognised) of \(doc.pageCount) pages",
                         message: "\(recognised) page\(recognised == 1 ? "" : "s") made searchable")
    }

    /// The original page drawn as is (vector), with invisible recognised text over it.
    static func searchablePage(_ page: PDFPage) async -> PDFPage? {
        guard let image = render(page, dpi: 200) else { return nil }
        let lines = recognize(image)
        let media = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        var box = media
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPage(mediaBox: &box)
        page.draw(with: .mediaBox, to: ctx)
        drawInvisibleText(lines, in: media, ctx: ctx)
        ctx.endPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    // MARK: Redact

    public struct RedactResult: Sendable {
        public let output: String?
        public let matches: Int
        public let pages: Int
        /// True once the saved copy was searched again and none of the terms were found.
        public let verified: Bool
        public let message: String
    }

    /// Really removes the terms: each page that contains one is replaced by an image of the page with black boxes
    /// painted in (the text underneath is gone, not hidden), plus recognised text for everything else on it.
    /// Pages without matches are kept as they are. Author and title are cleared too.
    public static func redact(_ path: String, terms: [String], into folder: URL? = nil,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> RedactResult {
        let src = URL(fileURLWithPath: path)
        let terms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 }
        guard let doc = PDFDocument(url: src), !terms.isEmpty else {
            return RedactResult(output: nil, matches: 0, pages: 0, verified: false, message: terms.isEmpty ? "Add at least one word to remove" : "Not a readable PDF")
        }
        if doc.isLocked { return RedactResult(output: nil, matches: 0, pages: 0, verified: false, message: "This PDF is password-protected. Unlock it first.") }
        var boxes: [Int: [CGRect]] = [:]
        var matches = 0
        for term in terms {
            for sel in doc.findString(term, withOptions: [.caseInsensitive]) {
                for page in sel.pages {
                    let i = doc.index(for: page)
                    // One box per line, so a match that wraps doesn't black out the space between.
                    for line in sel.selectionsByLine() where line.pages.contains(page) {
                        boxes[i, default: []].append(line.bounds(for: page))
                    }
                    matches += 1
                }
            }
        }
        guard matches > 0 else {
            return RedactResult(output: nil, matches: 0, pages: 0, verified: true, message: "None of these words appear in the PDF's text.")
        }
        for (n, (i, rects)) in boxes.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let page = doc.page(at: i), let image = render(page, dpi: 200, blackout: rects),
                  let replacement = imagePage(image, media: page.bounds(for: .mediaBox), recognizeText: true) else { continue }
            doc.removePage(at: i)
            doc.insert(replacement, at: i)
            progress(Double(n + 1) / Double(boxes.count))
        }
        var attrs = doc.documentAttributes ?? [:]
        for key in [PDFDocumentAttribute.authorAttribute, .creatorAttribute, .producerAttribute, .titleAttribute, .subjectAttribute, .keywordsAttribute] {
            attrs[key] = nil
        }
        doc.documentAttributes = attrs
        let dest = MediaConverter.uniqueURL((folder ?? src.deletingLastPathComponent())
            .appendingPathComponent(src.deletingPathExtension().lastPathComponent + " (redacted).pdf"))
        guard doc.write(to: dest), let check = PDFDocument(url: dest) else {
            return RedactResult(output: nil, matches: matches, pages: boxes.count, verified: false, message: "Couldn't save the redacted copy")
        }
        // Verify: none of the terms may be found in the saved copy (including the recognised text).
        let leaked = terms.contains { !check.findString($0, withOptions: [.caseInsensitive]).isEmpty }
        if leaked {
            try? FileManager.default.removeItem(at: dest)
            return RedactResult(output: nil, matches: matches, pages: boxes.count, verified: false,
                                message: "A term could still be found in the result, so nothing was saved.")
        }
        return RedactResult(output: dest.path, matches: matches, pages: boxes.count, verified: true,
                            message: "\(matches) match\(matches == 1 ? "" : "es") removed on \(boxes.count) page\(boxes.count == 1 ? "" : "s"), checked")
    }

    /// A one-page PDF of an image (lossless, so redaction boxes stay crisp), with recognised text minus anything blacked out.
    static func imagePage(_ image: CGImage, media: CGRect, recognizeText: Bool) -> PDFPage? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: media.size)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil),
              let jpg = jpeg(image, quality: 0.85) else { return nil }
        ctx.beginPage(mediaBox: &box)
        ctx.draw(jpg, in: box)
        if recognizeText { drawInvisibleText(recognize(image), in: box, ctx: ctx) }
        ctx.endPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// Emails, phone numbers and card numbers in the PDF's text, as suggested terms to redact.
    public static func suggestedTerms(_ path: String) -> [String] {
        guard let text = PDFDocument(url: URL(fileURLWithPath: path))?.string else { return [] }
        var out: [String] = []
        out += SensitiveScanner.matches(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: text)
        out += SensitiveScanner.matches(#"(?<![\d+])\+?\d[\d \-]{8,14}\d(?!\d)"#, in: text).filter { m in
            let digits = m.filter(\.isNumber)
            return (10...13).contains(digits.count) && !SensitiveScanner.luhn(digits)
        }
        out += SensitiveScanner.matches(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#, in: text).filter { SensitiveScanner.luhn($0.filter(\.isNumber)) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }.prefix(40).map { $0 }
    }

    // MARK: Merge & split

    public static func merge(_ paths: [String], to url: URL) throws -> URL {
        let result = PDFDocument()
        for path in paths {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { throw PDFToolError.unreadable((path as NSString).lastPathComponent) }
            if doc.isLocked { throw PDFToolError.locked((path as NSString).lastPathComponent) }
            for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { result.insert(p, at: result.pageCount) } }
        }
        let dest = MediaConverter.uniqueURL(url)
        guard result.write(to: dest) else { throw PDFToolError.couldNotSave }
        return dest
    }

    /// Splits into one file per range (1-based, inclusive). Pass nil for one file per page.
    public static func split(_ path: String, ranges: [ClosedRange<Int>]? = nil, into folder: URL? = nil) throws -> [URL] {
        let src = URL(fileURLWithPath: path)
        guard let doc = PDFDocument(url: src) else { throw PDFToolError.unreadable(src.lastPathComponent) }
        if doc.isLocked { throw PDFToolError.locked(src.lastPathComponent) }
        let parts = ranges ?? (1...max(1, doc.pageCount)).map { $0...$0 }
        let dir = folder ?? src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        var out: [URL] = []
        for r in parts {
            let lo = max(1, r.lowerBound), hi = min(doc.pageCount, r.upperBound)
            guard lo <= hi else { continue }
            let part = PDFDocument()
            for i in (lo - 1)..<hi { if let p = doc.page(at: i)?.copy() as? PDFPage { part.insert(p, at: part.pageCount) } }
            let name = lo == hi ? "\(stem) (page \(lo)).pdf" : "\(stem) (pages \(lo)-\(hi)).pdf"
            let dest = MediaConverter.uniqueURL(dir.appendingPathComponent(name))
            guard part.write(to: dest) else { throw PDFToolError.couldNotSave }
            out.append(dest)
        }
        return out
    }

    /// "1-3, 5, 8-10" → [1...3, 5...5, 8...10]
    public static func parseRanges(_ s: String) -> [ClosedRange<Int>]? {
        var out: [ClosedRange<Int>] = []
        for part in s.split(separator: ",") {
            let bits = part.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let a = Int(bits.first ?? ""), a > 0 else { return nil }
            let b = bits.count > 1 ? Int(bits[1]) : a
            guard let b, b >= a, bits.count <= 2 else { return nil }
            out.append(a...b)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Helpers

    static func fail(_ path: String, _ message: String) -> PDFResult {
        PDFResult(source: path, output: nil, originalBytes: fileSize(path), bytes: 0, method: "", message: message)
    }

    static func fileSize(_ path: String) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0)
    }
}

public enum PDFToolError: LocalizedError {
    case unreadable(String), locked(String), couldNotSave
    public var errorDescription: String? {
        switch self {
        case let .unreadable(n): "\(n) isn't a readable PDF"
        case let .locked(n): "\(n) is password-protected. Unlock it first."
        case .couldNotSave: "Couldn't save the PDF"
        }
    }
}
#endif
