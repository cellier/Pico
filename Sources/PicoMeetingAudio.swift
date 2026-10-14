import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio

struct PicoAudioDevice: Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let input: Bool
    let output: Bool
    var physical: Bool { input && !virtual && !["zoom", "parrot", "loopback", "virtual"].contains(where: { (uid + name).lowercased().contains($0) }) }
    var virtual: Bool { uid.lowercased().contains("blackhole") }
    static func all() -> [Self] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var result: CFString = "" as CFString; var size = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr else { return "" }
            return result as String
        }
        func supports(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: 0)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
        }
        return ids.map { Self(id: $0, name: string($0, kAudioObjectPropertyName), uid: string($0, kAudioDevicePropertyDeviceUID), input: supports($0, kAudioObjectPropertyScopeInput), output: supports($0, kAudioObjectPropertyScopeOutput)) }
    }
}

/// Bounded PCM buffer. Switching owners atomically flushes every queued agent sample.
final class PicoAudioGate: @unchecked Sendable {
    enum Owner { case silence, human, agent }
    private let lock = NSLock()
    private var samples = [Float](repeating: 0, count: 24000 * 120)
    private var read = 0, count = 0
    private var owner: Owner = .silence
    private(set) var generation = 0
    func switchTo(_ value: Owner) { lock.lock(); defer { lock.unlock() }; owner = value; read = 0; count = 0; generation += 1 }
    func clearAgent() { lock.lock(); defer { lock.unlock() }; if owner == .agent { read = 0; count = 0; generation += 1 } }
    var bufferedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(count) / 24000 }
    func token() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
    @discardableResult func append(_ values: [Float], from: Owner, token: Int? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == from, token == nil || token == generation else { return true }
        guard values.count <= samples.count - count else { return false }
        for value in values { samples[(read + count) % samples.count] = value; count += 1 }
        return true
    }
    func render(_ frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        lock.lock(); defer { lock.unlock() }
        for frame in 0..<frames {
            let value: Float = count > 0 ? samples[read] : 0
            if count > 0 { read = (read + 1) % samples.count; count -= 1 }
            for buffer in buffers {
                guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for channel in 0..<Int(buffer.mNumberChannels) { pointer[frame * Int(buffer.mNumberChannels) + channel] = value }
            }
        }
    }
}

final class PicoMeetingAudio {
    let gate = PicoAudioGate()
    private var output: AVAudioEngine?
    private var microphone: AVAudioEngine?
    private var micConverter: AVAudioConverter?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    var onError: ((String) -> Void)?
    var running: Bool { output?.isRunning == true && microphone?.isRunning == true }
    func start(virtual: PicoAudioDevice, mic: PicoAudioDevice) throws {
        stop()
        guard virtual.virtual, virtual.input, virtual.output, mic.physical, virtual.id != mic.id else { throw BailianMeetingTranscription.problem("Choose BlackHole and a physical microphone.") }
        let engine = AVAudioEngine(); output = engine
        var device = virtual.id
        guard let unit = engine.outputNode.audioUnit, AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { stop(); throw BailianMeetingTranscription.problem("Could not open the BlackHole output.") }
        let gate = self.gate
        let source = AVAudioSourceNode(format: format) { _, _, count, list in gate.render(Int(count), into: UnsafeMutableAudioBufferListPointer(list)); return noErr }
        engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            let input = AVAudioEngine(); microphone = input
            var micID = mic.id
            guard let micUnit = input.inputNode.audioUnit, AudioUnitSetProperty(micUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &micID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw BailianMeetingTranscription.problem("Could not open the selected microphone.") }
            let native = input.inputNode.outputFormat(forBus: 0)
            guard native.sampleRate > 0, native.channelCount > 0, let converter = AVAudioConverter(from: native, to: format) else { throw BailianMeetingTranscription.problem("The physical microphone is unavailable.") }
            micConverter = converter
            input.inputNode.installTap(onBus: 0, bufferSize: 1024, format: native) { [weak self] buffer, _ in
                guard let self else { return }
                let token = gate.token()
                guard let converted = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24000 / native.sampleRate)) + 64) else { return }
                var supplied = false, error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }; supplied = true; state.pointee = .haveData; return buffer
                }
                guard status != .error, let pointer = converted.floatChannelData?[0] else { self.onError?("Microphone conversion stopped."); return }
                if !gate.append(Array(UnsafeBufferPointer(start: pointer, count: Int(converted.frameLength))), from: .human, token: token) { self.onError?("Microphone output cannot keep up.") }
            }
            try input.start()
            gate.switchTo(.human)
        } catch { stop(); throw error }
    }
    func stop() { gate.switchTo(.silence); microphone?.stop(); microphone?.inputNode.removeTap(onBus: 0); microphone = nil; output?.stop(); output = nil; micConverter = nil }
    func appendAgent(_ data: Data, token: Int) -> Bool {
        guard data.count % 2 == 0 else { return false }
        let values: [Float] = data.withUnsafeBytes { bytes in
            (0..<(data.count / 2)).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
        return gate.append(values, from: .agent, token: token)
    }
}
