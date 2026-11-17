// Renders Kan's app icon.
//
//   make icon                                     regenerates Resources/AppIcon.icns (commit it)
//   swift scripts/make-icon.swift --icns Resources/AppIcon.icns
//   swift scripts/make-icon.swift --iconset /tmp/AppIcon.iconset --preview /tmp/AppIcon.png
//
// Design: a squircle on the macOS icon grid (superellipse, n = 5, 824 of 1024 px) filled with a
// warm saffron → tangerine → raspberry gradient, the white SF Symbol "ear", and from 128 px up
// the wordmark "কান" ("ear" in Bangla) in Kohinoor Bangla. Below 64 px the icon uses the filled ear
// and no shadows, which would only blur it.

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct IconError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One PNG of an .iconset: file name, pixel size and DPI (72 for @1x, 144 for @2x).
struct IconsetEntry {
    let name: String
    let pixels: Int
    let dpi: Int
}

let iconsetEntries: [IconsetEntry] = [16, 32, 128, 256, 512].flatMap { points in
    [IconsetEntry(name: "icon_\(points)x\(points).png", pixels: points, dpi: 72),
     IconsetEntry(name: "icon_\(points)x\(points)@2x.png", pixels: points * 2, dpi: 144)]
}

let wordmark = "কান"
/// Fonts tried for the wordmark, best first. The first one installed that covers every character wins.
let wordmarkFonts = ["KohinoorBangla-Semibold", "KohinoorBangla-Medium", "BanglaSangamMN-Bold", "BanglaMN-Bold"]

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

enum Palette {
    static let saffron = srgb(1.00, 0.77, 0.30)
    static let tangerine = srgb(1.00, 0.47, 0.20)
    static let raspberry = srgb(0.84, 0.19, 0.37)
    static let shadow = srgb(0, 0, 0, 0.30)
    static let glyphShadow = srgb(0.45, 0.07, 0.05, 0.28)
    static let white = srgb(1, 1, 1)
}

// MARK: - Geometry

/// A superellipse |x/a|ⁿ + |y/b|ⁿ = 1 (n = 5 is within a pixel of Apple's continuous-corner icon
/// shape at 1024 px), as a dense polygon.
func squircle(in rect: CGRect, exponent n: CGFloat = 5, points: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for i in 0..<points {
        let t = CGFloat(i) / CGFloat(points) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing helpers

func makeContext(width: Int, height: Int) throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw IconError("cannot create a \(width)×\(height) bitmap") }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    return context
}

/// The SF Symbol rendered white into its own bitmap, scaled so its height is `height` pixels.
func whiteSymbol(_ name: String, height: CGFloat, weight: NSFont.Weight) throws -> CGImage {
    func symbol(pointSize: CGFloat) throws -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        else { throw IconError("SF Symbol '\(name)' is not available on this Mac") }
        return image
    }
    let probe = try symbol(pointSize: 100).size
    let image = try symbol(pointSize: 100 * height / probe.height)
    let width = Int(image.size.width.rounded(.up)), pixelHeight = Int(image.size.height.rounded(.up))
    let context = try makeContext(width: width, height: pixelHeight)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: CGRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    // Keep the glyph's coverage, replace its colour.
    context.setBlendMode(.sourceIn)
    context.setFillColor(Palette.white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: pixelHeight))
    guard let result = context.makeImage() else { throw IconError("cannot rasterize SF Symbol '\(name)'") }
    return result
}

func covers(_ font: CTFont, _ text: String) -> Bool {
    let characters = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) && !glyphs.contains(0)
}

/// The wordmark as a CoreText line in the first suitable installed font, or nil if none is installed.
func wordmarkLine(fontSize: CGFloat) -> CTLine? {
    for name in wordmarkFonts {
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        // CTFontCreateWithName silently substitutes another font when `name` isn't installed.
        guard CTFontCopyPostScriptName(font) as String == name, covers(font, wordmark) else { continue }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.white,
            NSAttributedString.Key(kCTKernAttributeName as String): fontSize * 0.02,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: wordmark, attributes: attributes))
    }
    return nil
}

// MARK: - The icon

