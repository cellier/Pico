import Foundation

/// Run in the isolated PicoChatWindowFixture bundle with its local fake worker.
/// It never opens a provider connection or reads the user's application data.
@main struct PicoChatWindowTests {
    @MainActor static func main() throws {
        precondition(Bundle.main.object(forInfoDictionaryKey: "PicoChatWindowFixture") as? Bool == true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicoChatWindowTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = UUID()
        var seeded = (0..<10000).map { Message(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Seed message \($0): 中文 mixed English history.") }
        let historicalFile = Artifact(path: "historical-report.md", name: "historical-report.md")
        seeded[5001].artifacts = [historicalFile]
        let unassigned = Artifact(path: "unassigned.dat", name: "unassigned.dat")
        let messageJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(seeded))
        let snapshot: [String: Any] = ["conversationID": identity.uuidString, "messages": messageJSON,
                                       "artifacts": [["path": historicalFile.path, "name": historicalFile.name],
                                                     ["path": unassigned.path, "name": unassigned.name]], "status": "idle"]
        let file = root.appendingPathComponent("chat.json")
        let initialData = try JSONSerialization.data(withJSONObject: snapshot)
        try initialData.write(to: file, options: .atomic)
        let chat = PicoChatStore(dataDir: root)
        precondition(chat.totalMessageCount == 10000 && chat.messages.count == 80)
        precondition(chat.messages.map(\.id) == seeded.suffix(80).map(\.id))
        precondition(chat.hasEarlierMessages && !chat.hasLaterMessages)
        precondition(chat.unassignedArtifacts.map(\.path) == [unassigned.path])
        let earliest = chat.searchMessages("Seed message 0:")
        precondition(earliest.map(\.id) == [seeded[0].id])
        precondition(chat.searchMessages(historicalFile.name).map(\.id) == [seeded[5001].id])
        precondition(chat.searchMessages("Seed message").count == 200)
        for _ in 0..<20 {
            let previous = Set(chat.messages.map(\.id))
            let revision = chat.windowRevision
            chat.loadEarlier()
            precondition(chat.messages.count <= 240 && chat.windowRevision > revision)
            precondition(!previous.intersection(chat.messages.map(\.id)).isEmpty, "Paging needs overlapping IDs to preserve a reading anchor")
        }
        precondition(chat.hasEarlierMessages && chat.hasLaterMessages)
        for _ in 0..<20 { chat.loadLater(); precondition(chat.messages.count <= 240) }
        precondition(!chat.hasLaterMessages && chat.messages.last?.id == seeded.last?.id)
        chat.showLatest()
        precondition(chat.messages.map(\.id) == seeded.suffix(80).map(\.id))
        let afterPaging = try Data(contentsOf: file)
        precondition(afterPaging == initialData, "Paging and search must not rewrite or truncate the saved transcript")
        print("PASS 10,000 messages: initial80,20 earlier/later pages<=240 with overlap, full-history search, historical files, unchanged JSON")

        func wait(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(predicate(), "The isolated worker did not reach its expected state")
        }
        precondition(chat.send("hold while reading"))
        let responseID = chat.responseMessageID!
        wait { !chat.pendingArtifacts.isEmpty }
        precondition(chat.unassignedArtifacts.map(\.path) == [unassigned.path], "Pending output must not appear in unassigned files")
        for _ in 0..<20 { chat.loadEarlier() }
        let readingIDs = chat.messages.map(\.id)
        let readingRevision = chat.windowRevision
        chat.setFollowsLatest(true) // The older page's bottom is not the real end.
        try Data().write(to: root.appendingPathComponent("release-worker"))
        wait { !chat.isRunning }
        precondition(chat.messages.map(\.id) == readingIDs && chat.windowRevision == readingRevision,
                     "A background answer must preserve the exact page being read")
        precondition(chat.totalMessageCount == 10002 && chat.hasLaterMessages)
        precondition(chat.unassignedArtifacts.map(\.path) == [unassigned.path], "Completed output stays with its reply after cache invalidation")
        let outputReply = chat.searchMessages("window-fixture-output.md")
        precondition(outputReply.count == 1 && outputReply[0].role == "assistant")
        precondition(outputReply[0].id == responseID && chat.responseMessageID == nil)
        precondition(outputReply[0].artifacts?.map(\.name) == ["window-fixture-output.md"])

        chat.showLatest()
        let oldTail = chat.messages.map(\.id)
        precondition(oldTail.count == 80 && !chat.hasLaterMessages && oldTail.last == outputReply[0].id)
        precondition(chat.searchMessages("fresh cache update").isEmpty)
        precondition(chat.send("fresh cache update"))
        precondition(chat.messages.count == 80 && chat.messages.last?.text == "fresh cache update", "Local sends reveal latest immediately")
        wait { !chat.isRunning }
        precondition(chat.messages.count == 80 && !chat.hasLaterMessages && chat.totalMessageCount == 10004)
        precondition(Array(chat.messages.prefix(78).map(\.id)) == Array(oldTail.suffix(78)), "Tail append keeps stable IDs while evicting only the oldest rows")
        precondition(chat.searchMessages("fresh cache update").count == 2, "A previously cached empty search must update after appends")
        precondition(chat.searchMessages("Seed message 0:").map(\.id) == [seeded[0].id])
        let durable = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let durableMessages = durable["messages"] as! [[String: Any]]
        precondition(durableMessages.count == 10004)
        precondition(durableMessages.prefix(10000).map { ($0["id"] as! String).lowercased() } == seeded.map { $0.id.uuidString.lowercased() })
        let reloaded = PicoChatStore(dataDir: root)
        precondition(reloaded.totalMessageCount == 10004 && reloaded.messages.map(\.id) == chat.messages.map(\.id))
        precondition(reloaded.searchMessages(historicalFile.name).map(\.id) == [seeded[5001].id])
        precondition(reloaded.searchMessages("window-fixture-output.md")[0].id == outputReply[0].id)
        print("PASS incoming-answer reading anchors, later flag, immediate local send, constant80 tail, derived-cache invalidation, full durable IDs and per-reply files after reload")
    }
}
