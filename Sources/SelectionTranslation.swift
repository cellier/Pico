import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// Reads the text a gesture selected in another app.
/// Accessibility first; Chromium/Electron and web views that expose nothing fall back to a
/// generated ⌘C whose pasteboard change is reverted immediately.
@MainActor enum SelectionCapture {
    private static var manualAccessibility = Set<pid_t>()
    private static let iBeam = NSCursor.iBeam.image.tiffRepresentation

    static func accessibilitySelection(pid: pid_t) -> (text: String, bounds: CGRect?, secure: Bool)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium and Electron build their accessibility tree only when asked.
        if manualAccessibility.insert(pid).inserted {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let raw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return ("", nil, true) }
        guard let text = attribute(element, kAXSelectedTextAttribute) as? String else { return nil }
        var bounds: CGRect?
        if let range = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value) == .success,
               let value, CFGetTypeID(value) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(value as! AXValue, .cgRect, &rect) { bounds = rect }
            }
        }
        return (text, bounds, false)
    }

    static var pointerIsIBeam: Bool {
        guard let iBeam, let current = NSCursor.currentSystem?.image.tiffRepresentation else { return false }
        return current == iBeam
    }

    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        let before = pasteboard.changeCount
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return nil }
        down.flags = .maskCommand; up.flags = .maskCommand
        TelosKeyboardEvent.markSynthetic(down); TelosKeyboardEvent.markSynthetic(up)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        for _ in 0..<10 where pasteboard.changeCount == before {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        let items = saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return text
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Shows the Translate button above any text selected with the mouse, and the translation panel.
@MainActor final class SelectionTranslationController {
    private let store: TaskStore
    private var monitors: [Any] = []
    private var downPoint = CGPoint.zero
    private var gesture = UUID()
    private var button: NSPanel?
    private var panel: TranslationPanel?

    init(store: TaskStore) { self.store = store }

    func start() {
        guard monitors.isEmpty else { return }
        let handlers: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] event in self?.downPoint = Self.screenLocation(event); self?.hideButton() }),
            (.leftMouseUp, { [weak self] event in self?.mouseUp(event) }),
            ([.rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel], { [weak self] _ in self?.hideButton() }),
        ]
        for (mask, handler) in handlers {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                MainActor.assumeIsolated { handler(event) }
            }) { monitors.append(monitor) }
        }
    }

    /// Global monitor events carry no window, so their location is already in screen coordinates.
    private static func screenLocation(_ event: NSEvent) -> CGPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        hideButton(); panel?.close(); panel = nil
    }

    private func mouseUp(_ event: NSEvent) {
        let up = Self.screenLocation(event), down = downPoint
        let dragged = hypot(up.x - down.x, up.y - down.y) > 5
        guard dragged || event.clickCount >= 2, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let token = UUID(); gesture = token
        let iBeam = SelectionCapture.pointerIsIBeam
        Task { [weak self] in
            // Let the app finish updating its selection after mouse-up.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, self.gesture == token else { return }
            let found = SelectionCapture.accessibilitySelection(pid: app.processIdentifier)
            if found?.secure == true { return }
            var text = found?.text ?? ""
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Without bounds there is no proof the selection came from this gesture; trust it only over text.
            if found?.bounds == nil && !iBeam { return }
            if empty && found?.bounds == nil { text = await SelectionCapture.copySelection() ?? "" }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let primary = NSScreen.screens.first?.frame.height ?? 0
            guard self.gesture == token, !trimmed.isEmpty, trimmed.count <= 8000,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  let rect = SelectionTranslationLayout.selectionRect(accessibility: found?.bounds, primaryHeight: primary, down: down, up: up) else { return }
            self.showButton(text: trimmed, selection: rect)
        }
    }

    private func showButton(text: String, selection: CGRect) {
        hideButton()
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main else { return }
        let size = SelectionTranslationLayout.buttonSize
        let origin = SelectionTranslationLayout.buttonOrigin(selection: selection, visible: screen.visibleFrame)
        // Leave room around the capsule for its shadow.
        let margin: CGFloat = 12
        let window = FloatingPanel(contentRect: NSRect(x: origin.x - margin, y: origin.y - margin, width: size.width + margin * 2, height: size.height + margin * 2),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.allowsKey = false
        window.contentView = FirstMouseHostingView(rootView: TranslateButton { [weak self] in
            self?.hideButton(); self?.translate(text, selection: selection, screen: screen)
        }.padding(margin))
        window.orderFrontRegardless()
        button = window
    }

    /// Isolated preview: sample selection and translation, no network or event monitors.
    func preview() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let selection = CGRect(x: visible.midX - 420, y: visible.maxY - 160, width: 300, height: 40)
        showButton(text: "", selection: selection)
        let session = TranslationSession(source: "出现翻译的小 icon+文字入口，点击后，把划词文案传过去，翻译成英文（如果是中文翻译成英文）、或者中文（如果是英文翻译成中文）", settings: ProviderSettings(directory: store.dataDir))
        session.translation = "A small icon-plus-text entry point appears. When tapped, the selected text is passed over and translated into English if the source is Chinese, or into Chinese if the source is English."
        session.finished = true
        let window = TranslationPanel(session: session, store: store, origin: CGPoint(x: visible.midX, y: visible.maxY - 140 - SelectionTranslationLayout.panelSize.height))
        panel = window; window.present()
        if let path = ProcessInfo.processInfo.environment["TELOS_TRANSLATION_SNAPSHOT"] {
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await Self.snapshot(around: [button, window].compactMap { $0?.frame }, on: screen, to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }

    private static func snapshot(around frames: [CGRect], on screen: NSScreen, to url: URL) async {
        guard let union = frames.reduce(nil as CGRect?, { $0?.union($1) ?? $1 }),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screen.recordingDisplayID }) else { return }
        let local = union.insetBy(dx: -40, dy: -40).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: local.minX, y: screen.frame.height - local.maxY, width: local.width, height: local.height)
        configuration.width = Int(local.width * 2); configuration.height = Int(local.height * 2)
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration) }
        catch { FileHandle.standardError.write(Data("Translation snapshot failed: \(error)\n".utf8)); return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private func hideButton() {
        button?.orderOut(nil); button = nil
    }

    private func translate(_ text: String, selection: CGRect, screen: NSScreen) {
        panel?.close()
        let session = TranslationSession(source: text, settings: ProviderSettings(directory: store.dataDir))
        let origin = SelectionTranslationLayout.panelOrigin(selection: selection, visible: screen.visibleFrame)
        let window = TranslationPanel(session: session, store: store, origin: origin)
        window.closed = { [weak self, weak window] in if self?.panel === window { self?.panel = nil } }
        panel = window
        window.present()
        session.start()
    }
}

