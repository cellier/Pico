import AppKit
import SwiftUI

// Place the Pico artwork on the macOS app-icon grid: an 824 pt continuous rounded
// rectangle centred on a 1024 pt canvas, with the system's soft drop shadow.
// Full-bleed square artwork would otherwise sit in a gray system tile on macOS 26.
guard CommandLine.arguments.count == 3,
      let artwork = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Usage: build-app-icon.swift artwork.png output.png")
}
bitmap.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: tile).cgPath
let cg = context.cgContext
// Shadow first, under the tile.
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
cg.addPath(shape); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
cg.restoreGState()
// Artwork clipped to the tile.
cg.saveGState()
cg.addPath(shape); cg.clip()
artwork.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
cg.restoreGState()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the packaged Pico icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
