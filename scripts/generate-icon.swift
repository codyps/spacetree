#!/usr/bin/env swift
import AppKit

// Default output is relative to this script, regardless of the working directory.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? repository.appendingPathComponent("Sources/SpaceTree/Resources/AppIcon.png")
let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.clear(CGRect(x: 0, y: 0, width: size, height: size))
context.setShouldAntialias(true)
// Top-left coordinates, matching the treemap UI.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
let outline = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 184
let border: CGFloat = 20
let interior = outline.insetBy(dx: border, dy: border)
let innerRadius = radius - border
context.setFillColor(NSColor(srgbRed: 0.055, green: 0.085, blue: 0.16, alpha: 1).cgColor)
context.addPath(CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil))
context.fillPath()

// Every perimeter tile shares this clip. Reducing radius and bounds by the same
// inset makes the corner arcs concentric, with an even border. Internal joins
// stay square: no independently rounded tile can disagree with the silhouette.
context.saveGState()
context.addPath(CGPath(roundedRect: interior, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
context.clip()

struct Tile {
    let rect: CGRect
    let color: UInt32
}
// Partition the 784-point interior with consistent 12-point gutters.
let tiles: [Tile] = [
    Tile(rect: CGRect(x: 0, y: 0, width: 452, height: 472), color: 0x9657EB),
    Tile(rect: CGRect(x: 464, y: 0, width: 154, height: 230), color: 0xEB578E),
    Tile(rect: CGRect(x: 630, y: 0, width: 154, height: 230), color: 0xF28A3B),
    Tile(rect: CGRect(x: 464, y: 242, width: 154, height: 230), color: 0xE6B833),
    Tile(rect: CGRect(x: 630, y: 242, width: 154, height: 230), color: 0x33B894),
    Tile(rect: CGRect(x: 0, y: 484, width: 452, height: 300), color: 0x2EABC7),
    Tile(rect: CGRect(x: 464, y: 484, width: 154, height: 300), color: 0x7165D9),
    Tile(rect: CGRect(x: 630, y: 484, width: 154, height: 144), color: 0x408CF5),
    Tile(rect: CGRect(x: 630, y: 640, width: 71, height: 144), color: 0x48C5A8),
    Tile(rect: CGRect(x: 713, y: 640, width: 71, height: 144), color: 0xE56D9D),
]
for tile in tiles {
    let rect = tile.rect.offsetBy(dx: interior.minX, dy: interior.minY)
    let color = NSColor(srgbRed: CGFloat((tile.color >> 16) & 255) / 255,
                        green: CGFloat((tile.color >> 8) & 255) / 255,
                        blue: CGFloat(tile.color & 255) / 255, alpha: 1)
    let highlight = color.blended(withFraction: 0.12, of: .white)!
    let shade = color.blended(withFraction: 0.12, of: .black)!
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [highlight.cgColor, shade.cgColor] as CFArray,
                              locations: [0, 1])!
    context.saveGState()
    context.clip(to: rect)
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    context.restoreGState()
}
context.restoreGState()
NSGraphicsContext.restoreGraphicsState()
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
print("Wrote \(output.path) (\(size)×\(size))")
