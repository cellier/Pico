import AppKit
import Combine
import SwiftUI

/// Native viewport bookkeeping for a lazy transcript. Geometry is deliberately
/// not published: scrolling must not invalidate every SwiftUI message body.
@MainActor final class PicoChatScrollController: ObservableObject {
    struct Anchor: Equatable {
        let id: String
        /// Distance from the row's top to the viewport's top. It can be negative
        /// when the first row starts below the viewport's leading padding.
        let offset: CGFloat
    }
    var onEdges: ((Bool, Bool) -> Void)? // nearBottom, nearTop
    var onUserEdge: ((Bool, Bool) -> Void)? // nearTop, nearBottom
    var onFollowingChanged: ((Bool) -> Void)?
    /// Explicit jump completion is separate from automatic tail maintenance.
    /// A caller may trim a retained data window after it reaches the bottom.
    var onLatestAnimationFinished: (() -> Void)?
    var onLatestAnimationCancelled: (() -> Void)?
    /// Primary surfaces retain their bookmarks while transient typed-query
    /// scopes share the remaining bounded cache slots.
    var retainedScopes: Set<String> = ["history"]
    private(set) var followingLatest = true
    /// A bounded historical page can reach its own bottom without reaching the
    /// conversation's latest reply. Paging forward must keep a reading anchor.
    var canFollowLatest = true {
        didSet {
            guard !canFollowLatest, followingLatest else { return }
            cancelCorrection()
            readingAnchor = captureAnchor() ?? readingAnchor
            awaitingUserAnchor = false
            setFollowing(false)
        }
    }

