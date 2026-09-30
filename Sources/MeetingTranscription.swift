import Foundation
import AVFoundation
import Speech
import CoreMedia

protocol MeetingTranscribing: AnyObject {
    var onSegment: ((TranscriptSegment) async -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start(localeID: String) async throws
    func append(_ buffer: AVAudioPCMBuffer, source: SpeakerSource, time: Double)
    func finish() async
}

@available(macOS 26, *)
final class MeetingTranscription: MeetingTranscribing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Telos.meeting.transcription")
    private var channels: [SpeakerSource: Channel] = [:]
    private var accepting = true
    var onSegment: ((TranscriptSegment) async -> Void)?
    var onError: ((String) -> Void)?
    private struct Channel {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
        let resultTask: Task<Void, Never>
        let inputTask: Task<Void, Never>
        var converter: AVAudioConverter?
    }
    static func prepareAssets(localeID: String) async throws {
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw NSError(domain: "Meeting", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple on-device transcription is unavailable for this language or Mac."])
        }
        guard try await AssetInventory.reserve(locale: locale) else { throw NSError(domain: "Meeting", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple could not reserve this speech language. Free an unused speech language and try again."]) }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await install.downloadAndInstall() }
    }
    func start(localeID: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else { throw failure("Unsupported meeting language") }
        for source in [SpeakerSource.me, .others] {
            let module = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            guard await AssetInventory.status(forModules: [module]) == .installed else { throw failure("Download the meeting speech model in Settings first.") }
            let analyzer = SpeechAnalyzer(modules: [module])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw failure("No supported speech audio format") }
            try await analyzer.prepareToAnalyze(in: format)
            let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(1500))
            let resultTask = Task { [weak self] in
                do {
                    for try await result in module.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            await self?.onSegment?(.init(startTime: max(0, result.range.start.seconds), endTime: max(0, CMTimeRangeGetEnd(result.range).seconds), speakerSource: source, text: text, isFinal: result.isFinal))
                        }
                    }
                } catch { self?.onError?("Transcription stopped: \(error.localizedDescription)") }
            }
            let inputTask = Task { [weak self] in
                do { _ = try await analyzer.analyzeSequence(inputs) }
                catch { self?.onError?("Speech input failed: \(error.localizedDescription)") }
            }
            queue.sync { channels[source] = Channel(analyzer: analyzer, continuation: continuation, format: format, resultTask: resultTask, inputTask: inputTask) }
        }
    }
    func append(_ buffer: AVAudioPCMBuffer, source: SpeakerSource, time: Double) {
        queue.async { [self] in
            guard accepting, var channel = channels[source] else { return }
            if channel.converter?.inputFormat != buffer.format { channel.converter = AVAudioConverter(from: buffer.format, to: channel.format) }
            guard let converter = channel.converter,
                  let converted = AVAudioPCMBuffer(pcmFormat: channel.format, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * channel.format.sampleRate / buffer.format.sampleRate)) + 64) else { onError?("Unable to convert meeting audio"); return }
            var supplied = false, error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            channels[source] = channel
            guard status != .error, error == nil else { onError?("Audio conversion failed"); return }
            guard converted.frameLength > 0 else { return }
            let result = channel.continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: CMTime(seconds: max(0, time), preferredTimescale: 48000)))
            if case .dropped = result { accepting = false; onError?("Speech processing could not keep up. Recording stopped to avoid silently losing transcript.") }
        }
    }
    func finish() async {
        let current = queue.sync { () -> [Channel] in
            accepting = false
            let current = Array(channels.values)
            for channel in current { channel.continuation.finish() }
            return current
        }
        for channel in current {
            let watchdog = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                self?.onError?("Final speech processing timed out. The saved transcript may be missing its last interval.")
                await channel.analyzer.cancelAndFinishNow()
                channel.inputTask.cancel(); channel.resultTask.cancel()
            }
            await channel.inputTask.value
            do { try await channel.analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { onError?("Could not finalize the last speech segment: \(error.localizedDescription)") }
            await channel.resultTask.value
            watchdog.cancel()
        }
        queue.sync { channels.removeAll() }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "MeetingSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
