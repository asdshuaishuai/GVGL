#!/usr/bin/env swift
// Generates AppIcon.icns (gradient rounded square + 2×2 desktop-grid motif).
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func renderIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let s = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let corner = s * 0.22

    // Background: blue gradient rounded square.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.80, alpha: 1.0),
        NSColor(calibratedRed: 0.35, green: 0.70, blue: 0.95, alpha: 1.0),
    ])!
    let bg = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    gradient.draw(in: bg, angle: -55)

    // 2×2 desktop-grid motif (four rounded tiles).
    let g = s * 0.10          // gutter
    let cell = (s - g * 3) / 2
    for row in 0..<2 {
        for col in 0..<2 {
            let r = NSRect(x: g + CGFloat(col) * (cell + g),
                           y: g + CGFloat(row) * (cell + g),
                           width: cell, height: cell)
            let tile = NSBezierPath(roundedRect: r, xRadius: cell * 0.18, yRadius: cell * 0.18)
            let alpha: CGFloat = (row == 1 && col == 1) ? 1.0 : 0.78
            NSColor.white.withAlphaComponent(alpha).setFill()
            tile.fill()
        }
    }

    // Small green "live" dot at the top-right.
    let dotR = s * 0.055
    let dotRect = NSRect(x: s - g - dotR * 2.2, y: s - g - dotR * 2.2, width: dotR * 2, height: dotR * 2)
    NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.35, alpha: 1.0).setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// iconset sizes: name → pixel size
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
let iconsetDir = (outputDir as NSString).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(atPath: iconsetDir)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for entry in sizes {
    guard let data = renderIcon(pixels: entry.px) else {
        fputs("render failed for \(entry.name)\n", stderr)
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: (iconsetDir as NSString).appendingPathComponent(entry.name)))
}

let icnsPath = (outputDir as NSString).appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(atPath: iconsetDir)

guard fm.fileExists(atPath: icnsPath) else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("AppIcon.icns written: \(icnsPath)")