    private struct Position { var following: Bool; var anchor: Anchor? }
    private enum Intent: Equatable { case latest, reading(Anchor), top }
    private struct Correction {
        var intent: Intent
        var forceTarget: Bool
        var requestedTarget = false
        var targetRequests = 0
        var attempts = 0
        var stablePasses = 0
        var lastGeometry: [CGFloat] = []
    }
    private weak var scroll: NSScrollView?
    private weak var probe: NSView?
    private var scrollTo: ((String, UnitPoint) -> Void)?
    private var rows: [String: CGRect] = [:]
    private var readingAnchor: Anchor?
    private var awaitingUserAnchor = false
    private var positions: [String: Position] = [:]
    private var scope = "history"
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var correction: Correction?
    private var queued = false
    private var generation = 0
    private var applyingOffset = false
    private var userScrolling = false
    private var pendingReadingRestore: Anchor?
    private var userEnd: DispatchWorkItem?
    private var lastEdges: (bottom: Bool, top: Bool)?
    private var notifiedUserTop = false
    private var notifiedUserBottom = false
    private var lastViewport = CGSize.zero
    private var lastDocumentHeight: CGFloat = 0
    private var observedGeometry: [CGFloat] = []
    private struct LatestMotion {
        var position: CGFloat
        var velocity: CGFloat = 0
        var elapsed: TimeInterval = 0
        var lastTime: TimeInterval
        var stablePasses = 0
        var lastTarget: CGFloat?
    }
    private var latestMotion: LatestMotion?
    private var latestTimer: Timer?
    private var animateLatestAfterRestore = false
    private let reduceMotion: () -> Bool
    var isAnimatingLatest: Bool { latestMotion != nil || animateLatestAfterRestore }

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
    }
    private let diagnostics = ProcessInfo.processInfo.environment["PICO_SCROLL_DIAGNOSTICS"] == "1"
    private func trace(_ label: String) {
        if diagnostics { print("PicoChatScroll \(label): \(diagnosticSnapshot)") }
    }

    /// Opt-in native diagnostics; no published state or geometry readers.
    var diagnosticSnapshot: String {
        let anchor = readingAnchor
        return "following=\(followingLatest), anchor=\(String(describing: anchor)), pending=\(String(describing: pendingReadingRestore)), row=\(String(describing: anchor.flatMap { rows[$0.id] })), offset=\(offset), origin=\(contentOrigin), maximum=\(maximumOffset), viewport=\(String(describing: scroll?.contentView.bounds)), rows=\(rows.count), correction=\(String(describing: correction))"
    }

    var isRestoringReadingPosition: Bool {
        if pendingReadingRestore != nil { return true }
        if case .reading = correction?.intent { return true }
        return false
    }

    func configure(scrollTo: @escaping (String, UnitPoint) -> Void) {
        self.scrollTo = scrollTo
        if correction != nil { schedule() }
    }
    func record(id: String, frame: CGRect) {
        guard frame.minY.isFinite, frame.height.isFinite, frame.height > 0 else { return }
        guard rows[id] != frame else { return }
        rows[id] = frame
        if awaitingUserAnchor, let anchor = captureAnchor() {
            readingAnchor = anchor; awaitingUserAnchor = false
            publishEdges(user: true)
            return
        }
        if followingLatest || readingAnchor?.id == id || correction != nil { geometryChanged(force: true) }
    }
    func remove(id: String) { rows.removeValue(forKey: id) }

    func prepareForChange() -> Anchor? {
        guard !followingLatest else { return nil }
        if let pendingReadingRestore { return pendingReadingRestore }
        // A lazy stack can temporarily report another row at the same absolute
        // y while it reestimates heights after resize/prepend. Keep the pending
        // stable-ID intention until that correction has actually settled.
        if case .reading(let anchor) = correction?.intent { return anchor }
        let anchor = captureAnchor() ?? readingAnchor
        readingAnchor = anchor
        return anchor
    }

    /// A completed/deleted task can leave the current list. Preserve another
    /// visible task at its actual screen position instead of waiting for the
    /// removed stable ID to reappear. Call before replacing row geometry.
    func prepareForChange(survivingIDs: Set<String>) -> Anchor? {
        let current = prepareForChange()
        if let current, survivingIDs.contains(current.id) { return current }
        let top = offset - contentOrigin
        let bottom = top + viewportHeight
        let candidates = rows.filter {
            $0.key != "picoLatest" && survivingIDs.contains($0.key) &&
            $0.value.maxY > top + 0.5 && $0.value.minY < bottom
        }
        guard let next = candidates.min(by: { lhs, rhs in
            lhs.value.minY == rhs.value.minY ? lhs.key < rhs.key : lhs.value.minY < rhs.value.minY
        }) else { return nil }
        let anchor = Anchor(id: next.key, offset: top - next.value.minY)
        readingAnchor = anchor; awaitingUserAnchor = false
        return anchor
    }
    func restore(_ anchor: Anchor?) {
        if let anchor {
            readingAnchor = anchor; awaitingUserAnchor = false
            setFollowing(false)
            if userScrolling {
                // Edge pagination can change the data window during a live
                // gesture. Do not fight the pointer, but retain the old visual
                // anchor until native scrolling ends instead of dropping it.
                pendingReadingRestore = anchor
                return
            }
            enqueue(.reading(anchor), forceTarget: true)
        } else if followingLatest { enqueue(.latest, forceTarget: true) }
    }
    func followLatest(animated: Bool = false, preserving anchor: Anchor? = nil) {
        cancelCorrection(notifyAnimationCancellation: false)
        userEnd?.cancel(); userEnd = nil; userScrolling = false
        pendingReadingRestore = nil
        readingAnchor = nil; awaitingUserAnchor = false
        if animated, !reduceMotion(), let anchor {
            animateLatestAfterRestore = true
            readingAnchor = anchor
            setFollowing(false)
            enqueue(.reading(anchor), forceTarget: rows[anchor.id] == nil)
            return
        }
        setFollowing(true)
        if animated, !reduceMotion(), scroll != nil {
            latestMotion = LatestMotion(position: offset, lastTime: ProcessInfo.processInfo.systemUptime)
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.animateLatestFrame() }
            }
            latestTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        enqueue(.latest, forceTarget: true)
    }
    /// Explicit navigation can leave a retained bridge without finishing the
    /// jump. Keep the visible native position so the caller can rebase its data
    /// window around this reading anchor before restoring it.
    @discardableResult func cancelLatestJump() -> Anchor? {
        let anchor = prepareForChange() ?? captureAnchor() ?? readingAnchor
        cancelCorrection()
        pendingReadingRestore = nil
        readingAnchor = anchor; awaitingUserAnchor = false
        setFollowing(false)
        return anchor
    }
    /// Top-oriented surfaces such as task lists do not follow a transcript tail.
    /// Discard the previous row intention so later layout cannot pull them back.
    func scrollToTop() {
        cancelCorrection()
        pendingReadingRestore = nil
        readingAnchor = nil; awaitingUserAnchor = false
        setFollowing(false)
        enqueue(.top, forceTarget: false)
    }
    func contentChanged() { geometryChanged() }

    /// Search and normal history retain independent reading positions.
    func navigate(scope newScope: String, preservingSharedHeaderID: String? = nil,
                  retainingGeometryIDs: Set<String> = []) {
        guard newScope != scope else { return }
        let sharedHeaderAnchor: Anchor?
        if let id = preservingSharedHeaderID, let frame = rows[id] {
            let top = offset - contentOrigin
            sharedHeaderAnchor = frame.maxY > top + 0.5 && frame.minY < top + viewportHeight
                ? Anchor(id: id, offset: top - frame.minY) : nil
        } else { sharedHeaderAnchor = nil }
        // Query updates can replace the SwiftUI row tree before onChange runs.
        // The last adopted reading anchor belongs to the old scope reliably;
        // a fresh geometry capture might already describe the new results.
        positions[scope] = Position(following: followingLatest,
                                    anchor: followingLatest ? nil : (readingAnchor ?? prepareForChange()))
        if positions.count > 12, let key = positions.keys.first(where: { !retainedScopes.contains($0) && $0 != newScope }) {
            positions.removeValue(forKey: key)
        }
        cancelCorrection()
        pendingReadingRestore = nil
        // Shared chrome can remain the same SwiftUI view at the same frame
        // across scopes. It need not emit onAppear/onGeometryChange again.
        // Retain its measurement independently of whether its old position is
        // preserved or this scope restores a different saved reading position.
        let retainedGeometry = rows.filter { retainingGeometryIDs.contains($0.key) }
        rows.removeAll(keepingCapacity: true)
        rows.merge(retainedGeometry) { _, retained in retained }
        scope = newScope
        let saved = positions[newScope]
        readingAnchor = sharedHeaderAnchor ?? saved?.anchor; awaitingUserAnchor = false
        setFollowing(sharedHeaderAnchor == nil && (saved?.following ?? (newScope == "history")))
        if followingLatest { enqueue(.latest, forceTarget: true) }
        else if let anchor = readingAnchor {
            // A retained shared header is already measured at its valid frame.
            // Avoid briefly proxy-scrolling it to zero before correcting back
            // to the preserved within-header offset on the next frame.
            enqueue(.reading(anchor), forceTarget: rows[anchor.id] == nil)
        }
        else { enqueue(.top, forceTarget: false) }
    }

    fileprivate func attach(probe: NSView, scroll newScroll: NSScrollView) {
        self.probe = probe
        if scroll === newScroll { geometryChanged(); return }
        detachObservers()
        observedGeometry.removeAll(keepingCapacity: true)
        scroll = newScroll
        newScroll.contentView.postsBoundsChangedNotifications = true
        newScroll.contentView.postsFrameChangedNotifications = true
        newScroll.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, object: AnyObject?, _ action: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { _ in action() })
        }
        observe(NSView.boundsDidChangeNotification, object: newScroll.contentView) { [weak self] in self?.boundsChanged() }
        observe(NSView.frameDidChangeNotification, object: newScroll.contentView) { [weak self] in self?.geometryChanged() }
        observe(NSView.frameDidChangeNotification, object: newScroll.documentView) { [weak self] in self?.geometryChanged() }
        observe(NSScrollView.willStartLiveScrollNotification, object: newScroll) { [weak self] in self?.beginUserScroll() }
        observe(NSScrollView.didLiveScrollNotification, object: newScroll) { [weak self] in self?.adoptUserPosition() }
        observe(NSScrollView.didEndLiveScrollNotification, object: newScroll) { [weak self] in self?.endUserScroll() }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let scroll = self.scroll, event.window === scroll.window else { return event }
            let point = scroll.convert(event.locationInWindow, from: nil)
            if event.type == .scrollWheel && scroll.bounds.contains(point) {
                self.beginUserScroll(); self.deferUserScrollEnd()
            } else if event.type == .keyDown, [115, 116, 119, 121, 125, 126].contains(Int(event.keyCode)),
                      let responder = scroll.window?.firstResponder as? NSView,
                      responder === scroll || responder.isDescendant(of: scroll) {
                self.beginUserScroll(); self.deferUserScrollEnd()
            }
            return event
        }
        lastViewport = newScroll.contentView.bounds.size
        lastDocumentHeight = documentHeight
        publishEdges(user: false)
        geometryChanged()
    }
    fileprivate func probeChanged(_ view: NSView) {
        if let owner = view.enclosingScrollView { attach(probe: view, scroll: owner) }
    }
    fileprivate func detach(probe view: NSView) {
        guard probe === view else { return }
        cancelCorrection(); pendingReadingRestore = nil; userScrolling = false
        detachObservers(); probe = nil; scroll = nil
    }

    private var documentHeight: CGFloat { scroll?.documentView?.bounds.height ?? 0 }
    private var viewportHeight: CGFloat { scroll?.contentView.bounds.height ?? 0 }
    private var maximumOffset: CGFloat { max(0, documentHeight - viewportHeight) }
    private var offset: CGFloat {
        guard let scroll, let document = scroll.documentView else { return 0 }
        let visible = scroll.contentView.bounds
        return document.isFlipped ? visible.minY : document.bounds.maxY - visible.maxY
    }
    private var contentOrigin: CGFloat {
        guard let probe, let document = scroll?.documentView else { return 0 }
        let rect = probe.convert(probe.bounds, to: document)
        return document.isFlipped ? rect.minY : document.bounds.maxY - rect.maxY
    }
    private var latestOffset: CGFloat {
        guard let tail = rows["picoLatest"] else { return maximumOffset }
        return min(maximumOffset, max(0, contentOrigin + tail.maxY - viewportHeight))
    }
    private func captureAnchor() -> Anchor? {
        let top = offset - contentOrigin
        let visibleBottom = top + viewportHeight
        let visible = rows.filter { $0.key != "picoLatest" && $0.value.maxY > top + 0.5 && $0.value.minY < visibleBottom }
        guard let first = visible.min(by: { lhs, rhs in
            lhs.value.minY == rhs.value.minY ? lhs.key < rhs.key : lhs.value.minY < rhs.value.minY
        }) else { return nil }
        return Anchor(id: first.key, offset: top - first.value.minY)
    }
    private func setFollowing(_ value: Bool) {
        guard followingLatest != value else { return }
        followingLatest = value
        onFollowingChanged?(value)
    }
    private func publishEdges(user: Bool) {
        let top = offset <= 2
        let bottom = offset >= latestOffset - 36
        if lastEdges?.bottom != bottom || lastEdges?.top != top {
            lastEdges = (bottom, top); onEdges?(bottom, top)
        }
        if !top { notifiedUserTop = false }
        if !bottom { notifiedUserBottom = false }
        if user && ((top && !notifiedUserTop) || (bottom && !notifiedUserBottom)) {
            notifiedUserTop = top; notifiedUserBottom = bottom
            onUserEdge?(top, bottom)
        }
    }
    private func boundsChanged() {
        guard let scroll else { return }
        let viewport = scroll.contentView.bounds.size
        let changedGeometry = viewport != lastViewport || abs(documentHeight - lastDocumentHeight) > 0.5
        lastViewport = viewport; lastDocumentHeight = documentHeight
        if applyingOffset { publishEdges(user: false); return }
        if userScrolling { adoptUserPosition(); return }
        if var motion = latestMotion {
            // Lazy estimation/defaultScrollAnchor can move the clip while
            // realizing new rows. Keep that bookkeeping from bypassing the
            // explicit motion with a visible one-frame jump.
            motion.position = min(maximumOffset, max(0, motion.position))
            latestMotion = motion
            applyOffset(motion.position)
            publishEdges(user: false)
            return
        }
        if changedGeometry { geometryChanged(); return }
        // SwiftUI also changes the native clip while reconciling lazy height
        // estimates. Only explicit wheel/key/live-scroll intent can replace a
        // reading anchor; otherwise a delayed layout adjustment looks like a
        // user moving to a different message.
        geometryChanged(force: true)
    }
    private func beginUserScroll() {
        if !userScrolling { pendingReadingRestore = nil }
        cancelCorrection(); userScrolling = true
    }
    private func deferUserScrollEnd() {
        userEnd?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.endUserScroll() }
        userEnd = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }
    private func endUserScroll() {
        // A native momentum gesture may end after an explicit button click.
        // Its stale end notification must not replace the new jump intention.
        if isAnimatingLatest && !userScrolling { return }
        userEnd?.cancel(); userEnd = nil
        userScrolling = false
        if let anchor = pendingReadingRestore {
            pendingReadingRestore = nil
            readingAnchor = anchor; awaitingUserAnchor = false
            setFollowing(false)
            enqueue(.reading(anchor), forceTarget: true)
            publishEdges(user: false)
        } else { adoptUserPosition() }
    }
    private func adoptUserPosition() {
        trace("adoptUserPosition")
        if pendingReadingRestore != nil {
            publishEdges(user: false)
            return
        }
        let atEnd = canFollowLatest && offset >= latestOffset - 36
        setFollowing(atEnd)
        let captured = atEnd ? nil : captureAnchor()
        readingAnchor = atEnd ? nil : (captured ?? readingAnchor)
        awaitingUserAnchor = !atEnd && captured == nil
        // Pagination callbacks must see the new anchor, not the previous row.
        publishEdges(user: !awaitingUserAnchor)
    }
    private func geometryChanged(force: Bool = false) {
        PicoDiag.track("scroll.geometry", "doc=\(Int(documentHeight)) view=\(Int(viewportHeight)) offset=\(Int(offset)) follow=\(followingLatest)")
        let viewport = scroll?.contentView.bounds.size ?? .zero
        let geometry = [viewport.width, viewport.height, documentHeight, contentOrigin]
        let widthChanged = !observedGeometry.isEmpty && abs(observedGeometry[0] - viewport.width) > 0.5
        let changed = observedGeometry.count != geometry.count || zip(observedGeometry, geometry).contains { abs($0 - $1) > 0.5 }
        observedGeometry = geometry
        guard force || changed else { return }
        if widthChanged { trace("widthChanged") }
        guard !userScrolling, !awaitingUserAnchor else { publishEdges(user: false); return }
        if latestMotion != nil { publishEdges(user: false); return }
        if followingLatest { enqueue(.latest, forceTarget: widthChanged) }
        else if let anchor = readingAnchor { enqueue(.reading(anchor), forceTarget: widthChanged) }
        else { publishEdges(user: false) }
    }
    private func enqueue(_ intent: Intent, forceTarget: Bool) {
        guard !userScrolling else { return }
        if correction?.intent != intent {
            trace("enqueue \(intent), force \(forceTarget)")
            correction = Correction(intent: intent, forceTarget: forceTarget)
        } else if forceTarget {
            correction?.forceTarget = true; correction?.requestedTarget = false
            correction?.targetRequests = 0; correction?.attempts = 0
            correction?.stablePasses = 0; correction?.lastGeometry = []
        }
        schedule()
    }
    private func cancelCorrection(notifyAnimationCancellation: Bool = true) {
        let interrupted = latestMotion != nil || animateLatestAfterRestore
        generation &+= 1; queued = false; correction = nil
        latestTimer?.invalidate(); latestTimer = nil; latestMotion = nil
        animateLatestAfterRestore = false
        if interrupted && notifyAnimationCancellation { onLatestAnimationCancelled?() }
    }
    private func applyOffset(_ target: CGFloat) {
        PicoDiag.track("scroll.applyOffset", "\(Int(target))")
        guard let scroll, let document = scroll.documentView else { return }
        let value = min(maximumOffset, max(0, target))
        guard abs(offset - value) > 0.01 else { return }
        applyingOffset = true
        var point = scroll.contentView.bounds.origin
        point.y = document.isFlipped ? value : document.bounds.maxY - viewportHeight - value
        scroll.contentView.scroll(to: point)
        scroll.reflectScrolledClipView(scroll.contentView)
        applyingOffset = false
    }
    private func animateLatestFrame() {
        guard !userScrolling, var motion = latestMotion, scroll != nil else { return }
        let clock = ProcessInfo.processInfo.systemUptime
        let step = min(0.05, max(0.001, clock - motion.lastTime))
        motion.lastTime = clock; motion.elapsed += step
        let target = latestOffset
        motion.position = min(maximumOffset, max(0, motion.position))
        // Analytic critically damped spring: no integration drift or overshoot,
        // with a fresh target for lazy row estimates, streaming and resizing.
        let omega: CGFloat = 17
        let displacement = motion.position - target
        let decay = CGFloat(exp(-Double(omega) * step))
        let coefficient = motion.velocity + omega * displacement
        let next = target + (displacement + coefficient * step) * decay
        motion.velocity = (motion.velocity - omega * coefficient * step) * decay
        motion.position = min(maximumOffset, max(0, next))
        if target >= offset { motion.position = min(target, max(offset, motion.position)) }
        latestMotion = motion
        applyOffset(motion.position)
        let stableTarget = motion.lastTarget.map { abs($0 - target) < 0.5 } ?? false
        motion.lastTarget = target
        motion.stablePasses = stableTarget && abs(offset - target) < 0.5 && abs(motion.velocity) < 3
            ? motion.stablePasses + 1 : 0
        latestMotion = motion
        lastViewport = scroll?.contentView.bounds.size ?? .zero; lastDocumentHeight = documentHeight
        publishEdges(user: false)
        guard reduceMotion() || motion.stablePasses >= 3 || motion.elapsed >= 2 else { return }
        latestTimer?.invalidate(); latestTimer = nil; latestMotion = nil
        applyOffset(latestOffset)
        // Subsequent automatic tail maintenance stays immediate. No repeated
        // proxy scrollTo may cut across the explicit button animation.
        enqueue(.latest, forceTarget: false)
        onLatestAnimationFinished?()
    }
    private func schedule() {
        guard !queued, correction != nil, scroll != nil else { return }
        queued = true
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self, self.generation == token else { return }
            self.queued = false; self.correct()
        }
    }
    private func correct() {
        guard !userScrolling, var work = correction, let scroll, let document = scroll.documentView else { return }
        trace("correct")
        if !work.requestedTarget {
            work.requestedTarget = true; correction = work
            let target: (String, UnitPoint)?
            switch work.intent {
            case .latest: target = work.forceTarget || rows["picoLatest"] == nil ? ("picoLatest", .bottom) : nil
            case .reading(let anchor): target = work.forceTarget || rows[anchor.id] == nil ? (anchor.id, .top) : nil
            case .top: target = nil
            }
            if let target, let scrollTo {
                work.targetRequests += 1; correction = work
                trace("proxy target \(target.0)")
                scrollTo(target.0, target.1); schedule(); return
            }
        }
        let target: CGFloat
        switch work.intent {
        case .latest: target = latestOffset
        case .top: target = 0
        case .reading(let anchor):
            guard let rect = rows[anchor.id] else {
                work.attempts += 1
                // A lazy stack may initially resolve an unseen ID against old
                // width estimates and realize a neighbouring row instead. Once
                // that geometry is known, ask for the same stable ID again.
                // Keep both requests and total waiting bounded.
                if work.attempts.isMultiple(of: 4), work.targetRequests < 4 {
                    work.requestedTarget = false
                }
                correction = work.attempts < 24 ? work : nil
                if correction == nil && animateLatestAfterRestore {
                    animateLatestAfterRestore = false
                    followLatest(animated: true)
                    return
                }
                schedule(); return
            }
            let withinRow = anchor.offset > 0 ? min(anchor.offset, max(0, rect.height - 1)) : anchor.offset
            target = min(maximumOffset, max(0, contentOrigin + rect.minY + withinRow))
        }
        if abs(offset - target) > 0.5 { applyOffset(target) }
        lastViewport = scroll.contentView.bounds.size; lastDocumentHeight = documentHeight
        let measured = [documentHeight, viewportHeight, lastViewport.width, target]
        let stable = measured.count == work.lastGeometry.count && zip(measured, work.lastGeometry).allSatisfy { abs($0 - $1) < 0.5 }
        work.stablePasses = stable && abs(offset - target) < 0.5 ? work.stablePasses + 1 : 0
        work.lastGeometry = measured; work.attempts += 1
        correction = work.stablePasses >= 2 || work.attempts >= 24 ? nil : work
        publishEdges(user: false)
        if correction == nil && animateLatestAfterRestore {
            animateLatestAfterRestore = false
            followLatest(animated: true)
            return
        }
        schedule()
    }
    private func detachObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil; userEnd?.cancel(); userEnd = nil
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        userEnd?.cancel()
        latestTimer?.invalidate()
    }
}

/// Background of the padded lazy content; its native origin is the bridge from
/// row rectangles in the named SwiftUI content space to the clip's document.
struct PicoChatScrollProbe: NSViewRepresentable {
    let controller: PicoChatScrollController
    func makeNSView(context: Context) -> PicoChatScrollProbeView {
        let view = PicoChatScrollProbeView(); view.controller = controller; return view
    }
    func updateNSView(_ view: PicoChatScrollProbeView, context: Context) {
        view.controller = controller; view.attachSoon()
    }
    static func dismantleNSView(_ view: PicoChatScrollProbeView, coordinator: ()) {
        view.controller?.detach(probe: view)
    }
}
final class PicoChatScrollProbeView: NSView {
    weak var controller: PicoChatScrollController?
    private var attachmentQueued = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attachSoon() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachSoon() }
    override func layout() { super.layout(); attachSoon() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); attachSoon() }
    func attachSoon() {
        guard !attachmentQueued else { return }
        attachmentQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachmentQueued = false; self.controller?.probeChanged(self)
        }
    }
}
