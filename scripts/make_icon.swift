#!/usr/bin/env swift
//
// make_icon.swift — renders the CocoGram app icon as an .iconset directory.
//
// A macOS-style rounded-square ("squircle") with a Telegram-blue gradient and depth (drop
// shadow, top sheen, inner bevel), carrying a custom two-tone origami paper plane with a soft
// shadow and a faint motion trail. Rendered fresh at every size macOS expects; package.sh then
// runs `iconutil -c icns` to produce AppIcon.icns.
//
// IMPORTANT (color correctness): the bitmap is rendered into an explicit **sRGB, premultiplied**
// CGContext and exported via ImageIO with the sRGB profile embedded. An earlier version drew into
// an NSCalibratedRGB / non-premultiplied NSBitmapImageRep; that PNG decoded fine in NSImage but
// the system icon-services pipeline (Finder / NSWorkspace) mis-read its channels and showed the
// icon orange (R/B swapped) or rejected it (generic icon). A canonical sRGB CGImage → ImageIO PNG
// avoids that entirely.
//
// Usage: swift make_icon.swift <output.iconset-dir>
//

import AppKit
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Telegram-ish blue, lighter at top.
let gradientTop = NSColor(srgbRed: 0.27, green: 0.68, blue: 0.95, alpha: 1.0)
let gradientBottom = NSColor(srgbRed: 0.11, green: 0.45, blue: 0.80, alpha: 1.0)

/// Continuous-corner ("squircle") rounded rectangle. Apple's icon corner radius is ~22.37% of the
/// side, which reads as the familiar macOS shape.
func squirclePath(in rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
}

/// Draws the whole icon into the current `NSGraphicsContext` at the given canvas size.
func drawIcon(canvas size: CGFloat) {
    let bodyInset = size * 0.085
    let body = NSRect(x: bodyInset, y: bodyInset * 1.25,
                      width: size - 2 * bodyInset, height: size - 2 * bodyInset).integral
    let squircle = squirclePath(in: body)

    // 1) Drop shadow: fill once with shadow set so the body casts a soft shadow beneath it.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.set()
    gradientBottom.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 2) Background gradient, clipped to the squircle.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: gradientTop, ending: gradientBottom)?.draw(in: body, angle: -90)

    // 3) Soft top-left sheen for depth.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)])?
        .draw(in: body, relativeCenterPosition: NSPoint(x: -0.35, y: 0.7))

    // 4) Subtle inner bevel along the edge.
    let bevel = squirclePath(in: body)
    bevel.lineWidth = max(1, size * 0.004)
    NSColor.white.withAlphaComponent(0.18).setStroke()
    bevel.stroke()
    NSGraphicsContext.restoreGraphicsState()

    drawPaperPlane(in: body, canvas: size)
}

/// Two-tone origami paper plane (with a fold) + a faint motion trail, optically centered. Points
/// to the upper-right (a "send" motif).
func drawPaperPlane(in body: NSRect, canvas: CGFloat) {
    let glyph = CGFloat(0.58) * body.width
    let originX = body.midX - glyph * 0.5 - body.width * 0.015
    let originY = body.midY - glyph * 0.5 - body.height * 0.01
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: originX + (x / 100) * glyph, y: originY + (y / 100) * glyph)
    }
    let nose = p(92, 70), backTop = p(8, 56), notch = p(46, 44), backBottom = p(34, 8)

    NSGraphicsContext.saveGraphicsState()
    let planeShadow = NSShadow()
    planeShadow.shadowColor = NSColor(srgbRed: 0.05, green: 0.20, blue: 0.40, alpha: 0.35)
    planeShadow.shadowBlurRadius = canvas * 0.02
    planeShadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
    planeShadow.set()

    let trail = NSBezierPath()
    trail.move(to: p(2, 30))
    trail.curve(to: p(30, 24), controlPoint1: p(12, 24), controlPoint2: p(22, 22))
    trail.lineWidth = glyph * 0.022
    trail.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.45).setStroke()
    trail.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let topWing = NSBezierPath()
    topWing.move(to: nose); topWing.line(to: backTop); topWing.line(to: notch); topWing.close()
    NSColor.white.setFill()
    topWing.fill()

    let keel = NSBezierPath()
    keel.move(to: nose); keel.line(to: notch); keel.line(to: backBottom); keel.close()
    NSColor(srgbRed: 0.86, green: 0.92, blue: 0.99, alpha: 1.0).setFill()
    keel.fill()
}

/// Renders one size into a canonical sRGB, premultiplied PNG with the color profile embedded.
func renderPNG(px: Int) -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        FileHandle.standardError.write(Data("ERROR: could not create sRGB context for \(px)px\n".utf8))
        exit(1)
    }
    context.interpolationQuality = .high

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    drawIcon(canvas: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = context.makeImage() else {
        FileHandle.standardError.write(Data("ERROR: could not snapshot image for \(px)px\n".utf8))
        exit(1)
    }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("ERROR: could not create PNG destination for \(px)px\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("ERROR: could not finalize PNG for \(px)px\n".utf8))
        exit(1)
    }
    return data as Data
}

func write(px: Int, to name: String) {
    do {
        try renderPNG(px: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    } catch {
        FileHandle.standardError.write(Data("ERROR: failed to write \(name): \(error)\n".utf8))
        exit(1)
    }
}

// Required iconset members: 16, 32, 128, 256, 512 at @1x and @2x.
for base in [16, 32, 128, 256, 512] {
    write(px: base, to: "icon_\(base)x\(base).png")
    write(px: base * 2, to: "icon_\(base)x\(base)@2x.png")
}
print("wrote iconset to \(outDir)")
