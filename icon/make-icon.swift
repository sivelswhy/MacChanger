// Draws the app icon and writes icon/AppIcon.icns.
// Run: swift icon/make-icon.swift
import AppKit

// Point d'une courbe de Catmull-Rom passant par p1 et p2.
func catmull(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    let t2 = t * t, t3 = t2 * t
    func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
        0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
    }
    return CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y))
}

// Tube lisse : des disques posés le long d'une courbe, dont le rayon varie d'un point à l'autre.
func tube(_ ctx: CGContext, _ pts: [(CGFloat, CGFloat, CGFloat)]) {
    let p = pts.map { CGPoint(x: $0.0, y: $0.1) }
    for i in 0..<(p.count - 1) {
        let p0 = p[max(0, i - 1)], p3 = p[min(p.count - 1, i + 2)]
        for step in 0...40 {
            let t = CGFloat(step) / 40
            let c = catmull(p0, p[i], p[i + 1], p3, t)
            let r = pts[i].2 + (pts[i + 1].2 - pts[i].2) * t
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }
}

func draw(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // Drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Eau profonde, de plus en plus sombre vers le fond
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let sea = [CGColor(red: 0.10, green: 0.30, blue: 0.45, alpha: 1),
               CGColor(red: 0.03, green: 0.08, blue: 0.18, alpha: 1)] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: sea, locations: [0, 1])!,
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Hippocampe en silhouette claire, tourné vers la gauche
    let cream = CGColor(red: 0.97, green: 0.93, blue: 0.84, alpha: 1)
    let water = CGColor(red: 0.07, green: 0.20, blue: 0.32, alpha: 1)
    ctx.setFillColor(cream)
    // Corps et queue enroulée
    tube(ctx, [(520, 720, 58), (560, 640, 60), (600, 545, 82), (600, 450, 80), (565, 365, 58), (530, 300, 42),
               (515, 240, 31), (540, 192, 23), (588, 186, 17), (612, 222, 13), (592, 256, 10), (566, 240, 8)])
    // Tête et museau
    ctx.fillEllipse(in: CGRect(x: 445, y: 668, width: 150, height: 140))
    tube(ctx, [(470, 722, 36), (410, 703, 22), (350, 690, 20), (325, 688, 24)])
    // Couronne
    ctx.move(to: CGPoint(x: 495, y: 790)); ctx.addLine(to: CGPoint(x: 530, y: 855)); ctx.addLine(to: CGPoint(x: 548, y: 800))
    ctx.addLine(to: CGPoint(x: 572, y: 840)); ctx.addLine(to: CGPoint(x: 585, y: 780)); ctx.closePath(); ctx.fillPath()
    // Nageoire dorsale, plus transparente
    ctx.setFillColor(CGColor(red: 0.97, green: 0.93, blue: 0.84, alpha: 0.6))
    ctx.move(to: CGPoint(x: 662, y: 585))
    ctx.addCurve(to: CGPoint(x: 700, y: 470), control1: CGPoint(x: 760, y: 590), control2: CGPoint(x: 765, y: 485))
    ctx.addLine(to: CGPoint(x: 668, y: 480)); ctx.closePath(); ctx.fillPath()
    ctx.setStrokeColor(CGColor(red: 0.97, green: 0.93, blue: 0.84, alpha: 0.9)); ctx.setLineWidth(5)
    for (x, y) in [(712.0, 568.0), (728.0, 535.0), (726.0, 500.0)] {
        ctx.move(to: CGPoint(x: 672, y: 530)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.strokePath()
    }
    // Anneaux du ventre et œil, découpés dans la couleur de l'eau
    ctx.setStrokeColor(water); ctx.setLineWidth(9); ctx.setLineCap(.round)
    for (y, x0, x1) in [(600.0, 525.0, 575.0), (540.0, 520.0, 568.0), (480.0, 523.0, 566.0), (420.0, 532.0, 568.0)] {
        ctx.move(to: CGPoint(x: x0, y: y)); ctx.addQuadCurve(to: CGPoint(x: x1, y: y - 14), control: CGPoint(x: (x0 + x1) / 2, y: y + 6))
        ctx.strokePath()
    }
    ctx.setFillColor(water)
    ctx.fillEllipse(in: CGRect(x: 484, y: 727, width: 30, height: 30))
    ctx.setFillColor(cream)
    ctx.fillEllipse(in: CGRect(x: 499, y: 743, width: 9, height: 9))

    // Bulles qui montent devant le museau
    ctx.setStrokeColor(CGColor(red: 0.97, green: 0.93, blue: 0.84, alpha: 0.8)); ctx.setLineWidth(10)
    for (x, y, r) in [(290.0, 770.0, 20.0), (260.0, 840.0, 13.0), (318.0, 868.0, 9.0)] {
        ctx.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    ctx.restoreGState()
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
