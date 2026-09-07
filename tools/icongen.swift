import AppKit
import CoreGraphics

// Icônes de Vigil : œil au trait épais, pupille pleine découpée d'un
// symbole power. Rendu vectoriel par taille (pas de redimensionnement).
// Sorties : iconset app (squircle blanc + glyphe noir) et MenuIcon.png
// (glyphe seul, noir sur transparent, pour la barre de menus en template).
// Usage : swift icongen.swift Vigil.iconset MenuIcon.png
//         puis iconutil -c icns Vigil.iconset -o ../Resources/Icon.icns

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Vigil.iconset"
let menuIconPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "MenuIcon.png"

let black = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.05, 0.05, 0.07, 1])!
let white = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.98, 0.98, 0.98, 1])!

// Glyphe œil+power dessiné dans un espace 1024x1024, centré.
func drawEyeGlyph(_ ctx: CGContext) {
    let strokeWidth: CGFloat = 68

    // Contour : amande à pointes adoucies (joints ronds)
    let left = CGPoint(x: 152, y: 512)
    let right = CGPoint(x: 872, y: 512)
    let outline = CGMutablePath()
    outline.move(to: left)
    outline.addCurve(to: right,
                     control1: CGPoint(x: 296, y: 818),
                     control2: CGPoint(x: 728, y: 818))
    outline.addCurve(to: left,
                     control1: CGPoint(x: 728, y: 206),
                     control2: CGPoint(x: 296, y: 206))
    outline.closeSubpath()
    ctx.setStrokeColor(black)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.addPath(outline)
    ctx.strokePath()

    // Pupille pleine, découpe power (tige + rond central) en calque
    let pupilRadius: CGFloat = 148
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(black)
    ctx.fillEllipse(in: CGRect(x: 512 - pupilRadius, y: 512 - pupilRadius,
                               width: pupilRadius * 2, height: pupilRadius * 2))
    ctx.setBlendMode(.destinationOut)
    let stemWidth: CGFloat = 52
    ctx.fill(CGRect(x: 512 - stemWidth / 2, y: 512, width: stemWidth, height: pupilRadius + 40))
    let bulbRadius: CGFloat = 43
    ctx.fillEllipse(in: CGRect(x: 512 - bulbRadius, y: 512 - bulbRadius,
                               width: bulbRadius * 2, height: bulbRadius * 2))
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()
}

// Icône d'app : squircle blanc plein cadre macOS + glyphe
func drawAppIcon(_ ctx: CGContext, scale: CGFloat) {
    ctx.scaleBy(x: scale, y: scale)
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil))
    ctx.clip()
    ctx.setFillColor(white)
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    // Glyphe réduit et centré
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 0.74, y: 0.74)
    ctx.translateBy(x: -512, y: -512)
    drawEyeGlyph(ctx)
}

func makeContext(_ px: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("contexte impossible pour \(px)px")
    }
    return ctx
}

func writePNG(_ ctx: CGContext, to path: String) {
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("png impossible pour \(path)")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for entry in sizes {
    let ctx = makeContext(entry.pixels)
    drawAppIcon(ctx, scale: CGFloat(entry.pixels) / 1024)
    writePNG(ctx, to: "\(outDir)/\(entry.name).png")
}

// Icône de barre de menus : glyphe seul, 256 px, fond transparent
let menuCtx = makeContext(256)
menuCtx.scaleBy(x: 256.0 / 1024.0, y: 256.0 / 1024.0)
drawEyeGlyph(menuCtx)
writePNG(menuCtx, to: menuIconPath)

print("iconset + MenuIcon générés")
