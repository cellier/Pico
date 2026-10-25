import AppKit
import SwiftUI
import AVFoundation
import PaperKit

@MainActor final class ScreenshotEditor: NSObject, ObservableObject, NSWindowDelegate {
    @Published var message = ""
    @Published var busy = false
    @Published var annotations: [ScreenshotAnnotation] = []
    @Published var target: CGPoint?
    @Published var image: NSImage
    @Published var size: CGSize
    @Published var instruction = ""
    @Published var localEdit = true
    @Published var markupMode = true
    let editUndoManager = UndoManager()
    var markupSession: ScreenshotMarkupSession?
    var canUndo: Bool { editUndoManager.canUndo }
    var canRedo: Bool { editUndoManager.canRedo }
    private let local = LocalImageEditor()
    private var window: NSWindow?
    private let speech = DictationEngine()
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var process: Process?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var obstacles: [CGRect] = []
    var closed: () -> Void = {}
    init(image: NSImage) {
        self.image = image
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        size = CGSize(width:rep?.pixelsWide ?? Int(image.size.width),height:rep?.pixelsHigh ?? Int(image.size.height))
        super.init()
        editUndoManager.levelsOfUndo = 100
        if #available(macOS 26.0, *) { markupSession = PaperScreenshotSession(size:size) }
        else { markupMode = false; message = "PaperKit requires macOS 26 or later." }
    }
    func show() {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x:0,y:0,width:1200,height:900)
        let w = ScreenshotEditingWindow(editor:self,contentRect:CGRect(x:0,y:0,width:min(1000,visible.width-48),height:min(720,visible.height-48)),styleMask:[.titled,.fullSizeContentView,.resizable],backing:.buffered,defer:false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.title = "Edit Screenshot"; w.isReleasedWhenClosed = false; w.delegate = self
        w.isMovable = true; w.isMovableByWindowBackground = false
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true; w.level = .floating
        w.minSize = CGSize(width:820,height:500); w.appearance = NSAppearance(named:.aqua)
        let host = NSHostingController(rootView:ScreenshotEditorView(editor:self)); host.safeAreaRegions = []
        w.contentViewController = host; w.setContentSize(CGSize(width:min(1000,visible.width-48),height:min(720,visible.height-48))); window = w; w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        speech.warm()
        obstacles = ScreenshotRenderer.textRects(image:image,size:size)
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == "screenshot",
           let instruction = ProcessInfo.processInfo.environment["TELOS_SCREENSHOT_INSTRUCTION"] {
            target = CGPoint(x:0.5,y:0.52); busy = true; perform(instruction)
        }
    }
    func begin(_ point: CGPoint) {
        guard !busy else { return }
        guard min(size.width,size.height) >= 100 else { message = "This screenshot is too small for a readable annotation."; return }
        guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else {
            message = "Allow microphone access, then hold again."
            AVCaptureDevice.requestAccess(for:.audio) { _ in }; return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TelosAnnotation-\(UUID().uuidString).wav")
        do {
            let recorder = try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16])
            guard recorder.prepareToRecord(), recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            self.recorder = recorder; audioURL = url; target = point; busy = true; message = localEdit ? "Listening… Release to edit locally" : "Listening… Release to annotate"
            NSSound(named:"Tink")?.play()
            setTimeout(seconds:60) { [weak self] in self?.release() }
        } catch { try? FileManager.default.removeItem(at:url); message = "Microphone could not start. Please try again." }
    }
    func release() {
        guard let recorder, let url = audioURL else { return }
        let length = recorder.currentTime; recorder.stop(); self.recorder = nil
        timeout?.cancel()
        guard length > 0.3 else { cancelWork(); return }
        message = "Transcribing on your Mac…"
        let id = generation
        speech.transcribe(url,polish:false) { [weak self] result in
            guard let self, self.generation == id else { return }
            if result["stage"] != nil { return }
            self.removeAudio()
            if let text = result["text"] as? String, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { self.perform(text) }
            else { self.fail(result["error"] as? String ?? "No speech detected. Hold and try again.") }
        }
        setTimeout(seconds:90) { [weak self] in self?.fail("Speech recognition timed out. Please try again.") }
    }
    func submit() {
        let text = instruction.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !busy, !text.isEmpty else { return }
        target = target ?? CGPoint(x:0.5,y:0.5); busy = true
        perform(text)
    }
    private func perform(_ text: String) {
        guard localEdit else { annotate(text); return }
        message = "Preparing local image editor…"
        Task { [weak self] in
            guard let self else { return }
            do { self.startLocalEdit(text, png:try await self.exportPNG()) }
            catch { self.fail(error.localizedDescription) }
        }
    }
    private func startLocalEdit(_ text: String, png: Data) {
        guard busy else { return }
        let id = generation
        local.edit(png:png,instruction:text) { [weak self] result in
            guard let self, self.generation == id else { return }
            if let stage = result["stage"] as? String {
                self.message = stage == "loading" ? "Loading image model on your Mac…" : "Editing on your Mac…"
                return
            }
            if let error = result["error"] as? String { self.fail(error); return }
            guard let path = result["output"] as? String, let bytes = try? Data(contentsOf:URL(fileURLWithPath:path)), let edited = NSImage(data:bytes) else { self.fail("No edited image was produced."); return }
            self.remember()
            self.image = edited; self.annotations = []; self.target = nil
            self.markupSession?.clear()
            self.obstacles = ScreenshotRenderer.textRects(image:edited,size:self.size)
            self.busy = false; self.timeout?.cancel(); self.instruction = ""
            let metrics = result["metrics"] as? [String:Any]
            let seconds = metrics?["total_seconds"] as? Double ?? 0
            self.message = String(format:"Edited locally in %.1fs · Check text before sharing",seconds)
            if let export = ProcessInfo.processInfo.environment["TELOS_SCREENSHOT_EXPORT"] {
                try? Data(contentsOf:URL(fileURLWithPath:path)).write(to:URL(fileURLWithPath:export))
            }
        }
        setTimeout(seconds:600) { [weak self] in self?.fail("Local editing timed out. Try a smaller screenshot.") }
    }
    func rememberMarkup(_ previous: Any) { remember(markup:previous) }
    private func remember(markup: Any? = nil) {
        let previous = (image,size,annotations,markup ?? markupSession?.snapshot())
        editUndoManager.registerUndo(withTarget:self) { editor in
            MainActor.assumeIsolated { editor.restore(previous) }
        }
    }
    private func restore(_ state: (NSImage,CGSize,[ScreenshotAnnotation],Any?)) {
        remember()
        image = state.0; size = state.1; annotations = state.2
        markupSession?.restore(state.3)
        obstacles = ScreenshotRenderer.textRects(image:image,size:size)
        message = ""
    }
    func exportPNG() async throws -> Data {
        guard let base = ScreenshotRenderer.png(image:image,size:size,annotations:annotations) else { throw CocoaError(.fileReadCorruptFile) }
        if let markupSession { return try await markupSession.png(background:base,size:size) }
        return base
    }
    private func export(_ action: @escaping (Data) throws -> Void) {
        guard !busy, window?.makeFirstResponder(nil) != false else { return }
        busy = true
        Task { [self] in
            do { let data = try await exportPNG(); try action(data) }
            catch { message = "Image export failed: \(error.localizedDescription)" }
            busy = false
        }
    }
    private func annotate(_ instruction: String) {
        guard let target, let python = BundledRuntime.python(), let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/screenshot_annotation.py"), let png = ScreenshotRenderer.png(image:image,size:size,annotations:annotations) else { fail("Could not prepare this screenshot."); return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TelosAnnotation-\(UUID().uuidString).png")
        let process = Process(), input = Pipe(), output = Pipe()
        do {
            try png.write(to:file,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            let designs = try annotations.suffix(3).map { try JSONSerialization.jsonObject(with:JSONEncoder().encode($0.design)) }
            let request = try JSONSerialization.data(withJSONObject:["image":file.path,"instruction":instruction,"target":[target.x,target.y],"previous_designs":designs])
            process.executableURL = URL(fileURLWithPath:python); process.arguments = ["-B",script.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            let id = generation
            process.terminationHandler = { [weak self] _ in
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                try? FileManager.default.removeItem(at:file)
                let result = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any]
                DispatchQueue.main.async {
                    guard let self, self.generation == id else { return }
                    self.process = nil
                    if let result { self.apply(result,at:target) } else { self.fail("Annotation could not finish. Please try again.") }
                }
            }
            self.process = process; try process.run()
            try input.fileHandleForWriting.write(contentsOf:request); try input.fileHandleForWriting.close()
            message = "Arranging your annotation…"
            setTimeout(seconds:60) { [weak self] in self?.fail("Annotation timed out. Please try again.") }
        } catch { try? FileManager.default.removeItem(at:file); fail("Could not start image annotation.") }
    }
    private func apply(_ result: [String:Any], at point: CGPoint) {
        if let error = result["error"] as? String { fail(error); return }
        guard let text = result["text"] as? String, !text.isEmpty, text.count <= 160,
              let x = result["x"] as? Double, let y = result["y"] as? Double, x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y), let style = result["style"] as? String, ["arrow","note","highlight"].contains(style) else { fail("The annotation was invalid. Please try again."); return }
        guard let rawDesign = result["design"], let data = try? JSONSerialization.data(withJSONObject:rawDesign),
              let design = try? JSONDecoder().decode(ScreenshotAnnotationDesign.self,from:data) else { fail("The annotation design was invalid. Please try again."); return }
        let boxSize = ScreenshotRenderer.labelSize(text:text,size:size,design:design)
        guard boxSize.height <= size.height-16 else { fail("This note is too long for the image. Try a shorter annotation."); return }
        let pixelTarget = CGPoint(x:point.x*size.width,y:point.y*size.height)
        let rect = ScreenshotLayout.label(size:boxSize,target:pixelTarget,preferred:CGPoint(x:x*size.width,y:y*size.height),canvas:size,obstacles:obstacles+annotations.map(\.rect))
        remember()
        annotations.append(ScreenshotAnnotation(text:text,target:pixelTarget,rect:rect,style:style,design:design))
        timeout?.cancel(); busy = false; target = nil; message = ""
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == "screenshot",
           let path = ProcessInfo.processInfo.environment["TELOS_SCREENSHOT_EXPORT"],
           let data = ScreenshotRenderer.png(image:image,size:size,annotations:annotations) { try? data.write(to:URL(fileURLWithPath:path)) }
    }
    private func setTimeout(seconds: UInt64, action: @escaping @MainActor () -> Void) {
        timeout?.cancel(); timeout = Task { try? await Task.sleep(nanoseconds:seconds*1_000_000_000); guard !Task.isCancelled else { return }; action() }
    }
    private func removeAudio() { if let audioURL { try? FileManager.default.removeItem(at:audioURL) }; audioURL = nil }
    func cancelWork() {
        generation = UUID(); timeout?.cancel(); timeout = nil; recorder?.stop(); recorder = nil
        local.stop(); speech.stop(); if let process, process.isRunning { process.terminate() }; process = nil
        removeAudio(); busy = false; target = nil; message = ""
    }
    private func fail(_ text: String) { cancelWork(); message = text }
    func undo() { guard !busy else { return }; window?.makeFirstResponder(nil); editUndoManager.undo(); objectWillChange.send() }
    func redo() { guard !busy else { return }; window?.makeFirstResponder(nil); editUndoManager.redo(); objectWillChange.send() }
    /// Copies the marked-up image, saves it in Pico Files as `<time>.png`, then closes.
    func done() {
        let captured = Date()
        export { [weak self] data in
            guard let bitmap = NSBitmapImageRep(data:data), let tiff = bitmap.tiffRepresentation else { throw CocoaError(.fileReadCorruptFile) }
            let item = NSPasteboardItem()
            guard item.setData(data,forType:.png), item.setData(tiff,forType:.tiff) else { throw CocoaError(.fileWriteUnknown) }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to:Self.outputURL(for:captured),options:.withoutOverwriting)
            self?.close()
        }
    }
    static func outputURL(for date: Date, in folder: URL? = nil) throws -> URL {
        let directory = try folder ?? PicoFileStorage.exportDirectory("Screenshots")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = formatter.string(from:date)
        var url = directory.appendingPathComponent("\(stem).png"), index = 2
        while FileManager.default.fileExists(atPath:url.path) { url = directory.appendingPathComponent("\(stem) \(index).png"); index += 1 }
        return url
    }
    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) { cancelWork(); speech.stop(); window = nil; closed() }
    func windowDidResignKey(_ notification: Notification) { if recorder != nil { cancelWork() } }
}

