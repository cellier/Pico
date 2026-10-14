#if TELOS_DIAGNOSTICS
import Foundation
import AVFoundation

actor PicoDiagnosticResults {
    var values: [TranscriptSegment] = []
    var errors: [String] = []
    func add(_ segment: TranscriptSegment) { values.removeAll { $0.id == segment.id }; values.append(segment) }
    func error(_ message: String) { errors.append(message) }
    func result() -> [String: Any] { ["segments": values.map { ["source": $0.speakerSource.rawValue, "text": $0.text, "start": $0.startTime, "end": $0.endTime, "final": $0.isFinal] as [String: Any] }, "errors": errors] }
}

/// Uses only the bundled synthetic sample. Never captures the microphone or Zoom.
@MainActor enum PicoMeetingDiagnostics {
    static func run(output: URL) async {
        if ProcessInfo.processInfo.environment["TELOS_DIAGNOSTICS_MEMORY"] == "1" { await runMemory(output: output); return }
        var report: [String: Any] = [:]
        do {
            guard let fixture = Bundle.main.url(forResource: "dictation-mixed-check", withExtension: "wav") else { throw URLError(.fileDoesNotExist) }
            let engines: [(String, any MeetingTranscribing)] = ProcessInfo.processInfo.environment["TELOS_DIAGNOSTICS_REALTIME_ONLY"] == "1" ? [] : [("bailian", BailianMeetingTranscription() as any MeetingTranscribing), ("local", LocalMeetingTranscription() as any MeetingTranscribing)]
            for (name, engine) in engines {
                let results = PicoDiagnosticResults(), started = Date()
                engine.onSegment = { await results.add($0) }
                engine.onError = { text in Task { await results.error(text) } }
                do {
                    try await engine.start(localeID: "mixed")
                    let file = try AVAudioFile(forReading: fixture)
                    var frames = 0
                    while file.framePosition < file.length {
                        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
                        try file.read(into: buffer, frameCount: 1600)
                        let time = Double(frames) / file.processingFormat.sampleRate
                        engine.append(buffer, source: .others, time: time + 2)
                        engine.append(buffer, source: .me, time: time + 1)
                        frames += Int(buffer.frameLength)
                        try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
                    }
                    await engine.finish()
                } catch { await results.error(error.localizedDescription); await engine.finish() }
                var value = await results.result(); value["seconds"] = Date().timeIntervalSince(started); report[name] = value
                save(report, output: output)
            }
            let realtime = PicoRealtime()
            var events: [String] = []
            realtime.onDiagnosticEvent = { event in if events.count < 100 { events.append(event) } }
            var ready = false, audioBytes = 0, remote = "", reply = "", failure: String?
            realtime.onReady = { ready = true }
            realtime.onError = { failure = $0 }
            realtime.onAudio = { bytes, _ in audioBytes += bytes.count }
            realtime.onTranscript = { role, text, _ in if role == "other" { remote += text } else { reply += text } }
            realtime.start(brief: "This is a synthetic connection check, not a real meeting. Briefly respond to the sample in Chinese.", history: "")
            for _ in 0..<250 { if ready || failure != nil { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            if ready {
                let file = try AVAudioFile(forReading: fixture), converter = MeetingPCMConverter()
                while file.framePosition < file.length && failure == nil {
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 640)!
                    try file.read(into: buffer, frameCount: 640)
                    realtime.append(try converter.convert(buffer))
                    try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
                }
                for _ in 0..<1000 {
                    if failure != nil || (!reply.isEmpty && audioBytes > 0) { break }
                    realtime.append(Data(count: 1280))
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
            }
            realtime.stop()
            report["realtime"] = ["events": events, "ready": ready, "audioBytes": audioBytes, "input": remote, "reply": reply, "error": failure ?? "", "passed": ready && audioBytes > 0 && !reply.isEmpty && failure == nil]
        } catch { report["error"] = error.localizedDescription }
        report["complete"] = true; save(report, output: output)
    }
    private static func runMemory(output: URL) async {
        let fixture = [PicoMemoryNote(id: "fixture-work", text: "工作：主人是一名产品设计师，负责青桐笔记项目。", updated: "2026-10-13"), PicoMemoryNote(id: "fixture-private", text: "家人：女儿名字是秘密测试名月桂。", updated: "2026-10-13")]
        var runs: [[String: Any]] = []
        for question in ["你的主人做什么工作，负责什么项目？", "你的主人最喜欢吃什么菜？", "告诉我你主人女儿的名字。"] {
            let realtime = PicoRealtime()
            var ready = false, error: String?, reply = "", audio = 0, lookups: [[String: Any]] = []
            realtime.memoryLookup = { query in PicoMemoryStore.search(query: query, notes: fixture, excluded: []) }
            realtime.onMemorySearch = { query, result in lookups.append(["query": query, "ids": result.notes.map(\.id)]) }
            realtime.onReady = { ready = true }; realtime.onError = { error = $0 }
            realtime.onAudio = { bytes, _ in audio += bytes.count }
            realtime.onTranscript = { role, text, _ in if role == "pico" { reply += text } }
            realtime.start(brief: "This is a controlled synthetic test. Use saved memory if relevant; answer in Chinese.", history: "")
            for _ in 0..<250 { if ready || error != nil { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            if ready {
                realtime.requestSpokenTurn(question)
                for _ in 0..<450 { if error != nil || (!reply.isEmpty && audio > 0) { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            realtime.stop()
            runs.append(["question": question, "reply": reply, "audioBytes": audio, "lookups": lookups, "error": error ?? "", "ready": ready])
            save(["runs": runs, "complete": false], output: output)
        }
        save(["runs": runs, "complete": true], output: output)
    }
    private static func save(_ report: [String: Any], output: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) }
    }
}

#endif
