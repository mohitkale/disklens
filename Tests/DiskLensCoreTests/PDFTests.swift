#if os(macOS)
import CoreText
@testable import DiskLensCore
import PDFKit
import XCTest

/// A two-page PDF with real (selectable) text, made on the fly: no personal data.
enum PDFFixture {
    static func make(_ url: URL, lines: [[String]]) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in lines {
            ctx.beginPage(mediaBox: &box)
            var y: CGFloat = 720
            for text in page {
                let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                ctx.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(line, ctx)
                y -= 32
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }
}

final class PDFToolTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdftests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRedactionRemovesTextForReal() async throws {
        let src = dir.appendingPathComponent("letter.pdf")
        PDFFixture.make(src, lines: [["Dear team,", "Contact alice.tester@example.com for access.", "Card 4242 4242 4242 4242 on file."],
                                     ["Page two has nothing secret.", "Just a note."]])
        let suggested = PDFTools.suggestedTerms(src.path)
        XCTAssertTrue(suggested.contains("alice.tester@example.com"), "\(suggested)")
        XCTAssertTrue(suggested.contains { $0.filter(\.isNumber) == "4242424242424242" }, "\(suggested)")

        let r = await PDFTools.redact(src.path, terms: suggested, into: dir)
        XCTAssertTrue(r.verified, r.message)
        XCTAssertEqual(r.pages, 1)
        let out = try XCTUnwrap(r.output)
        let doc = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: out)))
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertTrue(doc.findString("alice.tester", withOptions: .caseInsensitive).isEmpty)
        XCTAssertTrue(doc.findString("4242", withOptions: .caseInsensitive).isEmpty)
        // Not hidden but gone: the raw bytes don't contain it either.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
        XCTAssertNil(bytes.range(of: Data("alice.tester".utf8)))
        // Untouched page keeps its real text; the redacted page keeps the rest of its text via recognition.
        XCTAssertTrue(doc.page(at: 1)!.string!.contains("Page two has nothing secret"))
        XCTAssertTrue(doc.page(at: 0)!.string!.lowercased().contains("dear team"), doc.page(at: 0)!.string ?? "")
    }

    func testMergeSplitAndRanges() throws {
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        PDFFixture.make(a, lines: [["A1"], ["A2"]])
        PDFFixture.make(b, lines: [["B1"], ["B2"], ["B3"]])
        let merged = try PDFTools.merge([a.path, b.path], to: dir.appendingPathComponent("Merged.pdf"))
        let m = try XCTUnwrap(PDFDocument(url: merged))
        XCTAssertEqual(m.pageCount, 5)
        XCTAssertEqual(m.page(at: 2)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "B1")
        XCTAssertEqual(PDFTools.parseRanges("1-2, 4"), [1...2, 4...4])
        XCTAssertNil(PDFTools.parseRanges("3-1"))
        XCTAssertNil(PDFTools.parseRanges("x"))
        let parts = try PDFTools.split(merged.path, ranges: [1...2, 4...5], into: dir)
        XCTAssertEqual(parts.map { PDFDocument(url: $0)?.pageCount }, [2, 2])
        XCTAssertEqual(try PDFTools.split(a.path, into: dir).count, 2)
    }

    func testTextPDFIsReportedAsAlreadyCompact() async throws {
        let src = dir.appendingPathComponent("text.pdf")
        PDFFixture.make(src, lines: Array(repeating: (1...20).map { "Line \($0) of plain text that is already small." }, count: 3))
        let r = await PDFTools.compress(src.path, level: .medium, into: dir)
        XCTAssertNil(r.output, "a text-only PDF can't shrink by 10%, so nothing is saved")
        XCTAssertFalse(r.message.isEmpty)
    }
}

/// Real PDFs, off by default: DISKLENS_VERIFY14 points at a sandbox of copies.
final class Verify14Tests: XCTestCase {
    var sandbox: URL!
    override func setUpWithError() throws {
        let d = ProcessInfo.processInfo.environment["DISKLENS_VERIFY14"]
        try XCTSkipUnless(d != nil)
        sandbox = URL(fileURLWithPath: d!)
    }
    func log(_ s: String) { print("VERIFY14 " + s) }
    var copies: [String] { (try? FileManager.default.contentsOfDirectory(atPath: sandbox.appendingPathComponent("copies").path).filter { $0.hasSuffix(".pdf") }.sorted()) ?? [] }

    func testCompressRealPDFs() async throws {
        let out = sandbox.appendingPathComponent("out/pdf")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in copies {
            let path = sandbox.appendingPathComponent("copies/" + name).path
            let info = try XCTUnwrap(PDFTools.info(path))
            for level in [PDFTools.Level.medium] {
                let t = Date()
                let r = await PDFTools.compress(path, level: level, into: out)
                let after = r.output.flatMap { PDFTools.info($0) }
                log("\(name.prefix(10)) \(level): \(r.message) | \(r.method) | pages \(info.pages)->\(after?.pages ?? -1) text \(info.textCharacters)->\(after?.textCharacters ?? -1) | \(String(format: "%.0fs", Date().timeIntervalSince(t)))")
                if let after { XCTAssertEqual(after.pages, info.pages) }
            }
        }
    }

    func testTargetSizeAndSearchable() async throws {
        let out = sandbox.appendingPathComponent("out/pdf2")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let big = copies.first(where: { $0.hasPrefix("land") }), let deck = copies.first(where: { $0.hasPrefix("QuantX") }) else { return }
        let r = await PDFTools.compress(sandbox.appendingPathComponent("copies/" + big).path, level: .high, targetBytes: 2_000_000, into: out)
        log("target 2 MB: \(r.message) | \(r.method)")
        XCTAssertLessThanOrEqual(r.bytes, 2_000_000)
        let s = await PDFTools.makeSearchable(sandbox.appendingPathComponent("copies/" + deck).path, into: out)
        log("searchable deck: \(s.message), text chars now \(s.output.flatMap { PDFTools.info($0)?.textCharacters } ?? -1), \(ByteFormat.string(s.originalBytes)) -> \(ByteFormat.string(s.bytes))")
    }
}
#endif
