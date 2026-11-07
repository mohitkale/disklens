#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CollageOptions: Sendable {
    public enum Layout: String, Sendable, CaseIterable, Identifiable {
        /// Equal cells, photos cropped to fill.
        case grid
        /// Rows of equal height where each photo keeps its shape (like a photo album). Nothing is cropped.
        case rows
        public var id: Self { self }
        public var label: String { self == .grid ? "Grid" : "Album rows" }
    }

    public enum Aspect: String, Sendable, CaseIterable, Identifiable {
        case square, portrait, story, landscape, wide
        public var id: Self { self }
        public var ratio: CGFloat {
            switch self {
            case .square: 1
            case .portrait: 4.0 / 5.0
            case .story: 9.0 / 16.0
            case .landscape: 4.0 / 3.0
            case .wide: 16.0 / 9.0
            }
        }
        public var label: String {
            switch self {
            case .square: "1:1"
            case .portrait: "4:5"
            case .story: "9:16"
            case .landscape: "4:3"
            case .wide: "16:9"
            }
        }
    }

    public var layout: Layout = .grid
    public var aspect: Aspect = .square
    /// Output width in pixels.
    public var width: Int = 3000
    /// Gap between photos as a fraction of the width.
    public var spacing: CGFloat = 0.012
    public var cornerRadius: CGFloat = 0.012
    public var background = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    public init() {}
}

public enum CollageBuilder {
    /// Where each photo goes, in a canvas of `size` (origin top-left).
    public static func frames(for imageSizes: [CGSize], options: CollageOptions, canvas size: CGSize) -> [CGRect] {
        guard !imageSizes.isEmpty else { return [] }
        let gap = options.spacing * size.width
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: gap, dy: gap)
        switch options.layout {
        case .grid:
            // Pick the column count whose cells are closest to the photos' typical shape.
            let n = imageSizes.count
            let typical = imageSizes.map { $0.width / max($0.height, 1) }.sorted()[n / 2]
            var best = (cols: 1, score: CGFloat.infinity)
            for cols in 1...n {
                let rows = Int(ceil(Double(n) / Double(cols)))
                let cellW = (inner.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
                let cellH = (inner.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
                let empty = CGFloat(rows * cols - n)
                let score = abs(log((cellW / cellH) / typical)) + empty * 0.35
                if score < best.score { best = (cols, score) }
            }
            let cols = best.cols, rows = Int(ceil(Double(n) / Double(cols)))
            let cellW = (inner.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
            let cellH = (inner.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            return (0..<n).map { i in
                let r = i / cols, c = i % cols
                // Centre a short last row.
                let inRow = r == rows - 1 ? n - r * cols : cols
                let offset = CGFloat(cols - inRow) * (cellW + gap) / 2
                return CGRect(x: inner.minX + offset + CGFloat(c) * (cellW + gap), y: inner.minY + CGFloat(r) * (cellH + gap), width: cellW, height: cellH)
            }
        case .rows:
            // Justified rows: split photos into rows, each scaled to the full width, then fit rows to the height.
            let ratios = imageSizes.map { $0.width / max($0.height, 1) }
            let targetRows = max(1, Int((ratios.reduce(0, +) * inner.height / inner.width).squareRoot().rounded()))
            var rows: [[Int]] = [[]]
            let perRow = ratios.reduce(0, +) / CGFloat(targetRows)
            var acc: CGFloat = 0
            for (i, r) in ratios.enumerated() {
                if acc > 0 && acc + r / 2 > perRow && rows.count < targetRows { rows.append([]); acc = 0 }
                rows[rows.count - 1].append(i)
                acc += r
            }
            let heights = rows.map { row in (inner.width - CGFloat(row.count - 1) * gap) / row.map { ratios[$0] }.reduce(0, +) }
            let scale = min(1, (inner.height - CGFloat(rows.count - 1) * gap) / heights.reduce(0, +))
            let totalH = heights.reduce(0, +) * scale + CGFloat(rows.count - 1) * gap
            var y = inner.minY + (inner.height - totalH) / 2
            var out = Array(repeating: CGRect.zero, count: ratios.count)
            for (row, h0) in zip(rows, heights) {
                let h = h0 * scale
                let rowW = row.map { ratios[$0] * h }.reduce(0, +) + CGFloat(row.count - 1) * gap
                var x = inner.minX + (inner.width - rowW) / 2
                for i in row {
                    out[i] = CGRect(x: x, y: y, width: ratios[i] * h, height: h)
                    x += ratios[i] * h + gap
                }
                y += h + gap
            }
            return out
        }
    }

    public static func render(_ images: [CGImage], options: CollageOptions) -> CGImage? {
        let size = CGSize(width: CGFloat(options.width), height: (CGFloat(options.width) / options.aspect.ratio).rounded())
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(options.background)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        let rects = frames(for: images.map { CGSize(width: $0.width, height: $0.height) }, options: options, canvas: size)
        let radius = options.cornerRadius * size.width
        for (image, top) in zip(images, rects) {
            // CoreGraphics' origin is bottom-left.
            let rect = CGRect(x: top.minX, y: size.height - top.maxY, width: top.width, height: top.height)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let fill = max(rect.width / iw, rect.height / ih)
            let draw = CGRect(x: rect.midX - iw * fill / 2, y: rect.midY - ih * fill / 2, width: iw * fill, height: ih * fill)
            ctx.draw(image, in: draw)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Saves as JPEG or PNG (no metadata: collages never carry location).
    public static func save(_ image: CGImage, to url: URL, quality: Double = 0.92) throws {
        let type = url.pathExtension.lowercased() == "png" ? UTType.png : .jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
#endif
