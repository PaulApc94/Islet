#!/usr/bin/env swift
//
//  make-icon.swift
//
//  Renders the Islet app icon with CoreGraphics and packs it into an .icns.
//
//      swift scripts/make-icon.swift <output.icns>
//
//  The icon is code rather than a design file so it stays reproducible with
//  nothing but the Command Line Tools. The resulting .icns is committed; the
//  app build only copies it.
//

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Helpers

struct IconError: Error {
    let message: String
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func white(_ alpha: CGFloat) -> CGColor { rgb(0xFFFFFF, alpha) }
func black(_ alpha: CGFloat) -> CGColor { rgb(0x000000, alpha) }

extension CGContext {
    /// Fills the current clip with a linear gradient running from `start` to `end`.
    func fillLinear(_ stops: [(CGFloat, CGColor)], from start: CGPoint, to end: CGPoint) {
        guard let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: stops.map { $0.1 } as CFArray,
            locations: stops.map { $0.0 }
        ) else { return }
        drawLinearGradient(
            gradient, start: start, end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    /// Paints a soft round glow: `color` at `center`, fading out at `radius`.
    func fillGlow(_ color: CGColor, center: CGPoint, radius: CGFloat) {
        guard let clear = color.copy(alpha: 0),
              let gradient = CGGradient(colorsSpace: sRGB, colors: [color, clear] as CFArray, locations: [0, 1])
        else { return }
        drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: []
        )
    }

    /// Runs `body` with the clip narrowed to an inner hairline along `path`,
    /// which is how every rim light in the icon is drawn.
    func withInnerRim(of path: CGPath, width: CGFloat, _ body: () -> Void) {
        saveGState()
        addPath(path)
        clip()
        addPath(path)
        // Half of the stroke falls outside the first clip, so double it.
        setLineWidth(width * 2)
        replacePathWithStrokedPath()
        clip()
        body()
        restoreGState()
    }
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    // CGPath traps when the radius exceeds half a side, so clamp it.
    let r = max(0, min(radius, min(rect.width, rect.height) / 2))
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// A rounded rectangle with continuous ("squircle") corners.
///
/// CoreGraphics has no public API for the shape macOS icons use, so this
/// reproduces the well-known curve of system rounded rectangles: each corner
/// is three Bézier segments that ease into the straight edges instead of
/// meeting them abruptly like a circular arc does.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let reach: CGFloat = 1.528665
    let r = max(0, min(radius, min(rect.width, rect.height) / 2 / reach))
    let path = CGMutablePath()

    // Each corner uses the same coefficients, mirrored.
    typealias Corner = (CGFloat, CGFloat) -> CGPoint
    let topLeft: Corner = { CGPoint(x: rect.minX + $0 * r, y: rect.minY + $1 * r) }
    let topRight: Corner = { CGPoint(x: rect.maxX - $0 * r, y: rect.minY + $1 * r) }
    let bottomRight: Corner = { CGPoint(x: rect.maxX - $0 * r, y: rect.maxY - $1 * r) }
    let bottomLeft: Corner = { CGPoint(x: rect.minX + $0 * r, y: rect.maxY - $1 * r) }

    /// Curves from the horizontal edge into the vertical one.
    func turnIn(_ p: Corner) {
        path.addCurve(to: p(0.63149379, 0.07491139), control1: p(1.08849296, 0), control2: p(0.86840694, 0))
        path.addCurve(to: p(0.07491139, 0.63149379), control1: p(0.37282383, 0.16905956), control2: p(0.16905956, 0.37282383))
        path.addCurve(to: p(0, reach), control1: p(0, 0.86840694), control2: p(0, 1.08849296))
    }

    /// Curves from the vertical edge back into the horizontal one.
    func turnOut(_ p: Corner) {
        path.addCurve(to: p(0.07491139, 0.63149379), control1: p(0, 1.08849296), control2: p(0, 0.86840694))
        path.addCurve(to: p(0.63149379, 0.07491139), control1: p(0.16905956, 0.37282383), control2: p(0.37282383, 0.16905956))
        path.addCurve(to: p(reach, 0), control1: p(0.86840694, 0), control2: p(1.08849296, 0))
    }

