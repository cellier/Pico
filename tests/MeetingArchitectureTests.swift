import Foundation
import AVFoundation

@main struct MeetingArchitectureTests {
    @MainActor static func main() async throws {
        try await PicoRealtime.verifyResponseLifecycle()
        try PicoMeetingController.verifyNaturalContinuation()
        try PicoMeetingTests.main()
        try await MeetingLifecycleTests.main()
        try await MeetingAudioBoundaryTests.run()
        try MeetingUnderstandingEvidenceTests.run()
        let proxyInterval = MeetingAgentAudioInterval(start: 0, end: 139.968665)
        let boundaryAudio = TranscriptSegment(startTime: 139.925310, endTime: 141.685310, speakerSource: .me, text: "普通 Zoom 语音桥和。", isFinal: true)
        let uncertain = MeetingAudioAttribution.classified(boundaryAudio, agentIntervals: [proxyInterval])
        precondition(uncertain.excludedFromEvidence == true && uncertain.text == boundaryAudio.text && uncertain.id == boundaryAudio.id, "cross-boundary agent residue must be preserved but excluded as owner evidence")
        let ownerAudio = TranscriptSegment(startTime: 272.845310, endTime: 273.805310, speakerSource: .me, text: "现在由碧星接管。", isFinal: true)
        precondition(MeetingAudioAttribution.classified(ownerAudio, agentIntervals: [proxyInterval]).excludedFromEvidence != true)
        var otherAudio = boundaryAudio; otherAudio.speakerSource = .others
        precondition(MeetingAudioAttribution.classified(otherAudio, agentIntervals: [proxyInterval]).excludedFromEvidence != true)
        let guardedSession = MeetingSession(title: "Attribution", transcript: [uncertain, ownerAudio], locale: "mixed", processID: 9)
        precondition(!MeetingUnderstanding.verified(TranscriptEvidence(segmentID: uncertain.id, startTime: uncertain.startTime, endTime: uncertain.endTime, text: uncertain.text), in: guardedSession))
        precondition(MeetingUnderstanding.verified(TranscriptEvidence(segmentID: ownerAudio.id, startTime: ownerAudio.startTime, endTime: ownerAudio.endTime, text: ownerAudio.text), in: guardedSession))
        let source = FakeMeetingCapture()
        let hub = MeetingAudioHub(factory: { source })
        let first = hub.lease(), second = hub.lease()
        var firstBuffers = 0, secondBuffers = 0
        first.onBuffer = { _, _, _ in firstBuffers += 1 }
        second.onBuffer = { _, _, _ in secondBuffers += 1 }
        try await first.start(pid: 9, elapsed: 0)
        try await second.start(pid: 9, elapsed: 0)
        precondition(source.starts == 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 10)!
        buffer.frameLength = 10
        hub.setOwnerSpeechEnabled(false)
        source.onBuffer?(buffer, .me, 0.5)
        precondition(firstBuffers == 0 && secondBuffers == 0, "Pico output must never be transcribed as owner speech")
        hub.setOwnerSpeechEnabled(true)
        source.onBuffer?(buffer, .me, 0.6)
        precondition(firstBuffers == 1 && secondBuffers == 1, "takeover restores owner transcription")
        firstBuffers = 0; secondBuffers = 0
        source.onBuffer?(buffer, .others, 1)
        precondition(firstBuffers == 1 && secondBuffers == 1)
        await second.stop(); source.onBuffer?(buffer, .others, 2)
        precondition(firstBuffers == 2 && secondBuffers == 1 && source.stops == 0)
        await first.stop(); await first.stop()
        precondition(source.stops == 1)
        let bridgeStore = TaskStore()
        let ipc = bridgeStore.dataDir.appendingPathComponent("companion-v1")
        try FileManager.default.createDirectory(at: ipc, withIntermediateDirectories: true)
        let flag = ipc.appendingPathComponent("pico-meeting.open")
        try Data("open".utf8).write(to: flag)
        let bridge = CompanionBridge(store: bridgeStore, transcribe: { _, _ in }, cancel: {}, show: { _ in })
        precondition(FileManager.default.fileExists(atPath: flag.path), "cold-start must retain request before handler registration")
        var opened = false; bridge.showMeeting = { opened = true }; bridge.poll()
        precondition(opened && !FileManager.default.fileExists(atPath: flag.path))
        bridge.timer?.invalidate()
        let presentation = PicoMeetingController(dataDir: bridgeStore.dataDir) { _ in }
        presentation.handlePresentationInput("我打断你一下，可以吗？")
        precondition(presentation.presentationPaused, "a polite interruption question must wait for the actual question")
        presentation.handlePresentationInput("嗯，可以啊。")
        precondition(presentation.presentationPaused, "an acknowledgement must not release the interruption hold")
        presentation.handlePresentationInput("你叫什么名字？")
        precondition(!presentation.presentationPaused, "the actual question releases the interruption hold")
        presentation.handlePresentationInput("不要继续，等一下")
        precondition(presentation.presentationPaused, "an explicit pause must win over the substring continue")
        presentation.handlePresentationInput("你是什么？")
        precondition(presentation.presentationPaused, "a question must not release an explicit pause")
        presentation.handlePresentationInput("继续介绍")
        precondition(!presentation.presentationPaused, "an explicit continue releases the pause")
        presentation.handlePresentationInput("我能问一个问题吗？")
        precondition(presentation.presentationPaused, "asking permission to ask is still a hold")
        for phrase in ["行，那你先说到这吧。", "先讲到这里吧", "你不要反复讲", "不要继续，等一下"] {
            presentation.handlePresentationInput("继续介绍")
            presentation.handlePresentationInput(phrase)
            precondition(presentation.presentationPaused, "natural stop intent must pause the actual agenda: \(phrase)")
            presentation.handlePresentationInput("为什么这么做？")
            precondition(presentation.presentationPaused, "answering a question does not revoke an explicit stop")
        }
        presentation.handlePresentationInput("那你说个结尾吧")
        precondition(presentation.presentationConcluded && presentation.presentationPaused)
        presentation.handlePresentationInput("你还有哪些其他想法？")
        precondition(presentation.presentationConcluded && presentation.presentationPaused, "questions after a conclusion must not restart the outline")
        let control = presentation.applyPresentationControl("resume")
        precondition(control.contains("true") && !presentation.presentationConcluded && !presentation.presentationPaused)
        precondition(presentation.applyPresentationControl("takeover").contains("false"), "presentation tools cannot take over a microphone")
        print("PASS: one shared capture, buffer fanout, lease release, one meeting/task, separate agent evidence, lifecycle and presentation regressions")
    }
}