/// Borderless panel that never activates Telos, so the source app keeps its selection.
class FloatingPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true; level = .popUpMenu; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear; isOpaque = false; hasShadow = false; isReleasedWhenClosed = false
    }
}
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct TranslateButton: View {
    var action: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "translate").font(.system(size: 13, weight: .medium))
            Text("Translate").font(.system(size: 12, weight: .medium))
        }.foregroundStyle(TelosTheme.primary).padding(.horizontal, 12)
            .fixedSize().frame(minWidth: SelectionTranslationLayout.buttonSize.width, minHeight: SelectionTranslationLayout.buttonSize.height)
            .contentShape(Capsule())
        Group {
            if #available(macOS 26, *) {
                Button(action: action) { label }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
            } else {
                Button(action: action) { label }.buttonStyle(HoverButtonStyle())
                    .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.gray.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            }
        }
        .help("Translate selection").accessibilityLabel("Translate selection")
        .scaleEffect(shown || reduceMotion ? 1 : 0.85).opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { shown = true } }
    }
}

/// Streams the translation and keeps the follow-up task linked to it.
@MainActor final class TranslationSession: ObservableObject {
    let source: String
    let target: TranslationTarget
    private let settings: ProviderSettings
    @Published var translation = ""
    @Published var failure: String?
    @Published var finished = false
    @Published var taskID: UUID?
    private var work: Task<Void, Never>?

