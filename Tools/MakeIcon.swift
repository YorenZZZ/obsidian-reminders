import AppKit
import CoreGraphics

// Generates the app icon (all iconset sizes) with Core Graphics.
// Usage: swift MakeIcon.swift <output-iconset-dir>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let canvas: CGFloat = 1024
let purpleTop    = CGColor(red: 0.62, green: 0.44, blue: 0.98, alpha: 1)   // #9E70FA
let purpleBottom = CGColor(red: 0.36, green: 0.16, blue: 0.78, alpha: 1)   // #5C29C7
let ink          = CGColor(red: 0.36, green: 0.16, blue: 0.78, alpha: 1)
let white        = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

func arrowHead(_ ctx: CGContext, at center: CGPoint, angle: CGFloat, size: CGFloat) {
    // Tangent pointing in the direction of increasing angle.
    let t = CGPoint(x: -sin(angle), y: cos(angle))
    let n = CGPoint(x: cos(angle), y: sin(angle))
    let p = CGPoint(x: center.x + cos(angle) * 0, y: center.y + sin(angle) * 0)

    let tip = CGPoint(x: p.x + t.x * size * 1.35, y: p.y + t.y * size * 1.35)
    let a = CGPoint(x: p.x + n.x * size * 1.25, y: p.y + n.y * size * 1.25)
    let b = CGPoint(x: p.x - n.x * size * 1.25, y: p.y - n.y * size * 1.25)

    ctx.move(to: tip)
    ctx.addLine(to: a)
    ctx.addLine(to: b)
    ctx.closePath()
    ctx.fillPath()
}

func draw(_ ctx: CGContext) {
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // ---- Background squircle -------------------------------------------------
    let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bgPath = CGPath(roundedRect: bg, cornerWidth: 184, cornerHeight: 184, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [purpleTop, purpleBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 200, y: 924),
        end: CGPoint(x: 860, y: 120),
        options: []
    )
    ctx.restoreGState()

    // ---- Checklist rows ------------------------------------------------------
    let rows: [(CGFloat, Bool)] = [(700, true), (560, false), (420, false)]
    let boxSize: CGFloat = 62
    let barHeight: CGFloat = 38

    for (cy, checked) in rows {
        // Checkbox
        let box = CGRect(x: 196, y: cy - boxSize / 2, width: boxSize, height: boxSize)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 17, cornerHeight: 17, transform: nil))
        ctx.setStrokeColor(white)
        ctx.setLineWidth(15)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        if checked {
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: 212, y: cy + 0))
            ctx.addLine(to: CGPoint(x: 225, y: cy - 15))
            ctx.addLine(to: CGPoint(x: 246, y: cy + 17))
            ctx.setLineWidth(17)
            ctx.strokePath()
        }

        // Text bar
        let bar = CGRect(x: 296, y: cy - barHeight / 2, width: 470, height: barHeight)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
        ctx.setFillColor(white)
        ctx.fillPath()
    }

    // ---- Sync badge ----------------------------------------------------------
    let bc = CGPoint(x: 782, y: 250)
    let br: CGFloat = 126
    ctx.setFillColor(white)
    ctx.fillEllipse(in: CGRect(x: bc.x - br, y: bc.y - br, width: br * 2, height: br * 2))

    let ringR: CGFloat = 60
    let ringW: CGFloat = 26
    ctx.setStrokeColor(ink)
    ctx.setFillColor(ink)
    ctx.setLineWidth(ringW)
    ctx.setLineCap(.butt)

    let arcs: [(CGFloat, CGFloat)] = [
        (42 * .pi / 180, 158 * .pi / 180),
        (222 * .pi / 180, 338 * .pi / 180),
    ]
    for (start, end) in arcs {
        ctx.addArc(center: bc, radius: ringR, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()

        let p = CGPoint(x: bc.x + cos(end) * ringR, y: bc.y + sin(end) * ringR)
        arrowHead(ctx, at: p, angle: end, size: ringW)
    }
}

func render(size: Int) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(ctx)
    return ctx.makeImage()
}

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in outputs {
    guard let image = render(size: size) else {
        FileHandle.standardError.write("render failed at \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("png encode failed at \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

print("wrote \(outputs.count) images to \(outDir)")
