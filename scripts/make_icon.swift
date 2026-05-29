#!/usr/bin/env swift
//
// make_icon.swift — generates a placeholder CocoGram app icon as an .iconset directory.
// Renders a blue squircle background with a white SF Symbols paperplane glyph at every
// size macOS expects, then package.sh runs `iconutil -c icns` to produce AppIcon.icns.
//
// Usage: swift make_icon.swift <output.iconset-dir>
//

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Telegram-ish blue gradient.
let top = NSColor(calibratedRed: 0.20, green: 0.64, blue: 0.92, alpha: 1.0)
let bottom = NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.79, alpha: 1.0)

func renderIcon(px: Int) -> NSBitmapImageRep {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: artwork sits in ~80% of the canvas with rounded corners.
    let inset = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: top, ending: bottom)?.draw(in: squircle, angle: -90)

    // White paperplane glyph, centered.
    let glyphPointSize = rect.width * 0.52
    let config = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let g = symbol.size
        let gx = rect.midX - g.width / 2
        let gy = rect.midY - g.height / 2
        let tinted = NSImage(size: g)
        tinted.lockFocus()
        NSColor.white.set()
        let r = NSRect(origin: .zero, size: g)
        symbol.draw(in: r)
        r.fill(using: .sourceAtop)
        tinted.unlockFocus()
        // Nudge slightly to optically center the asymmetric glyph.
        tinted.draw(in: NSRect(x: gx - g.width * 0.02, y: gy - g.height * 0.02, width: g.width, height: g.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

// Required iconset members: 16,32,128,256,512 at @1x and @2x.
for base in [16, 32, 128, 256, 512] {
    write(renderIcon(px: base), to: "icon_\(base)x\(base).png")
    write(renderIcon(px: base * 2), to: "icon_\(base)x\(base)@2x.png")
}
print("wrote iconset to \(outDir)")
