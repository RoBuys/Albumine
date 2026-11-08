// Génère l'icône d'Albumine (monogramme A, variante « Ciel ») : swift Resources/make-icon.swift
// Produit Resources/AppIcon.icns et Resources/AppIcon-1024.png.
import AppKit

let size: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Repère « écran » : origine en haut à gauche.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Grille d'icône macOS : corps de 824 px centré, coins arrondis.
let inset: CGFloat = 100, body: CGFloat = 824
let k = body / 160 // le dessin d'origine fait 160 × 160
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: inset + x * k, y: inset + y * k) }

// Ombre portée discrète, comme les icônes système.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x1B3A6B, 0.28))
ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: body, height: body),
                   cornerWidth: 36 * k, cornerHeight: 36 * k, transform: nil))
ctx.setFillColor(color(0xCCDEFF)) // bleu ciel (un peu plus soutenu que la maquette)
ctx.fillPath()
ctx.restoreGState()

func bar(from a: CGPoint, to b: CGPoint, _ c: CGColor) {
    ctx.setLineCap(.round)
    ctx.setLineWidth(24 * k)
    ctx.setStrokeColor(c)
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()
}
bar(from: p(80, 36), to: p(50, 124), color(0xFF9E7A, 0.92)) // pêche
bar(from: p(80, 36), to: p(110, 124), color(0x5B9BFF, 0.80)) // bleu
ctx.setFillColor(color(0xFFD166)) // soleil
ctx.fillEllipse(in: CGRect(x: p(70, 88).x, y: p(70, 88).y, width: 20 * k, height: 20 * k))

let image = ctx.makeImage()!
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let master = dir.appendingPathComponent("AppIcon-1024.png")
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: master)

// Jeu de tailles pour iconutil.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: size, height: size))
            .draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✅ AppIcon.icns créé" : "❌ iconutil a échoué")