    init(source: String, settings: ProviderSettings) {
        self.source = source; self.settings = settings
        target = TranslationTarget.detect(source)
    }

    func start() {
        work?.cancel(); translation = ""; failure = nil; finished = false
        work = Task { [weak self] in await self?.run() }
    }
    func cancel() { work?.cancel(); work = nil }

    private func run() async {
        do {
            guard let endpoint = try settings.chatEndpoint() else {
                failure = "Add your model API key in Telos Settings to translate."; return
            }
            var request = URLRequest(url: endpoint.url, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + endpoint.apiKey, forHTTPHeaderField: "Authorization")
            var body: [String: Any] = ["model": endpoint.model, "stream": true, "temperature": 0.3, "messages": [
                ["role": "system", "content": target.systemPrompt], ["role": "user", "content": source]]]
            if endpoint.url.host?.hasSuffix("deepseek.com") == true { body["thinking"] = ["type": "disabled"] }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                failure = code == 401 ? "The model API key was rejected. Check it in Telos Settings." : "Translation failed (HTTP \(code)). Try again."
                return
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choice = (json["choices"] as? [[String: Any]])?.first,
                      let delta = choice["delta"] as? [String: Any],
                      let content = delta["content"] as? String else { continue }
                translation += translation.isEmpty ? String(content.drop { $0.isNewline }) : content
            }
            translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if translation.isEmpty { failure = "No translation was returned. Try again." } else { finished = true }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            failure = "Translation failed: \(error.localizedDescription)"
        }
    }
}

final class TranslationPanel: FloatingPanel {
    var closed: () -> Void = {}
    private let session: TranslationSession
    private var keyMonitor: Any?
    private var didClose = false

    init(session: TranslationSession, store: TaskStore, origin: CGPoint) {
        self.session = session
        let size = SelectionTranslationLayout.panelSize
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating; hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        let host = FirstMouseHostingView(rootView: TranslationPanelView(session: session, store: store) { [weak self] in self?.close() })
        host.safeAreaRegions = []
        contentView = host
    }

    func present() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self, event.keyCode == 53 else { return event }
            self.close(); return nil
        }
    }

    override func close() {
        guard !didClose else { return }
        didClose = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        session.cancel()
        super.close()
        closed()
    }
}

