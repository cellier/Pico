import AppKit
import ImageIO
import UniformTypeIdentifiers
#if canImport(PaperKit)
import PaperKit
#endif

@main struct ScreenshotEditorTests {
    @MainActor static func main() async throws {
        #if canImport(PaperKit)
        if #available(macOS 26.0, *) {
            _ = NSApplication.shared
            precondition(ScreenshotEditor.isSupported)
            let url = URL(fileURLWithPath: "/tmp/telos test/capture.png")
            let fileArguments = ScreenshotController.arguments(outputURL: url)
            precondition(fileArguments.contains("-i") && fileArguments.contains("-Jselection"))
            precondition(!fileArguments.contains("-c"), "Editor input must come from its own capture file")
            precondition(fileArguments.last == url.path, "Pass paths as a single Process argument")
            precondition(ScreenshotController.arguments(outputURL: nil) == ScreenshotController.arguments)

            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<24 {
                for x in 0..<40 {
                    let color: NSColor = y < 12 ? (x < 20 ? .red : .green) : (x < 20 ? .blue : .white)
                    bitmap.setColor(color, atX: x, y: y)
                }
            }
            let original = bitmap.representation(using: .png, properties: [:])!
            let raster = try ScreenshotRaster(pngData: original, canvasSize: CGSize(width: 20, height: 12))
            precondition(raster.image.width == 40 && raster.image.height == 24)
            let empty = PaperMarkup(bounds: raster.bounds)
            let unedited = try await ScreenshotMarkupRenderer.png(raster: raster, markup: empty)
            precondition(unedited == original, "An unedited screenshot must remain byte-for-byte unchanged")

            let dot = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            dot.setColor(.black, atX: 0, y: 0)
            var markup = PaperMarkup(bounds: raster.bounds)
            markup.insertNewImage(dot.cgImage!, frame: CGRect(x: 8, y: 4, width: 4, height: 4), rotation: 0)
            let rendered = try await ScreenshotMarkupRenderer.png(raster: raster, markup: markup)
            let output = NSBitmapImageRep(data: rendered)!
            precondition(output.pixelsWide == 40 && output.pixelsHigh == 24, "Export at original pixels, not window size")
            for (x, y) in [(2, 2), (37, 2), (2, 21), (37, 21)] {
                precondition(close(bitmap.colorAt(x: x, y: y)!, output.colorAt(x: x, y: y)!),
                    "Corner colors must stay in place: catch vertical flips, rotation and scaling")
            }
            precondition(close(.black, output.colorAt(x: 20, y: 12)!), "Markup must composite over the image")
            let markupData = try await markup.dataRepresentation()
            let document = try ScreenshotMarkupDocument(originalPNG: original, markupData: markupData,
                previewPNG: rendered, canvasWidth: 20, canvasHeight: 12)
            let reopened = try ScreenshotMarkupDocument.decode(document.encoded())
            let restored = try PaperMarkup(dataRepresentation: reopened.markupData)
            precondition(restored.bounds == markup.bounds)
            precondition(reopened.originalPNG == original)
            do {
                _ = try ScreenshotRaster(pngData: Data("not a PNG".utf8))
                preconditionFailure("Reject corrupt images")
            } catch { }
            print("PASS: capture arguments, original preservation, Retina-sized export, orientation, layer compositing and PaperKit serialization")
            return
        }
        #endif
        fatalError("These tests require macOS 26 and an SDK exposing PaperKit; do not count this as a native pass.")
    }

    @MainActor static func close(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.025 &&
            abs(a.greenComponent - b.greenComponent) < 0.025 &&
            abs(a.blueComponent - b.blueComponent) < 0.025 &&
            abs(a.alphaComponent - b.alphaComponent) < 0.025
    }
}