func renderIcon(pixels: Int, wordmarkAllowed: Bool) throws -> CGImage {
    let context = try makeContext(width: pixels, height: pixels)
    let unit = CGFloat(pixels) / 1024
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = squircle(in: body)
    let detailed = pixels >= 64
    let line = (wordmarkAllowed && pixels > 64) ? wordmarkLine(fontSize: body.height * 0.165) : nil

    if detailed {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 26 * unit, color: Palette.shadow)
        context.addPath(shape)
        context.setFillColor(Palette.tangerine)
        context.fillPath()
        context.restoreGState()
    }

    // Body: diagonal gradient from the top-left corner, then a soft highlight and a deeper base.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)
    guard let fill = CGGradient(colorsSpace: space, colors: [Palette.saffron, Palette.tangerine, Palette.raspberry] as CFArray,
                                locations: [0, 0.48, 1])
    else { throw IconError("cannot create the background gradient") }
    context.drawLinearGradient(fill, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    if detailed,
       let sheen = CGGradient(colorsSpace: space, colors: [srgb(1, 1, 1, 0.30), srgb(1, 1, 1, 0)] as CFArray, locations: [0, 1]),
       let base = CGGradient(colorsSpace: space, colors: [srgb(0.45, 0.02, 0.12, 0), srgb(0.45, 0.02, 0.12, 0.22)] as CFArray,
                             locations: [0, 1]) {
        let glow = CGPoint(x: body.minX + body.width * 0.28, y: body.maxY - body.height * 0.18)
        context.drawRadialGradient(sheen, startCenter: glow, startRadius: 0, endCenter: glow, endRadius: body.width * 0.75, options: [])
        context.drawLinearGradient(base, start: CGPoint(x: body.midX, y: body.midY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    }
    context.restoreGState()

    // Glyph: centred, or raised above the wordmark. Below 64 px the outline ear turns into a blur,
    // so those sizes use the filled ear, larger.
    let symbolName: String
    let glyphHeight: CGFloat
    switch pixels {
    case ..<64: symbolName = "ear.fill"; glyphHeight = body.height * 0.70
    case ..<128: symbolName = "ear"; glyphHeight = body.height * 0.60
    default: symbolName = "ear"; glyphHeight = body.height * (line == nil ? 0.58 : 0.50)
    }
    let glyph = try whiteSymbol(symbolName, height: glyphHeight, weight: .bold)
    let glyphCenterY = line == nil ? body.midY : body.minY + body.height * 0.615
    let glyphRect = CGRect(x: (body.midX - CGFloat(glyph.width) / 2).rounded(),
                           y: (glyphCenterY - CGFloat(glyph.height) / 2).rounded(),
                           width: CGFloat(glyph.width), height: CGFloat(glyph.height))
    context.saveGState()
    if detailed {
        context.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 14 * unit, color: Palette.glyphShadow)
    }
    context.draw(glyph, in: glyphRect)
    context.restoreGState()

    if let line {
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let baseline = body.minY + body.height * 0.16 - bounds.minY
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4 * unit), blur: 10 * unit, color: Palette.glyphShadow)
        context.textPosition = CGPoint(x: (body.midX - bounds.midX).rounded(), y: baseline.rounded())
        CTLineDraw(line, context)
        context.restoreGState()
    }

    guard let image = context.makeImage() else { throw IconError("cannot finish the \(pixels) px icon") }
    return image
}

func writePNG(_ image: CGImage, to url: URL, dpi: Int) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError("cannot create \(url.path)") }
    let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { throw IconError("cannot write \(url.path)") }
}

func writeIconset(to directory: URL, wordmarkAllowed: Bool) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for entry in iconsetEntries {
        let image = try renderIcon(pixels: entry.pixels, wordmarkAllowed: wordmarkAllowed)
        try writePNG(image, to: directory.appendingPathComponent(entry.name), dpi: entry.dpi)
    }
}

func runIconutil(iconset: URL, output: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IconError("iconutil failed with status \(process.terminationStatus)")
    }
}

// MARK: - Command line

struct Options {
    var iconset: URL?
    var icns: URL?
    var preview: URL?
    var wordmark = true
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    func value(after flag: String) throws -> URL {
        index += 1
        guard index < arguments.count else { throw IconError("\(flag) needs a path") }
        return URL(fileURLWithPath: arguments[index])
    }
    while index < arguments.count {
        switch arguments[index] {
        case "--iconset": options.iconset = try value(after: "--iconset")
        case "--icns": options.icns = try value(after: "--icns")
        case "--preview": options.preview = try value(after: "--preview")
        case "--no-wordmark": options.wordmark = false
        case "-h", "--help":
            print("usage: make-icon [--icns <AppIcon.icns>] [--iconset <dir.iconset>] [--preview <1024.png>] [--no-wordmark]")
            exit(0)
        default: throw IconError("unknown argument '\(arguments[index])' (see --help)")
        }
        index += 1
    }
    if options.iconset == nil && options.icns == nil && options.preview == nil {
        throw IconError("nothing to do: pass --icns, --iconset and/or --preview (see --help)")
    }
    if let iconset = options.iconset, iconset.pathExtension != "iconset" {
        throw IconError("the --iconset directory must end in .iconset (iconutil requires it)")
    }
    return options
}

func run() throws {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    if options.wordmark && wordmarkLine(fontSize: 100) == nil {
        FileHandle.standardError.write(Data("make-icon: no installed font covers \(wordmark); drawing the icon without the wordmark\n".utf8))
    }

    var temporary: URL?
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

    let iconset: URL
    if let requested = options.iconset {
        iconset = requested
    } else {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kan-icon-\(UUID().uuidString)")
        temporary = directory
        iconset = directory.appendingPathComponent("AppIcon.iconset")
    }
    if options.iconset != nil || options.icns != nil {
        try writeIconset(to: iconset, wordmarkAllowed: options.wordmark)
        if options.iconset != nil { print("wrote \(iconsetEntries.count) PNGs to \(iconset.path)") }
    }
    if let icns = options.icns {
        try FileManager.default.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runIconutil(iconset: iconset, output: icns)
        print("wrote \(icns.path)")
    }
    if let preview = options.preview {
        try writePNG(try renderIcon(pixels: 1024, wordmarkAllowed: options.wordmark), to: preview, dpi: 144)
        print("wrote \(preview.path)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