private struct ScreenshotEditorView: View {
    @ObservedObject var editor: ScreenshotEditor
    private var hasTextSelection: Bool {
        if #available(macOS 26.0, *), let session=editor.markupSession as? PaperScreenshotSession,
           let item=session.selected, case .text = item.content { return true }
        return false
    }
    var body: some View {
        ZStack(alignment:.top) {
            Color.white
            GeometryReader { geometry in
            ZStack {
                if #available(macOS 26.0, *), let session = editor.markupSession as? PaperScreenshotSession {
                    PaperScreenshotCanvas(session:session, editor:editor)
                        .frame(width:geometry.size.width,height:geometry.size.height)
                        .opacity(editor.markupMode ? 1 : 0)
                        .allowsHitTesting(editor.markupMode && !editor.busy)
                }
                if !editor.markupMode { ScreenshotCanvas(editor:editor) }
            }.frame(width:geometry.size.width,height:geometry.size.height).clipped()
            }.padding(.bottom,editor.markupMode ? 0 : 122)
            ScrollEdgeFade(top:true).frame(height:96)
            ZStack {
                ScreenshotWindowDragArea().frame(height:60)
                HStack {
                    GlassCircle(help:"Close",action:editor.close) { Image(systemName:"xmark").font(.system(size:14,weight:.medium)) }
                    Spacer()
                    Button(action:editor.done) {
                        Text("Done").font(.system(size:14,weight:.medium)).frame(width:72,height:36).contentShape(Capsule())
                    }.buttonStyle(.plain).help("Copy and save to Pico Files (⌘↩)").keyboardShortcut(.return,modifiers:.command)
                        .inputGlass().disabled(editor.busy)
                }.padding(.horizontal,12)
                if #available(macOS 26.0, *), let session = editor.markupSession as? PaperScreenshotSession {
                    ScreenshotMarkupToolbar(editor:editor,session:session)
                }
            }.frame(height:60)
            if #available(macOS 26.0, *), editor.markupMode,
               let session = editor.markupSession as? PaperScreenshotSession,
               let selected = session.selected, case .text = selected.content {
                ScreenshotTextInspector(editor:editor,session:session,item:selected)
            }
            if !editor.markupMode || !editor.message.isEmpty {
            VStack(spacing:8) {
                if !editor.message.isEmpty { Text(editor.message).font(.system(size:12)).textSelection(.enabled) }
                if !editor.markupMode {
                HStack(spacing:10) {
                    Picker("Mode",selection:$editor.localEdit) {
                        Text("Local edit").tag(true)
                        Text("Annotate").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().frame(width:190).disabled(editor.busy)
                    TextField(editor.localEdit ? "Describe what to change…" : "Describe an annotation…",text:$editor.instruction)
                        .textFieldStyle(.plain).onSubmit { editor.submit() }.disabled(editor.busy)
                    if editor.busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel",action:editor.cancelWork).buttonStyle(.plain)
                    } else {
                        Button(action:editor.submit) { Image(systemName:"arrow.up.circle.fill").font(.system(size:26)) }
                            .buttonStyle(.plain).disabled(editor.instruction.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    }
                }
                Text(editor.localEdit ? "On-device · Hold anywhere to speak · Generated edits may change text" : "Hold on a target to speak · Annotation uses your configured AI provider")
                    .font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.padding(14).background(RoundedRectangle(cornerRadius:20).fill(.regularMaterial))
                .padding(12).frame(maxHeight:.infinity,alignment:.bottom)
            }
        }
        .foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius:32))
        .onExitCommand {
            if editor.busy { editor.cancelWork() }
            else if #available(macOS 26.0, *), editor.markupMode, let session = editor.markupSession as? PaperScreenshotSession { session.endEditing(); session.select() }
        }
    }
}
/// Reserve the header gap for native window movement, keeping canvas gestures independent.
private struct ScreenshotWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> ScreenshotWindowDragView { ScreenshotWindowDragView() }
    func updateNSView(_ view: ScreenshotWindowDragView, context: Context) {}
}
private final class ScreenshotWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with:event) }
}
private struct ScreenshotCanvas: NSViewRepresentable {
    @ObservedObject var editor: ScreenshotEditor
    func makeNSView(context: Context) -> ScreenshotCanvasView { let view = ScreenshotCanvasView(); view.editor = editor; return view }
    func updateNSView(_ view: ScreenshotCanvasView, context: Context) { view.needsDisplay = true }
}
private final class ScreenshotCanvasView: NSView {
    weak var editor: ScreenshotEditor?
    private var arm: Timer?
    private var origin: CGPoint?
    private var viewport = ScreenshotViewport()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = viewport.rect(image:editor.size,canvas:bounds.size)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width:0,height:-3); shadow.set()
        NSColor.white.setFill(); rect.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState(); context.translateBy(x:rect.minX,y:rect.minY); context.scaleBy(x:rect.width/editor.size.width,y:rect.height/editor.size.height)
        ScreenshotRenderer.draw(image:editor.image,size:editor.size,annotations:editor.annotations)
        NSGraphicsContext.restoreGraphicsState()
        if let target = editor.target {
            NSColor.systemRed.setStroke(); let marker = NSBezierPath(ovalIn:CGRect(x:rect.minX+target.x*rect.width-7,y:rect.minY+target.y*rect.height-7,width:14,height:14)); marker.lineWidth = 2; marker.stroke()
        }
    }
    override func layout() { super.layout(); needsDisplay = true }
    private func cancelHoldForNavigation() {
        arm?.invalidate(); arm = nil
        if origin != nil { origin = nil; editor?.cancelWork() }
    }
    override func magnify(with event: NSEvent) {
        guard let editor else { return }
        cancelHoldForNavigation()
        viewport.magnify(by:event.magnification,around:convert(event.locationInWindow,from:nil),image:editor.size,canvas:bounds.size)
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        guard let editor else { return }
        cancelHoldForNavigation()
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        viewport.pan(by:CGPoint(x:event.scrollingDeltaX*factor,y:event.scrollingDeltaY*factor),image:editor.size,canvas:bounds.size)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard let editor, !editor.busy else { return }
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow,from:nil)
        guard let point = ScreenshotLayout.normalized(location,in:viewport.rect(image:editor.size,canvas:bounds.size)) else { return }
        origin = location
        arm?.invalidate(); let timer = Timer(timeInterval:0.35,repeats:false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.origin != nil else { return }; self.editor?.begin(point) }
        }; arm = timer; RunLoop.main.add(timer,forMode:.common)
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow,from:nil)
        if let origin, hypot(p.x-origin.x,p.y-origin.y)>8 { arm?.invalidate(); self.origin = nil; editor?.cancelWork() }
    }
    override func mouseUp(with event: NSEvent) { arm?.invalidate(); origin = nil; editor?.release() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { editor?.cancelWork() } else { super.keyDown(with:event) } }
}

