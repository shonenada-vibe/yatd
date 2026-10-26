// Draws the YATD app icon into YATD/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "YATD/Assets.xcassets/AppIcon.appiconset")

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824pt tile centred in 1024 with ~185pt corner radius.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.47, blue: 0.98, alpha: 1),
                        NSColor(red: 0.36, green: 0.30, blue: 0.93, alpha: 1)])!
        .draw(in: path, angle: -90)

    // Three task rows: two checked, one open.
    for (i, checked) in [true, true, false].enumerated() {
        let y = (640 - CGFloat(i) * 190) * s
        let circle = NSRect(x: 230 * s, y: y, width: 120 * s, height: 120 * s)
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = 22 * s
        NSColor.white.setStroke()
        if checked {
            NSColor.white.setFill()
            ring.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: 258 * s, y: y + 60 * s))
            tick.line(to: NSPoint(x: 282 * s, y: y + 36 * s))
            tick.line(to: NSPoint(x: 324 * s, y: y + 86 * s))
            tick.lineWidth = 20 * s
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor(red: 0.27, green: 0.40, blue: 0.96, alpha: 1).setStroke()
            tick.stroke()
        } else {
            ring.stroke()
        }
        let bar = NSBezierPath(roundedRect: NSRect(x: 400 * s, y: y + 38 * s, width: (i == 2 ? 300 : 390) * s, height: 44 * s),
                               xRadius: 22 * s, yRadius: 22 * s)
        NSColor.white.withAlphaComponent(checked ? 0.6 : 1).setFill()
        bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! draw(size: CGFloat(points * scale)).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(out.path)")
