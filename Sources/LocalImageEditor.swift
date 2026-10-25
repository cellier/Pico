import Foundation

/// One offline worker per editor window. Reuse loaded weights for subsequent edits.
@MainActor final class LocalImageEditor {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var completion: (([String:Any]) -> Void)?
    private var scratch: URL?

    func edit(png: Data, instruction: String, reply: @escaping ([String:Any]) -> Void) {
        guard completion == nil else { return }
        do {
            try start()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TelosLocalEdit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            scratch = dir
            let source = dir.appendingPathComponent("input.png"), result = dir.appendingPathComponent("output.png")
            try png.write(to:source,options:.atomic)
            var request = try JSONSerialization.data(withJSONObject:["image":source.path,"output":result.path,"instruction":instruction])
            request.append(0x0a)
            completion = reply
            try input?.fileHandleForWriting.write(contentsOf:request)
        } catch {
            stop()
            reply(["error":error.localizedDescription])
        }
    }

    private func start() throws {
        if process?.isRunning == true { return }
        guard let python = Bundle.main.object(forInfoDictionaryKey:"TelosImagePython") as? String,
              let model = Bundle.main.object(forInfoDictionaryKey:"TelosImageModel") as? String,
              FileManager.default.isExecutableFile(atPath:python),
              FileManager.default.fileExists(atPath:model + "/transformer/0.safetensors"),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/local_image_edit.py") else {
            throw NSError(domain:"TelosLocalImage",code:1,userInfo:[NSLocalizedDescriptionKey:"Local image editing is not installed. Run scripts/setup-image-edit.sh and rebuild Pico."])
        }
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = URL(fileURLWithPath:python)
        task.arguments = ["-B", "-u", script.path, "--model-path", model]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        task.environment = env
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.nullDevice
        let id = UUID(); generation = id
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == id else { return }
                if data.isEmpty {
                    if self.completion != nil { self.finish(["error":"Local editing stopped before producing an image. Please try again."]) }
                    return
                }
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of:0x0a) {
                    let line = self.buffer.prefix(upTo:newline)
                    self.buffer.removeSubrange(...newline)
                    guard let event = (try? JSONSerialization.jsonObject(with:line)) as? [String:Any] else { continue }
                    if event["stage"] != nil { self.completion?(event) }
                    else { self.finish(event) }
                }
            }
        }
        process = task; input = stdin; output = stdout
        try task.run()
    }

    private func finish(_ event: [String:Any]) {
        let callback = completion; completion = nil
        callback?(event) // The caller reads output.png synchronously before cleanup.
        cleanScratch()
    }
    private func cleanScratch() {
        if let scratch { try? FileManager.default.removeItem(at:scratch) }
        scratch = nil
    }
    func stop() {
        generation = UUID(); completion = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil; buffer = Data()
        cleanScratch()
    }
}
