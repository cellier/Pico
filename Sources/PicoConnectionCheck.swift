import Foundation

/// Assertions use synthetic facts only; a tool invocation alone is not a knowledge test.
enum PicoPreflightValidation {
    static func failure(reply: String, kind: String) -> String? {
        let text = reply.lowercased()
        guard !text.isEmpty else { return "没有获得完整回复文字" }
        if ["saved memory", "saved_memory", "function_call", "telos_memory_search"].contains(where: text.contains) {
            return "回复包含内部工具术语，不适合向参会者讲述"
        }
        if kind != "unknown", text.range(of: #"不是林蓝|不是青桐笔记|不知道|不能确定|无法确认|无法确定"#, options: .regularExpression) != nil {
            return "已提供的虚构事实被否定或当成未知"
        }
        switch kind {
        case "owner":
            return text.contains("林蓝") && text.contains("青桐笔记") ? nil : "没有正确回答虚构项目及负责人"
        case "purpose":
            return text.contains("青桐笔记") && text.contains("学生") && text.contains("读书笔记") ? nil : "项目用途与给定资料不一致"
        case "material":
            return text.contains("杉木") && text.contains("内测") ? nil : "没有正确使用本场虚构材料"
        case "unknown":
            let uncertainty = #"不知道|不清楚|不确定|不能确定|无法确认|无法确定|未提供|没有[^。！？]{0,24}(资料|数据|信息|记录)|资料[^。！？]{0,24}(没|缺)|not (known|provided|available)|don't know|do not know"#
            guard text.range(of: uncertainty, options: .regularExpression) != nil else { return "对资料中不存在的客户数没有明确说明未知" }
            guard text.rangeOfCharacter(from: .decimalDigits) == nil else { return "未知客户数回答包含没有资料支持的数字" }
            let fabricatedCount = #"[0-9一二三四五六七八九十百千万零两]+\s*(个|位|家|名)?\s*(付费)?\s*(客户|用户)|\d+\s*(paying|paid)?\s*(customers|users)"#
            return text.range(of: fabricatedCount, options: .regularExpression) == nil ? nil : "回复给出了资料中不存在的客户数字"
        default: return "未知检查类型"
        }
    }
}

