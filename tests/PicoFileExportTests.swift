import AppKit
import Foundation

/// Use private directories and a private pasteboard to verify durable output
/// delivery without changing the user's Desktop, files or clipboard.
@main struct PicoFileExportTests {
    @MainActor static func main() throws {
        let original = ProcessInfo.processInfo.environment
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("pico-file-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let data = fixture.appendingPathComponent("data")
        setenv("TELOS_DATA_DIR", data.path, 1)
        unsetenv("PICO_FILES_DIR")
        defer {
            try? FileManager.default.removeItem(at: fixture)
            for key in ["TELOS_DATA_DIR", "PICO_FILES_DIR"] {
                if let value = original[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let root = PicoFileStorage.directory(dataDirectory: data)
        precondition(root.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(data.standardizedFileURL.resolvingSymlinksInPath().path + "/"), "Tests must not use the real generated files folder")
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let image1 = try ScreenshotEditor.outputURL(for: date)
        precondition(image1.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("Screenshots").standardizedFileURL.path)
        try Data("first screenshot".utf8).write(to: image1, options: .withoutOverwriting)
        let image2 = try ScreenshotEditor.outputURL(for: date)
        precondition(image2 != image1 && image2.lastPathComponent.hasSuffix(" 2.png"))
        let preservedImage = try Data(contentsOf: image1)
        precondition(preservedImage == Data("first screenshot".utf8), "A same-second screenshot must never overwrite the existing image")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let movie1 = fixture.appendingPathComponent("capture-1.mp4")
        try Data("first recording".utf8).write(to: movie1)
        let saved1 = try ScreenRecordingController.deliver(movie1, startedAt: date, error: nil, to: pasteboard)
        precondition(saved1.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("Recordings").standardizedFileURL.path)
        precondition(!FileManager.default.fileExists(atPath: movie1.path))
        let savedMovie = try Data(contentsOf: saved1)
        precondition(savedMovie == Data("first recording".utf8))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        precondition(urls == [saved1], "The saved recording must remain immediately available to paste")

        let movie2 = fixture.appendingPathComponent("capture-2.mp4")
        try Data("second recording".utf8).write(to: movie2)
        let saved2 = try ScreenRecordingController.deliver(movie2, startedAt: date, error: nil, to: pasteboard)
        precondition(saved2 != saved1 && saved2.lastPathComponent.hasSuffix(" 2.mp4"))
        let preservedMovie = try Data(contentsOf: saved1)
        precondition(preservedMovie == Data("first recording".utf8), "Recording collisions must not overwrite the earlier movie")

        let blocked = fixture.appendingPathComponent("blocked-root")
        try Data("existing file".utf8).write(to: blocked)
        setenv("PICO_FILES_DIR", blocked.path, 1)
        let unsaved = fixture.appendingPathComponent("capture-unsaved.mp4")
        try Data("keep this recording".utf8).write(to: unsaved)
        var failed = false
        do { _ = try ScreenRecordingController.deliver(unsaved, startedAt: date, error: nil, to: pasteboard) }
        catch { failed = true }
        precondition(failed && FileManager.default.fileExists(atPath: unsaved.path), "An unavailable output folder must preserve the temporary recording")
        let preservedBlocker = try Data(contentsOf: blocked)
        precondition(preservedBlocker == Data("existing file".utf8))
        print("PASS screenshot and recording destinations, collision preservation, private clipboard delivery and failed-folder recovery")
    }
}
