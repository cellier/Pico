import AppKit
import SwiftUI

/// Metadata only: every paragraph remains reachable, while a realization window
/// bounds the number of selectable native text views, including one huge message.
@MainActor final class PicoTaskDetailTimelineCache: ObservableObject {
    private struct Signature: Equatable {
        let id: UUID
        let role: String
        let text: String
        let date: Date?
        let files: [String]
        let artifacts: [String]
    }
    private var signatures: [Signature] = []
    private var artifactSignatures: [String] = []
    private var cached: [PicoChatTimelineRowDescriptor] = []
    func rows(messages: [Message], artifacts: [Artifact] = []) -> [PicoChatTimelineRowDescriptor] {
        let current = messages.map {
            Signature(id: $0.id, role: $0.role, text: $0.text, date: $0.date,
                      files: ($0.files ?? []).map { $0.name + "\u{0}" + $0.path },
                      artifacts: ($0.artifacts ?? []).map { $0.name + "\u{0}" + $0.path })
        }
        let currentArtifacts = artifacts.map { $0.name + "\u{0}" + $0.path }
        if current != signatures || currentArtifacts != artifactSignatures {
            signatures = current
            artifactSignatures = currentArtifacts
            cached = PicoChatTimelineRows.build(messages: messages)
            // Legacy task outputs were stored on Todo instead of their reply.
            // Project only the final selections onto the latest assistant's final
            // chunk. Existing per-message ownership takes precedence, and the
            // caller supplies no task-level outputs while a run is in progress.
            if let reply = messages.last, reply.role == "assistant",
               let index = cached.lastIndex(where: { $0.ownerMessageID == reply.id && $0.isLast }) {
                let row = cached[index]
                let final = PicoChatTimelineRows.finalArtifacts(text: reply.text, artifacts: artifacts)
                var paths = Set<String>()
                let combined = (row.artifacts + final).filter { paths.insert($0.path).inserted }
                cached[index] = PicoChatTimelineRowDescriptor(
                    id: row.id, ownerMessageID: row.ownerMessageID, kind: row.kind,
                    markdown: row.markdown, text: row.text, fullMessageText: row.fullMessageText,
                    isFirst: row.isFirst, isLast: row.isLast, files: row.files,
                    artifacts: combined, placement: row.placement, inlineParts: row.inlineParts)
            }
        }
        return cached
    }
}

private final class PicoTaskDetailRowFrame {
    var frame: CGRect?
}

struct PicoTaskDetailRowGeometry: ViewModifier {
    let id: String
    let timeline: PicoChatScrollController
    @State private var cache = PicoTaskDetailRowFrame()
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("picoTaskDetailTimeline")) } action: { frame in
            cache.frame = frame
            timeline.record(id: id, frame: frame)
        }
        .onAppear { if let frame = cache.frame { timeline.record(id: id, frame: frame) } }
        .onDisappear { timeline.remove(id: id) }
    }
}

/// Task history uses the same renderer as Chat. The enclosing realization window
/// still bounds selectable text, while the shared row owns bubble runs, timestamps,
/// Markdown, attachments, final files and complete-message copying.
struct PicoTaskDetailTimelineRow: View {
    let row: PicoChatTimelineRowDescriptor
    let openAttachment: (ComposerFile) -> Void
    let openArtifact: (Artifact) -> Void
    let artifactsFolderURL: URL

    var body: some View {
        PicoChatTimelineRow(row: row,
                            openAttachment: openAttachment,
                            openArtifact: openArtifact,
                            artifactsFolderURL: artifactsFolderURL)
    }
}
