import AppKit
import SwiftUI

/// Files are paged independently of message chunks. A single media operation
/// can create thousands of files; none may become an unbounded responder tree.
enum PicoFileListPage {
    static let size = 24

    static func range(count: Int, page: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let index = min(max(0, page), (count - 1) / size)
        let lower = index * size
        return lower..<min(count, lower + size)
    }
}

struct PicoArtifactList: View {
    let artifacts: [Artifact]
    let folderURL: URL
    let openArtifact: (Artifact) -> Void
    var identifierPrefix = "chatArtifact-"
    @State private var page = 0

    var body: some View {
        let range = PicoFileListPage.range(count: artifacts.count, page: page)
        VStack(alignment: .leading, spacing: 6) {
            // Slice before ForEach: a lazy parent cannot bound children inside
            // one message row's ordinary VStack.
            ForEach(artifacts[range]) { file in
                Button { openArtifact(file) } label: {
                    Label(file.name, systemImage: "doc").font(.system(size: 13)).lineLimit(1)
                }
                .buttonStyle(HoverButtonStyle())
                .accessibilityIdentifier(identifierPrefix + file.path)
            }
            if artifacts.count > PicoFileListPage.size {
                HStack(spacing: 12) {
                    Button {
                        page = max(0, range.lowerBound / PicoFileListPage.size - 1)
                    } label: { Image(systemName: "chevron.left") }
                        .disabled(range.lowerBound == 0)
                        .accessibilityLabel("Previous files")
                        .accessibilityIdentifier("artifactPreviousPage")
                    Text("\(range.lowerBound + 1)–\(range.upperBound) of \(artifacts.count)")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button {
                        page = range.lowerBound / PicoFileListPage.size + 1
                    } label: { Image(systemName: "chevron.right") }
                        .disabled(range.upperBound == artifacts.count)
                        .accessibilityLabel("Next files")
                        .accessibilityIdentifier("artifactNextPage")
                }
                .font(.system(size: 12)).buttonStyle(HoverButtonStyle())
                Button {
                    NSWorkspace.shared.open(folderURL)
                } label: {
                    Label("Show all files in Finder", systemImage: "folder")
                        .font(.system(size: 12))
                }.buttonStyle(HoverButtonStyle())
                    .accessibilityIdentifier("artifactFolder")
            }
        }
    }
}