    path.move(to: topLeft(reach, 0))
    path.addLine(to: topRight(reach, 0))
    turnIn(topRight)
    path.addLine(to: bottomRight(0, reach))
    turnOut(bottomRight)
    path.addLine(to: bottomLeft(reach, 0))
    turnIn(bottomLeft)
    path.addLine(to: topLeft(0, reach))
    turnOut(topLeft)
    path.closeSubpath()
    return path
}

// MARK: - Layout

/// Geometry of one rendition, on a 1024-unit canvas with a top-left origin.
struct Layout {
    var body: CGRect
    var bodyRadius: CGFloat
    var capsule: CGRect
    var tile: CGRect
    var tileRadius: CGFloat
    var bars: [CGRect]
    var barRadius: CGFloat
    /// Gloss, rim lights and inner glows: only worth drawing when there are
    /// enough pixels to resolve them.
    var fineDetail: Bool
}

/// Equaliser bars centred on the canvas' horizontal axis.
func equaliser(x positions: [CGFloat], width: CGFloat, heights: [CGFloat]) -> [CGRect] {
    zip(positions, heights).map { x, height in
        CGRect(x: x, y: 512 - height / 2, width: width, height: height)
    }
}

/// The full design turns to mush below 64 px, so the small renditions get
/// their own simplified layouts whose edges land exactly on their pixel grid
/// (multiples of 64 units at 16 px, of 32 units at 32 px).
func layout(forPixels pixels: Int) -> Layout {
    if pixels <= 16 {
        return Layout(
            body: CGRect(x: 64, y: 64, width: 896, height: 896),
            bodyRadius: 200,
            capsule: CGRect(x: 128, y: 320, width: 768, height: 384),
            tile: CGRect(x: 192, y: 384, width: 256, height: 256),
            tileRadius: 48,
            bars: equaliser(x: [576, 704], width: 64, heights: [128, 256]),
            barRadius: 0,
            fineDetail: false
        )
    }
    if pixels <= 64 {
        return Layout(
            body: CGRect(x: 96, y: 96, width: 832, height: 832),
            bodyRadius: 187,
            capsule: CGRect(x: 160, y: 384, width: 704, height: 256),
            tile: CGRect(x: 192, y: 416, width: 192, height: 192),
            tileRadius: 40,
            bars: equaliser(x: [544, 640, 736], width: 64, heights: [128, 192, 64]),
            barRadius: 16,
            fineDetail: false
        )
    }
    // Apple's macOS icon grid: an 824 pt body centred in a 1024 pt canvas.
    // The capsule and its contents sit on multiples of 8 so the 128 px
    // rendition stays crisp too.
    return Layout(
        body: CGRect(x: 100, y: 100, width: 824, height: 824),
        bodyRadius: 185,
        capsule: CGRect(x: 176, y: 392, width: 672, height: 240),
        tile: CGRect(x: 216, y: 432, width: 160, height: 160),
        tileRadius: 46,
        bars: equaliser(x: [616, 664, 712, 760], width: 32, heights: [80, 144, 112, 64]),
        barRadius: 16,
        fineDetail: true
    )
}

// MARK: - Drawing

func drawIcon(in ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    let design = layout(forPixels: pixels)

    // Flip to a top-left origin so the geometry reads like the design grid.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)

    // Shadows ignore the transform (they live in device space, y up), hence
    // the manual scaling and the negative offsets to cast them downwards.
    func shadow(offset: CGFloat, blur: CGFloat, alpha: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: -offset * scale), blur: blur * scale, color: black(alpha))
    }

    let body = design.body
    let bodyPath = continuousRoundedRect(body, radius: design.bodyRadius)

    // Body silhouette, drawn once just to cast the drop shadow.
    ctx.saveGState()
    shadow(offset: 10, blur: 22, alpha: 0.30)
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0x6C74FF))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: diagonal blue-to-violet, lit from the top-left corner.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.fillLinear(
        [(0, rgb(0x46B4FF)), (0.5, rgb(0x6A7CFF)), (1, rgb(0x9A55F4))],
        from: CGPoint(x: body.minX, y: body.minY),
        to: CGPoint(x: body.maxX, y: body.maxY)
    )
    ctx.fillGlow(
        white(0.30),
        center: CGPoint(x: body.minX + body.width * 0.24, y: body.minY + body.height * 0.14),
        radius: body.width * 0.72
    )
    // A touch of shade at the bottom grounds the capsule.
    ctx.fillLinear(
        [(0, black(0)), (1, black(0.14))],
        from: CGPoint(x: 0, y: body.midY),
        to: CGPoint(x: 0, y: body.maxY)
    )
    ctx.restoreGState()

    if design.fineDetail {
        ctx.withInnerRim(of: bodyPath, width: 3) {
            ctx.fillLinear(
                [(0, white(0.42)), (0.5, white(0.06)), (1, black(0.10))],
                from: CGPoint(x: 0, y: body.minY),
                to: CGPoint(x: 0, y: body.maxY)
            )
        }
    }

    // The island.
    let capsule = design.capsule
    let capsulePath = roundedRect(capsule, radius: capsule.height / 2)

    ctx.saveGState()
    if design.fineDetail {
        shadow(offset: 16, blur: 36, alpha: 0.42)
    } else {
        // Tighter, or the blur would eat the few pixels around the pill.
        shadow(offset: 8, blur: 16, alpha: 0.30)
    }
    ctx.addPath(capsulePath)
    ctx.setFillColor(black(1))
    ctx.fillPath()
    ctx.restoreGState()

    if design.fineDetail {
        // Gloss: a faint lift of the black plus a sheen hugging the top edge.
        ctx.saveGState()
        ctx.addPath(capsulePath)
        ctx.clip()
        ctx.fillLinear(
            [(0, rgb(0x161618)), (0.5, rgb(0x040405)), (1, rgb(0x000000))],
            from: CGPoint(x: 0, y: capsule.minY),
            to: CGPoint(x: 0, y: capsule.maxY)
        )
        let sheen = capsule.insetBy(dx: 10, dy: 8)
        ctx.addPath(roundedRect(sheen, radius: sheen.height / 2))
        ctx.clip()
        ctx.fillLinear(
            [(0, white(0.13)), (1, white(0))],
            from: CGPoint(x: 0, y: sheen.minY),
            to: CGPoint(x: 0, y: capsule.midY - 16)
        )
        ctx.restoreGState()

        ctx.withInnerRim(of: capsulePath, width: 3) {
            ctx.fillLinear(
                [(0, white(0.40)), (0.6, white(0.08)), (1, white(0.14))],
                from: CGPoint(x: 0, y: capsule.minY),
                to: CGPoint(x: 0, y: capsule.maxY)
            )
        }
    }

    // Artwork tile at the leading end.
    let tile = design.tile
    let tilePath = continuousRoundedRect(tile, radius: design.tileRadius)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.fillLinear(
        [(0, rgb(0xFFD25A)), (0.5, rgb(0xFF8A3D)), (1, rgb(0xFF3F78))],
        from: CGPoint(x: tile.minX, y: tile.minY),
        to: CGPoint(x: tile.maxX, y: tile.maxY)
    )
    if design.fineDetail {
        ctx.fillGlow(
            white(0.24),
            center: CGPoint(x: tile.minX + tile.width * 0.28, y: tile.minY + tile.height * 0.22),
            radius: tile.width * 0.7
        )
    }
    ctx.restoreGState()

    if design.fineDetail {
        ctx.withInnerRim(of: tilePath, width: 2.5) {
            ctx.fillLinear(
                [(0, white(0.55)), (1, white(0.10))],
                from: CGPoint(x: 0, y: tile.minY),
                to: CGPoint(x: 0, y: tile.maxY)
            )
        }
    }

    // Equaliser bars at the trailing end, tinted like the artwork: the real
    // island colours its waveform from the cover.
    guard let firstBar = design.bars.first else { return }
    let barsBounds = design.bars.reduce(firstBar) { $0.union($1) }

    ctx.saveGState()
    if design.fineDetail {
        // A hint of glow so the bars read as lit rather than painted.
        ctx.setShadow(offset: .zero, blur: 18 * scale, color: rgb(0xFFB347, 0.55))
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for bar in design.bars {
        ctx.addPath(roundedRect(bar, radius: design.barRadius))
    }
    ctx.clip()
    ctx.fillLinear(
        [(0, rgb(0xFFE680)), (1, rgb(0xFF9A3C))],
        from: CGPoint(x: 0, y: barsBounds.minY),
        to: CGPoint(x: 0, y: barsBounds.maxY)
    )
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: - Output

func writePNG(pixels: Int, dpi: Int, to url: URL) throws {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError(message: "impossible de créer le contexte graphique (\(pixels) px)")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, pixels: pixels)

    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else {
        throw IconError(message: "impossible d'écrire \(url.lastPathComponent)")
    }
    // The density is what tells @2x files apart from their 1x siblings.
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError(message: "impossible d'écrire \(url.lastPathComponent)")
    }
}

