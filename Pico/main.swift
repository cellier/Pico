import Cocoa
import WebKit
import AVFoundation

let project=URL(fileURLWithPath:ProcessInfo.processInfo.environment["SPROUT_PROJECT"] ?? Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path)
let logDirectory=URL(fileURLWithPath:ProcessInfo.processInfo.environment["PICO_LOG_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pico").path)
func log(_ text:String){try? FileManager.default.createDirectory(at:logDirectory,withIntermediateDirectories:true);let u=logDirectory.appendingPathComponent("runtime.log");let d="\(Date()) \(text)\n".data(using:.utf8)!;if let h=try? FileHandle(forWritingTo:u){h.seekToEndOfFile();h.write(d);try? h.close()}else{try? d.write(to:u)}}
var chinese:Bool {Locale.preferredLanguages.first?.hasPrefix("zh") == true}
func L(_ en:String,_ zh:String)->String{chinese ? zh:en}
let petWindowSide:CGFloat = 143.36
enum PetScreenFacing {
 struct Screen {let frame:NSRect;let visibleFrame:NSRect}
 struct Direction:Equatable {
  let x:Double;let y:Double
  var script:String{"window.setScreenFacing?.(\(x),\(y))"}
 }
 static func direction(windowFrame:NSRect,screens:[Screen],preferred:Int?=nil)->Direction? {
  let candidates=screens.indices.filter{screens[$0].frame.width>0 && screens[$0].frame.height>0 && screens[$0].visibleFrame.width>0 && screens[$0].visibleFrame.height>0}
  guard !candidates.isEmpty else{return nil}
  func overlap(_ index:Int)->CGFloat {
   let rect=windowFrame.intersection(screens[index].frame)
   return rect.isNull ? 0:max(0,rect.width)*max(0,rect.height)
  }
  let largest=candidates.map(overlap).max() ?? 0
  let selected:Int
  if largest>0 {
   let mostVisible=candidates.filter{overlap($0)==largest}
   selected=preferred.flatMap{mostVisible.contains($0) ? $0:nil} ?? mostVisible[0]
  }else{
   // A disconnected display can leave the panel outside all current displays.
   selected=candidates.min {a,b in
    let af=screens[a].visibleFrame,bf=screens[b].visibleFrame
    return hypot(windowFrame.midX-af.midX,windowFrame.midY-af.midY)<hypot(windowFrame.midX-bf.midX,windowFrame.midY-bf.midY)
   }!
  }
  let visible=screens[selected].visibleFrame
  func normalized(_ delta:CGFloat,_ travel:CGFloat)->Double {
   let value=max(-1,min(1,Double(delta/max(1,travel))))
   return (value*1024).rounded()/1024
  }
  // AppKit uses positive Y upward; independent display origins are preserved.
  return Direction(x:normalized(visible.midX-windowFrame.midX,(visible.width-windowFrame.width)/2),y:normalized(visible.midY-windowFrame.midY,(visible.height-windowFrame.height)/2))
 }
}
enum PetVisualState {
 static let emotions:Set<String>=["idle","listening","transcribing","thinking","working","speaking","completed","error","needs_input","awaiting_approval","cancelled"]
 static func script(for state:String)->String {
  let emotion=emotions.contains(state) ? state:"idle"
  let modes=["listening":"meeting","speaking":"meeting","transcribing":"thinking","thinking":"thinking","working":"working"]
  // Props keep their existing modes; eyes receive the full voice/task state.
  return "window.sprout?.setState('\(modes[emotion] ?? "idle")');window.sprout?.setEmotion('\(emotion)')"
 }
}
enum PetSkin:String,CaseIterable {
 case classic,blossom,snowball
 static let preferenceKey="pet.skin"
 static func load(from defaults:UserDefaults = .standard)->PetSkin {
  PetSkin(rawValue:defaults.string(forKey:preferenceKey) ?? "") ?? .snowball
 }
 func save(to defaults:UserDefaults = .standard){defaults.set(rawValue,forKey:Self.preferenceKey)}
 var script:String{"window.sprout?.setSkin('\(rawValue)')"}
}
class PetPanel:NSPanel{override var canBecomeKey:Bool{false};override var canBecomeMain:Bool{false}}
class TouchView:NSView{
 weak var owner:AppDelegate?;var start=NSPoint.zero,origin=NSPoint.zero;var dragging=false,moved=false,voiceHold=false;var arm:Timer?
 override var acceptsFirstResponder:Bool{false}
 override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
 override func accessibilityPerformPress()->Bool{owner?.web.evaluateJavaScript("window.cheer()",completionHandler:nil);return true}
 override func mouseDown(with event:NSEvent){owner?.pressFeedback(true);owner?.stopSpeaking();start=NSEvent.mouseLocation;origin=window!.frame.origin;dragging=true;moved=false;voiceHold=false;arm?.invalidate();let t=Timer(timeInterval:0.45,repeats:false){[weak self] _ in guard let self,self.dragging,!self.moved else{return};self.voiceHold=true;self.owner?.beginVoice()};arm=t;RunLoop.main.add(t,forMode:.common)}
 override func mouseDragged(with event:NSEvent){guard !voiceHold else{return};let p=NSEvent.mouseLocation,dx=p.x-start.x,dy=p.y-start.y;if hypot(dx,dy)>4{moved=true;arm?.invalidate()};if moved{window?.setFrameOrigin(NSPoint(x:origin.x+dx,y:origin.y+dy))}}
 override func mouseUp(with event:NSEvent){arm?.invalidate();owner?.pressFeedback(false);dragging=false;if voiceHold{owner?.finishVoice()}else if !moved{owner?.web.evaluateJavaScript("window.cheer()",completionHandler:nil)}}
 override func rightMouseDown(with event:NSEvent){if let menu=owner?.menu{NSMenu.popUpContextMenu(menu,with:event,for:self)}}
}
class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate,WKScriptMessageHandler,NSSpeechSynthesizerDelegate{
 var panel:PetPanel!,web:WKWebView!,touch:TouchView!,status:NSStatusItem!,menu:NSMenu!,timer:Timer!
 var ready=false,paused=false,pinned=true,polling=false,ticks=0,current="idle",terminal="idle"
 var recorder:AVAudioRecorder?,audioURL:URL?,recordTimer:Timer?,meterTimer:Timer?,peak:Float = -160
 let cloudSpeech=CloudSpeech();var cloudRecognition=CloudRecognition();let voiceSettings=VoiceSettings()
 var recognitionAudio:URL?
 var replyLanguage:String?
 var requestID:String?,lastRouteRequestID:String?,lastResponse="",requestStart=Date(),taskID:String?,speech=NSSpeechSynthesizer(),spokenSignature=""
 var pauseMenu:NSMenuItem!,pinMenu:NSMenuItem!,stopMenu:NSMenuItem!,detailMenu:NSMenuItem!
 var skin=PetSkin.load(),skinMenu:NSMenu?
 var facingUpdate:DispatchWorkItem?,lastScreenFacing:PetScreenFacing.Direction?
 let root:URL
 init(root:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Telos/companion-v1")){self.root=root;super.init()}
 var telosURL:URL?{TelosApplication.resolve()}
 func label(_ state:String)->String{switch state{case "listening":return L("Listening","正在聆听");case "transcribing":return L("Transcribing","正在转写");case "thinking":return L("Thinking","思考中");case "working":return L("Working","工作中");case "speaking":return L("Speaking","正在回复");case "completed":return L("Done","已完成");case "error":return L("Error","出错了");case "needs_input","awaiting_approval":return L("Needs input","等待确认");case "cancelled":return L("Cancelled","已取消");default:return L("Idle","闲暇")}}
 func icon()->NSImage{let image=NSImage(size:NSSize(width:18,height:18),flipped:false){rect in NSGraphicsContext.saveGraphicsState();let t=NSAffineTransform();t.scale(by:18/35);t.concat();let p=NSBezierPath(roundedRect:NSRect(x:0,y:0,width:35,height:35),xRadius:12,yRadius:12);p.append(NSBezierPath(roundedRect:NSRect(x:8.71094,y:12.25,width:6.12496,height:10.5),xRadius:2.5,yRadius:2.5));p.append(NSBezierPath(roundedRect:NSRect(x:20.96,y:12.25,width:6.125,height:10.5),xRadius:2.5,yRadius:2.5));p.windingRule = .evenOdd;NSColor.black.setFill();p.fill();NSGraphicsContext.restoreGraphicsState();return true};image.isTemplate=true;return image}
 func applicationDidFinishLaunching(_ notification:Notification){
  NSApp.setActivationPolicy(.accessory);speech.delegate=self
  let f=NSScreen.main!.visibleFrame
  panel=PetPanel(contentRect:NSRect(x:f.maxX-200-petWindowSide/2,y:f.minY+250-petWindowSide/2,width:petWindowSide,height:petWindowSide),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false);panel.delegate=self;panel.title="Pico";panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.level = .floating;panel.hidesOnDeactivate=false;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.isReleasedWhenClosed=false
  let config=WKWebViewConfiguration();config.userContentController.add(self,name:"native");web=WKWebView(frame:NSRect(x:0,y:0,width:petWindowSide,height:petWindowSide),configuration:config);web.setValue(false,forKey:"drawsBackground")
  let container=NSView(frame:web.frame);container.addSubview(web);touch=TouchView(frame:web.frame);touch.owner=self;touch.setAccessibilityElement(true);touch.setAccessibilityRole(.button);touch.setAccessibilityLabel(L("Pico: hold to speak, move to drag, right-click for menu","Pico：按住说话，移动拖动，右键打开菜单"));container.addSubview(touch);panel.contentView=container
  let html=Bundle.main.url(forResource:"index",withExtension:"html")!;web.loadFileURL(html,allowingReadAccessTo:html.deletingLastPathComponent())
  status=NSStatusBar.system.statusItem(withLength:26);status.button?.image=icon();status.button?.imagePosition = .imageOnly;status.button?.font=NSFont.systemFont(ofSize:12,weight:.medium);status.button?.wantsLayer=true;status.button?.layer?.cornerRadius=10
  rebuildMenu();setState("idle");panel.orderFrontRegardless()
  timer=Timer(timeInterval:1/15,repeats:true){[weak self] _ in self?.poll()};timer.tolerance=0.012;RunLoop.main.add(timer,forMode:.common)
  NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(sleepPet),name:NSWorkspace.screensDidSleepNotification,object:nil);NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(wakePet),name:NSWorkspace.screensDidWakeNotification,object:nil)
  NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(motionPreference),name:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil)
  NotificationCenter.default.addObserver(self,selector:#selector(languageChanged),name:NSLocale.currentLocaleDidChangeNotification,object:nil)
  NotificationCenter.default.addObserver(self,selector:#selector(displayLayoutChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
  log("voice companion launched; opaque=false; key=\(panel.isKeyWindow)")
 }
 func rebuildMenu(){menu=NSMenu();menu.addItem(withTitle:label(current),action:nil,keyEquivalent:"");menu.addItem(withTitle:L("Hold still to speak · Move to drag","按住不动说话 · 移动拖动"),action:nil,keyEquivalent:"");stopMenu=menu.addItem(withTitle:L("Stop / Cancel voice conversation","停止或取消语音对话"),action:#selector(cancelVoice),keyEquivalent:".");stopMenu.target=self;detailMenu=menu.addItem(withTitle:L("Open conversation / task in Pico","在 Pico 查看对话 / 任务"),action:#selector(openTask),keyEquivalent:"");detailMenu.target=self;menu.addItem(.separator());pinMenu=menu.addItem(withTitle:L("Always on top","保持置顶"),action:#selector(togglePin),keyEquivalent:"");pinMenu.target=self;pauseMenu=menu.addItem(withTitle:L("Pause animation","暂停动画"),action:#selector(togglePause),keyEquivalent:"");pauseMenu.target=self;let reset=menu.addItem(withTitle:L("Reset position","重置位置"),action:#selector(resetPosition),keyEquivalent:"");reset.target=self;menu.addItem(.separator());let quit=menu.addItem(withTitle:L("Quit Pico","退出 Pico"),action:#selector(quitApp),keyEquivalent:"q");quit.target=self;
#if VOICE_QA
menu.addItem(.separator());for (title,selector) in [("QA: submit audio fixture",#selector(qaSend)),("QA: stop playback",#selector(qaStop)),("QA: cancel pending audio",#selector(qaCancel))]{let item=menu.addItem(withTitle:title,action:selector,keyEquivalent:"");item.target=self}
#endif
let meeting=NSMenuItem(title:L("Meeting companion…","会议代理…"),action:#selector(openMeeting),keyEquivalent:"");meeting.target=self;menu.insertItem(meeting,at:4);
let settings=NSMenuItem(title:L("Voice settings…","语音设置…"),action:#selector(openVoiceSettings),keyEquivalent:"");settings.target=self;menu.insertItem(settings,at:4)
let skinItem=NSMenuItem(title:L("Skin","皮肤"),action:nil,keyEquivalent:"");let choices=NSMenu(title:skinItem.title)
for choice in PetSkin.allCases {
 let title:String
 switch choice {
 case .classic:title=L("Classic Pico","经典 Pico")
 case .blossom:title=L("Pink Blossom","粉色花朵")
 case .snowball:title=L("White Balloon","白色气球")
 }
 let item=NSMenuItem(title:title,action:#selector(selectSkin(_:)),keyEquivalent:"");item.target=self;item.representedObject=choice.rawValue;choices.addItem(item)
}
skinMenu=choices;skinItem.submenu=choices;menu.insertItem(skinItem,at:6);updateSkinMenu();status.menu=menu;updateLabels()}
 func updateSkinMenu(){for item in skinMenu?.items ?? []{item.state=(item.representedObject as? String)==skin.rawValue ? .on:.off}}
 @objc func selectSkin(_ item:NSMenuItem){
  guard let raw=item.representedObject as? String,let selected=PetSkin(rawValue:raw),selected != skin else{return}
  skin=selected;skin.save();updateSkinMenu();applySkin()
 }
 func applySkin(){guard ready else{return};web?.evaluateJavaScript(skin.script,completionHandler:nil)}
 func syncScreenFacing(force:Bool=false){
  guard ready,let panel,let web else{return}
  let displays=NSScreen.screens
  let geometry=displays.map{PetScreenFacing.Screen(frame:$0.frame,visibleFrame:$0.visibleFrame)}
  let preferred=displays.firstIndex{ $0 === panel.screen }
  guard let facing=PetScreenFacing.direction(windowFrame:panel.frame,screens:geometry,preferred:preferred),force || facing != lastScreenFacing else{return}
  lastScreenFacing=facing;web.evaluateJavaScript(facing.script,completionHandler:nil)
 }
 func scheduleScreenFacing(){
  guard ready,facingUpdate == nil else{return}
  let update=DispatchWorkItem{[weak self] in self?.facingUpdate=nil;self?.syncScreenFacing()}
  facingUpdate=update;DispatchQueue.main.asyncAfter(deadline:.now()+1.0/30,execute:update)
 }
 func windowDidMove(_ notification:Notification){scheduleScreenFacing()}
 func windowDidChangeScreen(_ notification:Notification){scheduleScreenFacing()}
 @objc func displayLayoutChanged(){syncScreenFacing(force:true)}
 @objc func openMeeting(){
  cancelVoice()
  guard let telosURL else{lastResponse=L("Could not find the Pico app. Open Pico and try again.","找不到 Pico 主应用，请打开 Pico 后重试。");setState("error");return}
  let configuration=NSWorkspace.OpenConfiguration();configuration.activates=false;configuration.promptsUserIfNeeded=false
  // Open first, then publish: application reopen must not raise the main panel over this window.
  NSWorkspace.shared.openApplication(at:telosURL,configuration:configuration){[weak self] _,error in
   DispatchQueue.main.async {
    guard let self else{return}
    guard error == nil else{self.lastResponse=L("Could not open Pico.","未能打开 Pico。");self.setState("error");return}
    do {
     try FileManager.default.createDirectory(at:self.root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
     try Data("open".utf8).write(to:self.root.appendingPathComponent("pico-meeting.open"),options:.atomic)
    }catch{self.lastResponse=L("Could not open the meeting companion.","未能打开会议代理。");self.setState("error")}
   }
  }
 }
 func updateLabels(){status.button?.title="";status.button?.setAccessibilityLabel("Pico · "+label(current));menu?.item(at:0)?.title=label(current);status.button?.toolTip=label(current)+(lastResponse.isEmpty ? "":" · "+String(lastResponse.prefix(180)));status.button?.layer?.backgroundColor=NSColor.labelColor.withAlphaComponent(0.08).cgColor;pinMenu?.state=pinned ? .on:.off;pauseMenu?.title=paused ? L("Resume animation","恢复动画"):L("Pause animation","暂停动画")}
 func setState(_ s:String){
  // Voice feedback stays on Pico and in its menu; never cover the desktop.
  if s=="error" && lastResponse.isEmpty {lastResponse=L("Voice input failed. Please try again.","语音输入失败，请重试。")}
  if current==s {updateLabels();return}
  guard current != s else{return};current=s;updateLabels();syncVisualState();log("voice state=\(s)")}
 func syncVisualState(){guard ready else{return};web?.evaluateJavaScript(PetVisualState.script(for:current),completionHandler:nil)}
 func notifyGesture(_ down:Bool){DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.original.sprout.gesture"),object:"local.original.sprout",userInfo:["down":down],deliverImmediately:true)}
 func pressFeedback(_ down:Bool){notifyGesture(down);web.evaluateJavaScript("window.setPressed(\(down))",completionHandler:nil)
#if VOICE_QA
for delay in [0.0,0.07,0.20,0.5]{DispatchQueue.main.asyncAfter(deadline:.now()+delay){self.web.evaluateJavaScript("JSON.stringify(window.petStats().interaction)"){v,_ in if let v=v as? String{log("press native down=\(down) delay=\(delay) "+v)}}}}
#endif
 }
 @objc func motionPreference(){web?.evaluateJavaScript("window.setReducedMotion(\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))",completionHandler:nil)}
 @objc func languageChanged(){rebuildMenu()}
 func userContentController(_ u:WKUserContentController,didReceive m:WKScriptMessage){guard let v=m.body as? [String:Any],let type=v["type"] as? String else{return};if type=="ready"{ready=true;motionPreference();applySkin();syncScreenFacing(force:true);syncVisualState();updateLabels();log("WebGL ready")
#if VOICE_QA
DispatchQueue.main.asyncAfter(deadline:.now()+1){self.submitFixture()}
#endif
} }
 func poll(){guard ready else{return};if !touch.dragging && !polling{polling=true;let p=NSEvent.mouseLocation,x=p.x-panel.frame.minX,y=web.bounds.height-(p.y-panel.frame.minY);web.evaluateJavaScript("window.pointerAt(\(x),\(y))"){[weak self] v,_ in self?.polling=false;self?.panel.ignoresMouseEvents = !(v as? Bool ?? false)}};ticks+=1;if touch.dragging && ticks%6==0{notifyGesture(true)};if ticks%2==0{readStatus()}}

#if VOICE_QA
 @objc func qaSend(){submitFixture()}
 @objc func qaStop(){terminal="completed";speak("This is a local playback interruption test. The speech should stop before this sentence has finished. No task is being executed.");DispatchQueue.main.asyncAfter(deadline:.now()+0.7){self.stopSpeaking();DispatchQueue.main.asyncAfter(deadline:.now()+0.3){log("tts stop verification isSpeaking=\(self.speech.isSpeaking)")}}}
 @objc func qaCancel(){submitFixture();DispatchQueue.main.asyncAfter(deadline:.now()+0.05){self.cancelVoice()}}
 func submitFixture(){
  let id=UUID().uuidString;requestID=id;requestStart=Date();spokenSignature=""
  do {let audio=root.appendingPathComponent(id+".wav");try FileManager.default.copyItem(at:project.appendingPathComponent("qa/voice-question-basic.wav"),to:audio);try id.write(to:project.appendingPathComponent("qa/voice-ui-test-id.txt"),atomically:true,encoding:.utf8);submitAudio(audio,id:id)}catch{setState("error")}
 }
#endif
 func connected()->Bool{guard let d=try? Data(contentsOf:root.appendingPathComponent("heartbeat.json")),let o=(try? JSONSerialization.jsonObject(with:d)) as? [String:Any],let t=o["updated"] as? Double else{return false};return Date().timeIntervalSince1970-t<3}
 func beginVoice(){
  guard !["thinking","working","transcribing","awaiting_approval"].contains(current) else{lastResponse=L("Cancel the current task before starting another.","请先取消当前任务，再开始新的语音。");updateLabels();return}
  guard connected() else{lastResponse=L("Open the updated Pico app, then hold again.","请打开更新后的 Pico，再按住说话。");setState("error");return}
  guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else{lastResponse=L("Allow microphone access in the system prompt, then hold again.","请在系统弹窗允许麦克风，然后重新按住说话。");setState("needs_input");AVCaptureDevice.requestAccess(for:.audio){_ in};return}
  let id=UUID().uuidString;let url=root.appendingPathComponent(id+".wav")
  do{let r=try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16]);r.isMeteringEnabled=true;guard r.prepareToRecord(),r.record() else{throw CocoaError(.fileWriteUnknown)};try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);recorder=r;audioURL=url;requestID=id;lastResponse="";taskID=nil;peak = -160;spokenSignature="";replyLanguage=nil;setState("listening")
   let mt=Timer(timeInterval:0.06,repeats:true){[weak self] _ in guard let self,let r=self.recorder else{return};r.updateMeters();self.peak=max(self.peak,r.averagePower(forChannel:0))};meterTimer=mt;RunLoop.main.add(mt,forMode:.common)
   let rt=Timer(timeInterval:60,repeats:false){[weak self] _ in self?.cancelVoice()};recordTimer=rt;RunLoop.main.add(rt,forMode:.common)
  }catch{lastResponse=L("Microphone could not start.","麦克风未能启动。");setState("error")}
 }
 func submitAudio(_ url:URL,id:String){
  requestStart=Date();setState("transcribing")
  guard UserDefaults.standard.bool(forKey:"asr.enabled") else{sendRecognition(id:id,payload:[:]);return}
  recognitionAudio=url
  cloudRecognition.transcribe(url){[weak self] result in
   guard let self,self.requestID==id else{return}
   self.recognitionAudio=nil
   switch result {
   case .success(let text):
    try? FileManager.default.removeItem(at:url)
    log("cloud asr completed characters=\(text.count)")
    guard !text.isEmpty else{self.requestID=nil;self.lastResponse=L("No speech recognized. Please try again.","没有识别到语音，请重试。");self.setState("cancelled");return}
    self.sendRecognition(id:id,payload:["transcript":text])
   case .failure(let error):
    let failure=error as NSError
    let detail=RecognitionProtocol.diagnostic(error).map{" detail=\($0)"} ?? ""
    log("cloud asr failed domain=\(failure.domain) code=\(failure.code)\(detail); local recovery")
    self.lastResponse=L("Bailian unavailable. Recognizing locally…","百炼暂不可用，正在使用本机识别…");self.updateLabels()
    self.sendRecognition(id:id,payload:[:])
   }
  }
 }
 func sendRecognition(id:String,payload:[String:Any]){
  requestStart=Date()
  do{var request=payload;request["id"]=id;let d=try JSONSerialization.data(withJSONObject:request);try d.write(to:root.appendingPathComponent(id+".request.json"),options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent(id+".request.json").path)}catch{try? FileManager.default.removeItem(at:root.appendingPathComponent(id+".wav"));requestID=nil;lastResponse=L("Could not send speech to Pico.","未能将语音交给 Pico。");setState("error")}
 }
 func finishVoice(){guard let r=recorder,let id=requestID,let url=audioURL else{return};let duration=r.currentTime;r.stop();recorder=nil;recordTimer?.invalidate();meterTimer?.invalidate();audioURL=nil;guard duration>0.35,peak > -54 else{try? FileManager.default.removeItem(at:url);requestID=nil;lastResponse=L("No speech heard. Hold Pico and try again.","没有听清，请按住 Pico 再说一次。");setState("cancelled");return};submitAudio(url,id:id)}

 func readStatus(){guard let id=requestID,recorder==nil else{return}
  let elapsed=Date().timeIntervalSince(requestStart)
  if (elapsed>15 && ["transcribing","thinking","working","awaiting_approval"].contains(current) && !connected()) || (current=="transcribing" && elapsed>90) {
   let disconnected = !connected();cancelVoice()
   lastResponse=disconnected ? L("Pico is not responding. Open Pico and try again.","Pico 暂未响应，请打开 Pico 后重试。") : L("Speech recognition timed out. Please hold Pico and try again.","语音识别超时，请按住 Pico 重试。")
   setState("error");return
  }
  let file=root.appendingPathComponent(id+".status.json")
  guard let d=try? Data(contentsOf:file),let o=(try? JSONSerialization.jsonObject(with:d)) as? [String:Any],o["id"] as? String==id,let s=o["state"] as? String else{return};taskID=o["task_id"] as? String;replyLanguage=o["language"] as? String
  if o["source"] as? String == "chat" || !(taskID?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true){lastRouteRequestID=id}
  if s=="completed" || s=="needs_input" || s=="awaiting_approval" || s=="error"{let signature=id+":"+s;if spokenSignature==signature{return};spokenSignature=signature;terminal=s;lastResponse=o["text"] as? String ?? "";setState(s);let text:String;if s=="awaiting_approval"{text=L("Please review and confirm the action in Pico.","这一步需要你确认，请在 Pico 中查看审批。")}else if s=="error"{text=L("This reply could not finish. Please check Pico.","这次回复未能完成，请到 Pico 查看。")}else{text=shortReply(lastResponse)};if !text.isEmpty{speak(text)}
  }else{setState(s)}
 }
 func shortReply(_ input:String)->String{let text=SpeechText.prepare(input);log("tts prepared source_chars=\(input.count) spoken_chars=\(text.count)");return text}
 func speak(_ text:String){
  stopSpeaking();let language=replyLanguage ?? (text.unicodeScalars.contains{(0x3400...0x9FFF).contains(Int($0.value))} ? "zh":"en")
  if cloudSpeech.speak(text,language:language,completion:{[weak self] success in guard let self else{return};if success{self.setState(self.terminal)}else{log("cloud tts unavailable; system fallback");self.speakSystem(text)}}){setState("speaking");return}
  speakSystem(text)
 }
 func speakSystem(_ text:String){
  speech.stopSpeaking();speech.rate=175
  let isChinese=text.unicodeScalars.contains{(0x3400...0x9FFF).contains(Int($0.value))}
  let language=replyLanguage ?? (isChinese ? "zh":"en")
  let available=NSSpeechSynthesizer.availableVoices.filter{(NSSpeechSynthesizer.attributes(forVoice:$0)[.localeIdentifier] as? String)?.hasPrefix(language)==true}
  if let voice=available.first(where:{$0.rawValue.lowercased().contains(language == "zh" ? "tingting":"samantha")}) ?? available.first{speech.setVoice(voice);log("tts selected voice=\(voice.rawValue) language=\(language)")}
  setState("speaking");let accepted=speech.startSpeaking(text);log("tts accepted=\(accepted) characters=\(text.count)");if !accepted{lastResponse=L("System voice playback is unavailable; open the result in Pico.","系统语音暂不可用，请到 Pico 查看结果。");setState(terminal)}
 }
 func stopSpeaking(){if cloudSpeech.active{cloudSpeech.cancel();setState(terminal)};if speech.isSpeaking{speech.stopSpeaking();log("tts stop requested");setState(terminal)}}
 func speechSynthesizer(_ sender:NSSpeechSynthesizer,willSpeakWord characterRange:NSRange,of string:String){log("tts word callback")}
 func speechSynthesizer(_ sender:NSSpeechSynthesizer,didFinishSpeaking finishedSpeaking:Bool){log("tts finished=\(finishedSpeaking)");if current=="speaking"{setState(terminal)}}
 @objc func openVoiceSettings(){
 voiceSettings.recognitionTrial={ [weak self] in
  guard let self else{return}
  guard !["listening","transcribing","thinking","working"].contains(self.current) else{self.voiceSettings.message.stringValue=L("Finish the current task first.","请先结束当前任务。");return}
  guard let file=Bundle.main.url(forResource:"asr-mixed-check",withExtension:"wav") else{return}
  self.voiceSettings.message.stringValue=L("Testing a fixed Chinese-English sample…","正在识别固定中英文测试音频…")
  self.cloudRecognition.transcribe(file){ result in
   switch result {
   case .success(let text):self.voiceSettings.message.stringValue=L("Recognized: ","识别结果：")+text
   case .failure(let error):self.voiceSettings.message.stringValue=L("Recognition test failed. Check account/model access. Code: ","识别测试失败，请检查账号和模型权限。错误码：")+String((error as NSError).code)
   }
  }
 };voiceSettings.trial={ [weak self] text,language in
 guard let self else{return};self.stopSpeaking();self.terminal=self.current
 if self.cloudSpeech.speak(text,language:language,force:true,completion:{[weak self] success in guard let self else{return};self.voiceSettings.message.stringValue=success ? L("Cloud trial completed.","云端试听完成。") : L("Cloud trial failed. Check region, workspace, key and model access.","云端试听失败，请检查地域、业务空间、密钥与模型权限。");self.setState(self.terminal)}){self.setState("speaking");self.voiceSettings.message.stringValue=L("Cloud trial requested…","已请求云端试听…")}else{self.voiceSettings.message.stringValue=L("Save the region, workspace and new key first.","请先保存地域、业务空间和新密钥。")}
 };voiceSettings.show()}
 @objc func cancelVoice(){cloudRecognition.cancel();if let url=recognitionAudio{try? FileManager.default.removeItem(at:url)};recognitionAudio=nil;notifyGesture(false);web.evaluateJavaScript("window.setPressed(false)",completionHandler:nil);stopSpeaking();recorder?.stop();recorder=nil;recordTimer?.invalidate();meterTimer?.invalidate();if let u=audioURL{try? FileManager.default.removeItem(at:u)};audioURL=nil;if let id=requestID{try? Data().write(to:root.appendingPathComponent(id+".cancel"),options:.atomic)};requestID=nil;terminal="cancelled";setState("cancelled")}
 @objc func openTask(){
  guard let telosURL else{lastResponse=L("Could not find the Pico app. Open Pico and try again.","找不到 Pico 主应用，请打开 Pico 后重试。");setState("error");return}
  if let id=requestID ?? lastRouteRequestID{try? Data().write(to:root.appendingPathComponent(id+".show"),options:.atomic)}
  let configuration=NSWorkspace.OpenConfiguration();configuration.promptsUserIfNeeded=false
  NSWorkspace.shared.openApplication(at:telosURL,configuration:configuration){[weak self] _,error in
   guard error != nil else{return}
   DispatchQueue.main.async{guard let self else{return};self.lastResponse=L("Could not open Pico.","未能打开 Pico。");self.setState("error")}
  }
 }
 @objc func togglePin(){pinned.toggle();panel.level=pinned ? .floating:.normal;updateLabels()}
 @objc func togglePause(){paused.toggle();web.evaluateJavaScript("window.setPaused(\(paused))",completionHandler:nil);updateLabels()}
 @objc func resetPosition(){let f=NSScreen.main!.visibleFrame;panel.setFrameOrigin(NSPoint(x:f.maxX-200-petWindowSide/2,y:f.minY+250-petWindowSide/2));syncScreenFacing(force:true)}
 @objc func sleepPet(){web.evaluateJavaScript("window.setPressed(false)",completionHandler:nil);if recorder != nil{cancelVoice()};web.evaluateJavaScript("window.setPaused(true)",completionHandler:nil)}
 @objc func wakePet(){web.evaluateJavaScript("window.setPaused(\(paused))",completionHandler:nil);syncScreenFacing(force:true)}
 @objc func quitApp(){cancelVoice();log("quit");NSApp.terminate(nil)}
}
let app=NSApplication.shared,delegate=AppDelegate();app.delegate=delegate;app.run()
