import Foundation

/// Keep the local model loaded between utterances; use an ID to discard cancelled replies.
@MainActor final class DictationEngine {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var reply: (([String: Any]) -> Void)?
    private var requestID: String?
    func warm() {
        guard process == nil,
              let python = BundledRuntime.python(speech: true),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/dictation.py") else { return }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-B", script.path, "--serve"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(["HF_HUB_OFFLINE":"1"]) { _, new in new }
        self.process = process; self.input = input; self.output = output; buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { return }
            DispatchQueue.main.async { self?.receive(bytes, from: process) }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                let callback = self.reply
                self.process = nil; self.output?.fileHandleForReading.readabilityHandler = nil
                self.input = nil; self.output = nil; self.reply = nil; self.requestID = nil
                callback?(["error":"Speech engine stopped. Please try again."])
            }
        }
        do { try process.run() }
        catch { stop() }
    }
    func transcribe(_ url: URL, polish: Bool, reply: @escaping ([String: Any]) -> Void) {
        warm()
        guard process?.isRunning == true, let input else { reply(["error":"Speech engine unavailable"]); return }
        let id = UUID().uuidString; requestID = id; self.reply = reply
        do {
            var bytes = try JSONSerialization.data(withJSONObject: ["id":id,"path":url.path,"polish":polish])
            bytes.append(10); try input.fileHandleForWriting.write(contentsOf: bytes)
        } catch { cancel(); reply(["error":"Could not start transcription"]) }
    }
    private func receive(_ bytes: Data, from process: Process) {
        guard self.process === process else { return }
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; buffer.removeSubrange(...newline)
            guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  value["id"] as? String == requestID, requestID != nil else { continue }
            let callback = reply
            if value["stage"] == nil { reply = nil; requestID = nil }
            callback?(value)
        }
    }
    func cancel() { reply = nil; requestID = nil }
    func stop() {
        cancel(); output?.fileHandleForReading.readabilityHandler = nil
        let running = process; process = nil
        try? input?.fileHandleForWriting.close(); input = nil; output = nil; buffer = Data()
        if let running, running.isRunning { running.terminate() }
    }
}
