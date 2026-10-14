import Foundation
import AVFoundation
@main struct PicoMeetingTests {
    @MainActor static func main() throws {
        try PicoMeetingController.verifyControlledLifecycle()
        let protocolClient = PicoRealtime()
        var failures: [String] = [], recoveries: [String] = [], sent: [[String: Any]] = []
        protocolClient.onError = { failures.append($0) }; protocolClient.onRecoverableError = { recoveries.append($0) }
        protocolClient.onSentEvent = { sent.append($0) }
        protocolClient.injectDiagnosticEvent(["type": "session.updated"])
        precondition(protocolClient.requestSpokenTurn("one"))
        precondition(!protocolClient.requestSpokenTurn("duplicate"), "do not overlap response.create")
        protocolClient.injectDiagnosticEvent(["type": "error", "error": ["type": "invalid_request_error", "code": "invalid_value", "message": "Cannot create response while another response is in progress."]])
        precondition(failures.isEmpty && recoveries.isEmpty)
        protocolClient.injectDiagnosticEvent(["type": "error", "error": ["code": "response_idle_timeout"]])
        precondition(recoveries.count == 1 && failures.isEmpty)
        protocolClient.stop()
        let gate = PicoAudioGate()
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!
        buffer.frameLength = 10
        gate.switchTo(.agent); let old = gate.token()
        precondition(gate.append([1, 1, 1], from: .agent, token: old))
        gate.switchTo(.human)
        _ = gate.append([1, 1], from: .agent, token: old)
        _ = gate.append([0.25, 0.5], from: .human, token: gate.token())
        gate.render(10, into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        precondition(buffer.floatChannelData![0][0] == 0.25 && buffer.floatChannelData![0][1] == 0.5)
        precondition((2..<10).allSatisfy { buffer.floatChannelData![0][$0] == 0 }, "takeover must flush all AI audio and reject late samples")
        gate.switchTo(.agent); _ = gate.append([1, 1], from: .agent); gate.clearAgent()
        gate.render(10, into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        precondition((0..<10).allSatisfy { buffer.floatChannelData![0][$0] == 0 }, "interruption flushes playback")
        precondition(!gate.append([Float](repeating: 1, count: 24000 * 121), from: .agent), "output buffering must be bounded")
        let id = UUID()
        func event(_ text: String, end: Any, final: Bool) -> [String: Any] {
            ["payload": ["output": ["sentence": ["sentence_id": 1, "text": text, "begin_time": 500.0, "end_time": end, "sentence_end": final]]]]
        }
        let partial = BailianMeetingProtocol.segment(event("Hello", end: NSNull(), final: false), source: .others, epoch: 10, receivedThrough: 12, id: id)!
        let final = BailianMeetingProtocol.segment(event("Hello Zoom", end: 1800.0, final: true), source: .others, epoch: 10, receivedThrough: 12, id: id)!
        precondition(partial.startTime == 10.5 && final.endTime == 11.8)
        var session = MeetingSession(title: "Test", locale: "mixed", processID: 0)
        session.update(partial); session.update(final); session.update(final)
        precondition(session.transcript.count == 1 && session.transcript[0].text == "Hello Zoom" && session.transcript[0].isFinal)
        let converter = MeetingPCMConverter()
        let conversionBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!
        conversionBuffer.frameLength = 2400
        conversionBuffer.floatChannelData![0].initialize(repeating: 0.25, count: 2400)
        let pcm = try converter.convert(conversionBuffer)
        precondition(!pcm.isEmpty)
        let prompt = PicoMeetingPrompt.instructions(brief: "喜欢设计", history: "hello")
        precondition(prompt.contains("AI meeting representative") && prompt.contains("Do not invent") && prompt.contains("喜欢设计"))
        let data = try JSONEncoder().encode(PicoMeetingRecord(title: "Casual chat"))
        _ = try JSONDecoder().decode(PicoMeetingRecord.self, from: data)
        print("PASS: immediate offline takeover, late-audio rejection, barge-in flush, bounded playback, ASR timestamps, partial replacement, final deduplication, PCM conversion, handoff serialization")
    }
}