/// No microphone, meeting playback, private notes, or actual materials are used.
@MainActor final class PicoConnectionCheck: ObservableObject {
    @Published var status = ""
    @Published var running = false
    private var task: Task<Void, Never>?
    private let realtime = PicoRealtime()
    private var generation = UUID()
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        realtime.stop(); running = false; status = "检查已停止"
    }
    func run(directory: URL) {
        guard !running else { return }
        generation = UUID(); let token = generation; running = true
        task = Task { [self] in
            var ready = false, failure: String?, reply = "", bytes = 0, done = false, lookups = 0, reconnects = 0
            var results: [[String: Any]] = [], history: [String] = []
            var connectedAt: Date?, longestConnection = 0.0
            let started = Date()
            status = "正在检查会议转写新模型：发送虚构中英样本，不采集麦克风"
            save(["complete": false, "phase": "asr", "passed": false, "results": []], directory: directory)
            let asr: [String: Any]
            if let fixture = Bundle.main.url(forResource: "dictation-mixed-check", withExtension: "wav") {
                asr = await BailianMeetingTranscription.verifySample(fixture)
            } else { asr = ["passed": false, "error": "安装包缺少转写检查样本"] }
            guard generation == token, !Task.isCancelled else { return }
            let cloudASR = asr["bailian"] as? [String: Any] ?? [:]
            let asrPassed = cloudASR["passed"] as? Bool == true
            if !asrPassed {
                let detail = (cloudASR["errors"] as? [String] ?? []).joined(separator: "; ")
                failure = "会议转写新模型检查未通过：" + (detail.isEmpty ? (asr["error"] as? String ?? "样本关键词未被正确识别") : detail)
            }
            save(["complete": false, "phase": "conversation", "asr": asr, "passed": false, "results": []], directory: directory)
            let brief = "Synthetic connection test. Speak Chinese. Consult the memory tool for unknown facts. All supplied people and projects are fictional. Answer only the question, naturally and briefly."
            let fixture = [PicoMemoryNote(id: "synthetic", text: "测试项目：青桐笔记。负责人是林蓝。项目目标是帮助学生整理读书笔记。", updated: "2026-10-13")]
            realtime.preparationContext = "本场虚构材料：演示版本代号是杉木。杉木版本目前仅开放给小范围内测。材料没有付费客户数量，请勿猜测。"
            realtime.memoryLookup = { query in PicoMemoryStore.search(query: query, notes: fixture, excluded: []) }
            realtime.onMemorySearch = { _, result in if result.notes.contains(where: { $0.id == "synthetic" }) { lookups += 1 } }
            realtime.onReady = { ready = true; connectedAt = Date() }
            realtime.onError = { failure = $0 }
            realtime.onRecoverableError = { reason in
                if let connectedAt { longestConnection = max(longestConnection, Date().timeIntervalSince(connectedAt)) }
                connectedAt = nil; ready = false
                guard reconnects < 3 else { failure = "检查期间重连三次仍不稳定：" + reason; return }
                reconnects += 1
                self.realtime.start(brief: brief, history: history.joined(separator: "\n"))
            }
            realtime.onTranscript = { role, text, _ in if role == "pico" { reply += text } }
            realtime.onAudio = { data, _ in bytes += data.count }
            realtime.onResponseFinished = { _, completed in if completed && !reply.isEmpty { done = true } }
            if failure == nil { realtime.start(brief: brief, history: "") }
            for _ in 0..<300 {
                if ready || failure != nil || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !ready && failure == nil { failure = "模型没有在30秒内就绪" }
            let owner = "请查一下记忆，青桐笔记的负责人是谁？请同时说出项目名字。"
            let purpose = "青桐笔记帮助哪类人做什么？一句话回答。"
            let material = "这场材料写的演示版本代号是什么，目前对谁开放？"
            let unknown = "青桐笔记已经有多少付费客户？没有资料就明确说不能确定，不要猜数字。"
            let plan: [(Double, String, String)] = [
                (0, owner, "owner"), (15, unknown, "unknown"), (30, material, "material"),
                (240, purpose, "purpose"), (300, unknown, "unknown"), (360, owner, "owner"),
                (420, material, "material"), (480, unknown, "unknown"), (540, owner, "owner"), (600, purpose, "purpose")
            ]
            let conversationStarted = Date()
            for (index, step) in plan.enumerated() {
                while Date().timeIntervalSince(conversationStarted) < step.0 && failure == nil && !Task.isCancelled {
                    status = "正在检查10分钟会话：\(Int(Date().timeIntervalSince(conversationStarted)))/600秒，已完成\(results.count)/10题；不向会议播放"
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard failure == nil, !Task.isCancelled, generation == token else { break }
                reply = ""; bytes = 0; done = false
                let lookupBefore = lookups, reconnectBefore = reconnects
                let deadline = Date().addingTimeInterval(90)
                var sent = false, connectionForRequest = reconnects
                status = "正在检查资料、未知问题和会话稳定性：第\(index + 1)/10题"
                while !done && failure == nil && Date() < deadline && !Task.isCancelled {
                    if connectionForRequest != reconnects {
                        connectionForRequest = reconnects; sent = false; reply = ""; bytes = 0
                    }
                    if ready && !sent && realtime.canRequestTurn { sent = realtime.requestSpokenTurn(step.1) }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard !Task.isCancelled, generation == token else { break }
                let contentFailure = done ? PicoPreflightValidation.failure(reply: reply, kind: step.2) : "测试回复未完成"
                let audioFailure = bytes > 0 ? nil : "没有生成语音"
                let lookupFailure = index == 0 && lookups == lookupBefore ? "第一题没有实际检索到虚构记忆" : nil
                let issue = contentFailure ?? audioFailure ?? lookupFailure
                results.append(["question": step.1, "kind": step.2, "reply": reply, "audioBytes": bytes, "completed": done,
                                "verified": issue == nil, "validationError": issue ?? "", "memoryLookups": lookups - lookupBefore,
                                "reconnections": reconnects - reconnectBefore, "elapsedSeconds": Date().timeIntervalSince(conversationStarted)])
                save(["complete": false, "phase": "conversation", "asr": asr, "results": results, "reconnections": reconnects,
                      "passed": false, "error": issue ?? "", "conversationSeconds": Date().timeIntervalSince(conversationStarted)], directory: directory)
                if let issue { failure = failure ?? issue; break }
                history.append("user: " + step.1 + "\nassistant: " + reply)
            }
            guard generation == token else { return }
            if let connectedAt { longestConnection = max(longestConnection, Date().timeIntervalSince(connectedAt)) }
            realtime.stop(); running = false; task = nil
            if Task.isCancelled { return }
            let elapsed = Date().timeIntervalSince(conversationStarted)
            let passed = asrPassed && results.count == plan.count && failure == nil && elapsed >= 600 && results.allSatisfy { $0["verified"] as? Bool == true }
            let checkedKinds = Set(results.filter { $0["verified"] as? Bool == true }.compactMap { $0["kind"] as? String })
            let knowledgePassed = checkedKinds.isSuperset(of: ["owner", "purpose", "material", "unknown"]) && results.allSatisfy { $0["verified"] as? Bool == true }
            let uninterrupted = passed && reconnects == 0 && longestConnection >= 600
            status = passed ? "检查通过：10分钟、10题、记忆和材料回答正确，未知问题未编造；期间重连\(reconnects)次。未向会议播放。" : "检查未通过：" + (failure ?? "10分钟稳定性尚未完成")
            let report: [String: Any] = ["complete": true, "phase": "finished", "asr": asr, "results": results,
                                        "reconnections": reconnects, "passed": passed, "knowledgePassed": knowledgePassed,
                                        "continuousConnectionPassed": uninterrupted, "longestConnectionSeconds": longestConnection,
                                        "conversationSeconds": elapsed, "totalSeconds": Date().timeIntervalSince(started), "error": failure ?? ""]
            save(report, directory: directory)
        }
    }
    private func save(_ report: [String: Any], directory: URL) {
        var report = report; report["time"] = ISO8601DateFormatter().string(from: Date())
        let folder = directory.appendingPathComponent("pico-meetings")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("connection-check.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
