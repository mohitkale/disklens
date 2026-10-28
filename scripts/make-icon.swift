// Renders the app icon (a drive glyph over a pie-chart ring) into an .icns.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.16, green: 0.47, blue: 0.84, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.69, blue: 0.48, alpha: 1))!.draw(in: path, angle: -60)

    // Ring: used vs free.
    let center = NSPoint(x: 512 * s, y: 540 * s)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: 250 * s, startAngle: 90, endAngle: 90 - 0.65 * 360, clockwise: true)
    ring.lineWidth = 70 * s
    ring.lineCapStyle = .round
    NSColor.white.setStroke()
    ring.stroke()
    let rest = NSBezierPath()
    rest.appendArc(withCenter: center, radius: 250 * s, startAngle: 90 - 0.65 * 360 - 18, endAngle: 90 - 360 + 18, clockwise: true)
    rest.lineWidth = 70 * s
    rest.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.35).setStroke()
    rest.stroke()

    if let glyph = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 210 * s, weight: .semibold)) {
        let tinted = NSImage(size: glyph.size, flipped: false) { r in
            glyph.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let g = tinted.size
        tinted.draw(in: NSRect(x: center.x - g.width / 2, y: center.y - g.height / 2, width: g.width, height: g.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(CGFloat(px)).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "\(out)/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print("Wrote \(out)/AppIcon.icns")
