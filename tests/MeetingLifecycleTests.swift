import Foundation
import AVFoundation
final class FakeMeetingCapture: MeetingAudioCapturing {
    var onBuffer: ((AVAudioPCMBuffer, SpeakerSource, Double) -> Void)?
    var onActivity: (() -> Void)?
    var onError: ((String) -> Void)?
    var starts = 0, stops = 0
    func start(pid: pid_t, elapsed: Double) async throws { starts += 1 }
    func stop() async { stops += 1 }
}
final class FakeMeetingSpeech: MeetingTranscribing {
    var onSegment: ((TranscriptSegment) async -> Void)?
    var onError: ((String) -> Void)?
    func start(localeID: String) async throws {}
    func append(_ buffer: AVAudioPCMBuffer, source: SpeakerSource, time: Double) {}
    func finish() async {
        await onSegment?(.init(startTime: 10, endTime: 14, speakerSource: .others, text: "The final seconds are retained.", isFinal: true))
    }
}
@main struct MeetingLifecycleTests {
    @MainActor static func main() async throws {
        let store = TaskStore(); store.tasks = []
        let audio = FakeMeetingCapture(), speech = FakeMeetingSpeech()
        let manager = MeetingSessionManager(store: store, makeSpeech: { speech }, makeCapture: { audio })
        manager.enabled = true
        let now = Date()
        let joined = MeetingObservation(signal: .joined, pid: 123, title: "Test Meeting")
        manager.preparing = true
        await manager.receive(joined, at: now.addingTimeInterval(-10))
        await manager.receive(joined, at: now.addingTimeInterval(-5))
        precondition(store.tasks.isEmpty && audio.starts == 0, "Permission/model setup must not race meeting startup")
        manager.preparing = false
        await manager.receive(joined, at: now)
        await manager.receive(joined, at: now.addingTimeInterval(5))
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(store.tasks.count == 1 && store.tasks[0].status == "running" && audio.starts == 1)
        manager.enable()
        precondition(!manager.preparing, "Setting up access during capture must not start a second speech engine")
        let id = store.tasks[0].meetingID!
        await manager.receive(joined, at: now.addingTimeInterval(9))
        precondition(store.tasks.count == 1)
        await speech.onSegment?(.init(startTime: 1, endTime: 4, speakerSource: .me, text: "I will send the deck.", isFinal: true))
        await manager.receive(.init(signal: .absent), at: now.addingTimeInterval(10))
        await manager.receive(.init(signal: .unknown), at: now.addingTimeInterval(11))
        precondition(audio.stops == 0)
        await manager.receive(.init(signal: .absent), at: now.addingTimeInterval(20))
        await manager.receive(.init(signal: .absent), at: now.addingTimeInterval(51))
        precondition(audio.stops == 1 && store.tasks[0].status == "ready")
        precondition(store.tasks[0].completedAt == nil, "Ending recording must keep the task on the home page")
        precondition(store.meetings[id]!.transcript.count == 2)
        store.complete(store.tasks[0].id)
        precondition(store.tasks[0].status == "completed", "Only user completion archives the task")
        let restored = try MeetingRepository(directory: store.dataDir.appendingPathComponent("meetings")).load().first!
        precondition(restored.status == .completed && restored.transcript.count == 2)
        precondition(store.tasks.count == 1, "No automatic todo creation")
        await manager.shutdown()
        let interruptedStore = TaskStore(); interruptedStore.tasks = []
        let secondAudio = FakeMeetingCapture(), secondSpeech = FakeMeetingSpeech()
        let interruptedManager = MeetingSessionManager(store: interruptedStore, makeSpeech: { secondSpeech }, makeCapture: { secondAudio })
        interruptedManager.enabled = true
        await interruptedManager.receive(joined, at: now)
        await interruptedManager.receive(joined, at: now.addingTimeInterval(5))
        await interruptedManager.shutdown()
        precondition(interruptedStore.tasks.count == 1 && interruptedStore.tasks[0].status == "ready")
        let interruptedID = interruptedStore.tasks[0].meetingID!
        precondition(interruptedStore.meetings[interruptedID]?.status == .interrupted)
        await interruptedManager.receive(joined, at: now.addingTimeInterval(15))
        precondition(interruptedStore.tasks.count == 1, "Shutdown prevents a late detection from restarting capture")
        let recoveredStore = TaskStore(); recoveredStore.tasks = store.tasks
        let recovered = MeetingSessionManager(store: recoveredStore)
        try Data("broken fixture".utf8).write(to: store.dataDir.appendingPathComponent("meetings/broken.json"))
        recovered.start()
        precondition(recoveredStore.meetings[id]?.transcript.count == 2)
        precondition(recoveredStore.tasks.first { $0.meetingID == id }?.status == "completed", "Restart must preserve manual archive")
        precondition(recoveredStore.meetings[interruptedID]?.status == .interrupted)
        precondition(!recovered.setupMessage.isEmpty, "Report corrupted file without hiding other meetings")
        await recovered.shutdown()
        print("PASS: shutdown during startup, restart preservation, late detection blocked, corrupt-file isolation")
        print("PASS: simulated meeting detection → one task → live transcript → end debounce → final buffer → persisted completed meeting, no automatic todos")
    }
}
