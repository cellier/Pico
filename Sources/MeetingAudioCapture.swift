import AVFoundation
import ScreenCaptureKit
import CoreAudio
import CoreMedia

protocol MeetingAudioCapturing: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer, SpeakerSource, Double) -> Void)? { get set }
    var onActivity: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start(pid: pid_t, elapsed: Double) async throws
    func stop() async
}

/// Zoom process audio is independent of the physical speaker/headphone route.
@available(macOS 26, *)
final class MeetingAudioCapture: NSObject, MeetingAudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var captureLocalMicrophone = true
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Telos.meeting.audio")
    private var config = SCStreamConfiguration()
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var inputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var chosenMicrophone: String?
    private var epoch: Double = 0
    private var lastActivity = Date.distantPast
    var onBuffer: ((AVAudioPCMBuffer, SpeakerSource, Double) -> Void)?
    var onActivity: (() -> Void)?
    var onError: ((String) -> Void)?
    func start(pid: pid_t, elapsed: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let apps = content.applications.filter { $0.processID == pid || $0.bundleIdentifier.hasPrefix("us.zoom.") }
        guard !apps.isEmpty, let display = content.displays.first else { throw NSError(domain: "MeetingAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Zoom audio source is unavailable."]) }
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000; config.channelCount = 1
        config.captureMicrophone = captureLocalMicrophone
        config.microphoneCaptureDeviceID = chosenMicrophone ?? AVCaptureDevice.default(for: .audio)?.uniqueID
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if captureLocalMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        // No screen frames, raw audio files, or recordings are retained.
        epoch = CMClockGetTime(CMClockGetHostTimeClock()).seconds - elapsed
        self.stream = stream
        try await stream.startCapture()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self, let stream = self.stream else { return }
                self.config.microphoneCaptureDeviceID = self.chosenMicrophone ?? AVCaptureDevice.default(for: .audio)?.uniqueID
                do { try await stream.updateConfiguration(self.config) }
                catch { self.onError?("Microphone switch failed: \(error.localizedDescription)") }
            }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddress, queue, listener)
    }
    func chooseMicrophone(_ uid: String) async throws {
        chosenMicrophone = uid
        config.microphoneCaptureDeviceID = uid
        if let stream { try await stream.updateConfiguration(config) }
    }
    func stop() async {
        if let listener = deviceListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inputAddress, queue, listener); deviceListener = nil }
        if let stream { try? await stream.stopCapture() }
        // Drain the final captured buffers before finishing analyzers.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        stream = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?("Meeting capture stopped: \(error.localizedDescription)") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard (type == .audio || type == .microphone), sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList) == noErr else { onError?("Unable to read captured meeting audio"); return }
        let source: SpeakerSource = type == .microphone ? .me : .others
        if source == .others, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            if sqrt(sum / Float(buffer.frameLength)) > 0.002 && Date().timeIntervalSince(lastActivity) > 1 { lastActivity = Date(); onActivity?() }
        }
        onBuffer?(buffer, source, max(0, sampleBuffer.presentationTimeStamp.seconds - epoch))
    }
}
