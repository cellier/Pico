import Cocoa
import AVFoundation
import Security

struct BailianConfig {
    let region: String
    let workspace: String
    var account: String { region + ":" + workspace }
    var endpoint: URL? {
        guard ["cn-beijing", "ap-southeast-1"].contains(region),
              workspace.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,99}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "wss://\(workspace).\(region).maas.aliyuncs.com/api-ws/v1/inference")
    }
    static var legacy: BailianConfig { BailianConfig(region: UserDefaults.standard.string(forKey:"tts.region") ?? "", workspace: UserDefaults.standard.string(forKey:"tts.workspace") ?? "") }
    static var saved: BailianConfig {
        do { return try BailianCredentials.sharedAccount()?.config ?? legacy }
        catch { return BailianConfig(region: "", workspace: "") }
    }
}

/// Telos owns this file. Pico only reads it, so one saved account serves both apps.
enum BailianCredentials {
    struct Account: Codable {
        let region: String
        let workspace: String
        let apiKey: String
        var config: BailianConfig { BailianConfig(region: region, workspace: workspace) }
    }
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Telos/bailian.json")
    static var usesTelosSettings: Bool { FileManager.default.fileExists(atPath: settingsURL.path) }
    static func sharedAccount(at file: URL = settingsURL) throws -> Account? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        guard data.count < 64_000 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(Account.self, from: data)
    }
    static func load(at file: URL = settingsURL, legacy: BailianConfig = .legacy,
                     legacyRead: (String) -> String? = VoiceKeychain.readLegacy) throws -> Account {
        let account: Account
        if let saved = try sharedAccount(at: file) {
            // An empty, changed or invalid saved account never resurrects a legacy key.
            account = saved
        } else {
            guard let key = legacyRead(legacy.account) else { throw URLError(.userAuthenticationRequired) }
            account = Account(region: legacy.region, workspace: legacy.workspace, apiKey: key)
        }
        guard account.config.endpoint != nil, !account.apiKey.isEmpty,
              !account.apiKey.contains(where: { $0.isWhitespace }) else { throw URLError(.userAuthenticationRequired) }
        return account
    }
}
enum VoiceKeychain {
    // Legacy macOS login-keychain ACL dialogs do not honor every SecItem UI hint.
    // Keep optional Security interaction disabled for this process, including writes.
    private static let accessLock = NSRecursiveLock()
    private static func withoutAuthenticationUI<T>(_ denied: T, _ operation: () -> T) -> T {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return denied }
        return operation()
    }
    static let service = "local.original.sprout.bailian-tts"
    static func query(_ account:String)->[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail] }
    static func read(_ account:String)->String? {
        guard let saved = try? BailianCredentials.load(), saved.config.account == account else { return nil }
        return saved.apiKey
    }
    static func readLegacy(_ account:String)->String? {
        return withoutAuthenticationUI(nil) {
        var q=query(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess,let data=result as? Data else{return nil}
        return String(data:data,encoding:.utf8)
        }
    }
    static func save(_ value:String,account:String)->Bool {
        return withoutAuthenticationUI(false) {
        let q=query(account), attrs:[String:Any]=[kSecValueData as String:Data(value.utf8)]
        let result=SecItemUpdate(q as CFDictionary,attrs as CFDictionary)
        if result==errSecSuccess{return true};guard result==errSecItemNotFound else{return false}
        var item=q;item[kSecValueData as String]=Data(value.utf8);item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary,nil)==errSecSuccess
        }
    }
}
struct BailianProtocol {
    static let model="qwen-audio-3.0-tts-flash"
    static func message(_ action:String,id:String,text:String?=nil,language:String="en")->[String:Any] {
        var payload:[String:Any]=["input":text.map{["text":$0]} ?? [:]]
        if action=="run-task" {payload=["task_group":"audio","task":"tts","function":"SpeechSynthesizer","model":model,"input":[:],"parameters":["text_type":"PlainText","voice":language=="zh" ? "longanfengyue":"loongmary","format":"mp3","sample_rate":22050,"volume":50,"rate":1,"pitch":1,"enable_ssml":false]]}
        return ["header":["action":action,"task_id":id,"streaming":"duplex"],"payload":payload]
    }
    static func event(_ value:String,id:String)throws->String {
        let object=try JSONSerialization.jsonObject(with:Data(value.utf8)) as? [String:Any]
        guard let h=object?["header"] as? [String:Any], h["task_id"] as? String==id,let event=h["event"] as? String else{throw CocoaError(.coderInvalidValue)}
        return event
    }
}
// A new connection per short reply. No retries, disk audio cache, telemetry, or credentials in WebKit.
final class CloudSpeech:NSObject,AVAudioPlayerDelegate {
    var socket:URLSessionWebSocketTask?, session:URLSession?, player:AVAudioPlayer?, job:Task<Void,Never>?, timeout:Timer?
    var generation=UUID(), active=false
    var finished:((Bool)->Void)?
    func cancel(){if active{log("cloud tts cancelled generation=\(generation.uuidString)")};generation=UUID();active=false;job?.cancel();job=nil;timeout?.invalidate();timeout=nil;socket?.cancel(with:.goingAway,reason:nil);socket=nil;session?.invalidateAndCancel();session=nil;player?.stop();player=nil;finished=nil}
    @discardableResult func speak(_ text:String,language:String,force:Bool=false,completion:@escaping(Bool)->Void)->Bool {
        guard force || UserDefaults.standard.bool(forKey:"tts.enabled") else{return false}
        guard text.count<=12000 else{log("cloud tts skipped oversized reply; full system speech fallback");return false}
        let segments=SpeechText.chunks(text)
        guard !segments.isEmpty else{return false}
        guard let account=try? BailianCredentials.load(),let url=account.config.endpoint else{return false}
        let key=account.apiKey
        cancel();active=true;finished=completion;let token=generation,id=UUID().uuidString
        log("cloud tts request id=\(id) chars=\(text.count) segments=\(segments.count) language=\(language)")
        var request=URLRequest(url:url);request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization");request.timeoutInterval=20
        let configuration=URLSessionConfiguration.ephemeral;configuration.urlCache=nil;configuration.httpCookieStorage=nil
        let session=URLSession(configuration:configuration);self.session=session
        let ws=session.webSocketTask(with:request);self.socket=ws;ws.resume()
        timeout=Timer.scheduledTimer(withTimeInterval:120,repeats:false){[weak self] _ in log("cloud tts synthesis timeout id=\(id)");self?.finish(false,token:token)}
        job=Task { @MainActor [weak self] in
            guard let self else{return}
            do {
                func send(_ action:String,_ input:String?=nil) async throws {
                    let data=try JSONSerialization.data(withJSONObject:BailianProtocol.message(action,id:id,text:input,language:language))
                    try await ws.send(.string(String(decoding:data,as:UTF8.self)))
                }
                try await send("run-task")
                var data=Data(),started=false
                while !Task.isCancelled && self.generation==token {
                    let message=try await ws.receive()
                    switch message {
                    case .data(let bytes): guard data.count+bytes.count<8_000_000 else{throw CocoaError(.fileReadTooLarge)};data.append(bytes)
                    case .string(let json):
                        switch try BailianProtocol.event(json,id:id) {
                        case "task-started":guard !started else{throw CocoaError(.coderInvalidValue)};started=true;for (index,segment) in segments.enumerated(){guard self.generation==token,!Task.isCancelled else{return};try await send("continue-task",segment);log("cloud tts sent id=\(id) segment=\(index+1)/\(segments.count) chars=\(segment.count)")};try await send("finish-task");log("cloud tts input finished id=\(id)")
                        case "task-failed":log("cloud tts server task-failed id=\(id)");throw CocoaError(.coderInvalidValue)
                        case "task-finished":
                            guard self.generation==token,!Task.isCancelled,!data.isEmpty else{return self.finish(false,token:token)}
                            log("cloud tts audio complete id=\(id) bytes=\(data.count)");self.timeout?.invalidate();ws.cancel(with:.normalClosure,reason:nil);session.finishTasksAndInvalidate();self.socket=nil;self.session=nil
                            let audio=try AVAudioPlayer(data:data);self.player=audio;audio.delegate=self
                            guard audio.prepareToPlay(),audio.play() else{throw CocoaError(.fileReadCorruptFile)}
                            log("cloud tts playback started id=\(id) language=\(language) duration=\(audio.duration)");return
                        default:break
                        }
                    @unknown default:throw CocoaError(.coderInvalidValue)
                    }
                }
            }catch { if self.generation==token && !Task.isCancelled{log("cloud tts transport or decode error id=\(id)");self.finish(false,token:token)} }
        }
        return true
    }
    func finish(_ success:Bool,token:UUID){guard token==generation else{return};let callback=finished;log("cloud tts completed success=\(success)");active=false;cancel();callback?(success)}
    func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool){guard player === self.player else{return};log("cloud tts playback finished success=\(flag)");finish(flag,token:generation)}
    func audioPlayerDecodeErrorDidOccur(_ player:AVAudioPlayer,error:Error?){guard player === self.player else{return};log("cloud tts playback decode error");finish(false,token:generation)}
}
final class VoiceSettings:NSObject,NSWindowDelegate {
    var window:NSWindow!, region=NSPopUpButton(), workspace=NSTextField(), secret=NSSecureTextField(), enabled=NSButton(), recognition=NSButton(), message=NSTextField(labelWithString:"")
    let accountNotice=NSTextField(wrappingLabelWithString:"")
    var trial:((String,String)->Void)?
    var recognitionTrial:(()->Void)?
    func show(){
        if window != nil{refreshAccountSource();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return}
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:530),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title=L("Pico · Voice","Pico · 语音");window.isReleasedWhenClosed=false;window.delegate=self
        let view=window.contentView!
        func label(_ s:String,_ y:CGFloat,_ size:CGFloat=13){let v=NSTextField(wrappingLabelWithString:s);v.frame=NSRect(x:24,y:y,width:512,height:44);v.font = .systemFont(ofSize:size);view.addSubview(v)}
        label(L("Pico · Listening & speaking","Pico · 聆听与回复"),475,18)
        label(L("Cloud recognition sends your held recording to Bailian; cloud voice sends reply text. Both reuse the account saved in Telos Settings. Turn recognition off for local ASR.","云端识别将录音发给百炼，云端朗读发送回复文字。两者复用 Telos Settings 保存的账号；关闭云端识别可使用本地模型。"),425)
        recognition=NSButton(checkboxWithTitle:L("Bailian recognition · Chinese + English + mixed","百炼语音识别 · 中文、英文及混读"),target:nil,action:nil);recognition.frame=NSRect(x:24,y:378,width:512,height:25);recognition.state=UserDefaults.standard.bool(forKey:"asr.enabled") ? .on:.off;view.addSubview(recognition)
        let check=NSButton(title:L("Test mixed recognition (paid)","测试中英混读（付费）"),target:self,action:#selector(testRecognition));check.frame=NSRect(x:24,y:335,width:300,height:30);check.bezelStyle = .rounded;view.addSubview(check)
        region.frame=NSRect(x:24,y:298,width:220,height:28);region.addItems(withTitles:[L("Choose account region…","选择账号地域…"),L("Beijing","北京"),L("Singapore","新加坡")]);let saved=BailianConfig.saved;region.selectItem(at:saved.region=="cn-beijing" ? 1:saved.region=="ap-southeast-1" ? 2:0);view.addSubview(region)
        workspace.frame=NSRect(x:260,y:298,width:275,height:26);workspace.placeholderString=L("Bailian workspace ID","百炼业务空间 ID");workspace.stringValue=saved.workspace;view.addSubview(workspace)
        secret.frame=NSRect(x:24,y:252,width:511,height:26);secret.placeholderString=L("New API key · blank keeps existing key","新的 API Key · 留空保留已存密钥");view.addSubview(secret)
        enabled=NSButton(checkboxWithTitle:L("Enable paid cloud voice for replies","启用付费云端回复语音"),target:nil,action:nil);enabled.frame=NSRect(x:24,y:212,width:512,height:25);enabled.state=UserDefaults.standard.bool(forKey:"tts.enabled") ? .on:.off;view.addSubview(enabled)
        accountNotice.frame=NSRect(x:24,y:139,width:512,height:62);accountNotice.font = .systemFont(ofSize:12);view.addSubview(accountNotice)
        let save=NSButton(title:L("Save configuration","保存配置"),target:self,action:#selector(save));save.frame=NSRect(x:24,y:96,width:160,height:30);save.bezelStyle = .rounded;view.addSubview(save)
        let en=NSButton(title:L("Try English (paid)","试听英文（付费）"),target:self,action:#selector(tryEnglish));en.frame=NSRect(x:190,y:96,width:170,height:30);en.bezelStyle = .rounded;view.addSubview(en)
        let zh=NSButton(title:L("Try Chinese (paid)","试听中文（付费）"),target:self,action:#selector(tryChinese));zh.frame=NSRect(x:365,y:96,width:170,height:30);zh.bezelStyle = .rounded;view.addSubview(zh)
        message.frame=NSRect(x:24,y:24,width:512,height:54);message.lineBreakMode = .byWordWrapping;message.maximumNumberOfLines=3;view.addSubview(message)
        refreshAccountSource();window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func refreshAccountSource(){
        let shared=BailianCredentials.usesTelosSettings
        region.isEnabled = !shared;workspace.isEditable = !shared;secret.isEnabled = !shared
        if shared {
            let saved=BailianConfig.saved
            region.selectItem(at:saved.region=="cn-beijing" ? 1:saved.region=="ap-southeast-1" ? 2:0)
            workspace.stringValue=saved.workspace;secret.stringValue=""
            secret.placeholderString=L("Using the API key saved in Telos Settings","使用 Telos Settings 已保存的 API Key")
            accountNotice.stringValue=L("Account managed in Telos Settings. Pico reuses it after restart; no separate key is needed. Save configuration changes only Pico's voice switches. Cloud usage is billed by Bailian.","账号在 Telos Settings 管理，Pico 重启后继续复用，无需再填密钥。保存配置只更改 Pico 的语音开关。云端识别与朗读按百炼用量计费。")
        } else {
            secret.placeholderString=L("New API key · blank keeps existing key","新的 API Key · 留空保留已存密钥")
            accountNotice.stringValue=L("Save your Bailian account once in Telos Settings to share it with Pico. Until then, this panel uses Pico's existing Keychain account. Cloud usage is billed by Bailian.","推荐在 Telos Settings 保存一次百炼账号，即可与 Pico 共用。未配置时使用 Pico 已有的钥匙串账号。云端识别与朗读按百炼用量计费。")
        }
    }
    @objc func save(){
        refreshAccountSource()
        if BailianCredentials.usesTelosSettings {
            if (enabled.state == .on || recognition.state == .on) && (try? BailianCredentials.load()) == nil {
                message.stringValue=L("Check the saved Bailian account in Telos Settings.","请在 Telos Settings 检查已保存的百炼账号。");return
            }
            UserDefaults.standard.set(enabled.state == .on,forKey:"tts.enabled")
            UserDefaults.standard.set(recognition.state == .on,forKey:"asr.enabled")
            message.stringValue=L("Voice switches saved. Reusing the account in Telos Settings.","语音开关已保存，继续使用 Telos Settings 中的账号。")
            return
        }
        let r=region.indexOfSelectedItem==1 ? "cn-beijing":region.indexOfSelectedItem==2 ? "ap-southeast-1":""
        let config=BailianConfig(region:r,workspace:workspace.stringValue.trimmingCharacters(in:.whitespacesAndNewlines))
        guard config.endpoint != nil else{message.stringValue=L("Choose the key's region and enter a valid workspace ID.","请选择密钥所属地域并填写正确的业务空间 ID。");return}
        let key=secret.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        if !key.isEmpty && !VoiceKeychain.save(key,account:config.account){message.stringValue=L("Keychain save failed. Configuration was not enabled.","钥匙串保存失败，未启用配置。");return}
        if (enabled.state == .on || recognition.state == .on) && key.isEmpty && VoiceKeychain.read(config.account)==nil{message.stringValue=L("Enter your new API key before enabling cloud voice.","启用前请填写新的 API Key。");return}
        UserDefaults.standard.set(r,forKey:"tts.region");UserDefaults.standard.set(config.workspace,forKey:"tts.workspace");UserDefaults.standard.set(enabled.state == .on,forKey:"tts.enabled");UserDefaults.standard.set(recognition.state == .on,forKey:"asr.enabled");secret.stringValue=""
        message.stringValue=L("Saved. No cloud request has been made. Trial buttons use the saved configuration.","已保存，尚未发起云端调用。试听按钮使用已保存的配置。")
    }
    @objc func testRecognition(){recognitionTrial?()}
    @objc func tryEnglish(){trial?("Hello. I am here to help.","en")}
    @objc func tryChinese(){trial?("你好，我在这里陪你。","zh")}
    func windowWillClose(_ notification:Notification){secret.stringValue=""}
}
