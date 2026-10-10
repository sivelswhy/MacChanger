// Draws the app icon and writes icon/AppIcon.icns.
// Run: swift icon/make-icon.swift
import AppKit

func draw(_ ctx: CGContext) {
    let s: CGFloat = 1024
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Gradient background
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let colors = [CGColor(red: 0.20, green: 0.84, blue: 0.86, alpha: 1),
                  CGColor(red: 0.18, green: 0.36, blue: 0.95, alpha: 1),
                  CGColor(red: 0.33, green: 0.18, blue: 0.78, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    ctx.restoreGState()

    let white = CGColor(gray: 1, alpha: 1)
    ctx.setLineCap(.round)

    // Rotation ring: two arcs with arrowheads, turning clockwise
    let c = CGPoint(x: s / 2, y: s / 2), r: CGFloat = 300
    ctx.setStrokeColor(white); ctx.setFillColor(white)
    ctx.setLineWidth(40)
    for (from, to) in [(165.0, 30.0), (345.0, 210.0)] {
        let a0 = CGFloat(from) * .pi / 180, a1 = CGFloat(to) * .pi / 180
        ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
        ctx.strokePath()
        // Arrowhead at the end of the arc, pointing along the clockwise tangent
        let tip = CGPoint(x: c.x + r * cos(a1), y: c.y + r * sin(a1))
        let dir = CGPoint(x: sin(a1), y: -cos(a1))
        let nrm = CGPoint(x: cos(a1), y: sin(a1))
        let len: CGFloat = 84, half: CGFloat = 56
        let base = CGPoint(x: tip.x - dir.x * len * 0.35, y: tip.y - dir.y * len * 0.35)
        ctx.move(to: CGPoint(x: tip.x + dir.x * len * 0.65, y: tip.y + dir.y * len * 0.65))
        ctx.addLine(to: CGPoint(x: base.x + nrm.x * half, y: base.y + nrm.y * half))
        ctx.addLine(to: CGPoint(x: base.x - nrm.x * half, y: base.y - nrm.y * half))
        ctx.closePath(); ctx.fillPath()
    }

    // Wi-Fi symbol
    let w = CGPoint(x: s / 2, y: 410)
    ctx.setStrokeColor(white); ctx.setFillColor(white)
    ctx.setLineWidth(50)
    for radius in [95.0, 175.0, 255.0] {
        ctx.addArc(center: w, radius: CGFloat(radius), startAngle: .pi / 4, endAngle: 3 * .pi / 4, clockwise: false)
        ctx.strokePath()
    }
    ctx.fillEllipse(in: CGRect(x: w.x - 36, y: w.y - 36, width: 72, height: 72))
}

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        draw(ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("OK -> icon/AppIcon.icns")
