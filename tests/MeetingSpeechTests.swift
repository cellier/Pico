import Foundation
import AVFoundation
import Speech
actor Results {
    var segments: [TranscriptSegment] = []
    func append(_ value: TranscriptSegment) { segments.append(value) }
    func all() -> [TranscriptSegment] { segments }
}
@main struct MeetingSpeechTests {
    static func main() async throws {
        let results = Results()
        let engine = LocalMeetingTranscription()
        engine.onSegment = { value in await results.append(value) }
        engine.onError = { text in print("ERROR: " + text) }
        try await engine.start(localeID: "mixed")
        for (name, source) in [("me", SpeakerSource.me), ("others", SpeakerSource.others)] {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: "/tmp/telos-meeting-audio-test/\(name).wav"))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            // Less than one chunk: finish must flush this final speech, not discard it.
            engine.append(buffer, source: source, time: source == .me ? 1 : 10)
        }
        await engine.finish()
        let segments = await results.all()
        for segment in segments { print("\(segment.speakerSource): \(segment.text)") }
        precondition(segments.count == 2 && Set(segments.map(\.speakerSource)).count == 2)
        precondition(segments.allSatisfy { $0.isFinal && !$0.text.isEmpty && $0.endTime > $0.startTime })
        precondition(segments.first(where: { $0.speakerSource == .me })!.text.lowercased().contains("deck"))
        precondition(segments.first(where: { $0.speakerSource == .others })!.text.contains("明天"))
        if #available(macOS 26, *) { print("Apple speech available: \(SpeechTranscriber.isAvailable); installed locales: \(await SpeechTranscriber.installedLocales)") }
        if #available(macOS 26, *) {
            let nativeResults = Results(), native = MeetingTranscription()
            native.onSegment = { await nativeResults.append($0) }
            native.onError = { print("NATIVE ERROR: " + $0) }
            try await MeetingTranscription.prepareAssets(localeID: "en-US")
            try await native.start(localeID: "en-US")
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: "/tmp/telos-meeting-audio-test/me.wav"))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            native.append(buffer, source: .me, time: 1)
            native.append(buffer, source: .others, time: 10)
            await native.finish()
            let output = await nativeResults.all().filter { $0.isFinal }
            for segment in output { print("Apple \(segment.speakerSource): \(segment.text)") }
            precondition(Set(output.map(\.speakerSource)).count == 2)
            precondition(output.allSatisfy { $0.text.lowercased().contains("deck") })
            print("PASS: Apple SpeechAnalyzer two channels and finalization")
        }
        print("PASS: real local ASR on generated English/Chinese audio, source separation, timestamps and final short-buffer flush")
    }
}
