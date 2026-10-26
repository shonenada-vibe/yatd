// Draws the YATD app icon into YATD/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift [preview.png]
//
// Concept: the app itself. Three frosted glass pills (today's top 3) float over a deep
// blue-violet tile; the first is solid and checked off, the others are glass.
import AppKit

let out = URL(fileURLWithPath: "YATD/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint, locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// Superellipse-ish rounded rect (continuous corners), like macOS icon tiles.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k: CGFloat = 1.12 // stretch the corner curve for a continuous look
    let c = min(radius * k, min(r.width, r.height) / 2)
    p.move(to: CGPoint(x: r.minX + c, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + c), control1: CGPoint(x: r.maxX - c * 0.33, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + c * 0.33))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
    p.addCurve(to: CGPoint(x: r.maxX - c, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - c * 0.33), control2: CGPoint(x: r.maxX - c * 0.33, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control1: CGPoint(x: r.minX + c * 0.33, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - c * 0.33))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
    p.addCurve(to: CGPoint(x: r.minX + c, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + c * 0.33), control2: CGPoint(x: r.minX + c * 0.33, y: r.minY))
    p.closeSubpath()
    return p
}

func capsule(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
}

func draw(size: CGFloat) -> Data {
    let px = Int(size)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = size / 1024
    ctx.scaleBy(x: s, y: s) // draw in a 1024 space; y grows upwards

    // MARK: Tile — 824pt, centred, with the standard drop shadow.
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(tileRect, radius: 185)
    ctx.saveGState()
    // Shadow offset/blur are in device pixels and ignore the CTM, so scale them by hand.
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: color(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x2B2F8F))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    // Deep blue → violet, lit from the top.
    linear(ctx, [color(0x3D8BFF), color(0x4F46E5), color(0x7C3AED)],
           from: CGPoint(x: 220, y: 924), to: CGPoint(x: 820, y: 100), locations: [0, 0.55, 1])
    // Colour blooms behind the glass so it has something to refract.
    radial(ctx, [color(0x22D3EE, 0.55), color(0x22D3EE, 0)], center: CGPoint(x: 250, y: 760), radius: 420)
    radial(ctx, [color(0xF472B6, 0.45), color(0xF472B6, 0)], center: CGPoint(x: 830, y: 230), radius: 430)
    // Top sheen and inner rim light.
    linear(ctx, [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 640))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle(tileRect.insetBy(dx: 3, dy: 3), radius: 182))
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.setLineWidth(5)
    ctx.strokePath()
    ctx.restoreGState()

    // MARK: Three glass pills, back to front (bottom to top on screen).
    let pillW: CGFloat = 600, pillH: CGFloat = 150, x: CGFloat = 212
    let rows: [(y: CGFloat, front: Bool, bar: CGFloat)] = [
        (y: 222, front: false, bar: 250),
        (y: 412, front: false, bar: 320),
        (y: 602, front: true, bar: 300),
    ]
    for row in rows {
        let r = CGRect(x: x, y: row.y, width: pillW, height: pillH)
        let pill = capsule(r)

        // Soft shadow under each pill.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 34 * s, color: color(0x1E1B4B, 0.45))
        ctx.addPath(pill)
        ctx.setFillColor(color(0xFFFFFF, row.front ? 0.96 : 0.16))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(pill)
        ctx.clip()
        if row.front {
            linear(ctx, [color(0xFFFFFF), color(0xE8ECFF)], from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY))
        } else {
            // Frosted glass: brighter top edge, clearer middle, light caustic at the bottom.
            linear(ctx, [color(0xFFFFFF, 0.38), color(0xFFFFFF, 0.10), color(0xFFFFFF, 0.06), color(0xFFFFFF, 0.20)],
                   from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY), locations: [0, 0.45, 0.75, 1])
        }
        // Specular highlight along the top-left.
        radial(ctx, [color(0xFFFFFF, row.front ? 0.0 : 0.35), color(0xFFFFFF, 0)],
               center: CGPoint(x: r.minX + 110, y: r.maxY - 18), radius: 170)
        ctx.restoreGState()

        // Rim: bright top edge fading to a faint bottom edge, like light catching glass.
        ctx.saveGState()
        ctx.addPath(capsule(r.insetBy(dx: 2, dy: 2)))
        ctx.setLineWidth(4)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        linear(ctx, [color(0xFFFFFF, row.front ? 1 : 0.85), color(0xFFFFFF, row.front ? 0.6 : 0.15)],
               from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY))
        ctx.restoreGState()

        // Check circle + text bar.
        let c = CGPoint(x: r.minX + 82, y: r.midY)
        let radius: CGFloat = 40
        if row.front {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            ctx.clip()
            linear(ctx, [color(0x60A5FA), color(0x4F46E5)], from: CGPoint(x: c.x, y: c.y + radius), to: CGPoint(x: c.x, y: c.y - radius))
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setStrokeColor(color(0xFFFFFF))
            ctx.setLineWidth(13)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: c.x - 18, y: c.y + 1))
            ctx.addLine(to: CGPoint(x: c.x - 4, y: c.y - 14))
            ctx.addLine(to: CGPoint(x: c.x + 20, y: c.y + 16))
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            ctx.saveGState()
            ctx.setStrokeColor(color(0xFFFFFF, 0.92))
            ctx.setLineWidth(10)
            ctx.strokeEllipse(in: CGRect(x: c.x - radius + 5, y: c.y - radius + 5, width: radius * 2 - 10, height: radius * 2 - 10))
            ctx.restoreGState()
        }
        let bar = CGRect(x: r.minX + 156, y: r.midY - 15, width: row.bar, height: 30)
        ctx.addPath(capsule(bar))
        ctx.setFillColor(row.front ? color(0x4F46E5, 0.30) : color(0xFFFFFF, 0.85))
        ctx.fillPath()
    }

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 1 {
    // Preview: the 1024 icon plus small sizes side by side, on light and dark backgrounds.
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    try! draw(size: 1024).write(to: preview)
    print("Wrote preview \(preview.path)")
    exit(0)
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
