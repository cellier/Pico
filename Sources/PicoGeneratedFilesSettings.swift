import AppKit
import SwiftUI

struct PicoGeneratedFilesSettingsView: View {
    let dataDirectory: URL
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generated Files").font(.system(size: 14, weight: .medium))
            Text("Files created by Pico are saved here.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(PicoFileStorage.displayPath(PicoFileStorage.directory(dataDirectory: dataDirectory)))
                .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                .accessibilityIdentifier("generatedFilesPath")
            Button {
                do {
                    let folder = try PicoFileStorage.prepare(dataDirectory: dataDirectory)
                    guard NSWorkspace.shared.open(folder) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    error = nil
                } catch {
                    self.error = "Could not open the files folder. " + error.localizedDescription
                }
            } label: {
                Label("Open Files Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered).nativeHoverFeedback()
            .accessibilityIdentifier("openGeneratedFilesFolder")
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
    }
}