private final class ScreenshotEditingWindow: NSWindow {
    weak var editor: ScreenshotEditor?
    init(editor: ScreenshotEditor, contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        self.editor = editor
        super.init(contentRect:contentRect,styleMask:styleMask,backing:backing,defer:flag)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var undoManager: UndoManager? { editor?.editUndoManager }
    /// The editor has no Undo buttons or Edit menu, so handle ⌘Z / ⇧⌘Z here. Text fields keep their own shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let editor, event.charactersIgnoringModifiers?.lowercased() == "z", flags == .command || flags == [.command,.shift],
           !(firstResponder is NSTextView) {
            if flags.contains(.shift) { editor.redo() } else { editor.undo() }
            return true
        }
        // Zoom stays available by pinch, ⌘-scroll and these shortcuts; the editor shows no zoom controls.
        if #available(macOS 26.0, *), flags == .command, let session = editor?.markupSession as? PaperScreenshotSession,
           !(firstResponder is NSTextView), editor?.busy != true {
            switch event.charactersIgnoringModifiers {
            case "=", "+": session.zoom(by:0.25); return true
            case "-": session.zoom(by:-0.2); return true
            case "0": session.fitCanvas(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with:event)
    }
}

@available(macOS 26.0, *)
private struct ScreenshotMarkupToolbar: View {
    @ObservedObject var editor: ScreenshotEditor
    let session: PaperScreenshotSession
    private static let tools: [(PaperScreenshotSession.Tool,String,String)] = [
        (.selection,"pointer.arrow.ipad","Select"),(.pen,"scribble.variable","Pen"),(.marker,"pencil.tip","Marker"),(.eraser,"eraser","Eraser"),
        (.arrow,"arrow.up.left","Arrow"),(.rectangle,"rectangle","Rectangle"),(.ellipse,"circle","Ellipse"),(.text,"character.textbox","Text")]
    var body: some View {
        HStack(spacing:12) {
            ForEach(Self.tools,id:\.1) { tool,symbol,label in
                let active = session.tool == tool
                // Selecting the active tool again returns to select & move.
                Button { session.setTool(active && tool != .selection ? .selection : tool) } label: {
                    Image(systemName:symbol).font(.system(size:16,weight:.medium)).frame(width:24,height:24)
                        .foregroundStyle(active ? Color.accentColor : Color(white:0.10))
                        .background(RoundedRectangle(cornerRadius:8).fill(.black.opacity(active ? 0.08 : 0)).frame(width:32,height:30))
                        .contentShape(Rectangle())
                }.help(label).accessibilityLabel(label).accessibilityAddTraits(active ? .isSelected : [])
            }
        }.buttonStyle(.plain).padding(.horizontal,12).frame(height:36).inputGlass().disabled(editor.busy)
    }
}

@available(macOS 26.0, *)
private struct ScreenshotTextInspector:View {
    @ObservedObject var editor:ScreenshotEditor
    @ObservedObject var session:PaperScreenshotSession
    let item:ScreenshotPaperElement
    var body:some View {
        GeometryReader { geometry in
            let rect=session.selectionDisplayFrame
            let below=rect.maxY+32
            let y=below < geometry.size.height-60 ? below : rect.minY-32
            ScreenshotTextStyleBar(editor:editor,session:session,item:item)
                .position(x:min(max(rect.midX,86),geometry.size.width-86),y:min(max(y,88),geometry.size.height-66))
                .opacity(session.isTransforming || !rect.intersects(CGRect(x:0,y:60,width:geometry.size.width,height:geometry.size.height-104)) ? 0 : 1)
                .allowsHitTesting(!session.isTransforming)
        }
    }
}

@available(macOS 26.0, *)
private struct ScreenshotTextStyleBar: View {
    @ObservedObject var editor: ScreenshotEditor
    let session: PaperScreenshotSession
    let item: ScreenshotPaperElement
    @State private var showStyle=false
    @State private var showSize=false
    @State private var showColor=false
    private static let families = NSFontManager.shared.availableFontFamilies.sorted()
    private static let colors: [(String,NSColor)] = [("Black",.black),("White",.white),("Red",.systemRed),("Orange",.systemOrange),("Yellow",.systemYellow),("Green",.systemGreen),("Blue",.systemBlue),("Purple",.systemPurple)]
    var body: some View {
        HStack(spacing:2) {
            Button {session.focusCanvas();showColor.toggle()} label: {
                Circle().fill(Color(nsColor:item.fill ?? item.color)).overlay(Circle().stroke(.gray.opacity(0.3),lineWidth:0.5)).frame(width:18,height:18).frame(width:28,height:30)
            }.accessibilityLabel("Text color").popover(isPresented:$showColor,arrowEdge:.bottom) {
                LazyVGrid(columns:Array(repeating:GridItem(.fixed(28)),count:4),spacing:10) {
                    ForEach(Array(Self.colors.enumerated()),id:\.offset) { _,entry in
                        Button {session.setColor(entry.1);showColor=false} label: {Circle().fill(Color(nsColor:entry.1)).overlay(Circle().stroke(.gray.opacity(0.3),lineWidth:0.5)).frame(width:24,height:24)}.accessibilityLabel(entry.0)
                    }
                }.buttonStyle(.plain).padding(16)
            }
            Button {session.focusCanvas();showStyle.toggle()} label: {Text("Aa").frame(width:30,height:30).background(showStyle ? .black.opacity(0.08) : .clear,in:Circle())}
                .accessibilityLabel("Text style").popover(isPresented:$showStyle,arrowEdge:.bottom) {stylePanel}
            Button {session.focusCanvas();showSize.toggle()} label: {Text(item.fontSize,format:.number.precision(.fractionLength(0...1))).monospacedDigit().frame(minWidth:28).frame(height:30)}
                .accessibilityLabel("Font size").popover(isPresented:$showSize,arrowEdge:.bottom) {
                    VStack(spacing:12) {
                        HStack {
                            TextField("Size",value:Binding(get:{Double(item.fontSize)},set:{session.setTextStyle(size:CGFloat($0))}),format:.number.precision(.fractionLength(0...1))).frame(width:60).textFieldStyle(.roundedBorder).accessibilityLabel("Font size value")
                            Stepper("Font size",value:Binding(get:{Double(item.fontSize)},set:{session.setTextStyle(size:CGFloat($0))}),in:8...240,step:1).labelsHidden()
                        }
                        HStack {ForEach([12,18,24,36,48],id:\.self) {size in Button("\(size)"){session.setTextStyle(size:CGFloat(size))}}}
                    }.padding(16)
                }
        }.buttonStyle(.plain).font(.system(size:14)).padding(.horizontal,8).frame(height:40).inputGlass().fixedSize().disabled(editor.busy)
    }
    private var stylePanel:some View {
        VStack(spacing:10) {
            HStack(spacing:8) {
                HStack(spacing:0) {
                    styleButton("bold",label:"Bold",active:item.bold){session.setTextStyle(bold:!item.bold)}
                    Divider().frame(height:18)
                    styleButton("italic",label:"Italic",active:item.italic){session.setTextStyle(italic:!item.italic)}
                    Divider().frame(height:18)
                    styleButton("underline",label:"Underline",active:item.underline){session.setTextStyle(underline:!item.underline)}
                }.background(.black.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                Menu {
                    Button("System"){session.setTextStyle(family:"System")}
                    ForEach(Self.families,id:\.self) {family in Button(family){session.setTextStyle(family:family)}}
                } label: {Text("Aa").frame(width:64,height:30)}.accessibilityLabel("Font family").menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width:64,height:30)
                    .background(.black.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
            }
            HStack(spacing:8) {
                Menu {
                    Button("Align Left"){session.setTextStyle(alignment:.left)}
                    Button("Center"){session.setTextStyle(alignment:.center)}
                    Button("Align Right"){session.setTextStyle(alignment:.right)}
                } label: {Image(systemName:"text.alignleft").frame(width:64,height:30)}.accessibilityLabel("Text alignment").frame(width:64,height:30).background(.black.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                Menu {
                    Button("Tight"){session.setTextStyle(lineSpacing:0)}
                    Button("Normal"){session.setTextStyle(lineSpacing:4)}
                    Button("Loose"){session.setTextStyle(lineSpacing:8)}
                } label: {Image(systemName:"arrow.down.to.line.compact").frame(width:64,height:30)}.accessibilityLabel("Line spacing").frame(width:64,height:30).background(.black.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                Menu {
                    Button("None"){session.setListStyle(nil)}
                    Button("Bulleted List"){session.setListStyle(false)}
                    Button("Numbered List"){session.setListStyle(true)}
                } label: {Image(systemName:"list.bullet").frame(width:64,height:30)}.accessibilityLabel("List style").frame(width:64,height:30).background(.black.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
        }.buttonStyle(.plain).font(.system(size:16)).padding(16)
    }
    private func styleButton(_ icon:String,label:String,active:Bool,action:@escaping()->Void)->some View {
        Button(action:action) {Image(systemName:icon).frame(width:44,height:30).background(active ? .black.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))}
            .accessibilityLabel(label).accessibilityValue(active ? "On" : "Off")
    }
}
