import AppKit
import Foundation

/// Same-user file IPC. No TCP listener, credential, approval decision, or arbitrary file path API.
@MainActor final class CompanionBridge {
    let store: TaskStore
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
    init(store:TaskStore, transcribe:@escaping(URL,@escaping([String:Any])->Void)->Void, cancel:@escaping()->Void, show:@escaping(UUID)->Void) {
        self.store=store;self.transcribe=transcribe;cancelSpeech=cancel;showTask=show
        root=store.dataDir.appendingPathComponent("companion-v1",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let a=try FileManager.default.attributesOfItem(atPath:root.path)
            guard a[.type] as? FileAttributeType == .typeDirectory, (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else{return}
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
            timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.poll()}
            poll()
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
        let heartbeat:[String:Any] = ["protocol":1,"pid":ProcessInfo.processInfo.processIdentifier,"updated":Date().timeIntervalSince1970]
        if Date().timeIntervalSince(heartbeatAt)>1 { heartbeatAt=Date();if let data=try? JSONSerialization.data(withJSONObject:heartbeat){try? data.write(to:root.appendingPathComponent("heartbeat.json"),options:.atomic)} }
        guard let files=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]) else{return}
        for file in files {
            let name=file.lastPathComponent
            if name == "pico-meeting.open" {
                guard let showMeeting else { continue } // Keep cold-start request until the app installs its handler.
                defer { try? FileManager.default.removeItem(at: file) }
                guard let meta = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]), meta.isSymbolicLink != true, (meta.fileSize ?? 99999) < 100, Date().timeIntervalSince(meta.contentModificationDate ?? .distantPast) < 30 else { continue }
                showMeeting(); continue
            }
            if name.hasSuffix(".cancel") {
                let id=String(name.dropLast(7));guard UUID(uuidString:id) != nil else{continue}
                if recognizing==id {cancelSpeech();recognizing=nil}
                if let task=active.removeValue(forKey:id){store.stop(task)}
                try? FileManager.default.removeItem(at:root.appendingPathComponent(id+".wav"));write(id,"cancelled")
                try? FileManager.default.removeItem(at:file);continue
            }
            if name.hasSuffix(".show") {
                let id=String(name.dropLast(5));if let task=active[id]{showTask(task)}
                try? FileManager.default.removeItem(at:file);continue
            }
            guard name.hasSuffix(".request.json") else{continue}
            let id=String(name.dropLast(13));guard UUID(uuidString:id) != nil else{continue}
            defer {try? FileManager.default.removeItem(at:file)}
            guard let meta=try? file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey]),meta.isSymbolicLink != true,(meta.fileSize ?? 99999)<16384,Date().timeIntervalSince(meta.contentModificationDate ?? .distantPast)<120,
                  let data=try? Data(contentsOf:file),let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],request["id"] as? String==id else{continue}
            guard recognizing==nil else {write(id,"error","Speech recognition is busy. Please try again.");continue}
            guard active[id]==nil, !FileManager.default.fileExists(atPath:root.appendingPathComponent(id+".status.json").path) else{continue}
            // Pico may transcribe with the user's selected cloud provider first.
            // Treat that text exactly like locally recognized speech, with the
            // same task execution policy; it conveys no approval decisions.
            if request["transcript"] != nil {
                guard let text=CompanionTranscript.read(request["transcript"]) else {write(id,"error","Invalid speech transcript.");continue}
                startTask(text,id:id);continue
            }
            let audio=root.appendingPathComponent(id+".wav")
            guard let a=try? audio.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]),a.isSymbolicLink != true,(a.fileSize ?? 0)>44,(a.fileSize ?? 0)<2_000_000 else {write(id,"error","Audio input is invalid.");continue}
            recognizing=id;write(id,"transcribing")
            transcribe(audio){[weak self] result in
                guard let self,self.recognizing==id else{return}
                if result["stage"] != nil{return}
                self.recognizing=nil;try? FileManager.default.removeItem(at:audio)
                guard result["error"]==nil else{self.write(id,"error","Local speech recognition failed. Please try again.");return}
                let text=(result["text"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                guard text.count>1 else{self.write(id,"cancelled");return}
                self.startTask(text,id:id)
            }
        }
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
    private func startTask(_ text:String,id:String) {
        guard let task=store.add(text,voiceRequestID:id,voiceLanguage:CompanionLanguage.detect(text)) else{write(id,"error","Could not create the task.");return}
        active[id]=task;write(id,"thinking",task:task)
    }
}
