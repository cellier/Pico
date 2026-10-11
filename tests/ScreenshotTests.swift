import AppKit
import Carbon

@main struct ScreenshotTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("previous content", forType: .string)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 16, height: 12)); image.addRepresentation(bitmap)
        precondition(ScreenshotController.copyCapturedImage(image, to: clipboard))
        precondition(clipboard.data(forType: .png) != nil && clipboard.data(forType: .tiff) != nil)
        let pasted = NSBitmapImageRep(data: clipboard.data(forType: .png)!)!
        precondition(pasted.pixelsWide == 32 && pasted.pixelsHigh == 24, "Preserve screenshot pixel resolution")
        precondition(NSImage(pasteboard: clipboard) != nil && clipboard.string(forType: .string) == nil)
        print("PASS: captured image is immediately pasteable as PNG and TIFF, without editor action")
        // Hold the real shortcut to check that conflicts are reported, never stolen.
        var occupied: EventHotKeyRef?
        let held = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(optionKey), EventHotKeyID(signature: 0x54535453, id: 9), GetApplicationEventTarget(), 0, &occupied)
        let controller = ScreenshotController()
        precondition(controller.register() != noErr, "An occupied shortcut must report a conflict")
        controller.stop()
        if let occupied { UnregisterEventHotKey(occupied) }
        if held == noErr {
            precondition(controller.register() == noErr)
            precondition(controller.register() == noErr, "Registration is idempotent")
            controller.stop()
            precondition(controller.register() == noErr, "Stopping releases the shortcut")
            controller.stop()
        }
        var preparations = 0
        var completions = 0
        controller.finished = { completions += 1 }
        controller.prepare = { preparations += 1 }
        controller.start(); controller.start()
        precondition(preparations == 1, "Ignore repeated triggers during startup")
        precondition(controller.isSelecting, "Keep panel dismissal suspended during capture")
        controller.stop() // Cancel before the native selector launches.
        precondition(!controller.isSelecting && completions == 1, "Restore dismissal on cancellation exactly once")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        precondition(ScreenshotController.arguments.contains("-i"))
        precondition(ScreenshotController.arguments.contains("-c"))
        precondition(!ScreenshotController.arguments.contains("-x"), "Keep the shutter sound")
        print("PASS: shortcut conflict/release, duplicate trigger, pending cancellation, interactive clipboard capture with sound")
    }
}