struct TranslationPanelView: View {
    @ObservedObject var session: TranslationSession
    @ObservedObject var store: TaskStore
    var close: () -> Void
    @StateObject private var draft = ComposerDraft()
    @State private var footerHeight: CGFloat = 72
    @State private var sourceExpanded = false
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    private var task: Todo? { session.taskID.flatMap { id in store.tasks.first { $0.id == id } } }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Color.clear.frame(height: 40)
                        source
                        result
                        if let task { conversation(task) }
                        Color.clear.frame(height: footerHeight).id("bottom")
                    }.padding(.horizontal, 16).padding(.top, 16)
                }.scrollIndicators(.hidden)
                    .softScrollEdges(top: 56, bottom: footerHeight + 8, alwaysBottom: true)
                    .onChange(of: task?.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            Composer(draft: draft, placeholder: "Ask Telos", canSend: canSend, identifier: "translationAskField", action: submit)
                .padding(16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .overlay(alignment: .top) { header }
        .frame(width: SelectionTranslationLayout.panelSize.width, height: SelectionTranslationLayout.panelSize.height)
        .modifier(PanelGlass(shape: shape))
        .clipShape(shape)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let id = session.taskID {
                GlassCircle(help: "Open in Telos", action: { open(id) }) {
                    Image(systemName: "arrow.up.forward").font(.system(size: 13, weight: .medium))
                }
            }
            Spacer()
            GlassCircle(help: "Close", action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .medium)) }
        }.padding([.horizontal, .top], 16).frame(height: 56, alignment: .top)
            .modifier(WindowDrag())
    }

    private var source: some View {
        Text(session.source).font(.system(size: 11)).lineSpacing(3)
            .foregroundStyle(Color(red: 0.878, green: 0.878, blue: 0.886))
            .lineLimit(sourceExpanded ? nil : 2).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color(red: 0.149, green: 0.149, blue: 0.157), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { sourceExpanded.toggle() } }
            .help(sourceExpanded ? "Collapse" : "Show full selection")
            .accessibilityLabel("Selected text: " + session.source)
    }

    @ViewBuilder private var result: some View {
        if let failure = session.failure {
            VStack(alignment: .leading, spacing: 10) {
                Text(failure).font(.system(size: 13)).foregroundStyle(.secondary)
                Button("Try Again") { session.start() }.buttonStyle(HoverButtonStyle(standard: true)).font(.system(size: 12, weight: .medium))
            }.padding(.horizontal, 12).padding(.vertical, 10)
        } else if session.translation.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating…").font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 12)
        } else {
            TranslationResult(text: session.translation, finished: session.finished)
        }
    }

    @ViewBuilder private func conversation(_ task: Todo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(task.messages) { message in
                if message.role == "user" {
                    HStack { Spacer(minLength: 36); MessageBubble(text: message.text).frame(maxWidth: 280, alignment: .trailing) }
                } else if message.role != "confirmation" {
                    MessageText(text: message.text).font(.system(size: 14)).lineSpacing(1).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let stream = store.streams[task.id], !stream.isEmpty { MessageText(text: stream, markdown: false).font(.system(size: 14)) }
            if task.status == "running" || task.status == "awaiting_approval" {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(task.status == "awaiting_approval" ? "Waiting for approval in Telos" : task.summary)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if ["error", "paused", "needs_input"].contains(task.status) {
                Text(task.summary).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 12).padding(.top, 8)
    }

    private var canSend: Bool {
        guard draft.hasContent, session.finished || session.failure != nil else { return false }
        return !["running", "awaiting_approval"].contains(task?.status ?? "")
    }

    private func submit() {
        guard canSend else { return }
        let text = draft.text, files = draft.files
        if let id = session.taskID {
            guard store.ask(id, text: text, files: files) else { return }
        } else {
            let source = session.source, translation = session.translation, target = session.target
            guard let id = store.add(text, files: files, context: { request in
                SelectionTranslationContext.prompt(source: source, translation: translation, target: target, request: request)
            }) else { return }
            session.taskID = id
        }
        draft.clear()
    }

    private func open(_ id: UUID) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        store.completed = store.tasks.first { $0.id == id }?.status == "completed"
        store.selected = id; delegate.showPanel()
    }
}

/// The translated text; a copy control appears on hover.
private struct TranslationResult: View {
    let text: String
    let finished: Bool
    @State private var hovering = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).font(.system(size: 15)).lineSpacing(4).foregroundStyle(.white)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5)).frame(width: 18, height: 18).contentShape(Rectangle())
            }.buttonStyle(HoverButtonStyle(hoverScale: 1.1))
                .help(copied ? "Copied" : "Copy translation").accessibilityLabel("Copy translation")
                .opacity(finished && (hovering || copied) ? 1 : 0).allowsHitTesting(finished)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct PanelGlass: ViewModifier {
    let shape: RoundedRectangle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.background(Color.black.opacity(0.82), in: shape).glassEffect(.regular, in: shape)
        } else {
            content.background(Color(white: 0.06), in: shape)
        }
    }
}

private struct WindowDrag: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.contentShape(Rectangle()).gesture(WindowDragGesture()) } else { content }
    }
}
