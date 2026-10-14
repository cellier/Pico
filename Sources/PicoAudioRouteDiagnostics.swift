#if TELOS_DIAGNOSTICS
import Foundation
import AVFoundation
import AudioToolbox

/// Opt-in, local-only diagnostic. Stores aggregate signal measurements, never microphone recordings.
private final class PicoRouteMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = "warmup"
    private var values: [String: (frames: Int, energy: Double, tone: Double)] = [:]
    func select(_ value: String) { lock.lock(); stage = value; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength), rate = buffer.format.sampleRate
        var energy = 0.0, sine = 0.0, cosine = 0.0
        for index in 0..<count {
            let value = Double(samples[index]), angle = 2 * Double.pi * 997 * Double(index) / rate
            energy += value * value; sine += value * sin(angle); cosine += value * cos(angle)
        }
        let tone = count > 0 ? 2 * sqrt(sine * sine + cosine * cosine) / Double(count) : 0
        lock.lock(); defer { lock.unlock() }
        let old = values[stage] ?? (0, 0, 0)
        values[stage] = (old.frames + count, old.energy + energy, max(old.tone, tone))
    }
    func report() -> [String: [String: Double]] {
        lock.lock(); defer { lock.unlock() }
        return values.mapValues { ["frames": Double($0.frames), "rms": sqrt($0.energy / Double(max(1, $0.frames))), "peakToneAmplitude": $0.tone] }
    }
}

@MainActor enum PicoAudioRouteDiagnostics {
    static func run(output: URL) async {
        var result: [String: Any] = ["cloudAudioSent": false, "microphoneRecordingSaved": false]
        let audio = PicoMeetingAudio(), receiver = AVAudioEngine(), meter = PicoRouteMeter()
        var tapped = false
        defer { audio.stop(); receiver.stop(); if tapped { receiver.inputNode.removeTap(onBus: 0) } }
        do {
            let observation = await Task.detached { ZoomMeetingAdapter().observe() }.value
            guard observation.signal == .absent else { throw problem("Close any Zoom meeting before this local diagnostic.") }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw problem("Microphone permission is required.") }
            let devices = PicoAudioDevice.all()
            guard let bridge = devices.first(where: { $0.virtual && $0.input && $0.output }), let mic = devices.first(where: { $0.physical && $0.name.contains("MacBook") }) ?? devices.first(where: { $0.physical }) else { throw problem("BlackHole or physical microphone is missing.") }
            result["bridge"] = bridge.name; result["microphone"] = mic.name
            var id = bridge.id
            guard let unit = receiver.inputNode.audioUnit, AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else { throw problem("Could not read BlackHole.") }
            let deviceFormat = receiver.inputNode.outputFormat(forBus: 0)
            result["deviceFormat"] = deviceFormat.description
            let native = AVAudioFormat(standardFormatWithSampleRate: deviceFormat.sampleRate, channels: deviceFormat.channelCount)!
            receiver.inputNode.installTap(onBus: 0, bufferSize: 480, format: native) { buffer, _ in meter.append(buffer) }
            tapped = true
            try audio.start(virtual: bridge, mic: mic)
            try await Task.sleep(nanoseconds: 500_000_000)
            try receiver.start()
            try await Task.sleep(nanoseconds: 300_000_000)
            if !receiver.isRunning { try receiver.start() }
            result["receiverRunning"] = receiver.isRunning
            audio.gate.switchTo(.agent)
            let samples = (0..<24000 * 10).map { Float(0.2 * sin(2 * Double.pi * 997 * Double($0) / 24000)) }
            let token = audio.gate.token()
            guard audio.gate.append(samples, from: .agent, token: token) else { throw problem("Could not enqueue tone.") }
            meter.select("agent")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            audio.gate.clearAgent()
            try await Task.sleep(nanoseconds: 150_000_000)
            meter.select("interrupted")
            // Deliberately deliver a late model buffer. It must remain inaudible.
            audio.gate.append(samples, from: .agent, token: token)
            try await Task.sleep(nanoseconds: 700_000_000)
            meter.select("resuming")
            audio.gate.append(samples, from: .agent, token: audio.gate.token())
            try await Task.sleep(nanoseconds: 300_000_000)
            let before = DispatchTime.now().uptimeNanoseconds
            audio.gate.switchTo(.human)
            result["takeoverGateMilliseconds"] = Double(DispatchTime.now().uptimeNanoseconds - before) / 1_000_000
            audio.gate.append(samples, from: .agent, token: token)
            try await Task.sleep(nanoseconds: 150_000_000)
            meter.select("human")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            result["enginesRunning"] = audio.running
            audio.stop()
            try await Task.sleep(nanoseconds: 150_000_000)
            meter.select("disconnected")
            try await Task.sleep(nanoseconds: 700_000_000)
            let stats = meter.report(); result["measurements"] = stats
            result["passed"] = (stats["agent"]?["peakToneAmplitude"] ?? 0) > 0.1 && (stats["interrupted"]?["rms"] ?? 1) < 0.00001 && (stats["human"]?["peakToneAmplitude"] ?? 1) < 0.02 && (stats["human"]?["frames"] ?? 0) > 24000 && (stats["disconnected"]?["rms"] ?? 1) < 0.00001
        } catch { result["error"] = error.localizedDescription; result["passed"] = false }
        result["complete"] = true
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) }
    }
    private static func problem(_ text: String) -> NSError { NSError(domain: "PicoAudioRouteDiagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

#endif