func makeIcon(at output: URL) throws {
    let fileManager = FileManager.default
    let workDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("islet-icon-\(UUID().uuidString)", isDirectory: true)
    let iconset = workDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: workDirectory) }

    // The exact set of files iconutil expects.
    for points in [16, 32, 128, 256, 512] {
        try writePNG(
            pixels: points, dpi: 72,
            to: iconset.appendingPathComponent("icon_\(points)x\(points).png")
        )
        try writePNG(
            pixels: points * 2, dpi: 144,
            to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png")
        )
    }

    try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", "-o", output.path, iconset.path]
    do {
        try iconutil.run()
    } catch {
        throw IconError(message: "impossible de lancer /usr/bin/iconutil (\(error.localizedDescription))")
    }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0, fileManager.fileExists(atPath: output.path) else {
        throw IconError(message: "iconutil a échoué (code \(iconutil.terminationStatus))")
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2, !arguments[1].hasPrefix("-") else {
    FileHandle.standardError.write(Data("Usage : swift scripts/make-icon.swift <sortie.icns>\n".utf8))
    exit(64)
}

let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
do {
    try makeIcon(at: output)
    print("Icône générée : \(output.path)")
} catch let error as IconError {
    FileHandle.standardError.write(Data("Erreur : \(error.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("Erreur : \(error.localizedDescription)\n".utf8))
    exit(1)
}
