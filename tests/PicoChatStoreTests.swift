import Foundation

/// Run with the shared model fixtures, PicoChatStore and BundledRuntime.
/// The command-line test bundle has no interpreter configured, so no model runs.
@main struct PicoChatStoreTests {
    @MainActor static func main() throws {
        precondition(Bundle.main.object(forInfoDictionaryKey: "TelosPython") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicoChatTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testPagingPredecessor(in: root.appendingPathComponent("paging-predecessor"))
        let store = PicoChatStore(dataDir: root)
        precondition(!store.send("  "))
        for index in 0..<90 { precondition(store.send("Message \(index)")) }
        precondition(store.messages.count == 80 && store.hasEarlierMessages)
        precondition(store.searchMessages("Message 0").count == 1)
        store.loadEarlier()
        precondition(store.messages.count == 90 && !store.hasEarlierMessages)
        let identity = store.conversationID
        let reopened = PicoChatStore(dataDir: root)
        precondition(reopened.conversationID == identity && reopened.messages.count == 80)
        reopened.loadEarlier()
        precondition(reopened.messages.first?.text == "Message 0")

        let savedBeforeNavigation = try Data(contentsOf: root.appendingPathComponent("chat.json"))
        let earliestID = reopened.messages[0].id
        reopened.showLatest()
        reopened.showMessage(containing: earliestID)
        precondition(reopened.messages.count <= 80 && reopened.messages.first?.id == earliestID && reopened.hasLaterMessages)
        let readingIDs = reopened.messages.map(\.id)
        reopened.showMessage(containing: UUID())
        precondition(reopened.messages.map(\.id) == readingIDs)
        let savedAfterNavigation = try Data(contentsOf: root.appendingPathComponent("chat.json"))
        precondition(savedAfterNavigation == savedBeforeNavigation, "Restoring a reading page must not alter the saved conversation")
        reopened.showLatest()

        let attachment = root.appendingPathComponent("source.txt")
        try Data("Local attachment".utf8).write(to: attachment)
        precondition(reopened.send("Read this", files: [ComposerFile(name: "source.txt", path: attachment.path)]))
        let saved = reopened.messages.last!.files!.first!
        let copy = reopened.attachmentURL(saved)
        precondition(copy.path.hasPrefix(reopened.workspace.path))
        let copiedText = try String(contentsOf: copy, encoding: .utf8)
        precondition(copiedText == "Local attachment")
        precondition(reopened.messages.last!.attachmentPrompt!.contains(saved.path))
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks.json").path))
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tasks").path))

        // A result saved immediately before app termination is recovered once.
        let snapshot = root.appendingPathComponent("chat.json")
        var interrupted = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshot)) as! [String: Any]
        let runID = UUID()
        interrupted["activeRunID"] = runID.uuidString; interrupted["status"] = "working"
        interrupted["pendingArtifacts"] = [["path": "recovered.pdf", "name": "recovered.pdf"]]
        try JSONSerialization.data(withJSONObject: interrupted).write(to: snapshot)
        let checkpoint = root.appendingPathComponent("chats/\(identity.uuidString.lowercased())/last-turn.json")
        try JSONSerialization.data(withJSONObject: ["run_id": runID.uuidString,
                                                    "event": ["type": "done", "text": "Recovered reply", "status": "ready", "summary": "Ready"]]).write(to: checkpoint)
        let recovered = PicoChatStore(dataDir: root)
        precondition(recovered.messages.last?.text == "Recovered reply")
        precondition(recovered.messages.last?.id == runID && recovered.responseMessageID == nil,
                     "Recovery must retain the interrupted stream's run identity")
        precondition(recovered.messages.last?.artifacts?.map(\.name) == ["recovered.pdf"])
        precondition(recovered.pendingArtifacts.isEmpty && recovered.unassignedArtifacts.isEmpty)
        let recoveredAgain = PicoChatStore(dataDir: root)
        precondition(recoveredAgain.searchMessages("Recovered reply").count == 1)
        precondition(recoveredAgain.searchMessages("recovered.pdf").count == 1)
        precondition(recoveredAgain.messages.last?.id == recovered.messages.last?.id)

