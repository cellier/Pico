import AppKit
import SwiftUI
import WebKit

/// A size-independent contract between AppKit and the shared pet renderer.
/// X points right and Y points up; values outside the face keep its distance fade.
enum PicoAvatarPointer {
    static func script(point: NSPoint, bounds: NSRect) -> String? {
        guard point.x.isFinite, point.y.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let x = (point.x - bounds.minX) / bounds.width * 2 - 1
        let y = (point.y - bounds.minY) / bounds.height * 2 - 1
        guard x.isFinite, y.isFinite else { return nil }
        return "window.picoAvatar?.pointerAt(\(x), \(y))"
    }
}

/// The same local, mesh-based Pico character as the desktop companion. The web
/// surface never takes focus or clicks, so it can live inside an ordinary Button.
struct PicoAvatarView: NSViewRepresentable {
    var size: CGFloat = 26
    var state: String = "idle"
    var skin: String = "snowball"

    func makeNSView(context: Context) -> PicoAvatarSurface {
        let surface = PicoAvatarSurface(frame: NSRect(x: 0, y: 0, width: size, height: size))
        surface.update(state: state, skin: skin)
        return surface
    }

    func updateNSView(_ view: PicoAvatarSurface, context: Context) {
        view.update(state: state, skin: skin)
    }

    static func dismantleNSView(_ view: PicoAvatarSurface, coordinator: ()) {
        view.stop()
    }
}

@MainActor final class PicoAvatarSurface: NSView, WKNavigationDelegate {
    private let web: WKWebView
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var windowObserver: NSObjectProtocol?
    private var ready = false
    private var state = "idle"
    private var skin = "snowball"
    private var pointerUpdate: DispatchWorkItem?
    private var stopped = false
    private struct RenderSize: Equatable {
        var width: CGFloat
        var height: CGFloat
        var scale: CGFloat
    }
    private var renderedSize: RenderSize?

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        // No website storage, network resources, microphone, or audio is used.
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.isHidden = true
        addSubview(web)
        setAccessibilityElement(false)
        if let resource = Bundle.main.url(forResource: "PicoAvatar", withExtension: "html") {
            web.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        })
    }

    required init?(coder: NSCoder) { nil }

    // SwiftUI's enclosing Button handles hover, press, and accessibility.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let window, !stopped {
            window.acceptsMouseMovedEvents = true
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                     object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyVisibility() }
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.schedulePointer(event) }
                return event
            }
        }
        applySize()
        applyVisibility()
    }

    override func viewDidHide() { super.viewDidHide(); applyVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); applyVisibility() }

    override func layout() {
        super.layout()
        applySize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applySize()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        pointerUpdate?.cancel()
        pointerUpdate = nil
    }

    private func applySize() {
        guard ready, !stopped else { return }
        let size = RenderSize(width: max(1, bounds.width), height: max(1, bounds.height),
                              scale: min(2, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1))
        // Window resizing also lays out this fixed-size header view. Avoid a
        // WebKit round trip and WebGL drawing-buffer reset when it is unchanged.
        guard renderedSize != size else { return }
        renderedSize = size
        web.evaluateJavaScript("window.picoAvatar?.resize(\(size.width), \(size.height), \(size.scale))", completionHandler: nil)
    }

    func update(state: String, skin: String) {
        guard self.state != state || self.skin != skin else { return }
        self.state = state
        self.skin = skin
        applyPreferences()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped else { return }
        ready = true
        renderedSize = nil
        web.isHidden = false
        applyPreferences()
        layout()
        applyVisibility()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }

    private func applyPreferences() {
        guard ready, !stopped else { return }
        let values: [String: Any] = ["state": state, "skin": skin,
                                      "reducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion]
        guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.picoAvatar?.configure(\(json))", completionHandler: nil)
    }

    private func applyVisibility() {
        guard ready, !stopped else { return }
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
        web.evaluateJavaScript("window.setPaused?.(\(!visible))", completionHandler: nil)
    }

    private func schedulePointer(_ event: NSEvent) {
        guard ready, !stopped, !inLiveResize, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
        pointerUpdate?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        guard let script = PicoAvatarPointer.script(point: point, bounds: bounds) else { return }
        let update = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !self.inLiveResize else { return }
            self.web.evaluateJavaScript(script, completionHandler: nil)
        }
        pointerUpdate = update
        DispatchQueue.main.async(execute: update)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pointerUpdate?.cancel()
        pointerUpdate = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        web.evaluateJavaScript("window.picoAvatar?.dispose()", completionHandler: nil)
        web.stopLoading()
        web.navigationDelegate = nil
    }
}
