import AppKit
import Foundation

/// Both a pet menu request and an approval must reveal the task in the new tabbed shell.
@MainActor enum CompanionTaskPresentation {
    static func show(_ id: UUID, in store: TaskStore, present: () -> Void) {
        guard store.tasks.contains(where: { $0.id == id }) else { return }
        store.showMacAccess = false
        NotificationCenter.default.post(name: .init("PicoShowTasks"), object: nil)
        store.selected = id
        present()
    }
}

@MainActor enum CompanionChatPresentation {
    static func show(in store: TaskStore, present: () -> Void) {
        store.showMacAccess = false
        NotificationCenter.default.post(name: .init("PicoShowChat"), object: nil)
        present()
    }
}

private struct CompanionPendingChat: Codable {
    let id: String
    let text: String
    let language: String
    let created: TimeInterval
}

/// Same-user file IPC. No TCP listener, credential, approval decision, or arbitrary file path API.
@MainActor final class CompanionBridge {
    let store: TaskStore
    let chat: PicoChatStore
    let root: URL
    let transcribe: (URL, @escaping ([String:Any])->Void)->Void
    let cancelSpeech: ()->Void
    var timer: Timer?
    var active: [String:UUID] = [:]
    var recognizing: String?
    var heartbeatAt = Date.distantPast
    var lastStates: [String:String] = [:]
    var showMeeting: (() -> Void)?
    var showTask: (UUID)->Void
    var showChat: () -> Void
    private var queued: [String: CompanionPendingChat] = [:]
    private var chatRequests = Set<String>()
    private var cancelledRequests = Set<String>()
    private var lastChatStates: [String: String] = [:]
    private var rootReady = false
    private var recoveredChatStatus = false
    init(store:TaskStore, transcribe:@escaping(URL,@escaping([String:Any])->Void)->Void, cancel:@escaping()->Void, show:@escaping(UUID)->Void, showChat:@escaping()->Void = {}, automaticallyStart:Bool = true) {
        self.store=store;chat=store.chat;self.transcribe=transcribe;cancelSpeech=cancel;showTask=show;self.showChat=showChat
        root=store.dataDir.appendingPathComponent("companion-v1",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let a=try FileManager.default.attributesOfItem(atPath:root.path)
            guard a[.type] as? FileAttributeType == .typeDirectory, (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else{return}
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
            rootReady = true
            if automaticallyStart {
                timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.poll()}
                poll()
            }
        } catch { }
    }
    func write(_ id:String,_ state:String,_ text:String="",task:UUID?=nil){
        var value:[String:Any] = ["id":id,"state":state,"text":text,"updated":Date().timeIntervalSince1970]
        if let task {value["task_id"]=task.uuidString;value["language"]=store.tasks.first(where:{$0.id==task})?.voiceLanguage ?? "en";value["phase_events"]=store.tasks.first(where:{$0.id==task})?.voicePhaseEvents ?? []}
        guard let data=try? JSONSerialization.data(withJSONObject:value) else{return}
        let file=root.appendingPathComponent(id+".status.json")
        try? data.write(to:file,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func poll(){
        guard rootReady else { return }
        let heartbeat:[String:Any] = ["protocol":1,"pid":ProcessInfo.processInfo.processIdentifier,"updated":Date().timeIntervalSince1970]
        if Date().timeIntervalSince(heartbeatAt)>1 { heartbeatAt=Date();if let data=try? JSONSerialization.data(withJSONObject:heartbeat){try? data.write(to:root.appendingPathComponent("heartbeat.json"),options:.atomic)} }
        guard let files=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]) else{return}
        // A cancel already on disk wins over a queued request in this same poll.
        let ordered = files.sorted {
            let left = $0.lastPathComponent.hasSuffix(".cancel")
            let right = $1.lastPathComponent.hasSuffix(".cancel")
            return left != right ? left : $0.lastPathComponent < $1.lastPathComponent
        }
        for file in ordered {
            let name=file.lastPathComponent
            if name == "pico-meeting.open" {
                guard let showMeeting else { continue } // Keep cold-start request until the app installs its handler.
                defer { try? FileManager.default.removeItem(at: file) }
                guard let meta = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]), meta.isSymbolicLink != true, (meta.fileSize ?? 99999) < 100, Date().timeIntervalSince(meta.contentModificationDate ?? .distantPast) < 30 else { continue }
                showMeeting(); continue
            }
            if name.hasSuffix(".cancel") {
                let id=String(name.dropLast(7));guard UUID(uuidString:id) != nil else{continue}
                cancelledRequests.insert(id)
                if recognizing==id {cancelSpeech();recognizing=nil}
                let legacyTask = active.removeValue(forKey:id)
                if let task=legacyTask {store.stop(task)}
                queued.removeValue(forKey: id)
                try? FileManager.default.removeItem(at: pendingURL(id))
                chat.stopVoice(requestID: id)
                chatRequests.remove(id)
                try? FileManager.default.removeItem(at:root.appendingPathComponent(id+".wav"))
                if let task = legacyTask { write(id,"cancelled",task:task) }
                else { writeChat(id,"cancelled") }
                try? FileManager.default.removeItem(at:file);continue
            }
            if name.hasSuffix(".chat-pending.json") {
                let id = String(name.dropLast(".chat-pending.json".count))
                guard UUID(uuidString: id) != nil else { continue }
                if cancelledRequests.contains(id) { try? FileManager.default.removeItem(at: file); continue }
                if chat.voiceTurn(for: id) == nil, let status = readChatStatus(id),
                   ["cancelled", "error"].contains(status["state"] as? String ?? "") {
                    try? FileManager.default.removeItem(at: file); continue
                }
                if queued[id] == nil, let pending = readPending(file, id: id) {
                    queued[id] = pending
                    chatRequests.insert(id)
                }
                continue
            }
            if !recoveredChatStatus, name.hasSuffix(".status.json") {
                let id = String(name.dropLast(".status.json".count))
                // Chat may have recovered a checkpoint or marked an interrupted
                // turn cancelled. Publish that outcome to the waiting pet once.
                // Already terminal pet statuses must never be replayed aloud.
                if let status = readChatStatus(id), chat.voiceTurn(for: id) != nil,
                   ["thinking", "working", "awaiting_approval"].contains(status["state"] as? String ?? "") {
                    chatRequests.insert(id)
                }
                continue
            }
            if name.hasSuffix(".show") {
                let id=String(name.dropLast(5))
                guard UUID(uuidString:id) != nil,
                      let meta=try? file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]),
                      meta.isSymbolicLink != true,(meta.fileSize ?? 99999)<100,
                      Date().timeIntervalSince(meta.contentModificationDate ?? .distantPast)<30 else {
                    try? FileManager.default.removeItem(at:file);continue
                }
                if chat.voiceTurn(for: id) != nil || queued[id] != nil || isPersistedChatRequest(id) {
                    showChat()
                    try? FileManager.default.removeItem(at: file)
                } else if let task=active[id] ?? store.tasks.first(where:{$0.voiceRequestID==id})?.id,
                   store.tasks.contains(where:{$0.id==task}) {
                    showTask(task)
                    try? FileManager.default.removeItem(at:file)
                }
                // Keep a fresh request until recognition accepts its transcript;
                // directory enumeration does not guarantee .request precedes .show.
                continue
            }
            guard name.hasSuffix(".request.json") else{continue}
            let id=String(name.dropLast(13));guard UUID(uuidString:id) != nil else{continue}
            defer {try? FileManager.default.removeItem(at:file)}
            guard let meta=try? file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]),meta.isSymbolicLink != true,(meta.fileSize ?? 99999)<16384,Date().timeIntervalSince(meta.contentModificationDate ?? .distantPast)<120,
                  let data=try? Data(contentsOf:file),let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],request["id"] as? String==id else{continue}
            guard !cancelledRequests.contains(id) else { continue }
            if let turn = chat.voiceTurn(for: id) {
                writeChat(id, turn.state, turn.text, turn: turn)
                continue
            }
            guard recognizing==nil else {write(id,"error","Speech recognition is busy. Please try again.");continue}
            guard active[id]==nil, !FileManager.default.fileExists(atPath:root.appendingPathComponent(id+".status.json").path) else{continue}
            // Pico may transcribe with the user's selected cloud provider first.
            // Treat that text exactly like locally recognized speech, with the
            // same Chat execution policy; it conveys no approval decisions.
            if request["transcript"] != nil {
                guard let text=CompanionTranscript.read(request["transcript"]) else {write(id,"error","Invalid speech transcript.");continue}
                enqueueChat(text,id:id);continue
            }
            let audio=root.appendingPathComponent(id+".wav")
            guard let a=try? audio.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]),a.isSymbolicLink != true,(a.fileSize ?? 0)>44,(a.fileSize ?? 0)<2_000_000 else {write(id,"error","Audio input is invalid.");continue}
            recognizing=id;write(id,"transcribing")
            transcribe(audio){[weak self] result in
                guard let self,self.recognizing==id else{return}
                if result["stage"] != nil{return}
                self.recognizing=nil;try? FileManager.default.removeItem(at:audio)
                guard result["error"]==nil else{self.write(id,"error","Local speech recognition failed. Please try again.");return}
                guard let text=CompanionTranscript.read(result["text"]) else{self.writeChat(id,"cancelled");return}
                self.enqueueChat(text,id:id)
            }
        }
        recoveredChatStatus = true
        drainChatQueue()
        for id in Array(chatRequests) { publishChat(id) }
        for (id,task) in active {
            guard let todo=store.tasks.first(where:{$0.id==task}) else{continue}
            let state:String
            switch todo.status {
            case "running":state=todo.voicePhase ?? "thinking"
            case "awaiting_approval":state="awaiting_approval"
            case "ready","completed":state="completed"
            case "needs_input":state="needs_input"
            case "paused":state="cancelled"
            default:state="error"
            }
            let text = ["completed","needs_input"].contains(state) ? (todo.messages.last(where:{$0.role=="assistant"})?.text ?? todo.summary) : (state=="awaiting_approval" ? todo.summary : "")
            if state=="awaiting_approval",lastStates[id] != state {showTask(task)}
            if lastStates[id] != state {write(id,state,text,task:task);lastStates[id]=state}
        }
    }
    private func pendingURL(_ id: String) -> URL { root.appendingPathComponent(id + ".chat-pending.json") }

    private func readPending(_ file: URL, id: String) -> CompanionPendingChat? {
        guard let meta = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              meta.isSymbolicLink != true, (meta.fileSize ?? 99999) < 16384,
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(CompanionPendingChat.self, from: data),
              value.id == id, CompanionTranscript.read(value.text) != nil,
              ["zh", "en"].contains(value.language), value.created.isFinite else { return nil }
        return value
    }

    private func enqueueChat(_ text: String, id: String) {
        guard !cancelledRequests.contains(id) else { return }
        let pending = CompanionPendingChat(id: id, text: text, language: CompanionLanguage.detect(text), created: Date().timeIntervalSince1970)
        do {
            let url = pendingURL(id)
            try JSONEncoder().encode(pending).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            queued[id] = pending; chatRequests.insert(id)
            writeChat(id, "working", language: pending.language)
        } catch { writeChat(id, "error", "Could not save the voice message. Please try again.", language: pending.language) }
    }

    private func drainChatQueue() {
        // A prior crash can leave the queue marker after the Chat message was
        // saved. Its durable request mapping makes this an acknowledgement only.
        for id in Array(queued.keys) where chat.voiceTurn(for: id) != nil {
            queued.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: pendingURL(id))
            chatRequests.insert(id)
        }
        guard chat.canBeginVoiceTurn, let next = queued.values.min(by: {
            $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created
        }) else { return }
        if chat.sendVoice(next.text, requestID: next.id, language: next.language) {
            queued.removeValue(forKey: next.id)
            try? FileManager.default.removeItem(at: pendingURL(next.id))
            chatRequests.insert(next.id)
        } else if !chat.isRunning {
            // Preserve a failed input for local recovery, but never silently
            // replay it later after the pet has already reported an error.
            let failed = root.appendingPathComponent(next.id + ".chat-failed.json")
            try? FileManager.default.moveItem(at: pendingURL(next.id), to: failed)
            queued.removeValue(forKey: next.id); chatRequests.remove(next.id)
            writeChat(next.id, "error", chat.error ?? "Could not send the voice message. Please try again.", language: next.language)
        }
    }

    private func publishChat(_ id: String) {
        guard let turn = chat.voiceTurn(for: id) else { return }
        let signature = turn.state + "\0" + turn.text + "\0" + (chat.approval?.id ?? "")
        if lastChatStates[id] != signature {
            writeChat(id, turn.state, turn.text, turn: turn)
            lastChatStates[id] = signature
            if turn.state == "awaiting_approval" { showChat() }
        }
        if ["completed", "needs_input", "cancelled", "error"].contains(turn.state) { chatRequests.remove(id) }
    }

    private func writeChat(_ id: String, _ state: String, _ text: String = "", turn: PicoVoiceChatTurn? = nil, language: String? = nil) {
        var value: [String: Any] = ["id": id, "source": "chat", "state": state, "text": text,
                                  "conversation_id": chat.conversationID.uuidString,
                                  "user_message_id": turn?.userMessageID.uuidString ?? UUID(uuidString: id)?.uuidString ?? id,
                                  "language": turn?.language ?? language ?? "en", "updated": Date().timeIntervalSince1970]
        if let response = turn?.responseMessageID { value["response_message_id"] = response.uuidString }
        if let data = try? JSONSerialization.data(withJSONObject: value) {
            let file = root.appendingPathComponent(id + ".status.json")
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func readChatStatus(_ id: String) -> [String: Any]? {
        guard UUID(uuidString: id) != nil else { return nil }
        let url = root.appendingPathComponent(id + ".status.json")
        guard let meta = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
              meta.isSymbolicLink != true, (meta.fileSize ?? 999999) < 131072,
              let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["id"] as? String == id, value["source"] as? String == "chat" else { return nil }
        return value
    }

    private func isPersistedChatRequest(_ id: String) -> Bool { readChatStatus(id) != nil }
}