        // Older versions kept one floating file list. Migrate only exact,
        // unambiguous assistant references, never attach everything to latest.
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let first = Message(role: "assistant", text: "Created [the document](ten-design-principles.md). Also discussed shared.csv.")
        let followUp = Message(role: "assistant", text: "Here is the later answer. We also discussed shared.csv, and not-report.md is unrelated.")
        let legacyMessages = [Message(role: "user", text: "Create a file"), first,
                              Message(role: "user", text: "Continue the conversation"), followUp]
        let legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyMessages))
        let legacySnapshot: [String: Any] = ["conversationID": UUID().uuidString, "messages": legacyJSON, "status": "idle",
                                             "artifacts": [["path": "ten-design-principles.md", "name": "ten-design-principles.md"],
                                                           ["path": "shared.csv", "name": "shared.csv"],
                                                           ["path": "report.md", "name": "report.md"]]]
        let legacyURL = legacyRoot.appendingPathComponent("chat.json")
        try JSONSerialization.data(withJSONObject: legacySnapshot).write(to: legacyURL)
        let migrated = PicoChatStore(dataDir: legacyRoot)
        precondition(migrated.messages.first(where: { $0.id == first.id })?.artifacts?.map(\.name) == ["ten-design-principles.md"])
        precondition(migrated.messages.last?.id == followUp.id && migrated.messages.last?.artifacts == nil)
        precondition(Set(migrated.unassignedArtifacts.map(\.name)) == Set(["shared.csv", "report.md"]))
        precondition(migrated.artifactURL(migrated.artifacts[0]).path.hasPrefix(migrated.workspace.path))
        let migratedAgain = PicoChatStore(dataDir: legacyRoot)
        precondition(migratedAgain.messages.first(where: { $0.id == first.id })?.artifacts?.count == 1)

        // A crash with generated files but no terminal checkpoint preserves an
        // artifact-only assistant response in its original turn, exactly once.
        var interruptedLegacy = legacySnapshot
        interruptedLegacy["activeRunID"] = UUID().uuidString
        interruptedLegacy["pendingArtifacts"] = [["path": "unfinished.txt", "name": "unfinished.txt"]]
        try JSONSerialization.data(withJSONObject: interruptedLegacy).write(to: legacyURL)
        let paused = PicoChatStore(dataDir: legacyRoot)
        precondition(paused.status == "paused" && paused.pendingArtifacts.isEmpty)
        precondition(paused.messages.last?.role == "assistant" && paused.messages.last?.text == "")
        precondition(paused.messages.last?.artifacts?.map(\.name) == ["unfinished.txt"])
        let pausedAgain = PicoChatStore(dataDir: legacyRoot)
        precondition(pausedAgain.messages.count == paused.messages.count)
        precondition(pausedAgain.messages.last?.id == paused.messages.last?.id)

        // Disk failure must retain the draft rather than silently losing a send.
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        reopened.draft = "Keep my draft"
        precondition(!reopened.send() && reopened.draft == "Keep my draft")
        precondition(reopened.messages.last!.text == "Read this")
        print("PASS: independent durable chat, history paging/search, safe attachments, per-message legacy output migration, pending-output recovery exactly once, ambiguous-output preservation and failed-save draft preservation")
    }

    @MainActor private static func testPagingPredecessor(in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_792_747_200)
        let messages = (0..<320).map {
            Message(role: "user", text: "History \($0)", date: base.addingTimeInterval(Double($0) * 30))
        }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages))
        let snapshot: [String: Any] = ["conversationID": UUID().uuidString, "messages": json,
                                       "status": "idle", "artifacts": []]
        let url = root.appendingPathComponent("chat.json")
        let saved = try JSONSerialization.data(withJSONObject: snapshot)
        try saved.write(to: url)
        let store = PicoChatStore(dataDir: root)
        precondition(store.messages.first?.id == messages[240].id && store.precedingVisibleMessage?.id == messages[239].id)
        let firstRevision = store.windowRevision
        store.loadEarlier()
        precondition(store.messages.first?.id == messages[160].id && store.precedingVisibleMessage?.id == messages[159].id)
        precondition(store.windowRevision > firstRevision, "Changing a page must invalidate cached segment placements")
        store.loadEarlier()
        precondition(store.messages.first?.id == messages[80].id && store.precedingVisibleMessage?.id == messages[79].id)
        store.loadEarlier()
        precondition(store.messages.first?.id == messages[0].id && store.precedingVisibleMessage == nil,
                     "Only the real transcript beginning has no predecessor")
        store.loadLater()
        precondition(store.messages.first?.id == messages[80].id && store.precedingVisibleMessage?.id == messages[79].id)
        store.showMessage(containing: messages[160].id)
        precondition(store.messages.first?.id == messages[120].id && store.precedingVisibleMessage?.id == messages[119].id)
        let afterNavigation = try Data(contentsOf: url)
        precondition(afterNavigation == saved, "Reading timestamp context must not rewrite the conversation")

        // Receiving a notice while reading older history leaves its predecessor
        // unchanged. Following latest then advances both window and predecessor.
        let firstVisible = store.messages.first?.id
        precondition(store.appendProactiveNotice(id: UUID(), text: "A local update", date: base.addingTimeInterval(320 * 30)))
        precondition(store.messages.first?.id == firstVisible && store.precedingVisibleMessage?.id == messages[119].id)
        store.showLatest()
        precondition(store.messages.first?.id == messages[241].id && store.precedingVisibleMessage?.id == messages[240].id)
        let latestRevision = store.windowRevision
        precondition(store.appendProactiveNotice(id: UUID(), text: "Another local update", date: base.addingTimeInterval(321 * 30)))
        precondition(store.messages.first?.id == messages[242].id && store.precedingVisibleMessage?.id == messages[241].id)
        precondition(store.windowRevision > latestRevision, "Sliding the latest page must invalidate its timestamp boundary")
        print("PASS: transcript predecessors stay correct across earlier/later paging, focused history, parked history and latest-page appends")
    }
}
