import Foundation

@main struct PicoChatProcessTests {
    @MainActor static func main() throws {
        precondition(Bundle.main.object(forInfoDictionaryKey: "PicoFakeWorkerTest") as? Bool == true,
                     "Run only inside the isolated no-model fixture bundle.")
        let tasks = TaskStore()
        let chat = PicoChatStore(dataDir: tasks.dataDir, taskStore: tasks)
        func wait(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(predicate(), "The native worker lifecycle did not reach its expected state")
        }
        precondition(chat.send("normal fixture"))
        let firstLiveID = chat.responseMessageID!
        wait { chat.approval != nil }
        precondition(chat.stream.hasPrefix("First "))
        precondition(chat.pendingArtifacts.map(\.name) == ["normal-fixture.md"])
        precondition(chat.messages.last?.role == "user", "The live output must not be attached to an earlier reply")
        precondition(chat.approval?.actionHash == "exact-payload-hash")
        chat.decide(approve: true)
        wait { !chat.isRunning }
        precondition(chat.status == "idle" && chat.messages.last?.text == "Final fixture result")
        precondition(chat.stream.isEmpty && chat.approval == nil)
        let firstReply = chat.messages.last!
        precondition(firstReply.id == firstLiveID && chat.responseMessageID == nil,
                     "The completed message must retain its streaming row owner ID")
        precondition(firstReply.artifacts?.map(\.name) == ["normal-fixture.md"])
        precondition(chat.pendingArtifacts.isEmpty)
        precondition(tasks.tasks.count == 1 && tasks.tasks[0].status == "pending")
        precondition(tasks.tasks[0].sourceTaskID == chat.conversationID)

        precondition(chat.send("error fixture"))
        let errorLiveID = chat.responseMessageID!
        wait { !chat.isRunning }
        precondition(chat.status == "error" && chat.error == "Deliberate fixture error")
        precondition(chat.messages.last?.text == "First second")
        precondition(chat.messages.last?.id == errorLiveID && chat.responseMessageID == nil)
        precondition(chat.messages.last?.artifacts?.map(\.name) == ["error-fixture.md"])
        precondition(chat.messages.first(where: { $0.id == firstReply.id })?.artifacts?.map(\.name) == ["normal-fixture.md"],
                     "A later turn must not move an earlier output")

        precondition(chat.send("stop fixture"))
        let stoppedLiveID = chat.responseMessageID!
        wait { !chat.stream.isEmpty }
        chat.stop()
        precondition(!chat.isRunning && chat.status == "paused" && chat.approval == nil)
        precondition(chat.messages.last?.text.hasPrefix("First ") == true)
        precondition(chat.messages.last?.id == stoppedLiveID && chat.responseMessageID == nil)
        precondition(chat.messages.last?.artifacts?.map(\.name) == ["stop-fixture.md"])
        let userCount = chat.messages.filter { $0.role == "user" }.count
        chat.retry()
        let retryLiveID = chat.responseMessageID!
        precondition(retryLiveID != stoppedLiveID)
        wait { chat.isRunning && !chat.stream.isEmpty }
        chat.stop()
        precondition(chat.messages.last?.id == retryLiveID && chat.responseMessageID == nil)
        precondition(chat.messages.filter { $0.role == "user" }.count == userCount)
        precondition(chat.messages.suffix(2).allSatisfy { $0.role == "assistant" && $0.artifacts?.count == 1 })
        precondition(tasks.tasks.count == 1)

        precondition(chat.send("artifact only fixture"))
        let artifactOnlyLiveID = chat.responseMessageID!
        wait { !chat.isRunning }
        precondition(chat.messages.last?.role == "assistant" && chat.messages.last?.text == "")
        precondition(chat.messages.last?.id == artifactOnlyLiveID && chat.responseMessageID == nil)
        precondition(chat.messages.last?.artifacts?.map(\.name) == ["artifact-only-fixture.md"])
        precondition(chat.send("abrupt fixture"))
        let abruptLiveID = chat.responseMessageID!
        wait { !chat.isRunning }
        precondition(chat.status == "error")
        precondition(chat.messages.last?.id == abruptLiveID && chat.responseMessageID == nil)
        precondition(chat.messages.last?.artifacts?.map(\.name) == ["abrupt-fixture.md"])
        precondition(chat.pendingArtifacts.isEmpty && chat.unassignedArtifacts.isEmpty)
        let reloaded = PicoChatStore(dataDir: tasks.dataDir)
        precondition(reloaded.messages.map(\.id) == chat.messages.map(\.id))
        precondition(reloaded.messages.first(where: { $0.id == firstReply.id })?.artifacts?.map(\.name) == ["normal-fixture.md"])
        precondition(reloaded.messages.last?.artifacts?.map(\.name) == ["abrupt-fixture.md"])
        precondition(reloaded.searchMessages("normal-fixture.md").map(\.id) == [firstReply.id])
        print("PASS: native pipe streaming, stable live-to-committed IDs for done/error/stop/retry/artifact-only/abrupt exits, per-reply outputs, repeat-save deduplication, durable associations, exact approval, final flush and retry without duplicate user messages")
    }
}
